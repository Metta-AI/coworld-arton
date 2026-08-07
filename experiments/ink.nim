## Ink splat experiment. Opens a white window, click (or drag) to
## drop paint splats that bleed, diffuse and mix like wet ink.
##
## The state lives in two offscreen float buffers that ping pong
## every frame through a sim shader (advect, diffuse, splat), then a
## present shader draws the state with the paint look borrowed from
## the shadertoy paint streams shaders: sqrt color mixing, density
## shading and a gradient specular, tone mapped with tanh onto white.
##
## Run:        nim r experiments/ink.nim
## Self test:  nim r experiments/ink.nim --shot=tmp/ink.png --frames=300
##
## Shaders are written in Nim and compiled to GLSL with shady.

import
  std/[algorithm, os, random, strutils, times],
  opengl, pixie, shady, silky, vmath, windy

const
  SimWidth = 1024
  SimHeight = 1024

# Shader uniforms, shared by name with the GL side.
var
  statePrev: Uniform[Sampler2d]
  splatTex: Uniform[Sampler2d]
  resolution: Uniform[Vec2]
  splatPos: Uniform[Vec2]
  splatHue: Uniform[float32]
  splatAmount: Uniform[float32]
  splatSize: Uniform[float32]
  splatAngle: Uniform[float32]
  fadeMul: Uniform[float32]
  fadeSub: Uniform[float32]
  velDamp: Uniform[float32]
  speedCap: Uniform[float32]
  pushStrength: Uniform[float32]
  erasePos: Uniform[Vec2]
  eraseAmount: Uniform[float32]
  eraseRadius: Uniform[float32]
  colorSat: Uniform[float32]
  colorVal: Uniform[float32]

## Helper functions compiled into the shaders. Custom names so they
## never collide with GLSL builtins.

proc inkG(x: Vec2): float32 =
  ## Gaussian falloff, straight from the shadertoy G().
  exp(-dot(x, x))

proc sstep(a, b, x: float32): float32 =
  ## smoothstep.
  let t = clamp((x - a) / (b - a), 0.0'f32, 1.0'f32)
  result = t * t * (3.0'f32 - 2.0'f32 * t)

proc mixN(a, b: Vec3, k: float32): Vec3 =
  ## The shadertoy paint mixer: mixing in squared space reads like
  ## real pigment instead of muddy linear blends. Written as a manual
  ## lerp because the scalar-t vector mix overload upsets shady.
  let t = clamp(k, 0.0'f32, 1.0'f32)
  let m = (a * a) * (1.0'f32 - t) + (b * b) * t
  result = vec3(sqrt(m.x), sqrt(m.y), sqrt(m.z))

proc mod6(v: Vec3): Vec3 =
  ## Componentwise wrap into 0 .. 6, since vector mod is not a shady
  ## builtin.
  v - floor(v / 6.0'f32) * 6.0'f32

proc hsvToRgb(c: Vec3): Vec3 =
  ## The shadertoy hsv2rgb with cubic smoothing.
  var rgb = clamp(
    abs(mod6(c.x * 6.0'f32 + vec3(0.0, 4.0, 2.0)) - 3.0'f32) - 1.0'f32,
    0.0'f32,
    1.0'f32
  )
  rgb = rgb * rgb * (3.0'f32 - 2.0'f32 * rgb)
  result = c.z * mix(vec3(1.0, 1.0, 1.0), rgb, c.y)

proc dirV(ang: float32): Vec2 =
  ## Unit vector for an angle, the shadertoy Dir().
  vec2(cos(ang), sin(ang))

proc tanhF(x: float32): float32 =
  ## tanh via exp, since tanh is not a shady builtin.
  1.0'f32 - 2.0'f32 / (exp(2.0'f32 * x) + 1.0'f32)

proc tanh3(v: Vec3): Vec3 =
  ## Componentwise tanh tone map.
  vec3(tanhF(v.x), tanhF(v.y), tanhF(v.z))

## The two render passes.

proc inkVert(gl_Position: var Vec4, uv: var Vec2, vertexPos: Vec2) =
  ## Fullscreen triangle.
  uv = vertexPos * 0.5'f32 + 0.5'f32
  gl_Position = vec4(vertexPos.x, vertexPos.y, 0.0, 1.0)

proc inkSimFrag(fragColor: var Vec4, uv: Vec2) =
  ## One sim step. State per pixel: xy = flow velocity, z = ink
  ## density, w = pigment hue times density. Advect the state backward along the
  ## flow, diffuse it with a small gaussian, damp, then inject the
  ## frame's splat.
  let pos = uv * resolution
  let here = texture(statePrev, uv)
  let src = (pos - here.xy * 1.5'f32) / resolution

  # Ink diffuses with a wide kernel, velocity with a much tighter
  # one. Averaging velocity with still neighbors acts like heavy
  # friction, so keeping its kernel tight is what lets flow carry.
  var acc = vec4(0.0, 0.0, 0.0, 0.0)
  var accVel = vec2(0.0, 0.0)
  var wsum = 0.0'f32
  var velWsum = 0.0'f32
  for i in 0 ..< 3:
    for j in 0 ..< 3:
      let o = vec2(float32(i) - 1.0'f32, float32(j) - 1.0'f32)
      let sample = texture(statePrev, src + o / resolution)
      let w = inkG(o * 0.8'f32)
      let wv = inkG(o * 1.4'f32)
      acc = acc + w * sample
      accVel = accVel + wv * sample.xy
      wsum = wsum + w
      velWsum = velWsum + wv
  var state = acc / wsum
  state.x = accVel.x / velWsum
  state.y = accVel.y / velWsum

  # Gentle flow damping with a speed cap: flow carries, but bounded
  # speed keeps the explosion from diluting the ink into nothing.
  # Ink fades away over time, the exponential part thins heavy pools
  # and the linear part makes even the last faint stain reach zero,
  # so the page always clears back to white. All tunable in the UI.
  state.x = state.x * velDamp
  state.y = state.y * velDamp
  let speed = length(vec2(state.x, state.y))
  if speed > speedCap:
    state.x = state.x * speedCap / speed
    state.y = state.y * speedCap / speed
  let zBefore = state.z
  state.z = max(state.z * fadeMul - fadeSub, 0.0'f32)
  # Hue mass scales with the mass it belongs to.
  state.w = state.w * state.z / max(zBefore, 0.0001'f32)

  # The push brush: a tiny fuzzy circle that shoves paint away from
  # the cursor like a stick dragged through wet ink. Mostly velocity
  # with just a whisper of erase, so it carves by displacement.
  if eraseAmount > 0.0'f32:
    let ed = (pos - erasePos) / eraseRadius
    let g = eraseAmount * inkG(ed)
    let eAway = pos - erasePos + vec2(0.001, 0.001)
    let shove = normalize(eAway) * g * 4.0'f32
    state.x = state.x + shove.x
    state.y = state.y + shove.y
    state.z = max(state.z - g * 0.15'f32, 0.0'f32)

  # Splat: stamp the current splatter brush texture, rotated and
  # scaled, adding mass where the brush has ink. Hue blends by mass
  # and the flow gets a small outward push so the paint blooms.
  if splatAmount > 0.0'f32:
    let rel = (pos - splatPos) / splatSize
    let cA = cos(splatAngle)
    let sA = sin(splatAngle)
    let q = vec2(rel.x * cA - rel.y * sA, rel.x * sA + rel.y * cA) +
      0.5'f32
    if q.x > 0.0'f32 and q.x < 1.0'f32 and
      q.y > 0.0'f32 and q.y < 1.0'f32:
      let m = splatAmount * texture(splatTex, q).x
      if m > 0.0001'f32:
        state.w = state.w + splatHue * m
        state.z = state.z + m
        # Velocity kicks outward from the splat center, only where
        # the brush is dark since m carries the brush ink sample, so
        # the ink explodes outward from the stamp shape.
        let away = pos - splatPos + vec2(0.001, 0.001)
        let push = normalize(away) * m * pushStrength
        state.x = state.x + push.x
        state.y = state.y + push.y

  fragColor = state

proc inkDrawFrag(fragColor: var Vec4, uv: Vec2) =
  ## Paint look, borrowed from the shadertoy render pass: density
  ## drives coverage and depth, the density gradient drives a wet
  ## specular, and everything composites onto white through mixN
  ## with a tanh tone map.
  let pos = uv * resolution
  let state = texture(statePrev, uv)
  let rho = state.z

  let e = vec2(2.0'f32, 2.0'f32) / resolution
  let gx = texture(statePrev, uv + vec2(e.x, 0.0)).z -
    texture(statePrev, uv - vec2(e.x, 0.0)).z
  let gy = texture(statePrev, uv + vec2(0.0, e.y)).z -
    texture(statePrev, uv - vec2(0.0, e.y)).z
  let grad = vec2(-0.5'f32 * gx, -0.5'f32 * gy)
  let n = pow(length(grad), 0.2'f32) *
    normalize(grad + vec2(0.00001, 0.00001))
  let specular = pow(max(dot(n, dirV(1.4'f32)), 0.0'f32), 3.5'f32)

  let a = pow(sstep(0.0'f32, 1.0'f32, rho), 0.1'f32)
  let b = exp(-1.7'f32 * sstep(0.5'f32, 3.75'f32, rho))

  let hue = state.w / max(rho, 0.0001'f32)
  let fcol = hsvToRgb(vec3(hue, colorSat, colorVal))

  var col = vec3(3.0, 3.0, 3.0)
  col = mixN(col, fcol * (1.5'f32 * b + specular * 5.0'f32), a)
  col = tanh3(col)
  fragColor = vec4(col.x, col.y, col.z, 1.0)

## GL plumbing: shader compilation, fbo ping pong, fullscreen
## triangle. Raw OpenGL, buffer to buffer.

proc compileShader(kind: GLenum, source: string): GLuint =
  ## Compiles one shader stage or quits with the info log.
  result = glCreateShader(kind)
  let arr = allocCStringArray([source])
  glShaderSource(result, 1, arr, nil)
  deallocCStringArray(arr)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, addr status)
  if status == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, addr length)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    quit "shader compile failed:\n" & log & "\n" & source

proc makeProgram(vertSrc, fragSrc: string): GLuint =
  ## Links a vertex plus fragment program or quits with the log.
  let
    vert = compileShader(GL_VERTEX_SHADER, vertSrc)
    frag = compileShader(GL_FRAGMENT_SHADER, fragSrc)
  result = glCreateProgram()
  glAttachShader(result, vert)
  glAttachShader(result, frag)
  glLinkProgram(result)
  var status: GLint
  glGetProgramiv(result, GL_LINK_STATUS, addr status)
  if status == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, addr length)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    quit "shader link failed:\n" & log

proc loadSplatTexture(path: string): GLuint =
  ## Loads one black on white splatter png as a single channel ink
  ## texture, where 1 means full ink.
  let image = readImage(path)
  var ink = newString(image.width * image.height)
  for i in 0 ..< image.width * image.height:
    ink[i] = char(255 - image.data[i].r)
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GLint(GL_R8),
    GLsizei(image.width), GLsizei(image.height), 0,
    GL_RED, GL_UNSIGNED_BYTE, ink.cstring
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(
    GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(
    GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))

proc makeStateTexture(): GLuint =
  ## One RGBA32F sim buffer, linear filtered for smooth advection.
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GLint(GL_RGBA32F),
    SimWidth, SimHeight, 0, GL_RGBA, cGL_FLOAT, nil
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(
    GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(
    GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))

let window = newWindow(
  "Ink",
  ivec2(SimWidth, SimHeight),
  vsync = true
)
makeContextCurrent(window)
loadExtensions()

# Silky UI, reusing the widget skins and font from the silky
# basicwindow example atlas data.
const SilkyData = "../silky/examples/basicwindow/data/"
let builder = newAtlasBuilder(1024, 4)
builder.addDir(SilkyData, SilkyData)
builder.addFont(SilkyData & "IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont(SilkyData & "IBMPlexSans-Regular.ttf", "Default", 18.0)
createDir("tmp")
builder.write("tmp/ink_atlas.png")
let sk = newSilky(window, "tmp/ink_atlas.png")

# The splatter brush set, extracted from the abr by gen_splats.
var splatTextures: seq[GLuint]
block:
  var paths: seq[string]
  for path in walkFiles("experiments/data/splats/*.png"):
    paths.add(path)
  paths.sort()
  for path in paths:
    splatTextures.add(loadSplatTexture(path))
doAssert splatTextures.len > 0, "no splat pngs found, run gen_splats"
randomize()

let
  simProgram = makeProgram(
    toShader(inkVert, glsl3Desktop, shaderVertex),
    toShader(inkSimFrag, glsl3Desktop, shaderFragment)
  )
  drawProgram = makeProgram(
    toShader(inkVert, glsl3Desktop, shaderVertex),
    toShader(inkDrawFrag, glsl3Desktop, shaderFragment)
  )

# Fullscreen triangle.
var
  vao: GLuint
  vbo: GLuint
  triangle = [(-1.0'f32, -1.0'f32), (3.0'f32, -1.0'f32), (-1.0'f32, 3.0'f32)]
glGenVertexArrays(1, addr vao)
glBindVertexArray(vao)
glGenBuffers(1, addr vbo)
glBindBuffer(GL_ARRAY_BUFFER, vbo)
glBufferData(
  GL_ARRAY_BUFFER, sizeof(triangle), addr triangle, GL_STATIC_DRAW)
glEnableVertexAttribArray(0)
glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 8, nil)

# Ping pong state buffers and one fbo.
var
  stateTex = [makeStateTexture(), makeStateTexture()]
  fbo: GLuint
  current = 0
glGenFramebuffers(1, addr fbo)
for tex in stateTex:
  glBindFramebuffer(GL_FRAMEBUFFER, fbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)

var
  hue = 0.08'f32
  pendingAmount = 0.0'f32
  pendingPos = vec2(0, 0)
  pendingErase = 0.0'f32
  pendingErasePos = vec2(0, 0)
  currentSplat: GLuint
  currentSize = 220.0'f32
  currentAngle = 0.0'f32
  frameCount = 0
  shotPath = ""
  shotFrames = 300
  # The key sim parameters, draggable in the UI panel.
  showParams = true
  paramSize = 23.0'f32
  paramAmount = 7.7'f32
  paramPush = 8.8'f32
  paramDamp = 0.985'f32
  paramSpeedCap = 3.0'f32
  paramFadeKeep = 0.9984'f32
  paramFadeSub = 0.4'f32
  paramEraseSize = 3.0'f32
  paramEraseForce = 1.4'f32
  paramHue = 0.61'f32
  paramSat = 0.85'f32
  paramVal = 0.75'f32

currentSplat = splatTextures[0]

for param in commandLineParams():
  if param.startsWith("--shot="):
    shotPath = param.split("=")[1]
  elif param.startsWith("--frames="):
    shotFrames = parseInt(param.split("=")[1])

proc viewTransform(): tuple[scale: float32, offset: Vec2] =
  ## Uniform window to canvas scale and the letterbox offset that
  ## keeps the square canvas square on any window size and dpi.
  ## Same approach as the arton window: window.size and mousePos are
  ## both in physical pixels, so one transform covers retina too.
  let
    size = window.size.vec2
    scale = min(
      size.x / float32(SimWidth),
      size.y / float32(SimHeight)
    )
    drawSize = vec2(float32(SimWidth), float32(SimHeight)) * scale
  return (scale, (size - drawSize) / 2)

proc mouseCanvas(): Vec2 =
  ## Mouse position in canvas pixels, letterbox and dpi corrected.
  let view = viewTransform()
  return (window.mousePos.vec2 - view.offset) / view.scale

proc onCanvas(pos: Vec2): bool =
  ## Whether a canvas position is on the paper at all.
  pos.x >= 0 and pos.x < float32(SimWidth) and
    pos.y >= 0 and pos.y < float32(SimHeight)

proc queueSplat(pos: Vec2, amount: float32) =
  ## The next sim step injects one splat at this position.
  if not onCanvas(pos):
    return
  pendingPos = vec2(pos.x, float32(SimHeight) - pos.y)
  pendingAmount = amount

proc mouseOnUi(): bool =
  ## True while the mouse should go to the UI, not the paper.
  if sk.interactor.hotId != -1:
    return true
  let m = window.mousePos.vec2
  return showParams and m.x >= 8 and m.x <= 372 and
    m.y >= 8 and m.y <= 830

window.onButtonPress = proc(button: Button) =
  if button == MouseLeft and not mouseOnUi():
    # A new brush, rotation and size for every click. The color is
    # whatever the hsv sliders say.
    hue = paramHue
    currentSplat = splatTextures[rand(splatTextures.len - 1)]
    currentAngle = rand(6.28318'f32)
    currentSize = paramSize * (0.75'f32 + rand(0.5'f32))
    queueSplat(mouseCanvas(), paramAmount)

proc uniformLoc(program: GLuint, name: string): GLint =
  glGetUniformLocation(program, name.cstring)

proc runPass(program: GLuint, target: GLuint, sourceTex: GLuint) =
  ## One buffer to buffer pass: bind target fbo (0 for the screen),
  ## bind source state texture, draw the fullscreen triangle.
  glBindFramebuffer(GL_FRAMEBUFFER, target)
  if target == 0:
    # Present letterboxed: clear the whole window to paper white,
    # then draw the square canvas centered at uniform scale.
    glViewport(0, 0, window.size.x, window.size.y)
    glClearColor(0.995, 0.995, 0.995, 1)
    glClear(GL_COLOR_BUFFER_BIT)
    let view = viewTransform()
    glViewport(
      GLint(view.offset.x),
      GLint(view.offset.y),
      GLsizei(float32(SimWidth) * view.scale),
      GLsizei(float32(SimHeight) * view.scale)
    )
  else:
    glViewport(0, 0, SimWidth, SimHeight)
  # Rebind everything: the silky UI pass leaves its own vao, blend
  # and scissor state behind each frame.
  glBindVertexArray(vao)
  glDisable(GL_BLEND)
  glDisable(GL_SCISSOR_TEST)
  glBindVertexArray(vao)
  glUseProgram(program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sourceTex)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, currentSplat)
  glUniform1i(uniformLoc(program, "statePrev"), 0)
  glUniform1i(uniformLoc(program, "splatTex"), 1)
  glUniform2f(
    uniformLoc(program, "resolution"),
    float32(SimWidth), float32(SimHeight)
  )
  glUniform2f(
    uniformLoc(program, "splatPos"), pendingPos.x, pendingPos.y)
  glUniform1f(uniformLoc(program, "splatHue"), hue)
  glUniform1f(uniformLoc(program, "splatAmount"), pendingAmount)
  glUniform1f(uniformLoc(program, "splatSize"), currentSize)
  glUniform1f(uniformLoc(program, "splatAngle"), currentAngle)
  glUniform1f(uniformLoc(program, "fadeMul"), paramFadeKeep)
  glUniform1f(uniformLoc(program, "fadeSub"), paramFadeSub / 1000.0)
  glUniform1f(uniformLoc(program, "velDamp"), paramDamp)
  glUniform1f(uniformLoc(program, "speedCap"), paramSpeedCap)
  glUniform1f(uniformLoc(program, "pushStrength"), paramPush)
  glUniform2f(
    uniformLoc(program, "erasePos"), pendingErasePos.x, pendingErasePos.y)
  glUniform1f(uniformLoc(program, "eraseAmount"), pendingErase)
  glUniform1f(uniformLoc(program, "eraseRadius"), paramEraseSize)
  glUniform1f(uniformLoc(program, "colorSat"), paramSat)
  glUniform1f(uniformLoc(program, "colorVal"), paramVal)
  glDrawArrays(GL_TRIANGLES, 0, 3)

proc saveShot(path: string) =
  ## Reads back the screen and writes a png.
  let image = newImage(window.size.x, window.size.y)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glReadPixels(
    0, 0, window.size.x, window.size.y,
    GL_RGBA, GL_UNSIGNED_BYTE, addr image.data[0]
  )
  image.flipVertical()
  image.writeFile(path)
  echo "Saved ", path

window.onFrame = proc() =
  inc frameCount

  # Holding the mouse keeps pouring paint.
  if window.buttonDown[MouseLeft] and not mouseOnUi():
    queueSplat(mouseCanvas(), paramAmount * 0.1)

  # Right button drags a little fuzzy eraser circle through the
  # paint.
  if window.buttonDown[MouseRight] and not mouseOnUi():
    let pos = mouseCanvas()
    if onCanvas(pos):
      pendingErasePos = vec2(pos.x, float32(SimHeight) - pos.y)
      pendingErase = paramEraseForce

  # Sim pass: current state -> other buffer.
  glBindFramebuffer(GL_FRAMEBUFFER, fbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    stateTex[1 - current], 0
  )
  runPass(simProgram, fbo, stateTex[current])
  current = 1 - current
  pendingAmount = 0.0
  pendingErase = 0.0

  # Present pass: state -> screen.
  runPass(drawProgram, 0, stateTex[current])

  # Param panel on top.
  sk.beginUI(window, window.size)
  subWindow("Ink Params", showParams, vec2(16, 16), vec2(348, 790)):
    text "size label":
      characters "splat size"
    scrubber "size", paramSize, 0.0'f32, 300.0'f32,
      $int(paramSize)
    text "amount label":
      characters "splat amount"
    scrubber "amount", paramAmount, 0.0'f32, 10.0'f32,
      formatFloat(paramAmount, ffDecimal, 1)
    text "push label":
      characters "burst push"
    scrubber "push", paramPush, 0.0'f32, 10.0'f32,
      formatFloat(paramPush, ffDecimal, 1)
    text "damp label":
      characters "flow damping"
    scrubber "damp", paramDamp, 0.9'f32, 1.0'f32,
      formatFloat(paramDamp, ffDecimal, 3)
    text "cap label":
      characters "speed cap"
    scrubber "cap", paramSpeedCap, 0.5'f32, 8.0'f32,
      formatFloat(paramSpeedCap, ffDecimal, 1)
    text "fade keep label":
      characters "fade keep"
    scrubber "fadeKeep", paramFadeKeep, 0.985'f32, 1.0'f32,
      formatFloat(paramFadeKeep, ffDecimal, 4)
    text "fade sub label":
      characters "fade sub x1000"
    scrubber "fadeSub", paramFadeSub, 0.0'f32, 2.0'f32,
      formatFloat(paramFadeSub, ffDecimal, 2)
    text "erase size label":
      characters "push brush size"
    scrubber "eraseSize", paramEraseSize, 1.0'f32, 30.0'f32,
      formatFloat(paramEraseSize, ffDecimal, 1)
    text "erase force label":
      characters "push brush force"
    scrubber "eraseForce", paramEraseForce, 0.0'f32, 8.0'f32,
      formatFloat(paramEraseForce, ffDecimal, 1)
    text "hue label":
      characters "color hue"
    scrubber "hue", paramHue, 0.0'f32, 1.0'f32,
      formatFloat(paramHue, ffDecimal, 2)
    text "sat label":
      characters "color sat"
    scrubber "sat", paramSat, 0.0'f32, 1.0'f32,
      formatFloat(paramSat, ffDecimal, 2)
    text "val label":
      characters "color val"
    scrubber "val", paramVal, 0.0'f32, 1.0'f32,
      formatFloat(paramVal, ffDecimal, 2)
  sk.endUi()

  window.swapBuffers()

  if shotPath != "" and frameCount >= shotFrames:
    saveShot(shotPath)
    quit(0)

while not window.closeRequested:
  pollEvents()
