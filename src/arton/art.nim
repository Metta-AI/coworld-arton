## The art render mode: an ink fluid canvas behind everything, the
## paper texture mixed on top of it, and spinning low poly 3d planet
## orbs. Ported from experiments/ink.nim. Ships, selection ui and
## text stay on the cpu overlay drawn above all of this.

import
  std/[algorithm, hashes, os, random, tables],
  noisy, opengl, pixie, shady, vmath,
  sims

const
  InkW = WorldWidth.int32
  InkH = WorldHeight.int32

type
  ArtParams* = object
    ## Every live tunable of the art mode, scrubbed from the F1
    ## panel. Ship values are read by the splat queueing in arton.
    velDamp*, speedCap*, fadeKeep*, fadeSubK*, burstPush*: float32
    inkSat*, inkVal*, paperMix*: float32
    planetSat*, planetVal*, washout*, specular*: float32
    spinInner*, spinOuter*: float32
    jitterInner*, jitterShell*, shellScale*, shellMissing*: float32
    ringInner*, ringOuter*: float32
    showRing*: bool
    trailEvery*, trailSize*, trailAmount*, trailDrag*: float32
    deathSize*, deathAmount*, captureSize*, captureAmount*: float32

var artParams* = ArtParams(
  velDamp: 1.0, speedCap: 4.7, fadeKeep: 0.998, fadeSubK: 0.4,
  burstPush: 8.8, inkSat: 1.0, inkVal: 0.84, paperMix: 0.66,
  planetSat: 1.0, planetVal: 1.0, washout: 0.45,
  spinInner: 0.61, spinOuter: 1.89,
  specular: 1.0, jitterInner: 0.035, jitterShell: 0.106,
  shellScale: 1.22, shellMissing: 0.47, ringInner: 1.69,
  ringOuter: 1.51, showRing: false,
  trailEvery: 1, trailSize: 16, trailAmount: 0.4, trailDrag: 8.0,
  deathSize: 48, deathAmount: 4.0, captureSize: 240,
  captureAmount: 4.0)

var
  statePrev: Uniform[Sampler2d]
  paperTex: Uniform[Sampler2d]
  resolution: Uniform[Vec2]
  splatPos: Uniform[Vec2]
  splatHue: Uniform[float32]
  splatAmount: Uniform[float32]
  splatSize: Uniform[float32]
  splatAngle: Uniform[float32]
  splatVel: Uniform[Vec2]
  splatAspect: Uniform[float32]
  mvp: Uniform[Mat4]
  modelRot: Uniform[Mat4]
  ownerColor: Uniform[Vec3]
  velDamp: Uniform[float32]
  speedCap: Uniform[float32]
  fadeMul: Uniform[float32]
  fadeSub: Uniform[float32]
  pushStrength: Uniform[float32]
  colorSat: Uniform[float32]
  colorVal: Uniform[float32]
  paperMix: Uniform[float32]
  planetSpec: Uniform[float32]
  planetWash: Uniform[float32]

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
  # State w stores hue times mass, so plain linear diffusion and
  # texture filtering stay color correct at any density.
  var state = acc / wsum
  state.x = accVel.x / velWsum * velDamp
  state.y = accVel.y / velWsum * velDamp
  let speed = length(vec2(state.x, state.y))
  if speed > speedCap:
    state.x = state.x * speedCap / speed
    state.y = state.y * speedCap / speed
  let zBefore = state.z
  state.z = max(state.z * fadeMul - fadeSub, 0.0'f32)
  # Hue mass scales with the mass it belongs to.
  state.w = state.w * state.z / max(zBefore, 0.0001'f32)
  fragColor = state

proc artInjectFrag(fragColor: var Vec4, uv: Vec2) =
  ## Adds one splat brush stamp to the state, nothing else. Runs once
  ## per queued splat, ping ponging, so many splats land per frame.
  let pos = uv * resolution
  var state = texture(statePrev, uv)
  let rel = (pos - splatPos) / splatSize
  let cA = cos(splatAngle)
  let sA = sin(splatAngle)
  let q = vec2(
    rel.x * cA - rel.y * sA,
    (rel.x * sA + rel.y * cA) / splatAspect) + 0.5'f32
  if q.x > 0.0'f32 and q.x < 1.0'f32 and
    q.y > 0.0'f32 and q.y < 1.0'f32:
    let m = splatAmount * texture(paperTex, q).x
    if m > 0.0001'f32:
      state.w = state.w + splatHue * m
      state.z = state.z + m
      # Directed splats, like ship trails, drag the ink along their
      # motion. Undirected ones burst outward from the center.
      if abs(splatVel.x) + abs(splatVel.y) > 0.001'f32:
        state.x = state.x + splatVel.x * m
        state.y = state.y + splatVel.y * m
      else:
        let away = pos - splatPos + vec2(0.001, 0.001)
        let push = normalize(away) * m * pushStrength
        state.x = state.x + push.x
        state.y = state.y + push.y
  fragColor = state

proc trailVert(
  gl_Position: var Vec4, vUv: var Vec2, vHue: var float32,
  vAmount: var float32, vVel: var Vec2,
  vertexPos: Vec2, vertexUv: Vec2, vertexHue: float32,
  vertexAmount: float32, vertexVel: Vec2
) =
  ## Canvas pixel coords to ndc over the ink state buffer.
  let ndc = vertexPos / resolution * 2.0'f32 - vec2(1.0, 1.0)
  gl_Position = vec4(ndc.x, ndc.y, 0.0, 1.0)
  vUv = vertexUv
  vHue = vertexHue
  vAmount = vertexAmount
  vVel = vertexVel

proc trailFrag(
  fragColor: var Vec4, vUv: Vec2, vHue: float32,
  vAmount: float32, vVel: Vec2
) =
  ## Additive delta: velocity shaped by the brush, ink mass and hue
  ## mass where the stamp has ink. Blends ONE, ONE onto the state.
  let b = texture(paperTex, vUv).x
  let m = vAmount * b
  fragColor = vec4(vVel.x * b, vVel.y * b, m, vHue * m)

proc shipVert(
  gl_Position: var Vec4, vUv: var Vec2,
  vertexPos: Vec2, vertexUv: Vec2
) =
  ## Window pixel coords to ndc, y flipped.
  let ndc = vertexPos / resolution * 2.0'f32 - vec2(1.0, 1.0)
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0)
  vUv = vertexUv

proc shipFrag(fragColor: var Vec4, vUv: Vec2) =
  ## The sprite draws as authored: white body, black stroke, like
  ## the planet count letters. Premultiplied straight from the png.
  fragColor = texture(paperTex, vUv)

proc circleVert(
  gl_Position: var Vec4, vLocal: var Vec2, vRadius: var float32,
  vFill: var Vec4, vStroke: var Vec4,
  vertexPos: Vec2, vertexLocal: Vec2, vertexRadius: float32,
  vertexFill: Vec4, vertexStroke: Vec4
) =
  ## Window pixel coords to ndc, y flipped.
  let ndc = vertexPos / resolution * 2.0'f32 - vec2(1.0, 1.0)
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0)
  vLocal = vertexLocal
  vRadius = vertexRadius
  vFill = vertexFill
  vStroke = vertexStroke

proc circleFrag(
  fragColor: var Vec4, vLocal: Vec2, vRadius: float32,
  vFill: Vec4, vStroke: Vec4
) =
  ## Antialiased filled disc with a two pixel outline band.
  let d = length(vLocal)
  let fillA = 1.0'f32 - sstep(vRadius - 1.0'f32, vRadius, d)
  let strokeA =
    (1.0'f32 - sstep(vRadius, vRadius + 1.0'f32, d)) *
    sstep(vRadius - 2.5'f32, vRadius - 1.5'f32, d)
  var col = vFill * fillA
  col = col * (1.0'f32 - strokeA) + vStroke * strokeA
  fragColor = vec4(
    col.x * col.w, col.y * col.w, col.z * col.w, col.w)

proc compositeFrag(fragColor: var Vec4, uv: Vec2) =
  ## Draws the resolved msaa planet layer over the canvas.
  fragColor = texture(statePrev, uv)

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
  let hue = state.w / max(rho, 0.0001'f32)
  let fcol = hsvToRgb(vec3(hue, colorSat, colorVal))
  var col = vec3(3.0, 3.0, 3.0)
  col = mixN(col, fcol * (1.5'f32 * b + specular * 5.0'f32), a)
  col = tanh3(col)
  let paper = texture(paperTex, vec2(uv.x, 1.0'f32 - uv.y))
  let keep = 1.0'f32 - paperMix
  col = col * (paper.xyz * paperMix + vec3(keep, keep, keep))
  fragColor = vec4(col.x, col.y, col.z, 1.0)

## The 3d planet orbs, ported from experiments/sphere.nim: a solid
## jittered inner sphere, a shard shell rotating at its own rate and
## a viewer facing gradient ring. Face colors mix the owner color.

proc norm3(v: Vec3): Vec3 =
  result = v / sqrt(dot(v, v))

proc planetVert(
  gl_Position: var Vec4, vNormal: var Vec3, vMixK: var float32,
  vVariant: var float32, vertexPos: Vec3, vertexNormal: Vec3,
  vertexMix: float32, vertexVariant: float32
) =
  let world = modelRot * vec4(
    vertexPos.x, vertexPos.y, vertexPos.z, 1.0)
  gl_Position = mvp * world
  let n = modelRot * vec4(
    vertexNormal.x, vertexNormal.y, vertexNormal.z, 0.0)
  vNormal = vec3(n.x, n.y, n.z)
  vMixK = vertexMix
  vVariant = vertexVariant

proc planetFrag(
  fragColor: var Vec4, vNormal: Vec3, vMixK: float32,
  vVariant: float32
) =
  let n = norm3(vNormal)
  let l = norm3(vec3(0.15, 1.0, 0.45))
  let d = abs(dot(n, l))
  let h = norm3(l + vec3(0.0, 0.0, 1.0))
  let sp = pow(abs(dot(n, h)), 24.0'f32) * planetSpec
  var shade = 0.3'f32 + 0.75'f32 * d
  var base = vec3(vVariant, vVariant, vVariant)
  if vVariant > 1.5'f32:
    # Ring: unshaded gray to owner gradient.
    shade = 1.0'f32
    let t = vMixK
    base = vec3(0.88, 0.87, 0.89) * (1.0'f32 - t) +
      ownerColor * (t * 0.85'f32)
  else:
    # Every face is tinted with the owner color, the mix flag only
    # picks the bright or the dim brightness pool.
    base = ownerColor * vVariant
  var outC = base * shade
  if vVariant < 1.5'f32:
    # Faces square to the light wash out to full white.
    let wl = pow(d, 2.5'f32) * planetWash
    outC = outC * (1.0'f32 - wl) + vec3(1.0, 1.0, 1.0) * wl
  fragColor = vec4(
    outC.x + sp, outC.y + sp, outC.z + sp, 1.0)

type
  PlanetMesh = object
    vao, vbo: GLuint
    vertCount: GLsizei

  PlanetSet = object
    inner, outer, ring: PlanetMesh

  Splat* = object
    x*, y*: float32
    hue*: float32
    size*: float32
    amount*: float32
    vx*, vy*: float32
    angle*: float32
    ship*: bool

  ArtState* = object
    simProgram, injectProgram, drawProgram, planetProgram: GLuint
    stateTex: array[2, GLuint]
    fbo: GLuint
    current: int
    vao, vbo: GLuint
    orbCache: Table[int32, PlanetSet]
    meshStamp: array[6, float32]
    paper: GLuint
    brushes: seq[GLuint]
    shipBrush: GLuint
    ## The planets render into a multisampled offscreen layer that
    ## resolves and composites over the ink, so only their triangle
    ## edges pay for msaa.
    compositeProgram: GLuint
    msaaFbo, msaaColor, msaaDepth: GLuint
    resolveFbo, resolveTex: GLuint
    msaaSize: IVec2
    shipProgram, shipTex, shipVao, shipVbo: GLuint
    shipAspect, shipBrushAspect: float32
    trailProgram, trailVao, trailVbo: GLuint
    circleProgram, circleVao, circleVbo: GLuint
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

proc inkTexture(image: Image): GLuint =
  ## Single channel ink amount texture from an image, black is ink.
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  var ink = newString(image.width * image.height)
  for i in 0 ..< image.width * image.height:
    ink[i] = char(255 - image.data[i].r)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GLint(GL_R8),
    GLsizei(image.width), GLsizei(image.height), 0,
    GL_RED, GL_UNSIGNED_BYTE, ink.cstring
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))

proc shipBrushTexture(): tuple[tex: GLuint, aspect: float32] =
  ## The blurred ship splat as an ink stamp, rotated nose to plus x,
  ## so a trail stamp rotated by the ship heading inks its shape.
  ## The rotated canvas swaps the sprite dims so nothing clips, and
  ## the aspect (height over width) keeps the stamp unstretched.
  let sprite = readImage("data/ship_splat.png")
  let image = newImage(sprite.height, sprite.width)
  image.fill(rgba(255, 255, 255, 255))
  let ctx = newContext(image)
  ctx.translate(vec2(
    float32(image.width) / 2, float32(image.height) / 2))
  ctx.rotate(float32(PI) / 2)
  ctx.drawImage(
    sprite,
    -float32(sprite.width) / 2, -float32(sprite.height) / 2)
  return (
    inkTexture(image),
    float32(image.height) / float32(image.width))

proc loadTexture(path: string, red: bool): GLuint =
  ## Loads a png. Red means single channel ink amount, black is ink.
  let image = readImage(path)
  if red:
    return inkTexture(image)
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  block:
    glTexImage2D(
      GL_TEXTURE_2D, 0, GLint(GL_RGBA8),
      GLsizei(image.width), GLsizei(image.height), 0,
      GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](addr image.data[0])
    )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_REPEAT))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_REPEAT))

proc jitterV(p: Vec3, seed: int64, amount: float32): Vec3 =
  var h: Hash = 0
  h = h !& hash(cast[int32](p.x)) !& hash(cast[int32](p.y)) !&
    hash(cast[int32](p.z)) !& hash(seed)
  var r = initRand(int64(h) xor seed)
  let offset = vec3(
    r.rand(2.0'f32) - 1.0'f32, r.rand(2.0'f32) - 1.0'f32,
    r.rand(2.0'f32) - 1.0'f32)
  p + offset * amount

proc icosphere(subdivisions: int): seq[array[3, Vec3]] =
  let t = (1.0'f32 + sqrt(5.0'f32)) / 2.0'f32
  var v = @[
    vec3(-1, t, 0), vec3(1, t, 0), vec3(-1, -t, 0), vec3(1, -t, 0),
    vec3(0, -1, t), vec3(0, 1, t), vec3(0, -1, -t), vec3(0, 1, -t),
    vec3(t, 0, -1), vec3(t, 0, 1), vec3(-t, 0, -1), vec3(-t, 0, 1)]
  for p in v.mitems:
    p = normalize(p)
  let faces = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
    [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
    [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
  for face in faces:
    result.add([v[face[0]], v[face[1]], v[face[2]]])
  for round in 0 ..< subdivisions:
    var next: seq[array[3, Vec3]]
    for tri in result:
      let
        ab = normalize((tri[0] + tri[1]) / 2.0'f32)
        bc = normalize((tri[1] + tri[2]) / 2.0'f32)
        ca = normalize((tri[2] + tri[0]) / 2.0'f32)
      next.add([tri[0], ab, ca])
      next.add([tri[1], bc, ab])
      next.add([tri[2], ca, bc])
      next.add([ab, bc, ca])
    result = next

proc buildOrb(
  missing, teamRatio: float32, seed: int64, scale, jitterAmt: float32
): seq[float32] =
  ## Sphere.nim buildMesh with colors as mix plus variant scalars.
  var faceRand = initRand(seed)
  let islands = initSimplex(int(seed))
  for tri in icosphere(2):
    let colorPick = faceRand.rand(1.0'f32)
    let teamV = [0.75'f32, 0.88, 0.56, 0.95][faceRand.rand(3)]
    let dimV = [0.30'f32, 0.42, 0.22][faceRand.rand(2)]
    let centroid = normalize(tri[0] + tri[1] + tri[2])
    let field = islands.value(
      centroid.x * 1.3'f32, centroid.y * 1.3'f32,
      centroid.z * 1.3'f32) * 0.5'f32 + 0.5'f32
    if field < missing:
      continue
    let
      a = jitterV(tri[0], seed, jitterAmt) * scale
      b = jitterV(tri[1], seed, jitterAmt) * scale
      c = jitterV(tri[2], seed, jitterAmt) * scale
      normal = normalize(cross(b - a, c - a))
      team = colorPick < teamRatio
    for p in [a, b, c]:
      result.add([p.x, p.y, p.z, normal.x, normal.y, normal.z,
        (if team: 1.0'f32 else: 0.0'f32),
        (if team: teamV else: dimV)])

proc buildRing(innerR, outerR: float32): seq[float32] =
  ## Sphere.nim ring: flat annulus, gradient encoded in mixK with
  ## variant 2 marking ring mode.
  for i in 0 ..< 96:
    let
      a0 = float32(i) / 96.0'f32 * 2.0'f32 * PI
      a1 = float32(i + 1) / 96.0'f32 * 2.0'f32 * PI
      i0 = vec3(cos(a0) * innerR, sin(a0) * innerR, 0)
      i1 = vec3(cos(a1) * innerR, sin(a1) * innerR, 0)
      o0 = vec3(cos(a0) * outerR, sin(a0) * outerR, 0)
      o1 = vec3(cos(a1) * outerR, sin(a1) * outerR, 0)
      t0 = (cos(a0) + 1.0'f32) / 2.0'f32
      t1 = (cos(a1) + 1.0'f32) / 2.0'f32
    for (p, t) in [(i0, t0), (o0, t0), (o1, t1), (i0, t0), (o1, t1),
        (i1, t1)]:
      result.add([p.x, p.y, p.z, 0.0'f32, 0.0'f32, 1.0'f32, t, 2.0'f32])

proc uploadPlanetMesh(art: var ArtState, data: seq[float32]): PlanetMesh =
  glGenVertexArrays(1, addr result.vao)
  glBindVertexArray(result.vao)
  glGenBuffers(1, addr result.vbo)
  glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
  glBufferData(
    GL_ARRAY_BUFFER, data.len * 4, unsafeAddr data[0], GL_STATIC_DRAW)
  let stride = GLsizei(32)
  for spec in [("vertexPos", 3, 0), ("vertexNormal", 3, 12),
      ("vertexMix", 1, 24), ("vertexVariant", 1, 28)]:
    let loc = glGetAttribLocation(art.planetProgram, spec[0].cstring)
    if loc >= 0:
      glEnableVertexAttribArray(GLuint(loc))
      glVertexAttribPointer(
        GLuint(loc), GLint(spec[1]), cGL_FLOAT, GL_FALSE, stride,
        cast[pointer](spec[2]))
  result.vertCount = GLsizei(data.len div 8)

proc meshParamStamp(): array[6, float32] =
  [artParams.jitterInner, artParams.jitterShell,
    artParams.shellScale, artParams.shellMissing,
    artParams.ringInner, artParams.ringOuter]

proc dropOrbCache(art: var ArtState) =
  ## Frees every cached planet mesh so the next frame rebuilds them
  ## with the current mesh params.
  for id, meshes in art.orbCache:
    for mesh in [meshes.inner, meshes.outer, meshes.ring]:
      var vao = mesh.vao
      var vbo = mesh.vbo
      glDeleteVertexArrays(1, addr vao)
      glDeleteBuffers(1, addr vbo)
  art.orbCache.clear()

proc planetMeshes(art: var ArtState, id: int32): PlanetSet =
  ## Cached per planet meshes, sphere.nim settings, seeded by id.
  if id in art.orbCache:
    return art.orbCache[id]
  let seed = int64(id) * 977 + 12345
  result.inner = art.uploadPlanetMesh(
    buildOrb(0.0, 0.44, seed, 1.0, artParams.jitterInner))
  result.outer = art.uploadPlanetMesh(
    buildOrb(artParams.shellMissing, 0.44, seed + 7,
      artParams.shellScale, artParams.jitterShell))
  result.ring = art.uploadPlanetMesh(
    buildRing(artParams.ringInner, artParams.ringOuter))
  art.orbCache[id] = result

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
  result.compositeProgram = makeProgram(
    toShader(artVert, glsl3Desktop, shaderVertex),
    toShader(compositeFrag, glsl3Desktop, shaderFragment))

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

  result.shipProgram = makeProgram(
    toShader(shipVert, glsl3Desktop, shaderVertex),
    toShader(shipFrag, glsl3Desktop, shaderFragment))
  result.shipTex = loadTexture("data/ship.png", red = false)
  block:
    let sprite = readImage("data/ship.png")
    result.shipAspect =
      float32(sprite.height) / float32(sprite.width)
  glGenVertexArrays(1, addr result.shipVao)
  glBindVertexArray(result.shipVao)
  glGenBuffers(1, addr result.shipVbo)
  glBindBuffer(GL_ARRAY_BUFFER, result.shipVbo)
  let shipStride = GLsizei(16)
  for spec in [("vertexPos", 2, 0), ("vertexUv", 2, 8)]:
    let loc = glGetAttribLocation(
      result.shipProgram, spec[0].cstring)
    if loc >= 0:
      glEnableVertexAttribArray(GLuint(loc))
      glVertexAttribPointer(
        GLuint(loc), GLint(spec[1]), cGL_FLOAT, GL_FALSE, shipStride,
        cast[pointer](spec[2]))

  result.trailProgram = makeProgram(
    toShader(trailVert, glsl3Desktop, shaderVertex),
    toShader(trailFrag, glsl3Desktop, shaderFragment))
  glGenVertexArrays(1, addr result.trailVao)
  glBindVertexArray(result.trailVao)
  glGenBuffers(1, addr result.trailVbo)
  glBindBuffer(GL_ARRAY_BUFFER, result.trailVbo)
  let trailStride = GLsizei(32)
  for spec in [("vertexPos", 2, 0), ("vertexUv", 2, 8),
      ("vertexHue", 1, 16), ("vertexAmount", 1, 20),
      ("vertexVel", 2, 24)]:
    let loc = glGetAttribLocation(
      result.trailProgram, spec[0].cstring)
    if loc >= 0:
      glEnableVertexAttribArray(GLuint(loc))
      glVertexAttribPointer(
        GLuint(loc), GLint(spec[1]), cGL_FLOAT, GL_FALSE,
        trailStride, cast[pointer](spec[2]))

  result.circleProgram = makeProgram(
    toShader(circleVert, glsl3Desktop, shaderVertex),
    toShader(circleFrag, glsl3Desktop, shaderFragment))
  glGenVertexArrays(1, addr result.circleVao)
  glBindVertexArray(result.circleVao)
  glGenBuffers(1, addr result.circleVbo)
  glBindBuffer(GL_ARRAY_BUFFER, result.circleVbo)
  let circleStride = GLsizei(52)
  for spec in [("vertexPos", 2, 0), ("vertexLocal", 2, 8),
      ("vertexRadius", 1, 16), ("vertexFill", 4, 20),
      ("vertexStroke", 4, 36)]:
    let loc = glGetAttribLocation(
      result.circleProgram, spec[0].cstring)
    if loc >= 0:
      glEnableVertexAttribArray(GLuint(loc))
      glVertexAttribPointer(
        GLuint(loc), GLint(spec[1]), cGL_FLOAT, GL_FALSE,
        circleStride, cast[pointer](spec[2]))

  result.paper = loadTexture("data/bg.png", red = false)
  var paths: seq[string]
  for path in walkFiles("data/splats/*.png"):
    paths.add(path)
  paths.sort()
  for path in paths:
    result.brushes.add(loadTexture(path, red = true))
  doAssert result.brushes.len > 0, "no splat brushes found"
  (result.shipBrush, result.shipBrushAspect) = shipBrushTexture()

proc uniformLoc(program: GLuint, name: string): GLint =
  glGetUniformLocation(program, name.cstring)

proc clearCanvas*(art: var ArtState) =
  ## Wipes the ink state back to blank paper, for game restarts.
  art.queue.setLen(0)
  for tex in art.stateTex:
    glBindFramebuffer(GL_FRAMEBUFFER, art.fbo)
    glFramebufferTexture2D(
      GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
    glClearColor(0, 0, 0, 0)
    glClear(GL_COLOR_BUFFER_BIT)

proc fullscreenPass(
  art: var ArtState, program: GLuint, target: GLuint,
  sourceTex, brushTex: GLuint, splat: Splat, amount: float32,
  angle: float32, viewport: IVec2, aspect = 1.0'f32
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
  glUniform2f(uniformLoc(program, "splatVel"), splat.vx, splat.vy)
  glUniform1f(uniformLoc(program, "splatAspect"), aspect)
  glUniform1f(uniformLoc(program, "velDamp"), artParams.velDamp)
  glUniform1f(uniformLoc(program, "speedCap"), artParams.speedCap)
  glUniform1f(uniformLoc(program, "fadeMul"), artParams.fadeKeep)
  glUniform1f(
    uniformLoc(program, "fadeSub"), artParams.fadeSubK / 1000.0)
  glUniform1f(
    uniformLoc(program, "pushStrength"), artParams.burstPush)
  glUniform1f(uniformLoc(program, "colorSat"), artParams.inkSat)
  glUniform1f(uniformLoc(program, "colorVal"), artParams.inkVal)
  glUniform1f(uniformLoc(program, "paperMix"), artParams.paperMix)
  glDrawArrays(GL_TRIANGLES, 0, 3)

proc queueSplat*(
  art: var ArtState, x, y, hue, size: float32,
  amount = 4.0'f32, vx = 0.0'f32, vy = 0.0'f32,
  angle = 0.0'f32, ship = false
) =
  ## World position splat, queued for the next frame's inject
  ## passes. A velocity makes it a directed trail stain instead of
  ## an outward burst. Ship splats stamp the ship V brush at the
  ## given world heading angle instead of a random splatter brush.
  ## The y axis flips into canvas space.
  art.queue.add(Splat(
    x: x, y: float32(WorldHeight) - y, hue: hue, size: size,
    amount: amount, vx: vx, vy: -vy, angle: angle, ship: ship))

proc drawOne(program: GLuint, mesh: PlanetMesh, model, proj: Mat4) =
  ## One planet mesh with its own model matrix.
  var m = model
  var p = proj
  glBindVertexArray(mesh.vao)
  glUniformMatrix4fv(
    glGetUniformLocation(program, "modelRot"), 1, GL_FALSE,
    cast[ptr float32](addr m))
  glUniformMatrix4fv(
    glGetUniformLocation(program, "mvp"), 1, GL_FALSE,
    cast[ptr float32](addr p))
  glDrawArrays(GL_TRIANGLES, 0, mesh.vertCount)

proc drawShips*(
  art: var ArtState, viewport: IVec2,
  view: tuple[scale: float32, offset: Vec2], sim: Sim,
  size: float32
) =
  ## Every ship as one rotated textured quad in a single gl draw.
  if sim.ships.len == 0:
    return
  var verts = newSeqOfCap[float32](sim.ships.len * 6 * 4)
  let halfW = size / 2 * view.scale
  let halfH = halfW * art.shipAspect
  for ship in sim.ships:
    let
      x = view.offset.x +
        float32(ship.x) / float32(SubpixelScale) * view.scale
      y = view.offset.y +
        float32(ship.y) / float32(SubpixelScale) * view.scale
      # The sprite nose points up, headings point plus x, so the
      # quad rotates an extra quarter turn like the cpu path did.
      angle = float32(ship.heading) * 2.0'f32 * PI / 256.0'f32 +
        float32(PI) / 2
      ca = cos(angle)
      sa = sin(angle)
    template corner(ox, oy, u, v: float32) =
      verts.add([
        float32(x + ox * ca - oy * sa),
        float32(y + ox * sa + oy * ca),
        float32(u), float32(v)])
    corner(-halfW, -halfH, 0, 0)
    corner(halfW, -halfH, 1, 0)
    corner(halfW, halfH, 1, 1)
    corner(-halfW, -halfH, 0, 0)
    corner(halfW, halfH, 1, 1)
    corner(-halfW, halfH, 0, 1)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, viewport.x, viewport.y)
  glBindVertexArray(art.shipVao)
  glBindBuffer(GL_ARRAY_BUFFER, art.shipVbo)
  glBufferData(
    GL_ARRAY_BUFFER, verts.len * 4, addr verts[0], GL_STREAM_DRAW)
  glDisable(GL_DEPTH_TEST)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(art.shipProgram)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, art.shipTex)
  glUniform1i(uniformLoc(art.shipProgram, "paperTex"), 0)
  glUniform2f(
    uniformLoc(art.shipProgram, "resolution"),
    float32(viewport.x), float32(viewport.y))
  glDrawArrays(GL_TRIANGLES, 0, GLsizei(verts.len div 7))
  glDisable(GL_BLEND)

proc injectTrails(art: var ArtState, splats: seq[Splat]) =
  ## Every ship trail stamp in one additive pass straight into the
  ## current state texture: small quads, no per splat fullscreen
  ## cost, so every tick trails from big fleets all land.
  if splats.len == 0:
    return
  var verts = newSeqOfCap[float32](splats.len * 6 * 8)
  for splat in splats:
    let
      ca = cos(splat.angle)
      sa = sin(splat.angle)
      # Canvas y is flipped, so the world heading direction becomes
      # (cos, -sin) with (sin, cos) perpendicular.
      ux = ca
      uy = -sa
      px = sa
      py = ca
      hw = splat.size / 2
      hh = splat.size * art.shipBrushAspect / 2
    template corner(du, dv, u, v: float32) =
      verts.add([
        float32(splat.x + ux * du + px * dv),
        float32(splat.y + uy * du + py * dv),
        float32(u), float32(v),
        splat.hue, splat.amount, splat.vx, splat.vy])
    corner(-hw, -hh, 0, 0)
    corner(hw, -hh, 1, 0)
    corner(hw, hh, 1, 1)
    corner(-hw, -hh, 0, 0)
    corner(hw, hh, 1, 1)
    corner(-hw, hh, 0, 1)
  glBindFramebuffer(GL_FRAMEBUFFER, art.fbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    art.stateTex[art.current], 0)
  glViewport(0, 0, InkW, InkH)
  glBindVertexArray(art.trailVao)
  glBindBuffer(GL_ARRAY_BUFFER, art.trailVbo)
  glBufferData(
    GL_ARRAY_BUFFER, verts.len * 4, addr verts[0], GL_STREAM_DRAW)
  glDisable(GL_DEPTH_TEST)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE)
  glUseProgram(art.trailProgram)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, art.shipBrush)
  glUniform1i(uniformLoc(art.trailProgram, "paperTex"), 0)
  glUniform2f(
    uniformLoc(art.trailProgram, "resolution"),
    float32(InkW), float32(InkH))
  glDrawArrays(GL_TRIANGLES, 0, GLsizei(verts.len div 8))
  glDisable(GL_BLEND)

proc drawDebugPlanets*(
  art: var ArtState, viewport: IVec2,
  view: tuple[scale: float32, offset: Vec2], sim: Sim,
  fills, strokes: seq[Vec4]
) =
  ## The debug view planets as one batch of antialiased gl discs,
  ## indexed per planet, instead of cpu rasterized circles.
  if sim.planets.len == 0:
    return
  var verts = newSeqOfCap[float32](sim.planets.len * 6 * 13)
  for planet in sim.planets:
    let
      x = view.offset.x + float32(planet.x) * view.scale
      y = view.offset.y + float32(planet.y) * view.scale
      radius = float32(planet.radius) * view.scale
      half = radius + 3
      fill = fills[planet.id]
      stroke = strokes[planet.id]
    template corner(ox, oy: float32) =
      verts.add([
        x + ox, y + oy, ox, oy, radius,
        fill.x, fill.y, fill.z, fill.w,
        stroke.x, stroke.y, stroke.z, stroke.w])
    corner(-half, -half)
    corner(half, -half)
    corner(half, half)
    corner(-half, -half)
    corner(half, half)
    corner(-half, half)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, viewport.x, viewport.y)
  glBindVertexArray(art.circleVao)
  glBindBuffer(GL_ARRAY_BUFFER, art.circleVbo)
  glBufferData(
    GL_ARRAY_BUFFER, verts.len * 4, addr verts[0], GL_STREAM_DRAW)
  glDisable(GL_DEPTH_TEST)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(art.circleProgram)
  glUniform2f(
    uniformLoc(art.circleProgram, "resolution"),
    float32(viewport.x), float32(viewport.y))
  glDrawArrays(GL_TRIANGLES, 0, GLsizei(verts.len div 13))
  glDisable(GL_BLEND)

proc ensureMsaa(art: var ArtState, size: IVec2) =
  ## Allocates or resizes the multisampled planet layer and its
  ## resolve target to the window size.
  if art.msaaSize == size:
    return
  art.msaaSize = size
  if art.msaaFbo == 0:
    glGenFramebuffers(1, addr art.msaaFbo)
    glGenRenderbuffers(1, addr art.msaaColor)
    glGenRenderbuffers(1, addr art.msaaDepth)
    glGenFramebuffers(1, addr art.resolveFbo)
    glGenTextures(1, addr art.resolveTex)
  glBindRenderbuffer(GL_RENDERBUFFER, art.msaaColor)
  glRenderbufferStorageMultisample(
    GL_RENDERBUFFER, 4, GL_RGBA8, size.x, size.y)
  glBindRenderbuffer(GL_RENDERBUFFER, art.msaaDepth)
  glRenderbufferStorageMultisample(
    GL_RENDERBUFFER, 4, GL_DEPTH_COMPONENT24, size.x, size.y)
  glBindFramebuffer(GL_FRAMEBUFFER, art.msaaFbo)
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER,
    art.msaaColor)
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
    art.msaaDepth)
  glBindTexture(GL_TEXTURE_2D, art.resolveTex)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GLint(GL_RGBA8), size.x, size.y, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
  glBindFramebuffer(GL_FRAMEBUFFER, art.resolveFbo)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
    art.resolveTex, 0)

proc frame*(
  art: var ArtState, viewport: IVec2, view: tuple[scale: float32, offset: Vec2],
  sim: Sim, hues: seq[float32], time: float64, inkSteps = 2
) =
  ## One art frame: ink sim steps, splat injections, paint present
  ## with the paper mix, then the 3d planet orbs on top. inkSteps
  ## scales the ink flow with the game speed, two passes per frame
  ## at normal speed.
  var noSplat = Splat()
  for step in 0 ..< inkSteps:
    glBindFramebuffer(GL_FRAMEBUFFER, art.fbo)
    glFramebufferTexture2D(
      GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
      art.stateTex[1 - art.current], 0)
    art.fullscreenPass(
      art.simProgram, art.fbo, art.stateTex[art.current], art.paper,
      noSplat, 0.0, 0.0, viewport)
    art.current = 1 - art.current

  # Ship trail stamps all land in one additive batch, the other
  # splats keep the brush ping pong path with a sane cap.
  var trailSplats: seq[Splat]
  var otherSplats: seq[Splat]
  for splat in art.queue:
    if splat.ship:
      trailSplats.add(splat)
    else:
      otherSplats.add(splat)
  art.queue = otherSplats
  art.injectTrails(trailSplats)
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
      splat, splat.amount, rand(6.28318'f32), viewport)
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

  # The 3d planet orbs: inner sphere, shard shell and ring per
  # planet, each with its own size and rates from the planet id.
  # They render into their own multisampled layer so the triangle
  # edges come out smooth, then resolve and composite over the ink.
  art.ensureMsaa(viewport)
  glBindFramebuffer(GL_FRAMEBUFFER, art.msaaFbo)
  glViewport(0, 0, viewport.x, viewport.y)
  glClearColor(0, 0, 0, 0)
  glEnable(GL_DEPTH_TEST)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glViewport(
    GLint(view.offset.x), GLint(view.offset.y),
    GLsizei(float32(WorldWidth) * view.scale),
    GLsizei(float32(WorldHeight) * view.scale))
  glUseProgram(art.planetProgram)
  if art.meshStamp != meshParamStamp():
    art.meshStamp = meshParamStamp()
    art.dropOrbCache()
  glUniform1f(
    uniformLoc(art.planetProgram, "planetSpec"), artParams.specular)
  glUniform1f(
    uniformLoc(art.planetProgram, "planetWash"), artParams.washout)
  let proj = ortho(
    0.0'f32, float32(WorldWidth), float32(WorldHeight), 0.0'f32,
    -200.0'f32, 200.0'f32)
  for planet in sim.planets:
    let
      meshes = art.planetMeshes(planet.id)
      seed = float32(planet.id)
      rateK = 0.6'f32 + 0.8'f32 * abs(sin(seed * 3.7'f32))
      base = translate(vec3(
          float32(planet.x), float32(planet.y), 0.0'f32)) *
        scale(vec3(float32(planet.radius)))
      hue =
        if planet.ownerId == NeutralOwner or
          planet.ownerId > int32(hues.len):
            -1.0'f32
        else:
          hues[planet.ownerId - 1]
      color =
        if hue < 0:
          vec3(0.62, 0.60, 0.58)
        else:
          hsvToRgb(vec3(hue, artParams.planetSat, artParams.planetVal))
    glUniform3f(
      uniformLoc(art.planetProgram, "ownerColor"),
      color.x, color.y, color.z)

    let tfInner = float32(time) * artParams.spinInner
    let tfOuter = float32(time) * artParams.spinOuter
    drawOne(art.planetProgram, meshes.inner,
      base * rotateY(0.35'f32 * rateK * tfInner + seed) *
      rotateX(0.35'f32), proj)
    drawOne(art.planetProgram, meshes.outer,
      base * rotateY(-0.64'f32 * rateK * tfOuter + seed) *
      rotateZ(0.22'f32), proj)
    if artParams.showRing:
      drawOne(art.planetProgram, meshes.ring,
        base * rotateZ(2.0'f32 * rateK * tfOuter + seed), proj)
  glDisable(GL_DEPTH_TEST)

  # Resolve the msaa layer and blend it onto the screen.
  glBindFramebuffer(GL_READ_FRAMEBUFFER, art.msaaFbo)
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, art.resolveFbo)
  glBlitFramebuffer(
    0, 0, viewport.x, viewport.y, 0, 0, viewport.x, viewport.y,
    GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, viewport.x, viewport.y)
  glBindVertexArray(art.vao)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glUseProgram(art.compositeProgram)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, art.resolveTex)
  glUniform1i(uniformLoc(art.compositeProgram, "statePrev"), 0)
  glDrawArrays(GL_TRIANGLES, 0, 3)
  glDisable(GL_BLEND)
