## Arton, an ink wash strategy game for AIs. Dev graphics app.
## Run from the repo root: nim r src/arton.nim
## Headless screenshot: nim r src/arton.nim --shot=out.png --ticks=900 --demo

import
  std/[math, os, strformat, strutils, times],
  boxy, bumpy, opengl, pixie, windy,
  arton/sims

const
  FontPath = "data/IBMPlexSans-Regular.ttf"
  TickSeconds = 1.0 / float64(TicksPerSecond)
  DragThreshold = 5.0'f32
  ClickPadPixels = 6.0'f32
  DemoIntervalTicks = 240'i32
  HumanPlayer = 1'i32
  NeutralFill = rgba(200, 200, 200, 255)
  NeutralStroke = rgba(90, 90, 90, 255)
  PlayerFills = [
    rgba(216, 180, 245, 255),
    rgba(170, 200, 250, 255),
    rgba(250, 170, 170, 255),
    rgba(250, 215, 160, 255)
  ]
  PlayerStrokes = [
    rgba(120, 40, 180, 255),
    rgba(30, 80, 200, 255),
    rgba(200, 30, 30, 255),
    rgba(220, 130, 20, 255)
  ]
  SelectionColor = rgba(120, 40, 180, 255)
  HudColor = rgba(20, 20, 20, 255)

var
  sim: Sim
  selected: seq[int32]
  dragStart: Vec2
  dragging = false
  dragFromPlanet = -1'i32
  suppressClick = false
  demoEnabled = false
  shotIndex = 0

proc fillColor(ownerId: int32): ColorRGBA =
  ## Planet fill color for an owner.
  if ownerId == NeutralOwner:
    return NeutralFill
  return PlayerFills[(ownerId - 1) mod PlayerFills.len]

proc strokeColor(ownerId: int32): ColorRGBA =
  ## Planet outline and ship color for an owner.
  if ownerId == NeutralOwner:
    return NeutralStroke
  return PlayerStrokes[(ownerId - 1) mod PlayerStrokes.len]

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
    &"tick {sim.tickCount}  " &
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

proc headlessShot() =
  ## Runs the sim without a window and writes one screenshot.
  var
    shotPath = ""
    ticks = 600
    seed = 1'u32
    demo = false
  for param in commandLineParams():
    if param.startsWith("--shot="):
      shotPath = param.split("=")[1]
    elif param.startsWith("--ticks="):
      ticks = parseInt(param.split("=")[1])
    elif param.startsWith("--seed="):
      seed = uint32(parseInt(param.split("=")[1]))
    elif param == "--demo":
      demo = true
  sim = newSim(initSimConfig(seed = seed))
  for i in 0 ..< ticks:
    if demo:
      for player in 1'i32 .. sim.config.playerCount:
        sim.demoOrders(player)
    sim.tick()
  let frame = sim.renderFrame(@[], rect(0, 0, 0, 0), false, -1, @[])
  frame.writeFile(shotPath)
  echo "Saved ", shotPath, " at tick ", sim.tickCount
  quit(0)

for param in commandLineParams():
  if param.startsWith("--shot="):
    headlessShot()

sim = newSim(initSimConfig(seed = 1))

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
  ## Advances the sim on a fixed timestep from real elapsed time.
  let now = epochTime()
  accumulator += min(now - lastTime, 0.25)
  lastTime = now
  while accumulator >= TickSeconds:
    accumulator -= TickSeconds
    if demoEnabled:
      for player in 2'i32 .. sim.config.playerCount:
        sim.demoOrders(player)
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
