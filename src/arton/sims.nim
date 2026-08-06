## Deterministic Arton simulation core.
## All simulation math uses explicit 32-bit integers so native and WASM
## builds stay bit-identical. Floats appear only at compile time to
## bake the integer trig table.

import std/math, profiles

const
  TicksPerSecond* = 60'i32
  WorldWidth* = 1000'i32
  WorldHeight* = 1000'i32
  NeutralOwner* = 0'i32
  DefaultPlanetCount* = 24'i32
  DefaultPlayerCount* = 2'i32
  DefaultMaxTicks* = TicksPerSecond * 60 * 10
  PlanetSpawnMargin* = 48'i32
  PlanetSpacing* = 24'i32
  PlanetPlaceAttempts* = 1000'i32
  NeutralShipsMin* = 5'i32
  NeutralShipsMax* = 60'i32
  DefaultOffenseFactor* = 50'i32
  ## Planet radius in pixels and ship production interval in ticks,
  ## both indexed by PlanetSize. Bigger planets produce faster.
  PlanetRadii* = [16'i32, 24'i32, 32'i32]
  GrowthIntervals* = [112'i32, 75'i32, 45'i32]
  ## Ship positions use fixed point subpixels so movement stays
  ## integer only while still being smooth.
  SubpixelScale* = 256'i32
  ShipSpeedSubpixels* = 319'i32
  ShipRadiusPixels* = 9'i32
  ShipRadiusSubpixels* = ShipRadiusPixels * SubpixelScale
  ShipSpawnGapPixels* = 19'i32
  RingIntervalTicks* = 20'i32
  PushIterations* = 2'i32
  ## Cap on how far one push pass may move a ship. Pushes accumulate
  ## against a snapshot and apply capped, so crowded lanes cannot
  ## relay a ship across the map in one tick.
  PushMaxSubpixels* = 512'i32
  ## A spawn slot is blocked when another own ship is within this
  ## box. Smaller than the interaction diameter, so some overlap and
  ## pushing at the rim is fine, it just prevents overcrowding.
  SpawnBlockSubpixels* = 12'i32 * SubpixelScale
  ## Ship collision broadphase grid. Cells are bigger than the ship
  ## interaction diameter so only neighbor cells need checking.
  CollisionCellPixels* = 32'i32
  CollisionGridSide* = WorldWidth div CollisionCellPixels + 2
  CollisionCellCount* = CollisionGridSide * CollisionGridSide
  PlanetAvoidGatePixels* = 64'i32
  ## Integer trig: 256 headings around the circle, values scaled by
  ## TrigScale. Baked at compile time so runtime stays float free.
  HeadingCount* = 256'i32
  TrigScale* = 4096'i32
  ## How many heading steps a ship can rotate per tick. Fast enough
  ## that the turning circle stays smaller than the tightest landing
  ## ring, so ships can never orbit a planet they want to land on.
  TurnRateSteps* = 3'i32
  ## Stuck failsafe: a ship that barely moves for this many ticks
  ## phases out, ignoring all collision rules for a while, long
  ## enough to fly clear through anything it was wedged against.
  StuckLimitTicks* = 10'i32
  PhaseTicks* = 60'i32
  StuckSpeedSubpixels* = ShipSpeedSubpixels div 2
  SinTable* = block:
    var table: array[256, int32]
    for i in 0 ..< 256:
      table[i] = int32(round(sin(float(i) * 2.0 * PI / 256.0) * 4096.0))
    table

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
    ## Position and previous position in subpixels. Ships always fly
    ## forward along their heading and slowly turn toward the target,
    ## so they can be pushed around but never stall.
    x*: int32
    y*: int32
    prevX*: int32
    prevY*: int32
    heading*: int32
    ## Ticks spent flying. Older ships have priority: they push
    ## younger ships out of the way and hold their own course.
    age*: int32
    ## Ticks without real movement. Negative while the ship phases
    ## through everything to break out of a wedge.
    stuckTicks*: int32

  Wave* = object
    ## A send order that is still launching rings at its source rim.
    ownerId*: int32
    sourcePlanet*: int32
    targetPlanet*: int32
    shipsLeft*: int32
    cooldown*: int32

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

proc sin256*(heading: int32): int32 =
  ## Sine of a 256 step heading, scaled by TrigScale.
  return SinTable[heading and 255]

proc cos256*(heading: int32): int32 =
  ## Cosine of a 256 step heading, scaled by TrigScale.
  return SinTable[(heading + 64) and 255]

proc rotate(x, y, heading: int32): tuple[x, y: int32] =
  ## Rotates a small vector by a 256 step heading with integer trig.
  let
    c = cos256(heading)
    s = sin256(heading)
  return (
    (x * c - y * s) div TrigScale,
    (x * s + y * c) div TrigScale
  )

proc headingOf*(dx, dy: int32): int32 =
  ## Heading closest to the direction of a vector. Inputs must be
  ## pixel scale to stay clear of overflow. Rarely called, so the
  ## linear scan over all 256 headings is fine.
  var best = low(int32)
  for heading in 0'i32 ..< HeadingCount:
    let dot = cos256(heading) * dx + sin256(heading) * dy
    if dot > best:
      best = dot
      result = heading

proc turnToward(heading, dx, dy: int32): int32 =
  ## One tick of turning: rotates the heading up to TurnRateSteps
  ## toward the direction of (dx, dy). Inputs stay small enough that
  ## the cross and dot products fit 32 bits.
  let
    headingX = cos256(heading)
    headingY = sin256(heading)
    cross = headingX * dy - headingY * dx
    dot = headingX * dx + headingY * dy
  if cross > 0:
    return (heading + TurnRateSteps) and 255
  if cross < 0:
    return (heading - TurnRateSteps) and 255
  if dot >= 0:
    return heading
  # Dead behind: pick a fixed side so the choice is deterministic.
  return (heading + TurnRateSteps) and 255

proc spawnRing(sim: var Sim, wave: var Wave) =
  ## Launches one ring of ships around the source rim. A full ring
  ## holds as many ships as fit around the circumference, so bigger
  ## planets launch faster. A partial ring leaves as an arc centered
  ## on the direction the ships are going.
  let
    source = sim.planets[wave.sourcePlanet]
    target = sim.planets[wave.targetPlanet]
    dxPixels = target.x - source.x
    dyPixels = target.y - source.y
    distPixels = isqrt(dxPixels * dxPixels + dyPixels * dyPixels)
  if distPixels == 0:
    return
  let
    dirX = dxPixels * SubpixelScale div distPixels
    dirY = dyPixels * SubpixelScale div distPixels
    baseHeading = headingOf(dxPixels, dyPixels)
    spawnDistPixels = source.radius + ShipRadiusPixels + 2
    circumference = 628 * spawnDistPixels div 100
    capacity = max(circumference div ShipSpawnGapPixels, 1)
    count = min(min(wave.shipsLeft, source.ships), capacity)
    step = HeadingCount div capacity
  for i in 0 ..< count:
    # Slots alternate around the facing direction, so a partial ring
    # is an arc centered on it and a full ring closes the circle.
    # Every ship starts moving straight away from the planet and
    # turns toward the target over time.
    let
      side = (i + 1) div 2
      offset =
        if i mod 2 == 1:
          int32(side) * step
        else:
          -int32(side) * step
      spawnDir = rotate(dirX, dirY, offset)
      spawnX = source.x * SubpixelScale + spawnDir.x * spawnDistPixels
      spawnY = source.y * SubpixelScale + spawnDir.y * spawnDistPixels
      velX = spawnDir.x * ShipSpeedSubpixels div SubpixelScale
      velY = spawnDir.y * ShipSpeedSubpixels div SubpixelScale
    # A slot only spawns when it is mostly free. Ships already out
    # there, like an earlier wave passing the rim, block the slot and
    # those ships stay on the planet for a later ring. The check is
    # looser than the interaction diameter, so a little overlap and
    # pushing at spawn is fine, it just prevents overcrowding.
    var blocked = false
    for ship in sim.ships:
      if ship.ownerId != wave.ownerId:
        continue
      if abs(ship.x - spawnX) >= SpawnBlockSubpixels or
        abs(ship.y - spawnY) >= SpawnBlockSubpixels:
          continue
      blocked = true
      break
    if blocked:
      continue
    sim.ships.add(Ship(
      ownerId: wave.ownerId,
      targetPlanet: wave.targetPlanet,
      x: spawnX,
      y: spawnY,
      prevX: spawnX - velX,
      prevY: spawnY - velY,
      heading: (baseHeading + offset) and 255
    ))
    dec wave.shipsLeft
    dec sim.planets[wave.sourcePlanet].ships

proc spawnWaves(sim: var Sim) {.measure.} =
  ## Launches pending wave rings and drops finished or invalid waves.
  var kept: seq[Wave]
  for i in 0 ..< sim.waves.len:
    var wave = sim.waves[i]
    let source = sim.planets[wave.sourcePlanet]
    if source.ownerId != wave.ownerId or source.ships <= 0:
      continue
    if wave.cooldown > 0:
      dec wave.cooldown
    else:
      sim.spawnRing(wave)
      wave.cooldown = RingIntervalTicks
    if wave.shipsLeft > 0:
      kept.add(wave)
  sim.waves = kept

proc steerShips(sim: var Sim) {.measure.} =
  ## Moves every ship forward along its heading at full speed while
  ## the heading slowly rotates toward the target. Ships always move
  ## in their direction of travel, so they can never stall.
  for ship in sim.ships.mitems:
    # Stuck failsafe bookkeeping. Displacement over the whole last
    # tick, pushes and planet contact included. Barely moving for
    # too long flips the ship into phasing for a fixed window.
    let
      dispX = ship.x - ship.prevX
      dispY = ship.y - ship.prevY
      moved = dispX * dispX + dispY * dispY
    if ship.stuckTicks < 0:
      inc ship.stuckTicks
    elif moved < StuckSpeedSubpixels * StuckSpeedSubpixels:
      inc ship.stuckTicks
      if ship.stuckTicks > StuckLimitTicks:
        ship.stuckTicks = -PhaseTicks
    else:
      ship.stuckTicks = 0
    let
      target = sim.planets[ship.targetPlanet]
      dxPixels = target.x - ship.x div SubpixelScale
      dyPixels = target.y - ship.y div SubpixelScale
    ship.heading = turnToward(ship.heading, dxPixels, dyPixels)
    inc ship.age
    ship.prevX = ship.x
    ship.prevY = ship.y
    ship.x += cos256(ship.heading) * ShipSpeedSubpixels div TrigScale
    ship.y += sin256(ship.heading) * ShipSpeedSubpixels div TrigScale

proc pushPair(sim: Sim, i, j: int32,
    pushX, pushY: var seq[int32]) =
  ## Accumulates the separation push for one overlapping same player
  ## pair. Ships of different players pass through each other.
  if sim.ships[i].ownerId != sim.ships[j].ownerId:
    return
  # Phasing ships ignore all ship collision rules.
  if sim.ships[i].stuckTicks < 0 or sim.ships[j].stuckTicks < 0:
    return
  let
    dx = sim.ships[j].x - sim.ships[i].x
    dy = sim.ships[j].y - sim.ships[i].y
    minDist = ShipRadiusSubpixels * 2
  if abs(dx) >= minDist or abs(dy) >= minDist:
    return
  let distSq = dx * dx + dy * dy
  if distSq >= minDist * minDist:
    return
  var
    stepX = 0'i32
    stepY = 0'i32
  let dist = isqrt(distSq)
  if dist == 0:
    stepX = minDist div 2
  else:
    let overlap = minDist - dist
    stepX = dx * (overlap div 2) div dist
    stepY = dy * (overlap div 2) div dist
  # Priority queuing: the ship that has been flying longer holds its
  # course and the younger ship takes the whole push. Equal ages,
  # like ships from the same ring, split the push evenly. This keeps
  # crowds flowing instead of forming deadlocked shells.
  if sim.ships[i].age > sim.ships[j].age:
    pushX[j] += stepX * 2
    pushY[j] += stepY * 2
  elif sim.ships[j].age > sim.ships[i].age:
    pushX[i] -= stepX * 2
    pushY[i] -= stepY * 2
  else:
    pushX[i] -= stepX
    pushY[i] -= stepY
    pushX[j] += stepX
    pushY[j] += stepY

proc shipCell(ship: Ship): int32 =
  ## Grid cell index for a ship, clamped to the grid edges.
  let
    cellX = clamp(
      ship.x div SubpixelScale div CollisionCellPixels,
      0'i32,
      CollisionGridSide - 1
    )
    cellY = clamp(
      ship.y div SubpixelScale div CollisionCellPixels,
      0'i32,
      CollisionGridSide - 1
    )
  return cellY * CollisionGridSide + cellX

proc pushShips(sim: var Sim) {.measure.} =
  ## Pushes overlapping same player ships apart using a uniform grid
  ## broadphase: counting sort into cells, then only within cell and
  ## forward neighbor pairs. Deterministic order, no N squared scan.
  ## Pushes accumulate against a position snapshot and apply capped
  ## at the end, so a crowded lane cannot relay a ship far away.
  let shipCount = int32(sim.ships.len)
  if shipCount < 2:
    return
  var
    pushX = newSeq[int32](shipCount)
    pushY = newSeq[int32](shipCount)
    cellStart = newSeq[int32](CollisionCellCount + 1)
    order = newSeq[int32](shipCount)
  for i in 0 ..< shipCount:
    inc cellStart[sim.ships[i].shipCell + 1]
  for cell in 1 .. CollisionCellCount:
    cellStart[cell] += cellStart[cell - 1]
  var fill = cellStart
  for i in 0 ..< shipCount:
    let cell = sim.ships[i].shipCell
    order[fill[cell]] = i
    inc fill[cell]

  # Forward neighbor offsets cover every unordered cell pair once.
  const Neighbors = [
    [1'i32, 0'i32],
    [-1'i32, 1'i32],
    [0'i32, 1'i32],
    [1'i32, 1'i32]
  ]
  for cellY in 0 ..< CollisionGridSide:
    for cellX in 0 ..< CollisionGridSide:
      let cell = cellY * CollisionGridSide + cellX
      if cellStart[cell] == cellStart[cell + 1]:
        continue
      for a in cellStart[cell] ..< cellStart[cell + 1]:
        for b in a + 1 ..< cellStart[cell + 1]:
          sim.pushPair(order[a], order[b], pushX, pushY)
      for neighbor in Neighbors:
        let
          otherX = cellX + neighbor[0]
          otherY = cellY + neighbor[1]
        if otherX < 0 or otherX >= CollisionGridSide or
          otherY >= CollisionGridSide:
            continue
        let other = otherY * CollisionGridSide + otherX
        for a in cellStart[cell] ..< cellStart[cell + 1]:
          for b in cellStart[other] ..< cellStart[other + 1]:
            sim.pushPair(order[a], order[b], pushX, pushY)

  # Apply the accumulated pushes, capped per pass.
  for i in 0 ..< shipCount:
    var
      applyX = clamp(pushX[i], -16384'i32, 16384'i32)
      applyY = clamp(pushY[i], -16384'i32, 16384'i32)
    let mag = isqrt(applyX * applyX + applyY * applyY)
    if mag > PushMaxSubpixels:
      applyX = applyX * PushMaxSubpixels div mag
      applyY = applyY * PushMaxSubpixels div mag
    sim.ships[i].x += applyX
    sim.ships[i].y += applyY

proc avoidPlanets(sim: var Sim) {.measure.} =
  ## Keeps ships outside planets they are not landing on, so swarms
  ## flow around obstacles instead of tunneling through them.
  for ship in sim.ships.mitems:
    # Phasing ships fly straight through planets toward their target.
    if ship.stuckTicks < 0:
      continue
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
      # Contact. If the heading still points into the planet, turn
      # along the tangent the ship is already moving along, so it
      # slides around and never balances on the knife edge where the
      # target sits dead behind the planet. Momentum picks the side,
      # which cannot flicker, and turning at double rate means the
      # escape always beats the target steering pulling back in.
      let
        radialX = dx div SubpixelScale
        radialY = dy div SubpixelScale
        headingX = cos256(ship.heading)
        headingY = sin256(ship.heading)
        inward = headingX * radialX + headingY * radialY < 0
      if inward:
        let along = headingY * radialX - headingX * radialY
        var
          tangentX = -radialY
          tangentY = radialX
        if along < 0:
          tangentX = radialY
          tangentY = -radialX
        ship.heading = turnToward(ship.heading, tangentX, tangentY)
        ship.heading = turnToward(ship.heading, tangentX, tangentY)

proc landShips(sim: var Sim) {.measure.} =
  ## Annihilates ships that reached their target planet. Friendly
  ## arrivals reinforce, others attack and can flip the planet.
  var kept: seq[Ship]
  for ship in sim.ships:
    let
      planet = sim.planets[ship.targetPlanet]
      dxPixels = ship.x div SubpixelScale - planet.x
      dyPixels = ship.y div SubpixelScale - planet.y
      # Ships annihilate on rim contact, the same collision circle
      # that keeps passing ships out: planet radius + ship radius.
      contact = planet.radius + ShipRadiusPixels
      landed = abs(dxPixels) <= contact and
        abs(dyPixels) <= contact and
        dxPixels * dxPixels + dyPixels * dyPixels <
        contact * contact
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

proc producePlanets(sim: var Sim) {.measure.} =
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

proc tick*(sim: var Sim) {.measure.} =
  ## Advances the simulation by one tick with a fixed phase order.
  ## Does nothing once the match is decided.
  if sim.outcome != MatchOngoing:
    return
  inc sim.tickCount
  sim.spawnWaves()
  sim.steerShips()
  for i in 0 ..< PushIterations:
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
    hash.mix(ship.heading)
    hash.mix(ship.age)
    hash.mix(ship.stuckTicks)
  for wave in sim.waves:
    hash.mix(wave.ownerId)
    hash.mix(wave.sourcePlanet)
    hash.mix(wave.targetPlanet)
    hash.mix(wave.shipsLeft)
    hash.mix(wave.cooldown)
  return hash
