## Arton, an ink wash strategy game for AIs. Dev graphics app.
## Run from the repo root: nim r src/arton.nim
## Headless screenshot: nim r src/arton.nim --shot=out.png --ticks=900 --demo

import
  std/[math, os, strformat, strutils, tables, times],
  boxy, bumpy, opengl, pixie, windy,
  arton/agents, arton/art, arton/profiles, arton/sims

when not defined(emscripten):
  import silky

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
  artMode = true
  artReady = false
  artState: ArtState
  showParams = false
  paramTab = 0
  ## Capture splats wait out this many ticks before landing, so a
  ## contested planet that flips owners rapidly does not bury the
  ## board in giant blobs. Every extra flip re-arms the timer and
  ## shrinks the final splat.
  pendingCaptures: Table[
    (int32, int32), tuple[ticks, ownerId, flips: int32]]

const CaptureSplatDelay = 10'i32

when defined(glShotDebug):
  var glShotFrames = 0

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

proc flagValue(name: string): string =
  ## Value of --name=value or --name:value, empty when absent.
  let prefix = "--" & name
  for param in commandLineParams():
    if param.startsWith(prefix) and param.len > prefix.len + 1:
      let sep = param[prefix.len]
      if sep == '=' or sep == ':':
        return param[prefix.len + 1 .. ^1]

proc speedFlag(): float64 =
  ## Sim speed multiplier from --speed:N. 1 is human time. Ignored
  ## in headless mode, which always runs as fast as possible.
  result = 1.0
  if flagValue("speed") != "":
    result = float64(parseInt(flagValue("speed")))

proc maxTicksFlag(): int32 =
  ## Game end tick from --maxTicks:N, when a match becomes a draw.
  result = DefaultMaxTicks
  if flagValue("maxTicks") != "":
    result = int32(parseInt(flagValue("maxTicks")))

proc maxOpsFlag(): int =
  ## Per turn script instruction budget from --maxOps:N.
  result = DefaultOpsPerTurn
  if flagValue("maxOps") != "":
    result = parseInt(flagValue("maxOps"))

proc planetsFlag(playerCount: int32): int32 =
  ## Planet count from --planets:N, never below the player count so
  ## everyone still gets a home planet.
  result = DefaultPlanetCount
  if flagValue("planets") != "":
    result = int32(parseInt(flagValue("planets")))
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

proc stepAgents(sim: var Sim) {.measure.} =
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

let shipImage = readImage("data/ship.png")
var shipSprites: Table[int32, Image]

proc shipSprite(ownerId: int32): Image =
  ## The sprite multiply tinted per owner: the white body takes the
  ## owner color, the black stroke stays black. Screenshot path.
  if ownerId in shipSprites:
    return shipSprites[ownerId]
  let tint = strokeColor(ownerId)
  result = newImage(shipImage.width, shipImage.height)
  for i in 0 ..< shipImage.data.len:
    var p = shipImage.data[i]
    p.r = uint8(int(p.r) * int(tint.r) div 255)
    p.g = uint8(int(p.g) * int(tint.g) div 255)
    p.b = uint8(int(p.b) * int(tint.b) div 255)
    result.data[i] = p
  shipSprites[ownerId] = result

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
    pixelScale: float32 = 1.0, artOverlay = false,
    drawShips = true): Image {.measure.} =
  ## Draws the whole sim in world coordinates, scaled up to the real
  ## output pixel size so nothing gets blurry. Dev graphics only:
  ## flat circles, triangle ships and plain text on white.
  result = newImage(
    int(float32(WorldWidth) * pixelScale),
    int(float32(WorldHeight) * pixelScale)
  )
  if artOverlay:
    result.fill(rgba(0, 0, 0, 0))
  else:
    result.fill(rgba(255, 255, 255, 255))
  let ctx = newContext(result)
  ctx.scale(vec2(pixelScale, pixelScale))
  ctx.font = FontPath

  if not artOverlay:
    # In art mode the planet bodies are 3d orbs drawn by the art
    # layer, the overlay only adds ui and text.
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

  # The live window draws ships on the gpu through boxy instead,
  # this cpu path only runs for screenshots and headless shots.
  if drawShips:
    for ship in sim.ships:
      let
        x = float32(ship.x) / float32(SubpixelScale)
        y = float32(ship.y) / float32(SubpixelScale)
        angle = float32(ship.heading) * 2.0'f * PI / 256.0'f
      ctx.save()
      ctx.translate(vec2(x, y))
      ctx.rotate(angle + float32(PI) / 2)
      let aspect =
        float32(shipImage.height) / float32(shipImage.width)
      ctx.drawImage(
        shipSprite(ship.ownerId), -10, -10 * aspect, 20, 20 * aspect)
      ctx.restore()

  ctx.fillStyle = HudColor
  ctx.fontSize = 18
  for planet in sim.planets:
    let
      label = $planet.ships
      metrics = ctx.measureText(label)
    # Centered on the planet, white with a black outline so counts
    # read on any orb or ink.
    let at = vec2(
      float32(planet.x) - metrics.width / 2,
      float32(planet.y) + 6)
    ctx.strokeStyle = rgba(0, 0, 0, 255)
    ctx.lineWidth = 3
    ctx.strokeText(label, at)
    ctx.fillStyle = rgba(255, 255, 255, 255)
    ctx.fillText(label, at)
    ctx.fillStyle = HudColor

  if showBox:
    ctx.strokeStyle = SelectionColor
    ctx.lineWidth = 1
    ctx.strokeRect(boxRect)

  ctx.fontSize = 16
  ctx.fillStyle = HudColor
  let hud = &"offense {sim.offenseFactor(HumanPlayer)}%  " &
    &"time {gameClock(sim.tickCount)}  " &
    &"tick {sim.tickCount}  " &
    &"speed {hudSpeed}x [ ]  " &
    &"demo {(if demoEnabled: \"on\" else: \"off\")} (D)  " &
    "restart (F2)  screenshot (F3)"
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
    let bannerAt = vec2(
      float32(WorldWidth) / 2 - metrics.width / 2,
      float32(WorldHeight) / 2 - 24)
    ctx.strokeStyle = rgba(255, 255, 255, 255)
    ctx.lineWidth = 5
    ctx.strokeText(banner, bannerAt)
    ctx.fillText(banner, bannerAt)

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
  if flagValue("ticks") != "":
    ticks = parseInt(flagValue("ticks"))
  if flagValue("seed") != "":
    seed = uint32(parseInt(flagValue("seed")))
  for param in commandLineParams():
    if param == "--demo":
      demo = true
  sim = newSim(initSimConfig(
    seed = seed,
    planetCount = planetsFlag(aiPlayerCount()),
    playerCount = aiPlayerCount(),
    maxTicks = maxTicksFlag()
  ))
  agentOpsPerTurn = maxOpsFlag()
  aiAgents = loadAgents(sim.config.playerCount)
  if ticks == -1:
    ticks = int(sim.config.maxTicks)
  startProfileTrace()
  defer:
    finishProfileTrace()
  echo "map: ", sim.config.planetCount, " planets, ",
    sim.config.playerCount, " players, ", agentOpsPerTurn,
    " instructions per turn"
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
    if profileShouldDump(int(sim.tickCount)):
      finishProfileTrace()
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
    var
      note = ""
      actions = 0
      ops = 0'i64
      turns = 0
    for agent in aiAgents:
      if agent.playerId == player.id:
        actions = agent.actions
        ops = agent.ops
        turns = agent.turns
        if agent.failed:
          note = "  CRASHED: " & agent.error
    echo "player ", player.id, ": ", planetCount, " planets, ",
      shipCount, " ships, ", actions, " actions, ", ops,
      " instructions (avg ", ops div max(int64(turns), 1),
      " per turn)", note
  var
    totalActions = 0
    totalOps = 0'i64
  for agent in aiAgents:
    totalActions += agent.actions
    totalOps += agent.ops
  echo "total actions: ", totalActions,
    ", total instructions: ", totalOps
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
  let shotPath = flagValue("shot")
  if shotPath != "" or flagValue("window") == "false":
    runHeadless(shotPath)

var gameSeed = 1'u32
sim = newSim(initSimConfig(
  seed = gameSeed,
  planetCount = planetsFlag(aiPlayerCount()),
  playerCount = aiPlayerCount(),
  maxTicks = maxTicksFlag()
))
agentOpsPerTurn = maxOpsFlag()
aiAgents = loadAgents(sim.config.playerCount)
var speedMultiplier = speedFlag()
hudSpeed = speedMultiplier
echo "map: ", sim.config.planetCount, " planets, ",
  sim.config.playerCount, " players, ", agentOpsPerTurn,
  " instructions per turn"
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
var boxyVao: GLint
glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr boxyVao)

when not defined(emscripten):
  # The F1 params panel, silky UI reusing the basicwindow example
  # widget skins with the game's own font.
  const SilkyData = "../silky/examples/basicwindow/data/"
  let silkyBuilder = newAtlasBuilder(1024, 4)
  silkyBuilder.addDir(SilkyData, SilkyData)
  silkyBuilder.addFont(FontPath, "H1", 32.0)
  silkyBuilder.addFont(FontPath, "Default", 18.0)
  createDir("tmp")
  silkyBuilder.write("tmp/arton_atlas.png")
  let sk = newSilky(window, "tmp/arton_atlas.png")

proc mouseOnUi(): bool =
  ## True while the mouse should go to the params panel, not the
  ## game, so panel clicks never select planets or send ships.
  when defined(emscripten):
    return false
  else:
    if not showParams:
      return false
    if sk.interactor.hotId != -1:
      return true
    let m = window.mousePos.vec2
    return m.x >= 16 and m.x <= 412 and m.y >= 16 and m.y <= 780

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

proc restartGame() =
  ## A brand new match on a fresh seed, on blank paper.
  inc gameSeed
  sim = newSim(initSimConfig(
    seed = gameSeed,
    planetCount = planetsFlag(aiPlayerCount()),
    playerCount = aiPlayerCount(),
    maxTicks = maxTicksFlag()
  ))
  aiAgents = loadAgents(sim.config.playerCount)
  selected = @[]
  pendingCaptures.clear()
  if artReady:
    artState.clearCanvas()
  echo "restarted with seed ", gameSeed

proc changeSpeed(factor: float64) =
  ## Doubles or halves the game speed from the bracket keys.
  speedMultiplier = clamp(speedMultiplier * factor, 0.25, 64.0)
  hudSpeed = speedMultiplier
  echo "game speed: ", speedMultiplier, "x"

window.onButtonPress = proc(button: Button) =
  if button in {MouseLeft, DoubleClick} and mouseOnUi():
    return
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
  of KeyF10:
    artMode = not artMode
  of KeyF1:
    showParams = not showParams
  of KeyF2:
    restartGame()
  of KeyF3:
    let box = boxRectNow(mouseWorld())
    takeScreenshot(sim.renderFrame(selected, box, false, -1, @[]))
  of KeyLeftBracket:
    changeSpeed(0.5)
  of KeyRightBracket:
    changeSpeed(2.0)
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

let appStart = epochTime()
var
  lastTime = epochTime()
  accumulator = 0.0

when defined(fpsDebug):
  var
    fpsFrames = 0
    fpsStart = epochTime()
    fpsRenderSecs = 0.0
    fpsArtSecs = 0.0

proc stepSim() =
  ## Advances the sim on a fixed timestep from real elapsed time,
  ## scaled by the speed multiplier and fully decoupled from the
  ## frame rate: one frame may run many ticks or none at all.
  let now = epochTime()
  accumulator += min(now - lastTime, 0.25) * speedMultiplier
  lastTime = now
  # Keep the app responsive at silly speeds: at most four game
  # seconds advance per frame, any further backlog is dropped.
  accumulator = min(accumulator, 4.0)
  while accumulator >= TickSeconds:
    accumulator -= TickSeconds
    if demoEnabled:
      for player in 2'i32 .. sim.config.playerCount:
        sim.demoOrders(player)
    stepAgents(sim)
    sim.tick()
    if artReady:
      # Every annihilation splats ink in the ship's color.
      for death in sim.deaths:
        artState.queueSplat(
          float32(death.x), float32(death.y),
          playerHue(death.ownerId) / 360.0, artParams.deathSize,
          amount = artParams.deathAmount)
      # Captures only splat once the planet has kept its new owner
      # for a few ticks. A flip during the wait re-arms the timer
      # with the newest owner and shrinks the eventual splat, so
      # planets trading hands every tick do not flood the canvas.
      for capture in sim.captures:
        let key = (capture.x, capture.y)
        var pending = pendingCaptures.getOrDefault(key)
        pending.ticks = CaptureSplatDelay
        pending.ownerId = capture.ownerId
        inc pending.flips
        pendingCaptures[key] = pending
      var fired: seq[(int32, int32)]
      for key, pending in pendingCaptures.mpairs:
        dec pending.ticks
        if pending.ticks <= 0:
          artState.queueSplat(
            float32(key[0]), float32(key[1]),
            playerHue(pending.ownerId) / 360.0,
            artParams.captureSize,
            amount = artParams.captureAmount /
              float32(pending.flips))
          fired.add(key)
      for key in fired:
        pendingCaptures.del(key)
      # Every ship makes two stamps: a bow push ahead of it that
      # drags the ink in front of it along, and an ink stain behind
      # it at zero velocity, so the trail stays where the ship was.
      for ship in sim.ships:
        let every = max(int32(artParams.trailEvery), 1)
        if ship.age mod every == every - 1 and
          artState.queue.len < 4096:
            let
              shipX = float32(ship.x div SubpixelScale)
              shipY = float32(ship.y div SubpixelScale)
              dirX = float32(cos256(ship.heading)) / 4096.0'f32
              dirY = float32(sin256(ship.heading)) / 4096.0'f32
              angle = float32(ship.heading) * 2.0'f32 * PI / 256.0'f32
              size = artParams.trailSize
            artState.queueSplat(
              shipX + dirX * size * 0.7'f32,
              shipY + dirY * size * 0.7'f32,
              0.0, size, amount = 0.0,
              vx = dirX * artParams.trailDrag,
              vy = dirY * artParams.trailDrag,
              angle = angle, ship = true)
            # The stain shoots backward like a rocket exhaust, so
            # the ink jets away behind the ship.
            artState.queueSplat(
              shipX - dirX * size * 0.5'f32,
              shipY - dirY * size * 0.5'f32,
              playerHue(ship.ownerId) / 360.0, size,
              amount = artParams.trailAmount,
              vx = -dirX * artParams.trailExhaust,
              vy = -dirY * artParams.trailExhaust,
              angle = angle, ship = true)
  var keep: seq[int32]
  for planetId in selected:
    if sim.planets[planetId].ownerId == HumanPlayer:
      keep.add(planetId)
  selected = keep

when not defined(emscripten):
  proc fmtParam(value: float32, digits: int): string =
    if digits == 0:
      $int(value)
    else:
      formatFloat(value, ffDecimal, digits)

  template param(
    labelText, id: string, value: var float32, lo, hi: float32,
    digits: int
  ) =
    ## One labeled scrubber row with its live value.
    text id & " label":
      characters labelText
    scrubber id, value, lo, hi, fmtParam(value, digits)

  template shipsTab() =
    param "trail drag", "trailDrag",
      artParams.trailDrag, 0.0'f32, 8.0'f32, 1
    param "engine exhaust", "trailExhaust",
      artParams.trailExhaust, 0.0'f32, 12.0'f32, 1
    param "trail stain amount", "trailAmount",
      artParams.trailAmount, 0.0'f32, 3.0'f32, 2
    param "trail stain size", "trailSize",
      artParams.trailSize, 1.0'f32, 32.0'f32, 0
    param "trail every N ticks", "trailEvery",
      artParams.trailEvery, 1.0'f32, 30.0'f32, 0
    param "death splat size", "deathSize",
      artParams.deathSize, 4.0'f32, 200.0'f32, 0
    param "death splat amount", "deathAmount",
      artParams.deathAmount, 0.0'f32, 10.0'f32, 1
    param "capture splat size", "captureSize",
      artParams.captureSize, 20.0'f32, 600.0'f32, 0
    param "capture splat amount", "captureAmount",
      artParams.captureAmount, 0.0'f32, 10.0'f32, 1

  template planetsTab() =
    param "color sat", "planetSat",
      artParams.planetSat, 0.0'f32, 1.0'f32, 2
    param "color val", "planetVal",
      artParams.planetVal, 0.0'f32, 1.0'f32, 2
    param "inner spin", "spinInner",
      artParams.spinInner, 0.0'f32, 3.0'f32, 2
    param "outer spin", "spinOuter",
      artParams.spinOuter, 0.0'f32, 3.0'f32, 2
    param "white washout", "washout",
      artParams.washout, 0.0'f32, 1.0'f32, 2
    param "specular", "specular",
      artParams.specular, 0.0'f32, 1.0'f32, 2
    param "inner jitter", "jitterInner",
      artParams.jitterInner, 0.0'f32, 0.5'f32, 3
    param "shell jitter", "jitterShell",
      artParams.jitterShell, 0.0'f32, 0.5'f32, 3
    param "shell scale", "shellScale",
      artParams.shellScale, 1.0'f32, 1.6'f32, 2
    param "shell missing", "shellMissing",
      artParams.shellMissing, 0.0'f32, 0.95'f32, 2
    checkBox "ring", artParams.showRing
    param "ring inner", "ringInner",
      artParams.ringInner, 1.0'f32, 2.0'f32, 2
    param "ring outer", "ringOuter",
      artParams.ringOuter, 1.02'f32, 2.2'f32, 2

  template inkTab() =
    param "flow damping", "velDamp",
      artParams.velDamp, 0.9'f32, 1.0'f32, 3
    param "speed cap", "speedCap",
      artParams.speedCap, 0.5'f32, 8.0'f32, 1
    param "fade keep", "fadeKeep",
      artParams.fadeKeep, 0.985'f32, 1.0'f32, 4
    param "fade sub x1000", "fadeSubK",
      artParams.fadeSubK, 0.0'f32, 2.0'f32, 2
    param "burst push", "burstPush",
      artParams.burstPush, 0.0'f32, 20.0'f32, 1
    param "ink sat", "inkSat",
      artParams.inkSat, 0.0'f32, 1.0'f32, 2
    param "ink val", "inkVal",
      artParams.inkVal, 0.0'f32, 1.0'f32, 2
    param "paper mix", "paperMix",
      artParams.paperMix, 0.0'f32, 1.0'f32, 2

  proc drawParamsPanel(windowSize: IVec2) =
    ## The F1 tabbed params panel, drawn over everything.
    if not showParams:
      return
    sk.beginUI(window, windowSize)
    subWindow("Params (F1)", showParams, vec2(16, 16), vec2(396, 764)):
      group "tabs":
        box 356, 32
        layout LeftToRight
        itemSpacing 12
        radioButton "Ships", paramTab, 0
        radioButton "Planets", paramTab, 1
        radioButton "Ink", paramTab, 2
      if paramTab == 0:
        shipsTab()
      elif paramTab == 1:
        planetsTab()
      else:
        inkTab()
    sk.endUi()

proc drawWindow() {.measure.} =
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
  if not artReady:
    artState = initArt()
    artReady = true
  when defined(fpsDebug):
    let artT0 = epochTime()
  if artMode:
    var hues: seq[float32]
    for player in sim.players:
      hues.add(playerHue(player.id) / 360.0)
    artState.frame(
      windowSize, view, sim, hues, epochTime() - appStart)
  else:
    # The debug view is all gl too: white clear, flat disc planets
    # and the same ship sprites, no cpu rasterizing.
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    glViewport(0, 0, windowSize.x, windowSize.y)
    glClearColor(1, 1, 1, 1)
    glClear(GL_COLOR_BUFFER_BIT)
    var fills, strokes: seq[Vec4]
    for planet in sim.planets:
      let f = fillColor(planet.ownerId)
      let s = strokeColor(planet.ownerId)
      fills.add(vec4(
        float32(f.r) / 255, float32(f.g) / 255,
        float32(f.b) / 255, 1.0))
      strokes.add(vec4(
        float32(s.r) / 255, float32(s.g) / 255,
        float32(s.b) / 255, 1.0))
    artState.drawDebugPlanets(windowSize, view, sim, fills, strokes)
  var shipColors: seq[Vec3]
  for player in sim.players:
    let c = strokeColor(player.id)
    shipColors.add(vec3(
      float32(c.r) / 255, float32(c.g) / 255, float32(c.b) / 255))
  artState.drawShips(windowSize, view, sim, shipColors, 20.0)
  when defined(fpsDebug):
    glFinish()
    fpsArtSecs += epochTime() - artT0
  when defined(fpsDebug):
    let renderT0 = epochTime()
  let frame = sim.renderFrame(
    selected,
    boxRectNow(pos),
    showBox,
    dragTarget,
    dragSources,
    view.scale,
    artOverlay = true,
    drawShips = false
  )
  when defined(fpsDebug):
    fpsRenderSecs += epochTime() - renderT0
  # The art passes bind their own vaos and disable blending, boxy
  # assumes both stayed as it left them.
  glBindVertexArray(GLuint(boxyVao))
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  bxy.addImage("frame", frame, mipmaps = false)
  bxy.beginFrame(windowSize, clearFrame = false)
  bxy.drawImage("frame", rect(
    view.offset,
    vec2(float32(frame.width), float32(frame.height))
  ))
  bxy.endFrame()
  when not defined(emscripten):
    drawParamsPanel(windowSize)
  when defined(glShotDebug):
    inc glShotFrames
    if glShotFrames == 120:
      let shot = newImage(windowSize.x, windowSize.y)
      glBindFramebuffer(GL_FRAMEBUFFER, 0)
      glReadPixels(0, 0, windowSize.x, windowSize.y,
        GL_RGBA, GL_UNSIGNED_BYTE, addr shot.data[0])
      shot.flipVertical()
      shot.writeFile("tmp/glshot.png")
      echo "saved tmp/glshot.png"
      quit(0)
  window.swapBuffers()

startProfileTrace()

window.onFrame = proc() =
  stepSim()
  drawWindow()
  when defined(fpsDebug):
    inc fpsFrames
    if fpsFrames == 120:
      let secs = epochTime() - fpsStart
      echo "frame ms avg: ",
        formatFloat(secs / 120.0 * 1000.0, ffDecimal, 2),
        "  render ms: ",
        formatFloat(fpsRenderSecs / 120.0 * 1000.0, ffDecimal, 2),
        "  art ms: ",
        formatFloat(fpsArtSecs / 120.0 * 1000.0, ffDecimal, 2),
        "  ships: ", sim.ships.len, "  tick: ", sim.tickCount
      fpsFrames = 0
      fpsStart = epochTime()
      fpsRenderSecs = 0.0
      fpsArtSecs = 0.0
  if profileShouldDump(int(sim.tickCount)):
    finishProfileTrace()

while not window.closeRequested:
  pollEvents()
