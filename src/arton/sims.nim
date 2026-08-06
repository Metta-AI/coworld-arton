## Deterministic Arton simulation core.
## All simulation math uses explicit 32-bit integers so native and WASM
## builds stay bit-identical.

const
  TicksPerSecond* = 60'i32
  WorldWidth* = 1280'i32
  WorldHeight* = 720'i32
  NeutralOwner* = 0'i32
  DefaultPlanetCount* = 24'i32
  DefaultPlayerCount* = 2'i32
  DefaultMaxTicks* = TicksPerSecond * 60 * 5
  PlanetSpawnMargin* = 48'i32
  PlanetSpacing* = 24'i32
  PlanetPlaceAttempts* = 1000'i32
  NeutralShipsMin* = 5'i32
  NeutralShipsMax* = 60'i32
  DefaultOffenseFactor* = 100'i32
  ## Planet radius in pixels and ship production interval in ticks,
  ## both indexed by PlanetSize. Bigger planets produce faster.
  PlanetRadii* = [16'i32, 24'i32, 32'i32]
  GrowthIntervals* = [90'i32, 60'i32, 36'i32]

type
  ArtonError* = object of CatchableError

  Rng* = object
    ## Xorshift32 generator. Small, fast and identical on every target.
    state*: uint32

  PlanetSize* = enum
    PlanetSmall
    PlanetMedium
    PlanetLarge

  Planet* = object
    id*: int32
    x*: int32
    y*: int32
    size*: PlanetSize
    ownerId*: int32
    ships*: int32
    growthTicks*: int32

  Player* = object
    id*: int32
    homePlanet*: int32
    offenseFactor*: int32

  SimConfig* = object
    seed*: uint32
    planetCount*: int32
    playerCount*: int32
    maxTicks*: int32

  Sim* = object
    config*: SimConfig
    rng*: Rng
    tickCount*: int32
    planets*: seq[Planet]
    players*: seq[Player]

proc initRng*(seed: uint32): Rng =
  ## Creates a generator from a seed. Zero is remapped as xorshift32
  ## gets stuck on a zero state.
  if seed == 0:
    return Rng(state: 0x9E3779B9'u32)
  return Rng(state: seed)

proc next*(rng: var Rng): uint32 =
  ## Advances the generator and returns the next raw 32-bit value.
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  rng.state = x
  return x

proc randRange*(rng: var Rng, lo, hi: int32): int32 =
  ## Returns a value in lo .. hi inclusive.
  doAssert lo <= hi, "randRange needs lo <= hi"
  return lo + int32(rng.next() mod uint32(hi - lo + 1))

proc initSimConfig*(
  seed: uint32 = 1,
  planetCount: int32 = DefaultPlanetCount,
  playerCount: int32 = DefaultPlayerCount,
  maxTicks: int32 = DefaultMaxTicks
): SimConfig =
  ## Creates a simulation config with sensible defaults.
  return SimConfig(
    seed: seed,
    planetCount: planetCount,
    playerCount: playerCount,
    maxTicks: maxTicks
  )

proc radius*(planet: Planet): int32 =
  ## Returns the planet radius in pixels.
  return PlanetRadii[ord(planet.size)]

proc growthInterval*(planet: Planet): int32 =
  ## Returns ticks between produced ships for this planet size.
  return GrowthIntervals[ord(planet.size)]

proc overlaps(planets: seq[Planet], x, y, radius: int32): bool =
  ## Checks if a circle at x, y would sit too close to an existing planet.
  for other in planets:
    let
      dx = other.x - x
      dy = other.y - y
      minDist = other.radius + radius + PlanetSpacing
    if dx * dx + dy * dy < minDist * minDist:
      return true
  return false

proc placePlanet(sim: var Sim, id: int32): Planet =
  ## Finds a free spot for a new planet or raises ArtonError.
  let size = PlanetSize(sim.rng.randRange(0, 2))
  let radius = PlanetRadii[ord(size)]
  for attempt in 0 ..< PlanetPlaceAttempts:
    let
      x = sim.rng.randRange(PlanetSpawnMargin, WorldWidth - PlanetSpawnMargin)
      y = sim.rng.randRange(PlanetSpawnMargin, WorldHeight - PlanetSpawnMargin)
    if sim.planets.overlaps(x, y, radius):
      continue
    return Planet(
      id: id,
      x: x,
      y: y,
      size: size,
      ownerId: NeutralOwner,
      ships: sim.rng.randRange(NeutralShipsMin, NeutralShipsMax)
    )
  raise newException(ArtonError, "Could not place planet " & $id &
    ", map is too crowded")

proc newSim*(config: SimConfig): Sim =
  ## Creates a simulation with a map generated from the config seed.
  doAssert config.planetCount > 0, "planetCount must be positive"
  doAssert config.playerCount >= 0, "playerCount cannot be negative"
  doAssert config.playerCount <= config.planetCount,
    "more players than planets"
  var sim = Sim(config: config, rng: initRng(config.seed))
  for i in 0 ..< config.planetCount:
    sim.planets.add(sim.placePlanet(i))
  for playerId in 1'i32 .. config.playerCount:
    var homePlanet = sim.rng.randRange(0, config.planetCount - 1)
    while sim.planets[homePlanet].ownerId != NeutralOwner:
      homePlanet = sim.rng.randRange(0, config.planetCount - 1)
    sim.planets[homePlanet].ownerId = playerId
    sim.players.add(Player(
      id: playerId,
      homePlanet: homePlanet,
      offenseFactor: DefaultOffenseFactor
    ))
  return sim

proc tick*(sim: var Sim) =
  ## Advances the simulation by one tick. Player planets produce ships
  ## at a rate based on their size, neutral planets do not.
  inc sim.tickCount
  for planet in sim.planets.mitems:
    if planet.ownerId == NeutralOwner:
      continue
    inc planet.growthTicks
    if planet.growthTicks >= planet.growthInterval:
      planet.growthTicks = 0
      inc planet.ships

proc mix(hash: var uint32, value: int32) =
  ## Folds one value into an FNV-1a style hash.
  var bytes = cast[uint32](value)
  for i in 0 ..< 4:
    hash = hash xor (bytes and 0xFF'u32)
    hash = hash * 16777619'u32
    bytes = bytes shr 8

proc stateHash*(sim: Sim): uint32 =
  ## Hashes the full simulation state. Used to verify that two runs,
  ## or native and WASM builds, stay bit-identical.
  var hash = 2166136261'u32
  hash.mix(sim.tickCount)
  hash.mix(cast[int32](sim.rng.state))
  for planet in sim.planets:
    hash.mix(planet.id)
    hash.mix(planet.x)
    hash.mix(planet.y)
    hash.mix(int32(ord(planet.size)))
    hash.mix(planet.ownerId)
    hash.mix(planet.ships)
    hash.mix(planet.growthTicks)
  for player in sim.players:
    hash.mix(player.id)
    hash.mix(player.homePlanet)
    hash.mix(player.offenseFactor)
  return hash
