import Base

# All byte lists are checked before parsing; offsets count source bytes.
type Reader is Data:
  Reader{rest: +List<U32>, offset: U32}

def require(ok: Bool, message: String) -> Result<&2, &1, String, Unit>:
  match ok:
    case True{}:
      Done{Unit{}}
    case False{}:
      Fail{message}

def valid(fuel: Nat, xs: +List<U32>) -> Bool:
  match fuel xs:
    case _ Nil{}:
      True{}
    case 0n Con{h, t}:
      False{}
    case 1n+p Con{h, t}:
      (h <= 255 : U32) && valid(p, t)

def byte(r: Reader) -> Result<&2, &1, String, U32 & Reader>:
  match r:
    case Reader{Nil{}, offset}:
      Fail{"truncated input at byte " ++ U32.show(offset)}
    case Reader{Con{h, t}, offset}:
      Done{(h, Reader{t, U32.inc(offset)})}

def be32(r: Reader) -> Result<&2, &1, String, U32 & Reader>:
  match r:
    case Reader{a <> b <> c <> d <> rest, offset}:
      Done{((a * 16777216 + b * 65536 + c * 256 + d : U32), Reader{rest, (offset + 4 : U32)})}
    case Reader{rest, offset}:
      Fail{"truncated u32 at byte " ++ U32.show(offset)}

def take(n: Nat, r: Reader, acc: +List<U32>) -> Result<&2, &1, String, +List<U32> & Reader>:
  match n r:
    case 0n _:
      Done{(List.reverse(&2, U32, acc), r)}
    case 1n+p Reader{Nil{}, offset}:
      Fail{"truncated chunk at byte " ++ U32.show(offset)}
    case 1n+p Reader{b <> rest, offset}:
      take(p, Reader{rest, U32.inc(offset)}, b <> acc)

def empty(r: Reader) -> Bool:
  match r:
    case Reader{Nil{}, _}:
      True{}
    case Reader{Con{h, t}, _}:
      False{}

def crc_step(crc: U32, odd: Bool) -> U32:
  match odd:
    case True{}:
      U32.xor(U32.shr(crc), 3988292384)
    case False{}:
      U32.shr(crc)

def crc_bits(n: Nat, +crc: U32) -> U32:
  match n:
    case 0n:
      crc
    case 1n+p:
      crc_bits(p, crc_step(crc, U32.is_ne(U32.and(crc, 1), 0)))

def crc_fold(xs: +List<U32>, crc: U32) -> U32:
  match xs:
    case Nil{}:
      crc
    case Con{h, t}:
      crc_fold(t, crc_bits(8n, U32.xor(crc, h)))

def crc32(xs: +List<U32>) -> U32:
  U32.xor(crc_fold(xs, 4294967295), 4294967295)

def depth_go(n: Nat, +cap: U32, +size: U32, depth: Nat, enough: Bool) -> Nat:
  match n enough:
    case _ True{}:
      depth
    case 0n False{}:
      depth
    case 1n+p False{}:
      +next = U32.mul(cap, 2)
      depth_go(p, next, size, Succ{depth}, U32.is_ge(next, size))

def allocate(+size: U32) -> Array<U32>:
  Array.new(U32, depth_go(24n, 1, size, 0n, U32.is_ge(1,size)), 0)

def apply32(-T: Type, pair: U32 & Reader, f: U32 -> Reader -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  (v, r) = pair
  f(v, r)

def read32(~T: Type, r: Reader, f: U32 -> Reader -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  Result.bind(&2, &1, String, U32 & Reader, T, be32(r), pair => apply32(T, pair, f))

def apply_take(-T: Type, pair: +List<U32> & Reader, f: +List<U32> -> Reader -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  (v, r) = pair
  f(v, r)

def read_bytes(~T: Type, n: Nat, r: Reader, f: +List<U32> -> Reader -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  Result.bind(&2, &1, String, +List<U32> & Reader, T, take(n, r, Nil{}), pair => apply_take(T, pair, f))

def array_apply(-T: Type, pair: Array<U32> & U32, f: U32 -> Array<U32> -> T) -> T:
  (a, v) = pair
  f(v, a)

def get(~T: Type, a: Array<U32>, i: U32, f: U32 -> Array<U32> -> T) -> T:
  array_apply(T, a[i], f)

def get_or_zero(~T: Type, a: Array<U32>, i: U32, valid: Bool, f: U32 -> Array<U32> -> T) -> T:
  match valid:
    case False{}:
      f(0, a)
    case True{}:
      get(~T, a, i, f)

