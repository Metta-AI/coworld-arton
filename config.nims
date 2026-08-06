import std/[os, strformat, strutils]

when defined(emscripten):
  # WASM browser build. Requires emcc on the path. Build with:
  #   nim c -d:emscripten src/arton.nim
  # Output lands in dist/arton.html plus wasm and data files.
  --nimcache:tmp
  --os:linux
  --cpu:wasm32
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --clang.cpp.exe:emcc
  --clang.cpp.linkerexe:emcc
  --listCmd
  --threads:off
  --mm:arc
  --exceptions:goto
  --define:noSignalHandler
  --debugger:native
  --define:noAutoGLerrorCheck
  --define:release
  if not dirExists("dist"):
    mkDir("dist")
  switch(
    "passL",
    (&"""
    -o dist/arton.html
    --preload-file data
    --shell-file emscripten/emscripten.html
    -s ASYNCIFY
    -s FETCH
    -s USE_WEBGL2=1
    -s MAX_WEBGL_VERSION=2
    -s MIN_WEBGL_VERSION=1
    -s FULL_ES3=1
    -s GL_ENABLE_GET_PROC_ADDRESS=1
    -s ALLOW_MEMORY_GROWTH
    """).replace("\n", " ")
  )
