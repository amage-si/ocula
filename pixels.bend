import Base
import ./bytes.bend as B

type Raster is Type:
  Raster{width: U32, height: U32, pixels: Array<U32>}

def diff(+a: U32, +b: U32) -> U32:
  U32.sub(U32.max(a, b), U32.min(a, b))

def paeth(+a: U32, +b: U32, +c: U32) -> U32:
  +pa = diff(b, c)
  +pb = diff(a, c)
  +pc = diff(U32.add(a, b), U32.mul(c, 2))
  Bool.pick(U32, (pa <= pb : U32) && (pa <= pc : U32), a, Bool.pick(U32, (pb <= pc : U32), b, c))

def predictor(filter: U32, a: U32, b: U32, c: U32) -> U32:
  match filter:
    case 0:
      0
    case 1:
      a
    case 2:
      b
    case 3:
      ((a + b) / 2 : U32)
    case _:
      paeth(a, b, c)

type Buffers is Type:
  Buffers{raw: Array<U32>, rgba: Array<U32>}

# Four consecutive scanline bytes, read without a closure.
def quad(+r: U32, +g: U32, +b: U32, pair: Array<U32> & U32) -> Array<U32> & (U32 & (U32 & (U32 & U32))):
  (raw, a) = pair
  (raw, (r, (g, (b, a))))

def quad_b(+r: U32, +g: U32, pair: Array<U32> & U32, +i: U32) -> Array<U32> & (U32 & (U32 & (U32 & U32))):
  (raw, b) = pair
  quad(r, g, b, raw[U32.add(i, 3)])

def quad_g(+r: U32, pair: Array<U32> & U32, +i: U32) -> Array<U32> & (U32 & (U32 & (U32 & U32))):
  (raw, g) = pair
  quad_b(r, g, raw[U32.add(i, 2)], i)

def quad_r(pair: Array<U32> & U32, +i: U32) -> Array<U32> & (U32 & (U32 & (U32 & U32))):
  (raw, r) = pair
  quad_g(r, raw[U32.inc(i)], i)

def read4(raw: Array<U32>, +i: U32) -> Array<U32> & (U32 & (U32 & (U32 & U32))):
  quad_r(raw[i], i)

def channel(+filter: U32, +raw: U32, +a: U32, +b: U32, +c: U32) -> U32:
  U32.and(U32.add(raw, predictor(filter, a, b, c)), 255)

def done_row(cur: Array<U32> & (U32 & (U32 & (U32 & U32))), up: Array<U32> & U32) -> Buffers:
  (raw, _) = cur
  (rgba, _) = up
  Buffers{raw, rgba}

# Unfilters one scanline and packs it, one pixel per step. `cur` holds the
# pixel's four raw bytes (the fourth is ignored for RGB), `up` the packed pixel
# above it (masked to zero on the first row by `top`). The left pixel (l*) and
# the upper-left one (u*) are carried, starting at zero as PNG defines before
# the first pixel; scanlines are never written back.
def row_pixels(n: Nat, cur: Array<U32> & (U32 & (U32 & (U32 & U32))), up: Array<U32> & U32, +i: U32, +o: U32, +width: U32, +bpp: U32, +filter: U32, +top: U32, +lr: U32, +lg: U32, +lb: U32, +la: U32, +ur: U32, +ug: U32, +ub: U32, +ua: U32) -> Buffers:
  match n:
    case 0n:
      done_row(cur, up)
    case 1n+p:
      (raw, quad) = cur
      (r0, rest) = quad
      (g0, rest) = rest
      (b0, a0) = rest
      (rgba, word) = up
      +above = U32.mul(word, top)
      +br = U32.div(above, 16777216)
      +bg = U32.and(U32.div(above, 65536), 255)
      +bb = U32.and(U32.div(above, 256), 255)
      +ba = U32.and(above, 255)
      +r = channel(filter, r0, lr, br, ur)
      +g = channel(filter, g0, lg, bg, ug)
      +b = channel(filter, b0, lb, bb, ub)
      +a = channel(filter, a0, la, ba, ua)
      +rgb = U32.is_eq(bpp, 3)
      rgba = rgba[o] <- (r * 16777216 + g * 65536 + b * 256 + Bool.pick(U32, rgb, 255, a) : U32)
      +next = U32.add(i, bpp)
      +after = U32.inc(o)
      row_pixels(p, read4(raw, next), rgba[U32.sub(after, width)], next, after, width, bpp, filter, top, r, g, b, a, br, bg, bb, ba)

def row(buffers: Buffers, +y: U32, +width: U32, +stride: U32, +bpp: U32) -> Result<&2, &1, String, Buffers>:
  match buffers:
    case Buffers{raw, rgba}:
      +start = U32.mul(y, stride)
      +o = U32.mul(y, width)
      B.get(~Result<&2, &1, String, Buffers>, raw, start, +filter => raw => (
        do Result<&2, &1, String, Buffers>:
          u : Unit <- B.require((filter <= 4 : U32), "unsupported PNG scanline filter")
          return row_pixels(U32.to_nat(width), read4(raw, U32.inc(start)), rgba[U32.sub(o, width)], U32.inc(start), o, width, bpp, filter, Bool.to_u32(U32.is_gt(y, 0)), 0, 0, 0, 0, 0, 0, 0, 0)
      ))

def rows(n: Nat, +y: U32, +width: U32, +stride: U32, +bpp: U32, r: Result<&2, &1, String, Buffers>) -> Result<&2, &1, String, Buffers>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{buffers}:
      Done{buffers}
    case 1n+p Done{buffers}:
      rows(p, U32.inc(y), width, stride, bpp, row(buffers, y, width, stride, bpp))

def raster(width: U32, height: U32, buffers: Buffers) -> Raster:
  match buffers:
    case Buffers{_, out}:
      Raster{width, height, out}

def convert(raw: Array<U32>, +width: U32, +height: U32, +bpp: U32) -> Result<&2, &1, String, Raster>:
  +stride = U32.inc(U32.mul(width, bpp))
  do Result<&2, &1, String, Raster>:
    buffers : Buffers <- rows(U32.to_nat(height), 0, width, stride, bpp, Done{Buffers{raw, B.allocate(U32.mul(width, height))}})
    return raster(width, height, buffers)

def pixel(image: Raster, +x: U32, +y: U32) -> Result<&2, &1, String, Raster & U32>:
  match image:
    case Raster{+w, +h, pixels}:
      do Result<&2, &1, String, Raster & U32>:
        u : Unit <- B.require((x < w : U32) && (y < h : U32), "pixel outside image")
        B.get(~Result<&2, &1, String, Raster & U32>, pixels, (y * w + x : U32), p => pixels => Done{(Raster{w, h, pixels}, p)})

# Both list views walk the pixels backwards, prepending, so they need one
# closure-free pass and no reversal; slots past width * height are never read.
def bytes_down(n: Nat, cur: Array<U32> & U32, +i: U32, acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      (pixels, +v) = cur
      +prev = U32.sub(i, 1)
      bytes_down(p, pixels[prev], prev, U32.div(v, 16777216) <> U32.and(U32.div(v, 65536), 255) <> U32.and(U32.div(v, 256), 255) <> U32.and(v, 255) <> acc)

def rgba_bytes(image: Raster) -> +List<U32>:
  match image:
    case Raster{+w, +h, pixels}:
      +last = U32.sub(U32.mul(w, h), 1)
      bytes_down(U32.to_nat(U32.mul(w, h)), pixels[last], last, Nil{})

def packed_down(n: Nat, cur: Array<U32> & U32, +i: U32, acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      (pixels, v) = cur
      +prev = U32.sub(i, 1)
      packed_down(p, pixels[prev], prev, v <> acc)

# Row-major 0xRRGGBBAA words, exactly width * height of them.
def packed_pixels(image: Raster) -> +List<U32>:
  match image:
    case Raster{+w, +h, pixels}:
      +last = U32.sub(U32.mul(w, h), 1)
      packed_down(U32.to_nat(U32.mul(w, h)), pixels[last], last, Nil{})
