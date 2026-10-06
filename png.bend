import Base
import ./bytes.bend as B
import ./inflate.bend as Z

type Header is Data:
  Header{width: U32, height: U32, channels: U32}

type Chunk is Data:
  Chunk{kind: U32, bytes: +List<U32>, next: B.Reader}

type Parsed is Data:
  Parsed{reader: B.Reader, header: Header, phase: U32, parts: +List<+List<U32>>, size: U32, flags: U32}

def be4(a: U32, b: U32, c: U32, d: U32) -> U32:
  (a * 16777216 + b * 65536 + c * 256 + d : U32)

def kind_bytes(+kind: U32) -> +List<U32>:
  [U32.div(kind, 16777216), U32.and(U32.div(kind, 65536), 255), U32.and(U32.div(kind, 256), 255), U32.and(kind, 255)]

def ascii_letter(+v: U32) -> Bool:
  ((v >= 65 : U32) && (v <= 90 : U32)) || ((v >= 97 : U32) && (v <= 122 : U32))

def chunk(r: B.Reader) -> Result<&2, &1, String, Chunk>:
  B.read32(~Chunk, r, +length => r => (
    do Result<&2, &1, String, Chunk>:
      u : Unit <- B.require((length <= 2097152 : U32), "PNG chunk length exceeds input limit")
      B.read32(~Chunk, r, +kind => r => (
        do Result<&2, &1, String, Chunk>:
          u : Unit <- B.require(List.all(~&2, ~U32, ~(x => ascii_letter(x)), kind_bytes(kind)) && U32.is_eq(U32.and(kind, 8192), 0), "invalid PNG chunk type")
          B.read_bytes(~Chunk, U32.to_nat(length), r, +data => r => (
            B.read32(~Chunk, r, crc => r => (
              do Result<&2, &1, String, Chunk>:
                u : Unit <- B.require(U32.is_eq(crc, U32.xor(B.crc_fold(data, B.crc_fold(kind_bytes(kind), 4294967295)), 4294967295)), "PNG CRC-32 mismatch")
                return Chunk{kind, data, r}
            ))
          ))
      ))
  ))

def dimensions(+width: U32, +height: U32, +color: U32) -> Result<&2, &1, String, Header>:
  do Result<&2, &1, String, Header>:
    u : Unit <- B.require((width > 0 : U32) && (height > 0 : U32) && (width <= 4096 : U32) && (height <= 4096 : U32), "PNG dimensions outside 1..4096")
    u : Unit <- B.require((height <= 262144 / width : U32), "PNG exceeds 262144 pixel allocation limit")
    u : Unit <- B.require(U32.is_eq(color, 2) || U32.is_eq(color, 6), "unsupported PNG color type (RGB8/RGBA8 only)")
    return Header{width, height, Bool.pick(U32, U32.is_eq(color, 6), 4, 3)}

def header(data: +List<U32>) -> Result<&2, &1, String, Header>:
  match data:
    case a <> b <> c <> d <> e <> f <> g <> h <> depth <> color <> compression <> filter <> interlace <> Nil{}:
      do Result<&2, &1, String, Header>:
        u : Unit <- B.require(U32.is_eq(depth, 8), "unsupported PNG bit depth (8 only)")
        u : Unit <- B.require(U32.is_eq(compression, 0) && U32.is_eq(filter, 0), "unsupported PNG compression/filter method")
        u : Unit <- B.require(U32.is_eq(interlace, 0), "unsupported PNG interlace (Adam7)")
        dimensions(be4(a,b,c,d), be4(e,f,g,h), color)
    case _:
      Fail{"IHDR must contain exactly 13 bytes"}

def first(c: Chunk) -> Result<&2, &1, String, Parsed>:
  match c:
    case Chunk{1229472850, data, r}:
      do Result<&2, &1, String, Parsed>:
        h : Header <- header(data)
        return Parsed{r, h, 1, Nil{}, 0, 0}
    case _:
      Fail{"IHDR must be the first PNG chunk"}

def srgb(data: +List<U32>) -> Bool:
  match data:
    case intent <> Nil{}:
      (intent <= 3 : U32)
    case _:
      False{}

def phys(data: +List<U32>) -> Bool:
  match data:
    case _ <> _ <> _ <> _ <> _ <> _ <> _ <> _ <> unit <> Nil{}:
      (unit <= 1 : U32)
    case _:
      False{}

def gamma(data: +List<U32>) -> Bool:
  match data:
    case 0 <> 0 <> 177 <> 143 <> Nil{}:
      True{}
    case _:
      False{}

def metadata(kind: U32, +data: +List<U32>, +phase: U32, +flags: U32) -> Result<&2, &1, String, U32>:
  match kind:
    case 1347179589:
      do Result<&2, &1, String, U32>:
        u : Unit <- B.require(U32.is_eq(phase, 1) && U32.is_eq(U32.and(flags, 1), 0), "PLTE duplicated or out of order")
        +n : U32 = U32.from_nat(List.length(&2, U32, data))
        u : Unit <- B.require((n > 0 : U32) && (n <= 768 : U32) && U32.is_eq(U32.mod(n, 3), 0), "invalid optional PLTE length")
        return U32.or(flags, 1)
    case 1934772034:
      do Result<&2, &1, String, U32>:
        u : Unit <- B.require(U32.is_eq(phase, 1) && U32.is_eq(U32.and(flags, 3), 0) && srgb(data), "invalid/duplicate/out-of-order sRGB chunk")
        return U32.or(flags, 2)
    case 1732332865:
      do Result<&2, &1, String, U32>:
        u : Unit <- B.require(U32.is_eq(phase, 1) && U32.is_eq(U32.and(flags, 5), 0) && gamma(data), "unsupported/duplicate/out-of-order gAMA (requires 45455)")
        return U32.or(flags, 4)
    case 1883789683:
      do Result<&2, &1, String, U32>:
        u : Unit <- B.require(U32.is_eq(phase, 1) && U32.is_eq(U32.and(flags, 8), 0) && phys(data), "invalid/duplicate/out-of-order pHYs")
        return U32.or(flags, 8)
    case _:
      Fail{"unsupported PNG chunk type " ++ U32.show(kind)}

def next(c: Chunk, h: Header, +phase: U32, parts: +List<+List<U32>>, +size: U32, +flags: U32) -> Result<&2, &1, String, Parsed>:
  match c:
    case Chunk{1229209940, +data, r}:
      do Result<&2, &1, String, Parsed>:
        u : Unit <- B.require((phase <= 2 : U32), "non-consecutive IDAT chunks")
        +n : U32 = U32.from_nat(List.length(&2, U32, data))
        u : Unit <- B.require((n <= 2097152 - size : U32), "compressed PNG data exceeds limit")
        return Parsed{r, h, 2, data <> parts, U32.add(size, n), flags}
    case Chunk{1229278788, data, r}:
      do Result<&2, &1, String, Parsed>:
        u : Unit <- B.require((phase >= 2 : U32) && List.is_empty(&2, U32, data), "IEND must be empty and follow IDAT")
        u : Unit <- B.require(U32.is_eq(U32.and(flags,4),0) || U32.is_ne(U32.and(flags,2),0), "gAMA without sRGB requires unsupported color conversion")
        u : Unit <- B.require(B.empty(r), "trailing data after IEND")
        return Parsed{B.Reader{Nil{}, 0}, h, 4, parts, size, flags}
    case Chunk{kind, data, r}:
      do Result<&2, &1, String, Parsed>:
        flags : U32 <- metadata(kind, data, phase, flags)
        return Parsed{r, h, Bool.pick(U32, U32.is_eq(phase, 2), 3, phase), parts, size, flags}

def chunks(fuel: Nat, state: Result<&2, &1, String, Parsed>) -> Result<&2, &1, String, Parsed>:
  match fuel state:
    case _ Fail{e}:
      Fail{e}
    case _ Done{Parsed{r, h, 4, parts, size, flags}}:
      Done{Parsed{r, h, 4, parts, size, flags}}
    case 0n Done{_}:
      Fail{"PNG chunk count limit (4096)"}
    case 1n+p Done{Parsed{r, h, phase, parts, size, flags}}:
      next_state = Result.bind(&2, &1, String, Chunk, Parsed, chunk(r), c => next(c, h, phase, parts, size, flags))
      chunks(p, next_state)

def parse(bytes: +List<U32>) -> Result<&2, &1, String, Parsed>:
  match bytes:
    case 137 <> 80 <> 78 <> 71 <> 13 <> 10 <> 26 <> 10 <> rest:
      chunks(4096n, Result.bind(&2, &1, String, Chunk, Parsed, chunk(B.Reader{rest, 8}), first))
    case _:
      Fail{"invalid PNG signature"}
