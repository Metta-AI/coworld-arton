## The art render mode: an ink fluid canvas behind everything, the
## paper texture mixed on top of it, and spinning low poly 3d planet
## orbs. Ported from experiments/ink.nim. Ships, selection ui and
## text stay on the cpu overlay drawn above all of this.

import
  std/[algorithm, os, random],
  opengl, pixie, shady, vmath,
  sims

const
  InkW = WorldWidth.int32
  InkH = WorldHeight.int32

var
  statePrev: Uniform[Sampler2d]
  paperTex: Uniform[Sampler2d]
  resolution: Uniform[Vec2]
  splatPos: Uniform[Vec2]
  splatHue: Uniform[float32]
  splatAmount: Uniform[float32]
  splatSize: Uniform[float32]
  splatAngle: Uniform[float32]
  mvp: Uniform[Mat4]
  modelRot: Uniform[Mat4]
  ownerColor: Uniform[Vec3]

proc inkG(x: Vec2): float32 =
  exp(-dot(x, x))

proc sstep(a, b, x: float32): float32 =
  let t = clamp((x - a) / (b - a), 0.0'f32, 1.0'f32)
  result = t * t * (3.0'f32 - 2.0'f32 * t)

proc mixN(a, b: Vec3, k: float32): Vec3 =
  let t = clamp(k, 0.0'f32, 1.0'f32)
  let m = (a * a) * (1.0'f32 - t) + (b * b) * t
  result = vec3(sqrt(m.x), sqrt(m.y), sqrt(m.z))

proc mod6(v: Vec3): Vec3 =
  v - floor(v / 6.0'f32) * 6.0'f32

proc hsvToRgb(c: Vec3): Vec3 =
  var rgb = clamp(
    abs(mod6(c.x * 6.0'f32 + vec3(0.0, 4.0, 2.0)) - 3.0'f32) - 1.0'f32,
    0.0'f32,
    1.0'f32
  )
  rgb = rgb * rgb * (3.0'f32 - 2.0'f32 * rgb)
  result = c.z * mix(vec3(1.0, 1.0, 1.0), rgb, c.y)

proc dirV(ang: float32): Vec2 =
  vec2(cos(ang), sin(ang))

proc tanhF(x: float32): float32 =
  1.0'f32 - 2.0'f32 / (exp(2.0'f32 * x) + 1.0'f32)

proc tanh3(v: Vec3): Vec3 =
  vec3(tanhF(v.x), tanhF(v.y), tanhF(v.z))

proc artVert(gl_Position: var Vec4, uv: var Vec2, vertexPos: Vec2) =
  uv = vertexPos * 0.5'f32 + 0.5'f32
  gl_Position = vec4(vertexPos.x, vertexPos.y, 0.0, 1.0)

proc artSimFrag(fragColor: var Vec4, uv: Vec2) =
  ## Ink advect, diffuse and fade, the tuned ink.nim values baked in.
  let pos = uv * resolution
  let here = texture(statePrev, uv)
  let src = (pos - here.xy * 1.5'f32) / resolution
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
  state.x = accVel.x / velWsum * 0.985'f32
  state.y = accVel.y / velWsum * 0.985'f32
  let speed = length(vec2(state.x, state.y))
  if speed > 3.0'f32:
    state.x = state.x * 3.0'f32 / speed
    state.y = state.y * 3.0'f32 / speed
  state.z = max(state.z * 0.9984'f32 - 0.0004'f32, 0.0'f32)
  fragColor = state

proc artInjectFrag(fragColor: var Vec4, uv: Vec2) =
  ## Adds one splat brush stamp to the state, nothing else. Runs once
  ## per queued splat, ping ponging, so many splats land per frame.
  let pos = uv * resolution
  var state = texture(statePrev, uv)
  let rel = (pos - splatPos) / splatSize
  let cA = cos(splatAngle)
  let sA = sin(splatAngle)
  let q = vec2(rel.x * cA - rel.y * sA, rel.x * sA + rel.y * cA) +
    0.5'f32
  if q.x > 0.0'f32 and q.x < 1.0'f32 and
    q.y > 0.0'f32 and q.y < 1.0'f32:
    let m = splatAmount * texture(paperTex, q).x
    if m > 0.0001'f32:
      let total = state.z + m
      state.w = (state.w * state.z + splatHue * m) /
        max(total, 0.0001'f32)
      state.z = total
      let away = pos - splatPos + vec2(0.001, 0.001)
      let push = normalize(away) * m * 8.8'f32
      state.x = state.x + push.x
      state.y = state.y + push.y
  fragColor = state

proc artDrawFrag(fragColor: var Vec4, uv: Vec2) =
  ## Paint look over white, then the paper texture multiplied on top
  ## so the whole artwork sits on the canvas.
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
  let fcol = hsvToRgb(vec3(state.w, 0.85'f32, 0.75'f32))
  var col = vec3(3.0, 3.0, 3.0)
  col = mixN(col, fcol * (1.5'f32 * b + specular * 5.0'f32), a)
  col = tanh3(col)
  let paper = texture(paperTex, vec2(uv.x, 1.0'f32 - uv.y))
  col = col * (paper.xyz * 0.25'f32 + vec3(0.75, 0.75, 0.75))
  fragColor = vec4(col.x, col.y, col.z, 1.0)

## The 3d planet orbs.

proc planetVert(
  gl_Position: var Vec4,
  fragNormal: var Vec3,
  fragMixK: var float32,
  vertexPos: Vec3,
  vertexNormal: Vec3,
  vertexMix: float32
) =
  fragNormal = vertexNormal
  fragMixK = vertexMix
  gl_Position = mvp * vec4(vertexPos.x, vertexPos.y, vertexPos.z, 1.0)

proc norm3(v: Vec3): Vec3 =
  ## Manual normalize, the Vec3 normalize overload upsets shady.
  result = v / max(length(v), 0.000001'f32)

proc planetFrag(
  fragColor: var Vec4,
  fragNormal: Vec3,
  fragMixK: float32
) =
  let n = norm3((modelRot * vec4(
    fragNormal.x, fragNormal.y, fragNormal.z, 0.0)).xyz)
  let light = vec3(0.3714, -0.5571, 0.7428)
  let lit = 0.55'f32 + 0.45'f32 * max(dot(n, light), 0.0'f32)
  let base = ownerColor * fragMixK
  fragColor = vec4(base.x * lit, base.y * lit, base.z * lit, 1.0)

type
  Splat* = object
    x*, y*: float32
    hue*: float32
    size*: float32

  ArtState* = object
    simProgram, injectProgram, drawProgram, planetProgram: GLuint
    stateTex: array[2, GLuint]
    fbo: GLuint
    current: int
    vao, vbo: GLuint
    planetVao, planetVbo: GLuint
    planetVertCount: int32
    paper: GLuint
    brushes: seq[GLuint]
    queue*: seq[Splat]

proc compileShader(kind: GLenum, source: string): GLuint =
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
    quit "art shader compile failed:\n" & log & "\n" & source

proc makeProgram(vertSrc, fragSrc: string): GLuint =
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
    quit "art shader link failed"

proc makeStateTexture(): GLuint =
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GLint(GL_RGBA32F), InkW, InkH, 0,
    GL_RGBA, cGL_FLOAT, nil
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))

proc loadTexture(path: string, red: bool): GLuint =
  ## Loads a png. Red means single channel ink amount, black is ink.
  let image = readImage(path)
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  if red:
    var ink = newString(image.width * image.height)
    for i in 0 ..< image.width * image.height:
      ink[i] = char(255 - image.data[i].r)
    glTexImage2D(
      GL_TEXTURE_2D, 0, GLint(GL_R8),
      GLsizei(image.width), GLsizei(image.height), 0,
      GL_RED, GL_UNSIGNED_BYTE, ink.cstring
    )
  else:
    glTexImage2D(
      GL_TEXTURE_2D, 0, GLint(GL_RGBA8),
      GLsizei(image.width), GLsizei(image.height), 0,
      GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](addr image.data[0])
    )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_REPEAT))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_REPEAT))

proc buildPlanetMesh(art: var ArtState, program: GLuint) =
  ## A low poly icosphere with flat faces. Each vertex carries the
  ## face normal and a mix factor: some faces are nearly black, some
  ## are the owner color, so the orb reads as marbled ink.
  let t = (1.0 + sqrt(5.0)) / 2.0
  var base = @[
    vec3(-1, t, 0), vec3(1, t, 0), vec3(-1, -t, 0), vec3(1, -t, 0),
    vec3(0, -1, t), vec3(0, 1, t), vec3(0, -1, -t), vec3(0, 1, -t),
    vec3(t, 0, -1), vec3(t, 0, 1), vec3(-t, 0, -1), vec3(-t, 0, 1)
  ]
  for v in base.mitems:
    v = normalize(v)
  let faces = @[
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
    [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
    [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
  ]
  var data: seq[float32]
  var rng = initRand(7)
  for face in faces:
    # Subdivide each face once for a rounder orb.
    let
      a = base[face[0]]
      b = base[face[1]]
      c = base[face[2]]
      ab = normalize((a + b) / 2)
      bc = normalize((b + c) / 2)
      ca = normalize((c + a) / 2)
    for tri in [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]:
      let
        normal = normalize(cross(tri[1] - tri[0], tri[2] - tri[0]))
        mixK = if rng.rand(1.0) < 0.45: rng.rand(0.7 .. 1.0) else:
          rng.rand(0.05 .. 0.22)
      for v in tri:
        data.add([v.x, v.y, v.z, normal.x, normal.y, normal.z,
          float32(mixK)])
  art.planetVertCount = int32(data.len div 7)
  glGenVertexArrays(1, addr art.planetVao)
  glBindVertexArray(art.planetVao)
  glGenBuffers(1, addr art.planetVbo)
  glBindBuffer(GL_ARRAY_BUFFER, art.planetVbo)
  glBufferData(
    GL_ARRAY_BUFFER, data.len * 4, addr data[0], GL_STATIC_DRAW)
  # The linker assigns attribute locations, ask instead of assuming.
  let
    posLoc = GLuint(glGetAttribLocation(program, "vertexPos"))
    normalLoc = glGetAttribLocation(program, "vertexNormal")
    mixLoc = glGetAttribLocation(program, "vertexMix")
  glEnableVertexAttribArray(posLoc)
  glVertexAttribPointer(posLoc, 3, cGL_FLOAT, GL_FALSE, 28, nil)
  if normalLoc >= 0:
    glEnableVertexAttribArray(GLuint(normalLoc))
    glVertexAttribPointer(
      GLuint(normalLoc), 3, cGL_FLOAT, GL_FALSE, 28, cast[pointer](12))
  if mixLoc >= 0:
    glEnableVertexAttribArray(GLuint(mixLoc))
    glVertexAttribPointer(
      GLuint(mixLoc), 1, cGL_FLOAT, GL_FALSE, 28, cast[pointer](24))

proc initArt*(): ArtState =
  ## Builds every gl resource for the art mode. Needs a live context.
  result.simProgram = makeProgram(
    toShader(artVert, glsl3Desktop, shaderVertex),
    toShader(artSimFrag, glsl3Desktop, shaderFragment))
  result.injectProgram = makeProgram(
    toShader(artVert, glsl3Desktop, shaderVertex),
    toShader(artInjectFrag, glsl3Desktop, shaderFragment))
  result.drawProgram = makeProgram(
    toShader(artVert, glsl3Desktop, shaderVertex),
    toShader(artDrawFrag, glsl3Desktop, shaderFragment))
  result.planetProgram = makeProgram(
    toShader(planetVert, glsl3Desktop, shaderVertex),
    toShader(planetFrag, glsl3Desktop, shaderFragment))

  var triangle = [
    (-1.0'f32, -1.0'f32), (3.0'f32, -1.0'f32), (-1.0'f32, 3.0'f32)]
  glGenVertexArrays(1, addr result.vao)
  glBindVertexArray(result.vao)
  glGenBuffers(1, addr result.vbo)
  glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
  glBufferData(
    GL_ARRAY_BUFFER, sizeof(triangle), addr triangle, GL_STATIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 8, nil)

  result.stateTex = [makeStateTexture(), makeStateTexture()]
  glGenFramebuffers(1, addr result.fbo)
  for tex in result.stateTex:
    glBindFramebuffer(GL_FRAMEBUFFER, result.fbo)
    glFramebufferTexture2D(
      GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
    glClearColor(0, 0, 0, 0)
    glClear(GL_COLOR_BUFFER_BIT)

  result.paper = loadTexture("data/bg.png", red = false)
  var paths: seq[string]
  for path in walkFiles("experiments/data/splats/*.png"):
    paths.add(path)
  paths.sort()
  for path in paths:
    result.brushes.add(loadTexture(path, red = true))
  doAssert result.brushes.len > 0, "no splat brushes found"
  result.buildPlanetMesh(result.planetProgram)

proc uniformLoc(program: GLuint, name: string): GLint =
  glGetUniformLocation(program, name.cstring)

proc fullscreenPass(
  art: var ArtState, program: GLuint, target: GLuint,
  sourceTex, brushTex: GLuint, splat: Splat, amount: float32,
  angle: float32, viewport: IVec2
) =
  glBindFramebuffer(GL_FRAMEBUFFER, target)
  if target != 0:
    # Offscreen ink passes cover the whole state buffer. For the
    # screen the caller has already set the letterbox viewport.
    glViewport(0, 0, InkW, InkH)
  glBindVertexArray(art.vao)
  glDisable(GL_BLEND)
  glDisable(GL_DEPTH_TEST)
  glUseProgram(program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, sourceTex)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, brushTex)
  glUniform1i(uniformLoc(program, "statePrev"), 0)
  glUniform1i(uniformLoc(program, "paperTex"), 1)
  glUniform2f(
    uniformLoc(program, "resolution"), float32(InkW), float32(InkH))
  glUniform2f(uniformLoc(program, "splatPos"), splat.x, splat.y)
  glUniform1f(uniformLoc(program, "splatHue"), splat.hue)
  glUniform1f(uniformLoc(program, "splatAmount"), amount)
  glUniform1f(uniformLoc(program, "splatSize"), splat.size)
  glUniform1f(uniformLoc(program, "splatAngle"), angle)
  glDrawArrays(GL_TRIANGLES, 0, 3)

proc queueSplat*(art: var ArtState, x, y, hue, size: float32) =
  ## World position splat, queued for the next frame's inject passes.
  art.queue.add(Splat(
    x: x, y: float32(WorldHeight) - y, hue: hue, size: size))

proc frame*(
  art: var ArtState, viewport: IVec2, view: tuple[scale: float32, offset: Vec2],
  sim: Sim, hues: seq[float32], time: float64
) =
  ## One art frame: ink sim step, splat injections, paint present
  ## with the paper mix, then the 3d planet orbs on top.
  var noSplat = Splat()
  art.fullscreenPass(
    art.simProgram, art.fbo, art.stateTex[art.current], art.paper,
    noSplat, 0.0, 0.0, viewport)
  # The sim pass wrote into the other buffer.
  glBindFramebuffer(GL_FRAMEBUFFER, art.fbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    art.stateTex[1 - art.current], 0)
  art.fullscreenPass(
    art.simProgram, art.fbo, art.stateTex[art.current], art.paper,
    noSplat, 0.0, 0.0, viewport)
  art.current = 1 - art.current

  # Inject queued splats, up to a sane cap per frame.
  var injected = 0
  while art.queue.len > 0 and injected < 16:
    let splat = art.queue[0]
    art.queue.delete(0)
    glBindFramebuffer(GL_FRAMEBUFFER, art.fbo)
    glFramebufferTexture2D(
      GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      art.stateTex[1 - art.current], 0)
    art.fullscreenPass(
      art.injectProgram, art.fbo, art.stateTex[art.current],
      art.brushes[rand(art.brushes.len - 1)],
      splat, 4.0, rand(6.28318'f32), viewport)
    art.current = 1 - art.current
    inc injected

  # Present the paint with the paper mixed on top, letterboxed, with
  # paper toned bars around it.
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, viewport.x, viewport.y)
  glClearColor(0.93, 0.91, 0.87, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  glViewport(
    GLint(view.offset.x), GLint(view.offset.y),
    GLsizei(float32(WorldWidth) * view.scale),
    GLsizei(float32(WorldHeight) * view.scale))
  art.fullscreenPass(
    art.drawProgram, 0, art.stateTex[art.current], art.paper,
    noSplat, 0.0, 0.0, viewport)

  # The 3d planet orbs, each with its own size, spin axis and rate.
  glEnable(GL_DEPTH_TEST)
  glClear(GL_DEPTH_BUFFER_BIT)
  glBindVertexArray(art.planetVao)
  glUseProgram(art.planetProgram)
  let proj = ortho(
    0.0'f32, float32(WorldWidth), float32(WorldHeight), 0.0'f32,
    -100.0'f32, 100.0'f32)
  for planet in sim.planets:
    let
      seed = float32(planet.id)
      axis = normalize(vec3(
        sin(seed * 12.9898'f32), cos(seed * 78.233'f32), 0.6'f32))
      rate = 0.2'f32 + 0.5'f32 * abs(sin(seed * 3.7'f32))
      angle = float32(time) * rate + seed
      model = translate(vec3(
          float32(planet.x), float32(planet.y), 0.0'f32)) *
        rotate(angle, axis) *
        scale(vec3(float32(planet.radius)))
      rot = rotate(angle, axis)
      mvp = proj * model
      hue =
        if planet.ownerId == NeutralOwner or
          planet.ownerId > int32(hues.len):
            -1.0'f32
        else:
          hues[planet.ownerId - 1]
      color =
        if hue < 0:
          vec3(0.75, 0.73, 0.70)
        else:
          hsvToRgb(vec3(hue, 0.85'f32, 0.85'f32))
    glUniformMatrix4fv(
      uniformLoc(art.planetProgram, "mvp"), 1, GL_FALSE,
      cast[ptr float32](unsafeAddr mvp))
    glUniformMatrix4fv(
      uniformLoc(art.planetProgram, "modelRot"), 1, GL_FALSE,
      cast[ptr float32](unsafeAddr rot))
    glUniform3f(
      uniformLoc(art.planetProgram, "ownerColor"),
      color.x, color.y, color.z)
    glDrawArrays(GL_TRIANGLES, 0, art.planetVertCount)
  glDisable(GL_DEPTH_TEST)
