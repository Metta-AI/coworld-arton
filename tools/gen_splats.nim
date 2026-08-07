## Extracts sampled brush bitmaps from a Photoshop .abr (version 6)
## into black on white png files. Follows the GIMP abr loader logic.

import std/[os, strformat, strutils], pixie

proc beU16(data: string, at: int): int =
  (data[at].ord shl 8) or data[at + 1].ord

proc beU32(data: string, at: int): int =
  (data[at].ord shl 24) or (data[at + 1].ord shl 16) or
    (data[at + 2].ord shl 8) or data[at + 3].ord

let
  path = paramStr(1)
  outDir = paramStr(2)
  data = readFile(path)

createDir(outDir)

let
  version = beU16(data, 0)
  subVersion = beU16(data, 2)
echo "abr version ", version, ".", subVersion

doAssert version >= 6, "only sampled v6+ abr files supported"

# Find the 8BIM samp section.
var pos = 4
var sampEnd = -1
while pos + 12 <= data.len:
  doAssert data[pos .. pos + 3] == "8BIM", "expected 8BIM block"
  let
    key = data[pos + 4 .. pos + 7]
    size = beU32(data, pos + 8)
  if key == "samp":
    pos = pos + 12
    sampEnd = pos + size
    break
  pos = pos + 12 + size
doAssert sampEnd > 0, "no samp section found"

var brushIndex = 0
while pos < sampEnd - 4:
  let entryLen = beU32(data, pos)
  var entryEnd = pos + 4 + entryLen
  while (entryEnd - (pos + 4)) mod 4 != 0:
    inc entryEnd
  var p = pos + 4
  p += 37                       # brush id string
  if subVersion == 1:
    p += 10                     # short coordinates
  else:
    p += 264                    # v6.2 extra data
  let
    top = beU32(data, p)
    left = beU32(data, p + 4)
    bottom = beU32(data, p + 8)
    right = beU32(data, p + 12)
    depth = beU16(data, p + 16)
    compressed = data[p + 18].ord
    width = right - left
    height = bottom - top
  p += 19
  doAssert depth == 8, "only 8 bit brushes supported, got " & $depth

  var mask = newString(width * height)
  if compressed == 0:
    for i in 0 ..< width * height:
      mask[i] = data[p + i]
  else:
    # Row byte counts, then packbits per row.
    var rowStart = p + height * 2
    var outAt = 0
    for row in 0 ..< height:
      let rowBytes = beU16(data, p + row * 2)
      var q = rowStart
      let rowEnd = rowStart + rowBytes
      while q < rowEnd:
        let n = cast[int8](data[q].ord)
        inc q
        if n >= 0:
          for k in 0 .. int(n):
            mask[outAt] = data[q]
            inc q
            inc outAt
        elif n != -128:
          let repeat = 1 - int(n)
          for k in 0 ..< repeat:
            mask[outAt] = data[q]
            inc outAt
          inc q
      rowStart = rowEnd
    doAssert outAt == width * height,
      "rle decode mismatch " & $outAt & " vs " & $(width * height)

  # Black ink on white paper.
  let image = newImage(width, height)
  for i in 0 ..< width * height:
    let ink = mask[i].ord
    let v = uint8(255 - ink)
    image.data[i] = rgbx(v, v, v, 255)
  let outPath = outDir / &"splat_{brushIndex:02}.png"
  image.writeFile(outPath)
  echo outPath, "  ", width, "x", height,
    (if compressed == 1: "  rle" else: "  raw")
  inc brushIndex
  pos = entryEnd

echo "extracted ", brushIndex, " brushes"
