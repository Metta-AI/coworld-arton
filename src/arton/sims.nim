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
  ## Ship positions use fixed point subpixels so movement stays
  ## integer only while still being smooth.
  SubpixelScale* = 256'i32
  ShipSpeedSubpixels* = 204'i32
  ShipRadiusPixels* = 6'i32
  ShipRadiusSubpixels* = ShipRadiusPixels * SubpixelScale
  ShipSpawnGapPixels* = 13'i32
  ShipSpawnGapSubpixels* = ShipSpawnGapPixels * SubpixelScale
  SpawnIntervalTicks* = 2'i32
  PlanetAvoidGatePixels* = 64'i32

type
  ArtonError* = object of CatchableError

  Rng* = object
    ## Xorshift32 generator. Small, fast and identical on every target.
    state*: uint32

  PlanetSize* = enum
    PlanetSmall
    PlanetMedium
    PlanetLarge

  MatchOutcome* = enum
    MatchOngoing
    MatchWon
    MatchDraw

  Planet* = object
    id*: int32
    x*: int32
    y*: int32
    size*: PlanetSize
    ownerId*: int32
    ships*: int32
    growthTicks*: int32

  Ship* = object
    ownerId*: int32
    targetPlanet*: int32
    ## Position and previous position in subpixels. Velocity is the
    ## difference between them, verlet style.
    x*: int32
    y*: int32
    prevX*: int32
    prevY*: int32

  Wave* = object
    ## A send order that is still spawning ships at its source rim.
    ownerId*: int32
    sourcePlanet*: int32
    targetPlanet*: int32
    shipsLeft*: int32
    cooldown*: int32
    spawnIndex*: int32

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
    ships*: seq[Ship]
    waves*: seq[Wave]
    outcome*: MatchOutcome
    winner*: int32

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

proc isqrt*(value: int32): int32 =
  ## Deterministic integer square root.
  doAssert value >= 0, "isqrt needs a non negative value"
  var
    remaining = uint32(value)
    root = 0'u32
    bit = 1'u32 shl 30
  while bit > remaining:
    bit = bit shr 2
  while bit != 0:
    if remaining >= root + bit:
      remaining -= root + bit
      root = (root shr 1) + bit
    else:
      root = root shr 1
    bit = bit shr 2
  return int32(root)

proc send*(sim: var Sim, playerId, sourceId, targetId: int32) =
  ## Orders ships from a player's planet to another planet. The wave
  ## size is the source ship count scaled by the player's offense
  ## factor. Invalid orders are ignored.
  doAssert sourceId >= 0 and sourceId < int32(sim.planets.len),
    "sourceId out of range"
  doAssert targetId >= 0 and targetId < int32(sim.planets.len),
    "targetId out of range"
  if sourceId == targetId:
    return
  let source = sim.planets[sourceId]
  if source.ownerId != playerId:
    return
  var factor = DefaultOffenseFactor
  for player in sim.players:
    if player.id == playerId:
      factor = player.offenseFactor
  let count = source.ships * factor div 100
  if count <= 0:
    return
  sim.waves.add(Wave(
    ownerId: playerId,
    sourcePlanet: sourceId,
    targetPlanet: targetId,
    shipsLeft: count
  ))

proc spawnShip(sim: var Sim, wave: var Wave): bool =
  ## Tries to spawn one wave ship at the source rim, facing the target.
  ## Returns false when the launch arc has no room right now.
  let
    source = sim.planets[wave.sourcePlanet]
    target = sim.planets[wave.targetPlanet]
    dxPixels = target.x - source.x
    dyPixels = target.y - source.y
    distPixels = isqrt(dxPixels * dxPixels + dyPixels * dyPixels)
  if distPixels == 0:
    return false
  let
    dirX = dxPixels * SubpixelScale div distPixels
    dirY = dyPixels * SubpixelScale div distPixels
    maxSide = source.radius div ShipSpawnGapPixels
    slots = maxSide * 2 + 1
    slot = wave.spawnIndex mod slots
    side =
      if slot == 0:
        0'i32
      elif slot mod 2 == 1:
        (slot + 1) div 2
      else:
        -(slot div 2)
    spawnDistPixels = source.radius + ShipRadiusPixels + 2
    spawnX = source.x * SubpixelScale + dirX * spawnDistPixels +
      -dirY * side * ShipSpawnGapPixels
    spawnY = source.y * SubpixelScale + dirY * spawnDistPixels +
      dirX * side * ShipSpawnGapPixels
  for ship in sim.ships:
    if ship.ownerId != wave.ownerId:
      continue
    if abs(ship.x - spawnX) < ShipSpawnGapSubpixels and
      abs(ship.y - spawnY) < ShipSpawnGapSubpixels:
        return false
  let
    velX = dirX * ShipSpeedSubpixels div SubpixelScale
    velY = dirY * ShipSpeedSubpixels div SubpixelScale
  sim.ships.add(Ship(
    ownerId: wave.ownerId,
    targetPlanet: wave.targetPlanet,
    x: spawnX,
    y: spawnY,
    prevX: spawnX - velX,
    prevY: spawnY - velY
  ))
  inc wave.spawnIndex
  dec wave.shipsLeft
  dec sim.planets[wave.sourcePlanet].ships
  return true

proc spawnWaves(sim: var Sim) =
  ## Spawns pending wave ships and drops finished or invalid waves.
  var kept: seq[Wave]
  for i in 0 ..< sim.waves.len:
    var wave = sim.waves[i]
    let source = sim.planets[wave.sourcePlanet]
    if source.ownerId != wave.ownerId or source.ships <= 0:
      continue
    if wave.cooldown > 0:
      dec wave.cooldown
    elif sim.spawnShip(wave):
      wave.cooldown = SpawnIntervalTicks
    if wave.shipsLeft > 0:
      kept.add(wave)
  sim.waves = kept

proc steerShips(sim: var Sim) =
  ## Verlet moves every ship, steering it back toward its target so
  ## pushes can knock it off course but never off mission.
  for ship in sim.ships.mitems:
    let
      target = sim.planets[ship.targetPlanet]
      dx = target.x * SubpixelScale - ship.x
      dy = target.y * SubpixelScale - ship.y
      dxPixels = dx div SubpixelScale
      dyPixels = dy div SubpixelScale
      distPixels = isqrt(dxPixels * dxPixels + dyPixels * dyPixels)
    var
      velX = ship.x - ship.prevX
      velY = ship.y - ship.prevY
    if distPixels > 0:
      let
        desiredX = dx * ShipSpeedSubpixels div
          (distPixels * SubpixelScale)
        desiredY = dy * ShipSpeedSubpixels div
          (distPixels * SubpixelScale)
      velX = (velX * 3 + desiredX) div 4
      velY = (velY * 3 + desiredY) div 4
    let speed = isqrt(velX * velX + velY * velY)
    if speed > ShipSpeedSubpixels:
      velX = velX * ShipSpeedSubpixels div speed
      velY = velY * ShipSpeedSubpixels div speed
    ship.prevX = ship.x
    ship.prevY = ship.y
    ship.x += velX
    ship.y += velY

proc pushShips(sim: var Sim) =
  ## Pushes overlapping same player ships apart, sphere verlet style.
  ## Ships of different players pass through each other.
  for i in 0 ..< sim.ships.len:
    for j in i + 1 ..< sim.ships.len:
      if sim.ships[i].ownerId != sim.ships[j].ownerId:
        continue
      let
        dx = sim.ships[j].x - sim.ships[i].x
        dy = sim.ships[j].y - sim.ships[i].y
        minDist = ShipRadiusSubpixels * 2
      if abs(dx) >= minDist or abs(dy) >= minDist:
        continue
      let distSq = dx * dx + dy * dy
      if distSq >= minDist * minDist:
        continue
      var
        pushX = 0'i32
        pushY = 0'i32
      let dist = isqrt(distSq)
      if dist == 0:
        pushX = minDist div 2
      else:
        let overlap = minDist - dist
        pushX = dx * (overlap div 2) div dist
        pushY = dy * (overlap div 2) div dist
      sim.ships[i].x -= pushX
      sim.ships[i].y -= pushY
      sim.ships[j].x += pushX
      sim.ships[j].y += pushY

proc avoidPlanets(sim: var Sim) =
  ## Keeps ships outside planets they are not landing on, so swarms
  ## flow around obstacles instead of tunneling through them.
  for ship in sim.ships.mitems:
    for planet in sim.planets:
      if planet.id == ship.targetPlanet:
        continue
      let
        dxPixels = ship.x div SubpixelScale - planet.x
        dyPixels = ship.y div SubpixelScale - planet.y
      if abs(dxPixels) > PlanetAvoidGatePixels or
        abs(dyPixels) > PlanetAvoidGatePixels:
          continue
      let
        centerX = planet.x * SubpixelScale
        centerY = planet.y * SubpixelScale
        dx = ship.x - centerX
        dy = ship.y - centerY
        minDist = (planet.radius + ShipRadiusPixels) * SubpixelScale
        dist = isqrt(dx * dx + dy * dy)
      if dist >= minDist:
        continue
      if dist == 0:
        ship.x = centerX + minDist
        continue
      ship.x = centerX + dx * minDist div dist
      ship.y = centerY + dy * minDist div dist

proc landShips(sim: var Sim) =
  ## Annihilates ships that reached their target planet. Friendly
  ## arrivals reinforce, others attack and can flip the planet.
  var kept: seq[Ship]
  for ship in sim.ships:
    let
      planet = sim.planets[ship.targetPlanet]
      dxPixels = ship.x div SubpixelScale - planet.x
      dyPixels = ship.y div SubpixelScale - planet.y
      landed = abs(dxPixels) <= planet.radius and
        abs(dyPixels) <= planet.radius and
        dxPixels * dxPixels + dyPixels * dyPixels <
        planet.radius * planet.radius
    if not landed:
      kept.add(ship)
      continue
    if sim.planets[ship.targetPlanet].ownerId == ship.ownerId:
      inc sim.planets[ship.targetPlanet].ships
    elif sim.planets[ship.targetPlanet].ships == 0:
      sim.planets[ship.targetPlanet].ownerId = ship.ownerId
      sim.planets[ship.targetPlanet].growthTicks = 0
    else:
      dec sim.planets[ship.targetPlanet].ships
  sim.ships = kept

proc producePlanets(sim: var Sim) =
  ## Player planets produce ships at a rate based on their size,
  ## neutral planets do not.
  for planet in sim.planets.mitems:
    if planet.ownerId == NeutralOwner:
      continue
    inc planet.growthTicks
    if planet.growthTicks >= planet.growthInterval:
      planet.growthTicks = 0
      inc planet.ships

proc alive(sim: Sim, playerId: int32): bool =
  ## A player is alive while they own a planet, have ships in
  ## flight or still have a wave spawning.
  for planet in sim.planets:
    if planet.ownerId == playerId:
      return true
  for ship in sim.ships:
    if ship.ownerId == playerId:
      return true
  for wave in sim.waves:
    if wave.ownerId == playerId:
      return true
  return false

proc checkOutcome(sim: var Sim) =
  ## Decides the match. Single player wins by taking every planet,
  ## multiplayer by being the only player left alive. When time runs
  ## out first the match is a draw.
  if sim.players.len == 1:
    let playerId = sim.players[0].id
    var ownsAll = true
    for planet in sim.planets:
      if planet.ownerId != playerId:
        ownsAll = false
        break
    if ownsAll:
      sim.outcome = MatchWon
      sim.winner = playerId
      return
  elif sim.players.len > 1:
    var
      aliveCount = 0
      lastAlive = NeutralOwner
    for player in sim.players:
      if sim.alive(player.id):
        inc aliveCount
        lastAlive = player.id
    if aliveCount == 1:
      sim.outcome = MatchWon
      sim.winner = lastAlive
      return
    if aliveCount == 0:
      sim.outcome = MatchDraw
      return
  if sim.tickCount >= sim.config.maxTicks:
    sim.outcome = MatchDraw

proc tick*(sim: var Sim) =
  ## Advances the simulation by one tick with a fixed phase order.
  ## Does nothing once the match is decided.
  if sim.outcome != MatchOngoing:
    return
  inc sim.tickCount
  sim.spawnWaves()
  sim.steerShips()
  sim.pushShips()
  sim.avoidPlanets()
  sim.landShips()
  sim.producePlanets()
  sim.checkOutcome()

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
  hash.mix(int32(ord(sim.outcome)))
  hash.mix(sim.winner)
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
  for ship in sim.ships:
    hash.mix(ship.ownerId)
    hash.mix(ship.targetPlanet)
    hash.mix(ship.x)
    hash.mix(ship.y)
    hash.mix(ship.prevX)
    hash.mix(ship.prevY)
  for wave in sim.waves:
    hash.mix(wave.ownerId)
    hash.mix(wave.sourcePlanet)
    hash.mix(wave.targetPlanet)
    hash.mix(wave.shipsLeft)
    hash.mix(wave.cooldown)
    hash.mix(wave.spawnIndex)
  return hash
