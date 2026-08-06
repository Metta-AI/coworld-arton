## Nimmy AI agents. One script file drives one player. A script
## defines a tick() proc that gets called on a fixed cadence with the
## api below available:
##
## Read:  planets(), ships(), myId(), myOffense(), gameTick(),
##        mapWidth(), mapHeight(), selection()
## Act:   select(ids), selectAll(), sendTo(planetId),
##        setOffense(percent)
##
## The actions mirror the human controls: select any amount of your
## planets, send from the whole selection to one planet at a time.

import
  std/tables,
  nimmy,
  sims

const
  AgentIntervalTicks* = 15'i32

type
  Agent* = ref object
    ## A script driven player. A script that errors is disabled for
    ## the rest of the match, with the error kept for display.
    playerId*: int32
    selected*: seq[int32]
    ## Count of action calls the script made: select, selectAll,
    ## sendTo and setOffense.
    actions*: int
    failed*: bool
    error*: string
    vm: NimmyVM
    sim: ptr Sim

proc intArg(value: Value): int64 =
  ## Int from a script value, -1 for anything else.
  if value.kind == IntValue:
    return value.intVal
  return -1

proc planetIds(sim: Sim, args: seq[Value]): seq[int32] =
  ## Planet ids from script args: ints, or one array of ints.
  ## Out of range values are dropped.
  var raw: seq[int64]
  for arg in args:
    if arg.kind == ArrayValue:
      for item in arg.arrayVal:
        raw.add(intArg(item))
    else:
      raw.add(intArg(arg))
  for id in raw:
    if id >= 0 and id < int64(sim.planets.len):
      result.add(int32(id))

proc planetValue(planet: Planet): Value =
  ## Planet as a script object.
  result = objectValue("Planet")
  result.objFields["id"] = intValue(int64(planet.id))
  result.objFields["x"] = intValue(int64(planet.x))
  result.objFields["y"] = intValue(int64(planet.y))
  result.objFields["radius"] = intValue(int64(planet.radius))
  result.objFields["owner"] = intValue(int64(planet.ownerId))
  result.objFields["ships"] = intValue(int64(planet.ships))
  result.objFields["growth"] = intValue(int64(planet.growthInterval))

proc shipValue(ship: Ship): Value =
  ## Ship as a script object, positions in pixels.
  result = objectValue("Ship")
  result.objFields["owner"] = intValue(int64(ship.ownerId))
  result.objFields["target"] = intValue(int64(ship.targetPlanet))
  result.objFields["x"] = intValue(int64(ship.x div SubpixelScale))
  result.objFields["y"] = intValue(int64(ship.y div SubpixelScale))
  result.objFields["heading"] = intValue(int64(ship.heading))

proc live(agent: Agent): ptr Sim =
  ## The sim pointer, only valid while step is running.
  doAssert agent.sim != nil, "agent api used outside step"
  return agent.sim

proc register(agent: Agent) =
  ## Exposes the arton api to the agent's script vm.
  agent.vm.addProc("planets") do (args: seq[Value]) -> Value:
    var arr: seq[Value]
    for planet in agent.live[].planets:
      arr.add(planetValue(planet))
    arrayValue(arr)

  agent.vm.addProc("ships") do (args: seq[Value]) -> Value:
    var arr: seq[Value]
    for ship in agent.live[].ships:
      arr.add(shipValue(ship))
    arrayValue(arr)

  agent.vm.addProc("inbound") do (args: seq[Value]) -> Value:
    # inbound(planetId) counts every ship flying at the planet.
    # inbound(planetId, ownerId) counts one player's ships. Counting
    # natively keeps scripts fast and simple.
    if args.len < 1:
      return intValue(0)
    let target = intArg(args[0])
    var owner = -1'i64
    if args.len >= 2:
      owner = intArg(args[1])
    var count = 0'i64
    for ship in agent.live[].ships:
      if int64(ship.targetPlanet) == target:
        if owner == -1 or int64(ship.ownerId) == owner:
          inc count
    intValue(count)

  agent.vm.addProc("myId") do (args: seq[Value]) -> Value:
    intValue(int64(agent.playerId))

  agent.vm.addProc("myOffense") do (args: seq[Value]) -> Value:
    var factor = DefaultOffenseFactor
    for player in agent.live[].players:
      if player.id == agent.playerId:
        factor = player.offenseFactor
    intValue(int64(factor))

  agent.vm.addProc("gameTick") do (args: seq[Value]) -> Value:
    intValue(int64(agent.live[].tickCount))

  agent.vm.addProc("mapWidth") do (args: seq[Value]) -> Value:
    intValue(int64(WorldWidth))

  agent.vm.addProc("mapHeight") do (args: seq[Value]) -> Value:
    intValue(int64(WorldHeight))

  agent.vm.addProc("selection") do (args: seq[Value]) -> Value:
    var arr: seq[Value]
    for planetId in agent.selected:
      arr.add(intValue(int64(planetId)))
    arrayValue(arr)

  agent.vm.addProc("select") do (args: seq[Value]) -> Value:
    inc agent.actions
    agent.selected = @[]
    for planetId in agent.live[].planetIds(args):
      if agent.live[].planets[planetId].ownerId == agent.playerId and
        planetId notin agent.selected:
          agent.selected.add(planetId)
    nilValue()

  agent.vm.addProc("selectAll") do (args: seq[Value]) -> Value:
    inc agent.actions
    agent.selected = @[]
    for planet in agent.live[].planets:
      if planet.ownerId == agent.playerId:
        agent.selected.add(planet.id)
    nilValue()

  agent.vm.addProc("sendTo") do (args: seq[Value]) -> Value:
    inc agent.actions
    let targets = agent.live[].planetIds(args)
    if targets.len == 1:
      for sourceId in agent.selected:
        agent.live[].send(agent.playerId, sourceId, targets[0])
    nilValue()

  agent.vm.addProc("setOffense") do (args: seq[Value]) -> Value:
    inc agent.actions
    if args.len == 1:
      let factor = intArg(args[0])
      if factor >= 10 and factor <= 100:
        for player in agent.live[].players.mitems:
          if player.id == agent.playerId:
            player.offenseFactor = int32(factor)
    nilValue()

proc newAgent*(playerId: int32, source: string): Agent =
  ## Creates an agent and runs the script's top level once, which
  ## must define tick(). A broken script disables the agent.
  let agent = Agent(playerId: playerId, vm: newNimmyVM())
  agent.register()
  # The api is not available at the top level, only inside tick().
  try:
    discard agent.vm.run(source)
  except CatchableError as e:
    agent.failed = true
    agent.error = e.msg
  return agent

proc step*(agent: Agent, sim: var Sim) =
  ## Runs one AI decision by calling the script's tick() proc.
  ## Script errors disable the agent for the rest of the match.
  if agent.failed or sim.outcome != MatchOngoing:
    return
  agent.sim = addr sim
  # Drop selected planets the player no longer owns.
  var keep: seq[int32]
  for planetId in agent.selected:
    if sim.planets[planetId].ownerId == agent.playerId:
      keep.add(planetId)
  agent.selected = keep
  try:
    discard agent.vm.run("tick()")
  except CatchableError as e:
    agent.failed = true
    agent.error = e.msg
  agent.sim = nil
