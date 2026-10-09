import Base
import ./bytes.bend as B
import ./inflate.bend as Z
import ./png.bend as P
import ./pixels.bend as Pixels

def Raster() -> Type:
  Pixels.Raster

def decode_parsed(parsed: P.Parsed) -> Result<&2, &1, String, Pixels.Raster>:
  match parsed:
    case P.Parsed{_, P.Header{+width, +height, +bpp}, _, parts, total, _}:
      do Result<&2, &1, String, Pixels.Raster>:
        raw : Array<U32> <- Z.inflate_parts(List.reverse(&2, +List<U32>, parts), total, ((width * bpp + 1) * height : U32))
        Pixels.convert(raw, width, height, bpp)

def decode_png(+bytes: +List<U32>) -> Result<&2, &1, String, Pixels.Raster>:
  do Result<&2, &1, String, Pixels.Raster>:
    u : Unit <- B.require(B.valid(U32.to_nat(2097152), bytes), "input exceeds 2 MiB or contains a value outside byte range")
    parsed : P.Parsed <- P.parse(bytes)
    decode_parsed(parsed)
