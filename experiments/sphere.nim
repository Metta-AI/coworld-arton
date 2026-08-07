## Low poly planet experiment. Draws a random lumpy icosphere, the
## arton planet look: an inner solid sphere whose vertices are
## jittered so every polygon is a different shape, and an outer
## shard shell, a second jittered sphere with most triangles missing
## that rotates at its own rate. Triangles are team purple or black,
## lit flat from the top.
##
## Run:        nim r experiments/sphere.nim
## Self test:  nim r experiments/sphere.nim --shot=tmp/sphere.png --frames=60
##
## R rerolls the sphere. The silky panel has sliders for
## subdivisions, missing shell triangles, purple vs black, and both
## rotation rates.

import
  std/[hashes, os, random, strutils, times],
  opengl, pixie, shady, silky, vmath, windy

const WindowSize = 1024

# Shader uniforms.
var
  model: Uniform[Mat4]
  viewProj: Uniform[Mat4]

proc sphereVert(gl_Position: var Vec4, vNormal: var Vec3,
    vColor: var Vec3, vertexPos: Vec3, vertexNormal: Vec3,
    vertexColor: Vec3) =
  ## Transforms position and rotates the flat face normal along.
  let world = model * vec4(vertexPos.x, vertexPos.y, vertexPos.z, 1.0)
  gl_Position = viewProj * world
  let n = model * vec4(
    vertexNormal.x, vertexNormal.y, vertexNormal.z, 0.0)
  vNormal = vec3(n.x, n.y, n.z)
  vColor = vertexColor

proc norm3(v: Vec3): Vec3 =
  ## Hand rolled normalize, the vmath generic upsets shady for Vec3.
  result = v / sqrt(dot(v, v))

proc sphereFrag(fragColor: var Vec4, vNormal: Vec3, vColor: Vec3) =
  ## Light from the top on flat normals, two sided so the inside of
  ## the shard shell reads too, with a small glossy highlight.
  let n = norm3(vNormal)
  let l = norm3(vec3(0.15, 1.0, 0.45))
  let d = abs(dot(n, l))
  let h = norm3(l + vec3(0.0, 0.0, 1.0))
  let sp = pow(abs(dot(n, h)), 24.0'f32) * 0.35'f32
  let shade = 0.3'f32 + 0.75'f32 * d
  fragColor = vec4(
    vColor.x * shade + sp,
    vColor.y * shade + sp,
    vColor.z * shade + sp,
    1.0
  )

## Mesh generation: icosahedron subdivision with jittered vertices.

proc jitter(p: Vec3, seed: int64, amount: float32): Vec3 =
  ## Deterministic vertex offset hashed from the position, so shared
  ## vertices between faces move identically and the mesh stays
  ## watertight while every polygon becomes a different shape.
  var h: Hash = 0
  h = h !& hash(cast[int32](p.x)) !& hash(cast[int32](p.y)) !&
    hash(cast[int32](p.z)) !& hash(seed)
  var r = initRand(int64(h) xor seed)
  let offset = vec3(
    r.rand(2.0'f32) - 1.0'f32,
    r.rand(2.0'f32) - 1.0'f32,
    r.rand(2.0'f32) - 1.0'f32
  )
  p + offset * amount

proc icosphere(subdivisions: int): seq[array[3, Vec3]] =
  ## Unit icosphere as a flat face list.
  let t = (1.0'f32 + sqrt(5.0'f32)) / 2.0'f32
  var v = @[
    vec3(-1, t, 0), vec3(1, t, 0), vec3(-1, -t, 0), vec3(1, -t, 0),
    vec3(0, -1, t), vec3(0, 1, t), vec3(0, -1, -t), vec3(0, 1, -t),
    vec3(t, 0, -1), vec3(t, 0, 1), vec3(-t, 0, -1), vec3(-t, 0, 1)
  ]
  for p in v.mitems:
    p = normalize(p)
  let faces = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
    [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
    [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
  ]
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

proc buildMesh(
  subdivisions: int,
  missing: float32,
  purpleRatio: float32,
  seed: int64,
  scale: float32,
  jitterAmount: float32
): seq[float32] =
  ## Interleaved [pos, flat normal, color] triangles. A missing
  ## fraction drops whole triangles, colors pick team purple or
  ## black per face.
  let purples = [
    vec3(0.45, 0.15, 0.75),
    vec3(0.58, 0.24, 0.88),
    vec3(0.33, 0.10, 0.56),
    vec3(0.70, 0.35, 0.95)
  ]
  let blacks = [
    vec3(0.06, 0.05, 0.08),
    vec3(0.13, 0.12, 0.16),
    vec3(0.02, 0.02, 0.03)
  ]
  var faceRand = initRand(seed)
  for tri in icosphere(subdivisions):
    let keep = faceRand.rand(1.0'f32) >= missing
    let colorPick = faceRand.rand(1.0'f32)
    let purple = purples[faceRand.rand(purples.len - 1)]
    let black = blacks[faceRand.rand(blacks.len - 1)]
    if not keep:
      continue
    let
      a = jitter(tri[0], seed, jitterAmount) * scale
      b = jitter(tri[1], seed, jitterAmount) * scale
      c = jitter(tri[2], seed, jitterAmount) * scale
      normal = normalize(cross(b - a, c - a))
      color = (if colorPick < purpleRatio: purple else: black)
    for p in [a, b, c]:
      result.add([p.x, p.y, p.z])
      result.add([normal.x, normal.y, normal.z])
      result.add([color.x, color.y, color.z])

## GL plumbing.

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

let window = newWindow(
  "Sphere",
  ivec2(WindowSize, WindowSize),
  vsync = true
)
makeContextCurrent(window)
loadExtensions()

# Silky UI, reusing the basicwindow example atlas data.
const SilkyData = "../silky/examples/basicwindow/data/"
let builder = newAtlasBuilder(1024, 4)
builder.addDir(SilkyData, SilkyData)
builder.addFont(SilkyData & "IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont(SilkyData & "IBMPlexSans-Regular.ttf", "Default", 18.0)
createDir("tmp")
builder.write("tmp/sphere_atlas.png")
let sk = newSilky(window, "tmp/sphere_atlas.png")

let program = makeProgram(
  toShader(sphereVert, glsl3Desktop, shaderVertex),
  toShader(sphereFrag, glsl3Desktop, shaderFragment)
)

type Mesh = object
  vao: GLuint
  vbo: GLuint
  vertCount: GLsizei

proc uploadMesh(mesh: var Mesh, data: seq[float32]) =
  ## Uploads interleaved triangles into the mesh buffers.
  if mesh.vao == 0:
    glGenVertexArrays(1, addr mesh.vao)
    glGenBuffers(1, addr mesh.vbo)
  glBindVertexArray(mesh.vao)
  glBindBuffer(GL_ARRAY_BUFFER, mesh.vbo)
  glBufferData(
    GL_ARRAY_BUFFER,
    data.len * sizeof(float32),
    unsafeAddr data[0],
    GL_STATIC_DRAW
  )
  let stride = GLsizei(9 * sizeof(float32))
  for i, name in ["vertexPos", "vertexNormal", "vertexColor"]:
    let loc = glGetAttribLocation(program, name.cstring)
    if loc >= 0:
      glEnableVertexAttribArray(GLuint(loc))
      glVertexAttribPointer(
        GLuint(loc), 3, cGL_FLOAT, GL_FALSE, stride,
        cast[pointer](i * 3 * sizeof(float32))
      )
  mesh.vertCount = GLsizei(data.len div 9)

var
  inner: Mesh
  outer: Mesh
  seed = int64(12345)
  innerAngle = 0.0'f32
  outerAngle = 0.0'f32
  frameCount = 0
  shotPath = ""
  shotFrames = 60
  showParams = true
  # The sliders.
  paramSubdiv = 2.0'f32
  paramMissing = 0.7'f32
  paramPurple = 0.55'f32
  paramInnerRot = 0.35'f32
  paramOuterRot = -0.65'f32
  lastSubdiv = -1
  lastMissing = -1.0'f32
  lastPurple = -1.0'f32

for param in commandLineParams():
  if param.startsWith("--shot="):
    shotPath = param.split("=")[1]
  elif param.startsWith("--frames="):
    shotFrames = parseInt(param.split("=")[1])

proc rebuildMeshes() =
  ## Regenerates both spheres from the current sliders and seed.
  let subdiv = clamp(int(paramSubdiv + 0.5'f32), 0, 4)
  uploadMesh(inner, buildMesh(
    subdiv, 0.0, paramPurple, seed, 1.0, 0.09))
  uploadMesh(outer, buildMesh(
    subdiv, paramMissing, paramPurple, seed + 7, 1.5, 0.16))
  lastSubdiv = subdiv
  lastMissing = paramMissing
  lastPurple = paramPurple

randomize()
rebuildMeshes()

window.onButtonPress = proc(button: Button) =
  if button == KeyR:
    seed = int64(rand(1_000_000))
    rebuildMeshes()

proc drawMesh(mesh: Mesh, modelMat: Mat4, vp: Mat4) =
  ## One mesh with its own model matrix.
  var
    m = modelMat
    v = vp
  glBindVertexArray(mesh.vao)
  glUseProgram(program)
  glUniformMatrix4fv(
    glGetUniformLocation(program, "model"), 1, GL_FALSE,
    cast[ptr GLfloat](addr m)
  )
  glUniformMatrix4fv(
    glGetUniformLocation(program, "viewProj"), 1, GL_FALSE,
    cast[ptr GLfloat](addr v)
  )
  glDrawArrays(GL_TRIANGLES, 0, mesh.vertCount)

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

var lastTime = epochTime()

window.onFrame = proc() =
  inc frameCount
  let now = epochTime()
  let dt = float32(min(now - lastTime, 0.1))
  lastTime = now
  innerAngle += paramInnerRot * dt
  outerAngle += paramOuterRot * dt

  # Rebuild when a mesh slider moved.
  if clamp(int(paramSubdiv + 0.5'f32), 0, 4) != lastSubdiv or
    abs(paramMissing - lastMissing) > 0.001 or
    abs(paramPurple - lastPurple) > 0.001:
      rebuildMeshes()

  # Letterboxed square viewport, like the arton window.
  let
    size = window.size.vec2
    scale = min(size.x / WindowSize, size.y / WindowSize)
    draw = WindowSize * scale
    offset = (size - vec2(draw, draw)) / 2
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(0.97, 0.965, 0.95, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glViewport(
    GLint(offset.x), GLint(offset.y), GLsizei(draw), GLsizei(draw))

  glEnable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)

  let vp = perspective(35.0'f32, 1.0'f32, 0.1'f32, 100.0'f32) *
    lookAt(vec3(0.0'f32, 1.2, 6.2), vec3(0.0'f32, 0, 0),
      vec3(0.0'f32, 1, 0))
  drawMesh(inner, rotateY(innerAngle) * rotateX(0.35'f32), vp)
  drawMesh(outer, rotateY(outerAngle) * rotateZ(0.22'f32), vp)

  glDisable(GL_DEPTH_TEST)

  # Param panel.
  sk.beginUI(window, window.size)
  subWindow("Sphere Params", showParams, vec2(16, 16), vec2(348, 400)):
    text "subdiv label":
      characters "subdivisions"
    scrubber "subdiv", paramSubdiv, 0.0'f32, 4.0'f32, ""
    text "missing label":
      characters "shell missing"
    scrubber "missing", paramMissing, 0.0'f32, 0.95'f32, ""
    text "purple label":
      characters "purple vs black"
    scrubber "purple", paramPurple, 0.0'f32, 1.0'f32, ""
    text "inner label":
      characters "inner rotation"
    scrubber "innerRot", paramInnerRot, -2.0'f32, 2.0'f32, ""
    text "outer label":
      characters "outer rotation"
    scrubber "outerRot", paramOuterRot, -2.0'f32, 2.0'f32, ""
  sk.endUi()

  window.swapBuffers()

  if shotPath != "" and frameCount >= shotFrames:
    saveShot(shotPath)
    quit(0)

while not window.closeRequested:
  pollEvents()
