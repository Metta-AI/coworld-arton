import std/unittest, arton/sims

proc makePlanet(id, x, y: int32, size: PlanetSize,
    ownerId, ships: int32): Planet =
  ## Builds a planet for hand made test maps.
  return Planet(
    id: id,
    x: x,
    y: y,
    size: size,
    ownerId: ownerId,
    ships: ships
  )

proc makeSim(planets: seq[Planet], players: seq[Player]): Sim =
  ## Builds a sim from a hand made map.
  return Sim(
    config: initSimConfig(),
    rng: initRng(1),
    planets: planets,
    players: players
  )

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

suite "isqrt":
  test "known values":
    check isqrt(0) == 0
    check isqrt(1) == 1
    check isqrt(3) == 1
    check isqrt(4) == 2
    check isqrt(15) == 3
    check isqrt(16) == 4
    check isqrt(high(int32)) == 46340

suite "ship movement":
  test "friendly reinforcement is exact":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 1, 10)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 3000:
      sim.tick()
    check sim.waves.len == 0
    check sim.ships.len == 0
    check sim.planets[0].ships == 40 - 40 + 33
    check sim.planets[1].ships == 10 + 40 + 33

  test "offense factor scales the wave":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 1, 10)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 50)]
    )
    sim.send(1, 0, 1)
    check sim.waves[0].shipsLeft == 20

  test "attack flips a neutral planet":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, NeutralOwner, 10)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 3000:
      sim.tick()
    check sim.planets[1].ownerId == 1
    check sim.planets[1].ships > 0
    check sim.ships.len == 0

  test "enemy waves pass through each other":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 800, 360, PlanetSmall, 2, 40)
      ],
      @[
        Player(id: 1, homePlanet: 0, offenseFactor: 100),
        Player(id: 2, homePlanet: 1, offenseFactor: 100)
      ]
    )
    sim.send(1, 0, 1)
    sim.send(2, 1, 0)
    for i in 0 ..< 3000:
      sim.tick()
    check sim.planets[0].ownerId == 2
    check sim.planets[1].ownerId == 1

  test "ships go around planets in the way":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 30),
        makePlanet(1, 500, 360, PlanetLarge, NeutralOwner, 60),
        makePlanet(2, 800, 360, PlanetSmall, NeutralOwner, 5)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 2)
    for i in 0 ..< 3000:
      sim.tick()
      for ship in sim.ships:
        let
          dx = ship.x div SubpixelScale - sim.planets[1].x
          dy = ship.y div SubpixelScale - sim.planets[1].y
          minDist = sim.planets[1].radius - 1
        check dx * dx + dy * dy >= minDist * minDist
    check sim.planets[2].ownerId == 1

  test "ship speed stays bounded":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 1, 10)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 600:
      sim.tick()
      for ship in sim.ships:
        let
          velX = ship.x - ship.prevX
          velY = ship.y - ship.prevY
        check velX * velX + velY * velY <=
          9 * ShipSpeedSubpixels * ShipSpeedSubpixels

  test "same player ships keep apart in flight":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 1000, 360, PlanetSmall, 1, 10)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 400:
      sim.tick()
    var crowded = 0
    for i in 0 ..< sim.ships.len:
      for j in i + 1 ..< sim.ships.len:
        let
          dx = sim.ships[j].x - sim.ships[i].x
          dy = sim.ships[j].y - sim.ships[i].y
        if dx * dx + dy * dy <
          ShipRadiusSubpixels * ShipRadiusSubpixels:
            inc crowded
    check crowded == 0

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

  test "ships in flight stay identical":
    proc crossingSim(): Sim =
      ## Two players sending full waves at each other.
      var sim = makeSim(
        @[
          makePlanet(0, 200, 360, PlanetSmall, 1, 40),
          makePlanet(1, 800, 360, PlanetSmall, 2, 40)
        ],
        @[
          Player(id: 1, homePlanet: 0, offenseFactor: 100),
          Player(id: 2, homePlanet: 1, offenseFactor: 100)
        ]
      )
      sim.send(1, 0, 1)
      sim.send(2, 1, 0)
      return sim
    var
      simA = crossingSim()
      simB = crossingSim()
    for i in 0 ..< 1000:
      simA.tick()
      simB.tick()
      check simA.stateHash() == simB.stateHash()
