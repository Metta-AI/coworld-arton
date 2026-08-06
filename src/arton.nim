## Arton, an ink wash strategy game for AIs. Dev graphics app.
## Run from the repo root: nim r src/arton.nim
## Headless screenshot: nim r src/arton.nim --shot=out.png --ticks=900 --demo

import
  std/[math, os, strformat, strutils, times],
  boxy, bumpy, opengl, pixie, windy,
  arton/agents, arton/sims

const
  FontPath = "data/IBMPlexSans-Regular.ttf"
  TickSeconds = 1.0 / float64(TicksPerSecond)
  DragThreshold = 5.0'f32
  ClickPadPixels = 6.0'f32
  DemoIntervalTicks = 240'i32
  HumanPlayer = 1'i32
  NeutralFill = rgba(200, 200, 200, 255)
  NeutralStroke = rgba(90, 90, 90, 255)
  ## Player one sits at this hue, the rest spread evenly around the
  ## color wheel, so any number of players get distinct colors.
  FirstPlayerHue = 280.0'f32
  SelectionColor = rgba(120, 40, 180, 255)
  HudColor = rgba(20, 20, 20, 255)

var
  sim: Sim
  aiAgents: seq[Agent]
  selected: seq[int32]
  dragStart: Vec2
  dragging = false
  dragFromPlanet = -1'i32
  suppressClick = false
  demoEnabled = false
  shotIndex = 0
  hudSpeed = 1.0

proc aiPaths(): seq[string] =
  ## Script paths from repeated --ai=path arguments. Every flag adds
  ## one AI player, and a :count suffix adds that many copies, so
  ## --ai=players/alpha.nimmy:5 is five of the same player.
  for param in commandLineParams():
    if param.startsWith("--ai="):
      var
        path = param[5 .. ^1]
        count = 1
      let colon = path.rfind(':')
      if colon != -1:
        let tail = path[colon + 1 .. ^1]
        if tail.len > 0 and allCharsInSet(tail, Digits):
          count = parseInt(tail)
          path = path[0 ..< colon]
      for i in 0 ..< count:
        result.add(path)

proc gameClock(tick: int32): string =
  ## Game time as m:ss from a tick count.
  let seconds = tick div TicksPerSecond
  return $(seconds div 60) & ":" & align($(seconds mod 60), 2, '0')

proc speedFlag(): float64 =
  ## Sim speed multiplier from --speed=N. 1 is human time. Ignored
  ## in headless mode, which always runs as fast as possible.
  result = 1.0
  for param in commandLineParams():
    if param.startsWith("--speed="):
      result = float64(parseInt(param.split("=")[1]))

proc maxTicksFlag(): int32 =
  ## Game end tick from --maxTicks=N, when a match becomes a draw.
  result = DefaultMaxTicks
  for param in commandLineParams():
    if param.startsWith("--maxTicks="):
      result = int32(parseInt(param.split("=")[1]))

proc planetsFlag(playerCount: int32): int32 =
  ## Planet count from --planets:N (or --planets=N), never below the
  ## player count so everyone still gets a home planet.
  result = DefaultPlanetCount
  for param in commandLineParams():
    if param.startsWith("--planets") and param.len > 10:
      let sep = param[9]
      if sep == ':' or sep == '=':
        result = int32(parseInt(param[10 .. ^1]))
  result = max(result, playerCount)

proc aiPlayerCount(): int32 =
  ## Players in the game: every --ai flag adds an AI player and every
  ## --player flag adds a human slot, at least two players total.
  ## Human slots come first, so the human is always player 1.
  var humans = 0
  for param in commandLineParams():
    if param == "--player":
      inc humans
  return max(DefaultPlayerCount, int32(aiPaths().len + humans))

proc loadAgents(playerCount: int32): seq[Agent] =
  ## Loads the AI scripts into the last player slots: a single AI
  ## plays the human as player 2, two AIs play each other as players
  ## 1 and 2, and so on.
  let paths = aiPaths()
  for i, path in paths:
    let
      playerId = playerCount - int32(paths.len) + int32(i) + 1
      agent = newAgent(playerId, readFile(path))
    if agent.failed:
      echo "AI for player ", playerId, " failed to load: ", agent.error
    else:
      echo "AI for player ", playerId, ": ", path
    result.add(agent)

proc stepAgents(sim: var Sim) =
  ## Runs every AI script on its fixed cadence.
  if sim.tickCount mod AgentIntervalTicks != 0:
    return
  for agent in aiAgents:
    let wasFailed = agent.failed
    agent.step(sim)
    if agent.failed and not wasFailed:
      echo "AI for player ", agent.playerId, " crashed: ", agent.error

proc playerHue(ownerId: int32): float32 =
  ## The owner's spot on the color wheel, hues spaced evenly by the
  ## number of players in the game.
  let count = max(sim.players.len, 1)
  let slice = 360.0'f32 / float32(count)
  var hue = FirstPlayerHue + float32(ownerId - 1) * slice
  while hue >= 360.0'f32:
    hue -= 360.0'f32
  return hue

proc fillColor(ownerId: int32): ColorRGBA =
  ## Planet fill color for an owner: a light pastel of their hue.
  ## Every other player slot is a bit deeper, so players whose hues
  ## ended up close still read as different colors.
  if ownerId == NeutralOwner:
    return NeutralFill
  if ownerId mod 2 == 1:
    return hsv(playerHue(ownerId), 35, 97).color.rgba
  return hsv(playerHue(ownerId), 52, 88).color.rgba

proc strokeColor(ownerId: int32): ColorRGBA =
  ## Planet outline and ship color for an owner: a strong version of
  ## their hue, alternating bright and dark between player slots.
  if ownerId == NeutralOwner:
    return NeutralStroke
  if ownerId mod 2 == 1:
    return hsv(playerHue(ownerId), 82, 76).color.rgba
  return hsv(playerHue(ownerId), 95, 52).color.rgba

proc offenseFactor(sim: Sim, playerId: int32): int32 =
  ## Reads a player's offense factor.
  for player in sim.players:
    if player.id == playerId:
      return player.offenseFactor
  return DefaultOffenseFactor

proc setOffenseFactor(sim: var Sim, playerId, factor: int32) =
  ## Sets a player's offense factor.
  for player in sim.players.mitems:
    if player.id == playerId:
      player.offenseFactor = factor

proc planetAt(sim: Sim, pos: Vec2): int32 =
  ## Planet under a world position or -1. Includes click padding.
  for planet in sim.planets:
    let
      dx = pos.x - float32(planet.x)
      dy = pos.y - float32(planet.y)
      reach = float32(planet.radius) + ClickPadPixels
    if dx * dx + dy * dy <= reach * reach:
      return planet.id
  return -1

proc ownPlanets(sim: Sim, playerId: int32): seq[int32] =
  ## Ids of every planet the player owns.
  for planet in sim.planets:
    if planet.ownerId == playerId:
      result.add(planet.id)

proc demoOrders(sim: var Sim, playerId: int32) =
  ## Scripted sends so playtests and screenshots have ship traffic:
  ## every few seconds the strongest planet attacks the nearest
  ## planet the player does not own.
  if sim.tickCount mod DemoIntervalTicks != 0:
    return
  var
    source = -1'i32
    sourceShips = 0'i32
  for planet in sim.planets:
    if planet.ownerId == playerId and planet.ships > sourceShips:
      source = planet.id
      sourceShips = planet.ships
  if source == -1:
    return
  var
    target = -1'i32
    bestDist = high(int32)
  for planet in sim.planets:
    if planet.ownerId == playerId:
      continue
    let
      dx = planet.x - sim.planets[source].x
      dy = planet.y - sim.planets[source].y
      dist = dx * dx + dy * dy
    if dist < bestDist:
      target = planet.id
      bestDist = dist
  if target != -1:
    sim.send(playerId, source, target)

proc renderFrame(sim: Sim, selected: seq[int32], boxRect: Rect,
    showBox: bool, dragTarget: int32, dragSources: seq[int32],
    pixelScale: float32 = 1.0): Image =
  ## Draws the whole sim in world coordinates, scaled up to the real
  ## output pixel size so nothing gets blurry. Dev graphics only:
  ## flat circles, triangle ships and plain text on white.
  result = newImage(
    int(float32(WorldWidth) * pixelScale),
    int(float32(WorldHeight) * pixelScale)
  )
  result.fill(rgba(255, 255, 255, 255))
  let ctx = newContext(result)
  ctx.scale(vec2(pixelScale, pixelScale))
  ctx.font = FontPath

  for planet in sim.planets:
    let center = vec2(float32(planet.x), float32(planet.y))
    ctx.fillStyle = fillColor(planet.ownerId)
    ctx.fillCircle(circle(center, float32(planet.radius)))
    ctx.strokeStyle = strokeColor(planet.ownerId)
    ctx.lineWidth = 2
    ctx.strokeCircle(circle(center, float32(planet.radius)))

  for planetId in selected:
    let planet = sim.planets[planetId]
    ctx.strokeStyle = SelectionColor
    ctx.lineWidth = 3
    ctx.strokeCircle(circle(
      vec2(float32(planet.x), float32(planet.y)),
      float32(planet.radius) + 5
    ))

  if dragTarget != -1 and dragSources.len > 0:
    # Targeting lines snap to the target planet, which also gets a
    # highlight ring. No snapped planet, no lines at all.
    let
      target = sim.planets[dragTarget]
      targetCenter = vec2(float32(target.x), float32(target.y))
    var anyLine = false
    ctx.strokeStyle = SelectionColor
    ctx.lineWidth = 2
    for planetId in dragSources:
      if planetId == dragTarget:
        continue
      let
        planet = sim.planets[planetId]
        center = vec2(float32(planet.x), float32(planet.y))
        gap = (targetCenter - center).length
        sourceEdge = float32(planet.radius) + 5
        targetEdge = float32(target.radius) + 5
      # Ring to ring, not center to center. Skip if they overlap.
      if gap <= sourceEdge + targetEdge:
        continue
      anyLine = true
      let dir = (targetCenter - center) / gap
      ctx.strokeSegment(segment(
        center + dir * sourceEdge,
        targetCenter - dir * targetEdge
      ))
    if anyLine:
      ctx.lineWidth = 3
      ctx.strokeCircle(circle(
        targetCenter,
        float32(target.radius) + 5
      ))

  for ship in sim.ships:
    let
      x = float32(ship.x) / float32(SubpixelScale)
      y = float32(ship.y) / float32(SubpixelScale)
      angle = float32(ship.heading) * 2.0'f * PI / 256.0'f
    ctx.save()
    ctx.translate(vec2(x, y))
    ctx.rotate(angle)
    ctx.strokeStyle = strokeColor(ship.ownerId)
    ctx.lineWidth = 2
    # An open V pointing at the target, wings swept back.
    let path = newPath()
    path.moveTo(-6, -5)
    path.lineTo(8, 0)
    path.lineTo(-6, 5)
    ctx.stroke(path)
    ctx.restore()

  ctx.fillStyle = HudColor
  ctx.fontSize = 14
  for planet in sim.planets:
    let
      label = $planet.ships
      metrics = ctx.measureText(label)
    # Centered on the planet, baseline nudged for optical center.
    ctx.fillText(label, vec2(
      float32(planet.x) - metrics.width / 2,
      float32(planet.y) + 5
    ))

  if showBox:
    ctx.strokeStyle = SelectionColor
    ctx.lineWidth = 1
    ctx.strokeRect(boxRect)

  ctx.fontSize = 16
  ctx.fillStyle = HudColor
  let hud = &"offense {sim.offenseFactor(HumanPlayer)}%  " &
    &"time {gameClock(sim.tickCount)}  " &
    &"tick {sim.tickCount}  " &
    &"speed {hudSpeed}x  " &
    &"demo {(if demoEnabled: \"on\" else: \"off\")} (D)  " &
    "screenshot (F2)"
  ctx.fillText(hud, vec2(10, 24))

  if sim.outcome != MatchOngoing:
    let banner =
      if sim.outcome == MatchDraw:
        "Draw"
      else:
        &"Player {sim.winner} wins!"
    ctx.fontSize = 48
    ctx.fillStyle =
      if sim.outcome == MatchWon:
        strokeColor(sim.winner)
      else:
        HudColor
    let metrics = ctx.measureText(banner)
    ctx.fillText(banner, vec2(
      float32(WorldWidth) / 2 - metrics.width / 2,
      float32(WorldHeight) / 2 - 24
    ))

proc takeScreenshot(frame: Image) =
  ## Saves the current frame as a png without any OS tools.
  createDir("screenshots")
  let path = &"screenshots/shot_{shotIndex}_tick_{sim.tickCount}.png"
  frame.writeFile(path)
  inc shotIndex
  echo "Saved ", path

proc boxRectNow(mouseWorld: Vec2): Rect =
  ## Rect between the drag start and the mouse, any drag direction.
  let
    lo = vec2(min(dragStart.x, mouseWorld.x), min(dragStart.y, mouseWorld.y))
    hi = vec2(max(dragStart.x, mouseWorld.x), max(dragStart.y, mouseWorld.y))
  return rect(lo, hi - lo)

proc runHeadless(shotPath: string) =
  ## Runs the sim without a window as fast as possible and prints
  ## the result. With a shot path it also writes one screenshot.
  var
    ticks = -1
    seed = 1'u32
    demo = false
  for param in commandLineParams():
    if param.startsWith("--ticks="):
      ticks = parseInt(param.split("=")[1])
    elif param.startsWith("--seed="):
      seed = uint32(parseInt(param.split("=")[1]))
    elif param == "--demo":
      demo = true
  sim = newSim(initSimConfig(
    seed = seed,
    planetCount = planetsFlag(aiPlayerCount()),
    playerCount = aiPlayerCount(),
    maxTicks = maxTicksFlag()
  ))
  aiAgents = loadAgents(sim.config.playerCount)
  if ticks == -1:
    ticks = int(sim.config.maxTicks)
  echo "map: ", sim.config.planetCount, " planets, ",
    sim.config.playerCount, " players"
  echo "game speed: as fast as possible, one game second is ",
    TicksPerSecond, " ticks, game ends at tick ", sim.config.maxTicks,
    " (", gameClock(sim.config.maxTicks), ")"
  let start = epochTime()
  for i in 0 ..< ticks:
    if sim.outcome != MatchOngoing:
      break
    if demo:
      for player in 1'i32 .. sim.config.playerCount:
        sim.demoOrders(player)
    stepAgents(sim)
    sim.tick()
  let elapsed = epochTime() - start

  echo "result: ", sim.outcome,
    (if sim.outcome == MatchWon: " player " & $sim.winner else: ""),
    " at tick ", sim.tickCount, " (game time ",
    gameClock(sim.tickCount), ")"
  for player in sim.players:
    var
      planetCount = 0
      shipCount = 0'i32
    for planet in sim.planets:
      if planet.ownerId == player.id:
        inc planetCount
        shipCount += planet.ships
    for ship in sim.ships:
      if ship.ownerId == player.id:
        inc shipCount
    var note = ""
    for agent in aiAgents:
      if agent.playerId == player.id and agent.failed:
        note = "  CRASHED: " & agent.error
    echo "player ", player.id, ": ", planetCount, " planets, ",
      shipCount, " ships", note
  echo "elapsed ", formatFloat(elapsed, ffDecimal, 2), "s, ",
    int(float(sim.tickCount) / max(elapsed, 0.001)), " ticks/s"
  if shotPath != "":
    let frame = sim.renderFrame(@[], rect(0, 0, 0, 0), false, -1, @[])
    frame.writeFile(shotPath)
    echo "Saved ", shotPath, " at tick ", sim.tickCount
  quit(0)

proc determinismHash(): uint32 =
  ## Hash of a fixed scripted match. Printed on every start so the
  ## native and WASM builds can be compared for bit identical sims.
  var sim = newSim(initSimConfig(seed = 1))
  for i in 0 ..< 600:
    for player in 1'i32 .. sim.config.playerCount:
      sim.demoOrders(player)
    sim.tick()
  return sim.stateHash()

echo "determinism hash ", determinismHash()

block:
  var
    shotPath = ""
    noWindow = false
  for param in commandLineParams():
    if param.startsWith("--shot="):
      shotPath = param.split("=")[1]
    elif param == "--noWindow":
      noWindow = true
  if shotPath != "" or noWindow:
    runHeadless(shotPath)

sim = newSim(initSimConfig(
  seed = 1,
  planetCount = planetsFlag(aiPlayerCount()),
  playerCount = aiPlayerCount(),
  maxTicks = maxTicksFlag()
))
aiAgents = loadAgents(sim.config.playerCount)
let speedMultiplier = speedFlag()
hudSpeed = speedMultiplier
echo "map: ", sim.config.planetCount, " planets, ",
  sim.config.playerCount, " players"
echo "game speed: ", speedMultiplier, "x, one game second is ",
  TicksPerSecond, " ticks, game ends at tick ", sim.config.maxTicks,
  " (", gameClock(sim.config.maxTicks), ")"

let window = newWindow(
  "Arton",
  ivec2(WorldWidth, WorldHeight),
  vsync = true
)
makeContextCurrent(window)
loadExtensions()
let bxy = newBoxy()

proc viewTransform(windowSize: IVec2): tuple[scale: float32, offset: Vec2] =
  ## Uniform world to window scale and the letterbox offset that
  ## keeps the world aspect ratio on any window size.
  let
    size = windowSize.vec2
    scale = min(
      size.x / float32(WorldWidth),
      size.y / float32(WorldHeight)
    )
    drawSize = vec2(float32(WorldWidth), float32(WorldHeight)) * scale
  return (scale, (size - drawSize) / 2)

proc mouseWorld(): Vec2 =
  ## Mouse position in world pixels regardless of dpi scale or
  ## letterboxing.
  let view = viewTransform(window.size)
  return (window.mousePos.vec2 - view.offset) / view.scale

proc shiftDown(): bool =
  ## True while either shift key is held.
  return window.buttonDown[KeyLeftShift] or
    window.buttonDown[KeyRightShift]

proc snapTarget(pos: Vec2): int32 =
  ## Planet a send drag snaps to: the nearest planet whose center is
  ## within three of its radii of the cursor, or -1 for none.
  result = -1
  var best = 1e9'f32
  for planet in sim.planets:
    let
      center = vec2(float32(planet.x), float32(planet.y))
      dist = (pos - center).length
    if dist <= float32(planet.radius) * 3 and dist < best:
      best = dist
      result = planet.id

proc handleBoxSelect(boxRect: Rect) =
  ## Box select: own planets whose circle touches the rect at all,
  ## not just their center. Shift adds.
  if not shiftDown():
    selected = @[]
  for planet in sim.planets:
    if planet.ownerId != HumanPlayer:
      continue
    let
      center = vec2(float32(planet.x), float32(planet.y))
      closest = vec2(
        clamp(center.x, boxRect.x, boxRect.x + boxRect.w),
        clamp(center.y, boxRect.y, boxRect.y + boxRect.h)
      )
      radius = float32(planet.radius)
    if (center - closest).lengthSq <= radius * radius and
      planet.id notin selected:
        selected.add(planet.id)

window.onButtonPress = proc(button: Button) =
  case button
  of DoubleClick:
    selected = sim.ownPlanets(HumanPlayer)
    suppressClick = true
  of MouseLeft:
    dragStart = mouseWorld()
    dragging = true
    let planetId = sim.planetAt(dragStart)
    if planetId != -1 and
      sim.planets[planetId].ownerId == HumanPlayer:
        dragFromPlanet = planetId
        # Selection updates on press. A plain press on a planet that
        # is not selected replaces the selection, shift press adds.
        # Pressing an already selected planet keeps the group, so a
        # drag can send from the whole selection.
        if planetId notin selected:
          if shiftDown():
            selected.add(planetId)
          else:
            selected = @[planetId]
    else:
      dragFromPlanet = -1
  of Key1: sim.setOffenseFactor(HumanPlayer, 10)
  of Key2: sim.setOffenseFactor(HumanPlayer, 20)
  of Key3: sim.setOffenseFactor(HumanPlayer, 30)
  of Key4: sim.setOffenseFactor(HumanPlayer, 40)
  of Key5: sim.setOffenseFactor(HumanPlayer, 50)
  of Key6: sim.setOffenseFactor(HumanPlayer, 60)
  of Key7: sim.setOffenseFactor(HumanPlayer, 70)
  of Key8: sim.setOffenseFactor(HumanPlayer, 80)
  of Key9: sim.setOffenseFactor(HumanPlayer, 90)
  of Key0: sim.setOffenseFactor(HumanPlayer, 100)
  of KeyD:
    demoEnabled = not demoEnabled
  of KeyF2:
    let box = boxRectNow(mouseWorld())
    takeScreenshot(sim.renderFrame(selected, box, false, -1, @[]))
  else:
    discard

window.onButtonRelease = proc(button: Button) =
  if button != MouseLeft:
    return
  if not dragging:
    return
  dragging = false
  let fromPlanet = dragFromPlanet
  dragFromPlanet = -1
  if suppressClick:
    suppressClick = false
    return
  let
    pos = mouseWorld()
    moved = (pos - dragStart).length
  if fromPlanet != -1:
    if moved > DragThreshold:
      # Dragging is the only way to send ships. The target is the
      # snapped planet, no snap means no send.
      let targetId = snapTarget(pos)
      if targetId != -1:
        for sourceId in selected:
          sim.send(HumanPlayer, sourceId, targetId)
    # A plain click already updated the selection on press.
  elif moved > DragThreshold:
    handleBoxSelect(boxRectNow(pos))
  elif not shiftDown():
    # Clicking empty space or a planet that is not owned just
    # clears the selection.
    selected = @[]

var
  lastTime = epochTime()
  accumulator = 0.0

proc stepSim() =
  ## Advances the sim on a fixed timestep from real elapsed time,
  ## scaled by the speed multiplier.
  let now = epochTime()
  accumulator += min(now - lastTime, 0.25) * speedMultiplier
  lastTime = now
  while accumulator >= TickSeconds:
    accumulator -= TickSeconds
    if demoEnabled:
      for player in 2'i32 .. sim.config.playerCount:
        sim.demoOrders(player)
    stepAgents(sim)
    sim.tick()
  var keep: seq[int32]
  for planetId in selected:
    if sim.planets[planetId].ownerId == HumanPlayer:
      keep.add(planetId)
  selected = keep

proc drawWindow() =
  ## Renders and presents one frame. The window size and dpi are
  ## polled fresh at the top and everything in the frame, including
  ## the viewport, derives from that one snapshot, so a frame can
  ## never be drawn at a stale size or shape.
  let windowSize = window.size
  if windowSize.x <= 0 or windowSize.y <= 0:
    return
  makeContextCurrent(window)
  let
    pos = mouseWorld()
    inDrag = dragging and (pos - dragStart).length > DragThreshold
    showBox = inDrag and dragFromPlanet == -1
    sendDrag = inDrag and dragFromPlanet != -1
    dragTarget =
      if sendDrag:
        snapTarget(pos)
      else:
        -1
    dragSources =
      if sendDrag:
        selected
      else:
        @[]
    view = viewTransform(windowSize)
    frame = sim.renderFrame(
      selected,
      boxRectNow(pos),
      showBox,
      dragTarget,
      dragSources,
      view.scale
    )
  bxy.addImage("frame", frame, mipmaps = false)
  bxy.beginFrame(windowSize)
  bxy.drawImage("frame", rect(
    view.offset,
    vec2(float32(frame.width), float32(frame.height))
  ))
  bxy.endFrame()
  window.swapBuffers()

window.onFrame = proc() =
  stepSim()
  drawWindow()

while not window.closeRequested:
  pollEvents()
