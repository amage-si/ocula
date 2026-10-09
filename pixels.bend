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

# One scanline byte per step: `cur` holds the raw byte and the byte above it,
# read directly; the last four reconstructed bytes (l1..l4) and the four bytes
# above them (u1..u4) are carried, so the left and upper-left neighbours need no
# read. They start at zero, which is the PNG value before the first pixel.
# Bytes above the first row are masked to zero by `top`.
def row_bytes(n: Nat, cur: Array<U32> & (U32 & U32), +index: U32, +stride: U32, +bpp: U32, +filter: U32, +top: U32, +l1: U32, +l2: U32, +l3: U32, +l4: U32, +u1: U32, +u2: U32, +u3: U32, +u4: U32) -> Array<U32>:
  match n:
    case 0n:
      (data, _) = cur
      data
    case 1n+p:
      (data, (raw, up)) = cur
      +b = U32.mul(up, top)
      +wide = U32.is_eq(bpp, 4)
      +v = U32.and(U32.add(raw, predictor(filter, Bool.pick(U32, wide, l4, l3), b, Bool.pick(U32, wide, u4, u3))), 255)
      +next = U32.inc(index)
      data = data[index] <- v
      row_bytes(p, B.read2(data, next, U32.sub(next, stride)), next, stride, bpp, filter, top, v, l1, l2, l3, b, u1, u2, u3)

def row(data: Array<U32>, +row_index: U32, +stride: U32, +bpp: U32) -> Result<&2, &1, String, Array<U32>>:
  +start = U32.mul(row_index, stride)
  +first = U32.inc(start)
  B.get(~Result<&2, &1, String, Array<U32>>, data, start, +filter => data => (
    do Result<&2, &1, String, Array<U32>>:
      u : Unit <- B.require((filter <= 4 : U32), "unsupported PNG scanline filter")
      return row_bytes(U32.to_nat(U32.sub(stride, 1)), B.read2(data, first, U32.sub(first, stride)), first, stride, bpp, filter, Bool.to_u32(U32.is_gt(row_index, 0)), 0, 0, 0, 0, 0, 0, 0, 0)
  ))

def rows(n: Nat, +y: U32, +stride: U32, +bpp: U32, r: Result<&2, &1, String, Array<U32>>) -> Result<&2, &1, String, Array<U32>>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{data}:
      Done{data}
    case 1n+p Done{data}:
      rows(p, U32.inc(y), stride, bpp, row(data, y, stride, bpp))

type Buffers is Type:
  Buffers{raw: Array<U32>, rgba: Array<U32>}

def alpha(raw: Array<U32>, index: U32, rgba: Bool, f: U32 -> Array<U32> -> Buffers) -> Buffers:
  match rgba:
    case False{}:
      f(255, raw)
    case True{}:
      B.get(~Buffers, raw, index, f)

def pack_one(buffers: Buffers, +source: U32, dest: U32, rgba: Bool) -> Buffers:
  match buffers:
    case Buffers{raw, out}:
      B.get(~Buffers, raw, source, r => raw => (
        B.get(~Buffers, raw, U32.inc(source), g => raw => (
          B.get(~Buffers, raw, U32.add(source, 2), b => raw => (
            alpha(raw, U32.add(source, 3), rgba, a => raw => (
              Buffers{raw, out[dest] <- (r * 16777216 + g * 65536 + b * 256 + a : U32)}
            ))
          ))
        ))
      ))

def pack(n: Nat, +index: U32, +width: U32, +stride: U32, +bpp: U32, buffers: Buffers) -> Buffers:
  match n:
    case 0n:
      buffers
    case 1n+p:
      source = ((index / width) * stride + 1 + (index % width) * bpp : U32)
      pack(p, U32.inc(index), width, stride, bpp, pack_one(buffers, source, index, U32.is_eq(bpp, 4)))

def raster(width: U32, height: U32, buffers: Buffers) -> Raster:
  match buffers:
    case Buffers{_, out}:
      Raster{width, height, out}

def convert(raw: Array<U32>, +width: U32, +height: U32, +bpp: U32) -> Result<&2, &1, String, Raster>:
  +count = U32.mul(width, height)
  +stride = U32.inc(U32.mul(width, bpp))
  do Result<&2, &1, String, Raster>:
    raw : Array<U32> <- rows(U32.to_nat(height), 0, stride, bpp, Done{raw})
    return raster(width, height, pack(U32.to_nat(count), 0, width, stride, bpp, Buffers{raw, B.allocate(count)}))

def pixel(image: Raster, +x: U32, +y: U32) -> Result<&2, &1, String, Raster & U32>:
  match image:
    case Raster{+w, +h, pixels}:
      do Result<&2, &1, String, Raster & U32>:
        u : Unit <- B.require((x < w : U32) && (y < h : U32), "pixel outside image")
        B.get(~Result<&2, &1, String, Raster & U32>, pixels, (y * w + x : U32), p => pixels => Done{(Raster{w, h, pixels}, p)})

def rgba_bytes_loop(n: Nat, +index: U32, pixels: Array<U32>, acc: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      List.reverse(&2, U32, acc)
    case 1n+p:
      B.get(~(+List<U32>), pixels, index, +v => pixels => (
        rgba_bytes_loop(p, U32.inc(index), pixels, U32.and(v, 255) <> U32.and(U32.div(v, 256), 255) <> U32.and(U32.div(v, 65536), 255) <> U32.div(v, 16777216) <> acc)
      ))

def rgba_bytes(image: Raster) -> +List<U32>:
  match image:
    case Raster{w, h, pixels}:
      rgba_bytes_loop(U32.to_nat(U32.mul(w, h)), 0, pixels, Nil{})

def packed_loop(n: Nat, xs: List<U32>, acc: +List<U32>) -> +List<U32>:
  match n xs:
    case 0n _:
      List.reverse(&2,U32,acc)
    case _ Nil{}:
      List.reverse(&2,U32,acc)
    case 1n+p h <> t:
      packed_loop(p,t,h <> acc)

def packed_pixels(image: Raster) -> +List<U32>:
  match image:
    case Raster{w,h,pixels}:
      packed_loop(U32.to_nat(U32.mul(w,h)),Array.to_list(~U32,pixels),Nil{})
