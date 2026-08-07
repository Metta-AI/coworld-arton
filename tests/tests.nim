import std/unittest, arton/agents, arton/sims

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

  test "homes are large and distinct":
    let big = newSim(initSimConfig(seed = 9, playerCount = 4))
    var owners: seq[int32]
    for player in big.players:
      let home = big.planets[player.homePlanet]
      check home.ownerId == player.id
      check home.size == PlanetLarge
      check player.id notin owners
      owners.add(player.id)

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
    # The far neutral planet keeps the match ongoing, otherwise a
    # single player owning everything wins instantly and freezes.
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 1, 10),
        makePlanet(2, 1150, 100, PlanetSmall, NeutralOwner, 5)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 3000:
      sim.tick()
    check sim.waves.len == 0
    check sim.ships.len == 0
    let produced = 3000'i32 div GrowthIntervals[ord(PlanetSmall)]
    check sim.planets[0].ships == 40 - 40 + produced
    check sim.planets[1].ships == 10 + 40 + produced

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
        makePlanet(1, 500, 360, PlanetSmall, NeutralOwner, 10),
        makePlanet(2, 1150, 100, PlanetSmall, NeutralOwner, 5)
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
        # A ship that got wedged is allowed to phase through, so the
        # keep out rule only applies to ships that are not phasing.
        if ship.stuckTicks < 0:
          continue
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
        makePlanet(1, 500, 360, PlanetSmall, 1, 10),
        makePlanet(2, 1150, 100, PlanetSmall, NeutralOwner, 5)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 600:
      sim.tick()
      for ship in sim.ships:
        # Launch rings jostle near the rim, so only cruise speed out
        # in open space is bounded.
        var nearPlanet = false
        for planet in sim.planets:
          let
            dxPixels = ship.x div SubpixelScale - planet.x
            dyPixels = ship.y div SubpixelScale - planet.y
          if dxPixels * dxPixels + dyPixels * dyPixels < 60 * 60:
            nearPlanet = true
        if nearPlanet:
          continue
        # Young ships yielding to several older ships can take a few
        # full pushes in one tick, so the bound is loose. It exists
        # to catch runaway teleports, not push jostle.
        let
          velX = ship.x - ship.prevX
          velY = ship.y - ship.prevY
        check velX * velX + velY * velY <=
          64 * ShipSpeedSubpixels * ShipSpeedSubpixels

  test "same player ships keep apart in flight":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 1000, 360, PlanetSmall, 1, 10),
        makePlanet(2, 1150, 100, PlanetSmall, NeutralOwner, 5)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 400:
      sim.tick()
    proc nearAnyPlanet(ship: Ship): bool =
      ## Rim jostle and arrival funnels are allowed to compress.
      for planet in sim.planets:
        let
          dxPixels = ship.x div SubpixelScale - planet.x
          dyPixels = ship.y div SubpixelScale - planet.y
        if dxPixels * dxPixels + dyPixels * dyPixels < 60 * 60:
          return true
      return false
    var crowded = 0
    for i in 0 ..< sim.ships.len:
      for j in i + 1 ..< sim.ships.len:
        if sim.ships[i].nearAnyPlanet or sim.ships[j].nearAnyPlanet:
          continue
        let
          dx = sim.ships[j].x - sim.ships[i].x
          dy = sim.ships[j].y - sim.ships[i].y
        # Box gate before squaring so subpixel math cannot overflow.
        if abs(dx) >= ShipRadiusSubpixels or
          abs(dy) >= ShipRadiusSubpixels:
            continue
        if dx * dx + dy * dy <
          ShipRadiusSubpixels * ShipRadiusSubpixels:
            inc crowded
    check crowded == 0

suite "win and draw":
  test "capturing the last enemy planet wins":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 2, 5)
      ],
      @[
        Player(id: 1, homePlanet: 0, offenseFactor: 100),
        Player(id: 2, homePlanet: 1, offenseFactor: 100)
      ]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 3000:
      sim.tick()
    check sim.outcome == MatchWon
    check sim.winner == 1

  test "finished match freezes":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 2, 5)
      ],
      @[
        Player(id: 1, homePlanet: 0, offenseFactor: 100),
        Player(id: 2, homePlanet: 1, offenseFactor: 100)
      ]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 3000:
      sim.tick()
    let frozen = sim.stateHash()
    sim.tick()
    check sim.stateHash() == frozen

  test "ships in flight keep a player alive":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 60),
        makePlanet(1, 500, 360, PlanetSmall, 2, 20),
        makePlanet(2, 1050, 650, PlanetSmall, NeutralOwner, 1)
      ],
      @[
        Player(id: 1, homePlanet: 0, offenseFactor: 100),
        Player(id: 2, homePlanet: 1, offenseFactor: 100)
      ]
    )
    sim.send(2, 1, 2)
    sim.send(1, 0, 1)
    var sawLandlessAlive = false
    for i in 0 ..< 3000:
      sim.tick()
      var ownsAny = false
      for planet in sim.planets:
        if planet.ownerId == 2:
          ownsAny = true
      if not ownsAny and sim.outcome == MatchOngoing:
        sawLandlessAlive = true
    check sawLandlessAlive
    check sim.outcome == MatchOngoing
    check sim.planets[2].ownerId == 2

  test "draw when time runs out":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, 2, 40)
      ],
      @[
        Player(id: 1, homePlanet: 0, offenseFactor: 100),
        Player(id: 2, homePlanet: 1, offenseFactor: 100)
      ]
    )
    sim.config.maxTicks = 100
    for i in 0 ..< 200:
      sim.tick()
    check sim.outcome == MatchDraw
    check sim.tickCount == 100

  test "single player wins by taking every planet":
    var sim = makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, NeutralOwner, 5)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )
    sim.send(1, 0, 1)
    for i in 0 ..< 3000:
      sim.tick()
    check sim.outcome == MatchWon
    check sim.winner == 1

suite "agents":
  proc twoPlanetSim(): Sim =
    ## Player 1 with a strong planet next to a weak neutral.
    return makeSim(
      @[
        makePlanet(0, 200, 360, PlanetSmall, 1, 40),
        makePlanet(1, 500, 360, PlanetSmall, NeutralOwner, 5),
        makePlanet(2, 900, 100, PlanetSmall, NeutralOwner, 5)
      ],
      @[Player(id: 1, homePlanet: 0, offenseFactor: 100)]
    )

  test "script can select and send":
    var sim = twoPlanetSim()
    let agent = newAgent(1, """
proc tick() =
  if gameTick() == 0:
    selectAll()
    sendTo(1)
""")
    check not agent.failed
    agent.step(sim)
    check sim.waves.len == 1
    check sim.waves[0].targetPlanet == 1
    check sim.waves[0].shipsLeft == 40

  test "script reads planets and sets offense":
    var sim = twoPlanetSim()
    let agent = newAgent(1, """
proc tick() =
  var mine = 0
  for planet in planets():
    if planet.owner == myId():
      mine = mine + 1
  if mine == 1:
    setOffense(30)
""")
    agent.step(sim)
    check not agent.failed
    check sim.players[0].offenseFactor == 30

  test "selection only takes own planets":
    var sim = twoPlanetSim()
    let agent = newAgent(1, """
proc tick() =
  select([0, 1, 2])
  sendTo(1)
""")
    agent.step(sim)
    check not agent.failed
    check sim.waves.len == 1

  test "broken script disables the agent without crashing":
    var sim = twoPlanetSim()
    let agent = newAgent(1, """
proc tick() =
  explode()
""")
    check not agent.failed
    agent.step(sim)
    check agent.failed
    check agent.error.len > 0
    agent.step(sim)
    check sim.waves.len == 0

  test "grabber bot plays a whole match":
    var sim = twoPlanetSim()
    let agent = newAgent(1, readFile("players/grabber.nimmy"))
    check not agent.failed
    for i in 0 ..< 6000:
      if sim.tickCount mod AgentIntervalTicks == 0:
        agent.step(sim)
      sim.tick()
    check not agent.failed
    var owned = 0
    for planet in sim.planets:
      if planet.ownerId == 1:
        inc owned
    check owned == 3
    check sim.outcome == MatchWon

  test "agent driven matches are deterministic":
    proc playSim(): Sim =
      var sim = twoPlanetSim()
      let agent = newAgent(1, readFile("players/grabber.nimmy"))
      for i in 0 ..< 2000:
        if sim.tickCount mod AgentIntervalTicks == 0:
          agent.step(sim)
        sim.tick()
      return sim
    check playSim().stateHash() == playSim().stateHash()
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
