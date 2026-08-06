import std/unittest, arton

suite "rng":
  test "same seed gives same stream":
    var
      rngA = initRng(123)
      rngB = initRng(123)
    for i in 0 ..< 1000:
      check rngA.next() == rngB.next()

  test "zero seed is remapped":
    var rng = initRng(0)
    check rng.state != 0

suite "map generation":
  let config = initSimConfig(seed = 7)
  var sim = newSim(config)

  test "planet and player counts":
    check sim.planets.len == int(config.planetCount)
    check sim.players.len == int(config.playerCount)

  test "planets stay inside the world":
    for planet in sim.planets:
      check planet.x >= PlanetSpawnMargin
      check planet.x <= WorldWidth - PlanetSpawnMargin
      check planet.y >= PlanetSpawnMargin
      check planet.y <= WorldHeight - PlanetSpawnMargin

  test "starting ships are in range":
    for planet in sim.planets:
      check planet.ships >= NeutralShipsMin
      check planet.ships <= NeutralShipsMax

  test "planets do not overlap":
    for i in 0 ..< sim.planets.len:
      for j in i + 1 ..< sim.planets.len:
        let
          a = sim.planets[i]
          b = sim.planets[j]
          dx = a.x - b.x
          dy = a.y - b.y
          minDist = a.radius + b.radius + PlanetSpacing
        check dx * dx + dy * dy >= minDist * minDist

  test "each player owns exactly their home planet":
    var owned = 0
    for planet in sim.planets:
      if planet.ownerId != NeutralOwner:
        inc owned
    check owned == int(config.playerCount)
    for player in sim.players:
      check sim.planets[player.homePlanet].ownerId == player.id
      check player.offenseFactor == DefaultOffenseFactor

suite "ship production":
  test "player planet produces one ship per interval":
    var sim = newSim(initSimConfig(seed = 7))
    let
      home = sim.players[0].homePlanet
      startShips = sim.planets[home].ships
      interval = sim.planets[home].growthInterval
    for i in 0 ..< int(interval):
      sim.tick()
    check sim.planets[home].ships == startShips + 1

  test "neutral planets do not grow":
    var sim = newSim(initSimConfig(seed = 7))
    for i in 0 ..< 200:
      sim.tick()
    for planet in sim.planets:
      if planet.ownerId == NeutralOwner:
        check planet.growthTicks == 0

  test "bigger planets produce faster":
    check GrowthIntervals[ord(PlanetLarge)] <
      GrowthIntervals[ord(PlanetMedium)]
    check GrowthIntervals[ord(PlanetMedium)] <
      GrowthIntervals[ord(PlanetSmall)]

suite "determinism":
  test "same seed stays identical over 600 ticks":
    var
      simA = newSim(initSimConfig(seed = 42))
      simB = newSim(initSimConfig(seed = 42))
    check simA.stateHash() == simB.stateHash()
    for i in 0 ..< 600:
      simA.tick()
      simB.tick()
      check simA.stateHash() == simB.stateHash()

  test "different seeds give different maps":
    let
      simC = newSim(initSimConfig(seed = 1))
      simD = newSim(initSimConfig(seed = 2))
    check simC.stateHash() != simD.stateHash()
