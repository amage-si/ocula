import Base
import ./bytes.bend as B

type Bits is Data:
  Bits{rest: +List<U32>, buffer: U32, count: U32}

type Huffman is Data:
  Huffman{counts: +List<U32>, symbols: +List<U32>}

type Output is Type:
  Output{data: Array<U32>, used: U32, limit: U32, adler_a: U32, adler_b: U32}

def one(s: Bits) -> Result<&2, &1, String, U32 & Bits>:
  match s:
    case Bits{Nil{}, _, 0}:
      Fail{"truncated DEFLATE bitstream"}
    case Bits{+h <> t, _, 0}:
      Done{(U32.and(h, 1), Bits{t, U32.shr(h), 7})}
    case Bits{t, +v, c}:
      Done{(U32.and(v, 1), Bits{t, U32.shr(v), U32.sub(c, 1)})}

def bits_loop(n: Nat, acc: U32, +mul: U32, r: Result<&2, &1, String, U32 & Bits>) -> Result<&2, &1, String, U32 & Bits>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{(b, s)}:
      Done{((acc + b * mul : U32), s)}
    case 1n+p Done{(b, s)}:
      bits_loop(p, (acc + b * mul : U32), U32.mul(mul, 2), one(s))

def bits(n: Nat, s: Bits) -> Result<&2, &1, String, U32 & Bits>:
  match n:
    case 0n:
      Done{(0, s)}
    case 1n+p:
      bits_loop(p, 0, 1, one(s))

def apply_read(-T: Type, pair: U32 & Bits, f: U32 -> Bits -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  (value, next) = pair
  f(value, next)

def read(~T: Type, n: Nat, s: Bits, f: U32 -> Bits -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  Result.bind(&2, &1, String, U32 & Bits, T, bits(n, s), pair => apply_read(T, pair, f))

def align(s: Bits) -> Bits:
  match s:
    case Bits{rest, _, _}:
      Bits{rest, 0, 0}

def at(xs: +List<U32>, n: Nat) -> U32:
  match xs n:
    case Nil{} _:
      0
    case h <> t 0n:
      h
    case h <> t 1n+p:
      at(t, p)

def count_length(xs: +List<U32>, +length: U32, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      count_length(t, length, U32.add(acc, Bool.to_u32(U32.is_eq(h, length))))

def count_all(n: Nat, +length: U32, +lengths: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      count_length(lengths, length, 0) <> count_all(p, U32.inc(length), lengths)

def symbols_at(xs: +List<U32>, +length: U32, +index: U32, +acc: +List<U32>) -> +List<U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case h <> t:
      next = Bool.pick(+List<U32>, U32.is_eq(h, length), index <> acc, acc)
      symbols_at(t, length, U32.inc(index), next)

def sorted_symbols(n: Nat, +length: U32, +lengths: +List<U32>) -> +List<U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      List.append(&2, U32, symbols_at(lengths, length, 0, Nil{}), sorted_symbols(p, U32.inc(length), lengths))

# Kraft budget. An incomplete tree is legal only for a single one-bit code.
def kraft(counts: +List<U32>, left: U32, valid: Bool) -> Result<&2, &1, String, U32>:
  match counts valid:
    case _ False{}:
      Fail{"oversubscribed Huffman tree"}
    case Nil{} True{}:
      Done{left}
    case +h <> t True{}:
      +space = U32.mul(left, 2)
      kraft(t, U32.sub(space, h), U32.is_le(h, space))

def tree_finish(+counts: +List<U32>, symbols: +List<U32>, allow_single: Bool, +remaining: U32) -> Result<&2, &1, String, Huffman>:
  do Result<&2, &1, String, Huffman>:
    u : Unit <- B.require(U32.is_eq(remaining, 0) || (allow_single && U32.is_eq(at(counts, 0n), 1) && U32.is_eq(remaining, 16384)), "incomplete Huffman tree")
    return Huffman{counts, symbols}

def tree(+lengths: +List<U32>, allow_single: Bool) -> Result<&2, &1, String, Huffman>:
  +counts = count_all(15n, 1, lengths)
  do Result<&2,&1,String,Huffman>:
    u : Unit <- B.require(List.all(~&2,~U32,~(v => (v <= 15 : U32)),lengths),"Huffman code length exceeds 15 bits")
    Result.bind(&2, &1, String, U32, Huffman, kraft(counts, 1, True{}), remaining => tree_finish(counts, sorted_symbols(15n, 1, lengths), allow_single, remaining))

type DecodeState is Data:
  DecodeState{bits: Bits, code: U32, first: U32, index: U32}

def decode_step(+count: U32, +code: U32, +first: U32, +index: U32, s: Bits, found: Bool, symbols: +List<U32>) -> Result<&2, &1, String, U32 & DecodeState>:
  match found:
    case True{}:
      Done{(1, DecodeState{s, at(symbols, U32.to_nat(U32.add(index, U32.sub(code, first)))), 0, 0})}
    case False{}:
      Done{(0, DecodeState{s, U32.mul(code, 2), U32.mul(U32.add(first, count), 2), U32.add(index, count)})}

def decode_loop(counts: +List<U32>, +symbols: +List<U32>, r: Result<&2, &1, String, U32 & DecodeState>) -> Result<&2, &1, String, U32 & Bits>:
  match counts r:
    case _ Fail{e}:
      Fail{e}
    case _ Done{(1, DecodeState{s, symbol, _, _})}:
      Done{(symbol, s)}
    case Nil{} Done{(_, _)}:
      Fail{"invalid Huffman code"}
    case +count <> rest Done{(_, DecodeState{s, code, +first, +index})}:
      next = read(~(U32 & DecodeState), 1n, s, bit => s => (
        +code = U32.add(code, bit)
        decode_step(count, code, first, index, s, (code >= first : U32) && (code < first + count : U32), symbols)
      ))
      decode_loop(rest, symbols, next)

def symbol(h: Huffman, s: Bits) -> Result<&2, &1, String, U32 & Bits>:
  match h:
    case Huffman{counts, symbols}:
      decode_loop(counts, symbols, Done{(0, DecodeState{s, 0, 0, 0})})

def read_symbol(~T: Type, h: Huffman, s: Bits, f: U32 -> Bits -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  Result.bind(&2, &1, String, U32 & Bits, T, symbol(h, s), pair => apply_read(T, pair, f))

def put_value(out: Output, +value: U32, room: Bool) -> Result<&2, &1, String, Output>:
  match out room:
    case _ False{}:
      Fail{"DEFLATE output exceeds exact image size"}
    case Output{data, +used, limit, a, b} True{}:
      +a = ((a + value) % 65521 : U32)
      data = data[used] <- value
      Done{Output{data, U32.inc(used), limit, a, ((b + a) % 65521 : U32)}}

def put(out: Output, value: U32) -> Result<&2, &1, String, Output>:
  match out:
    case Output{data, +used, +limit, a, b}:
      put_value(Output{data, used, limit, a, b}, value, U32.is_lt(used, limit))

def copy_read(used: U32, limit: U32, a: U32, b: U32, pair: Array<U32> & U32) -> Result<&2, &1, String, Output>:
  (data, v) = pair
  put(Output{data, used, limit, a, b}, v)

def copy_loop(n: Nat, +distance: U32, r: Result<&2, &1, String, Output>) -> Result<&2, &1, String, Output>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{out}:
      Done{out}
    case 1n+p Done{Output{data, +used, limit, a, b}}:
      copy_loop(p, distance, copy_read(used, limit, a, b, data[U32.sub(used, distance)]))

def copy(out: Output, +length: U32, +distance: U32) -> Result<&2, &1, String, Output>:
  match out:
    case Output{data, +used, +limit, a, b}:
      do Result<&2, &1, String, Output>:
        u : Unit <- B.require((distance > 0 : U32) && (distance <= used : U32) && (distance <= 32768 : U32), "invalid DEFLATE backward distance")
        u : Unit <- B.require((length <= limit - used : U32), "DEFLATE match exceeds exact image size")
        copy_loop(U32.to_nat(length), distance, Done{Output{data, used, limit, a, b}})

def fixed_lengths() -> +List<U32>:
  List.concat(&2, U32, [List.replicate(U32, 144n, 8), List.replicate(U32, 112n, 9), List.replicate(U32, 24n, 7), List.replicate(U32, 8n, 8)])

def length_base(code: U32) -> U32:
  at([3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258], U32.to_nat(U32.sub(code, 257)))

def length_extra(code: U32) -> Nat:
  U32.to_nat(at([0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0], U32.to_nat(U32.sub(code, 257))))

def distance_base(code: U32) -> U32:
  at([1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577], U32.to_nat(code))

def distance_extra(code: U32) -> Nat:
  U32.to_nat(at([0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13], U32.to_nat(code)))

type Step is Type:
  Step{bits: Bits, out: Output, ended: Bool}

def pair_step(s: Bits, out: Output) -> Step:
  Step{s, out, False{}}

def decode_distance(+code: U32, s: Bits, length: U32, out: Output) -> Result<&2, &1, String, Step>:
  do Result<&2, &1, String, Step>:
    u : Unit <- B.require((code < 30 : U32), "reserved DEFLATE distance symbol")
    read(~Step, distance_extra(code), s, extra => s => (
      Result.map(&2, &1, String, Output, Step, pair_step(s), copy(out, length, U32.add(distance_base(code), extra)))
    ))

def decode_value(+code: U32, s: Bits, out: Output, dist: Huffman, literal: Bool) -> Result<&2, &1, String, Step>:
  match literal:
    case True{}:
      Result.map(&2, &1, String, Output, Step, pair_step(s), put(out, code))
    case False{}:
      do Result<&2, &1, String, Step>:
        u : Unit <- B.require((code >= 257 : U32) && (code <= 285 : U32), "reserved DEFLATE length symbol")
        read(~Step, length_extra(code), s, extra => s => (
          length = U32.add(length_base(code), extra)
          read_symbol(~Step, dist, s, d => s => decode_distance(d, s, length, out))
        ))

def decode_code(code: U32, s: Bits, out: Output, dist: Huffman) -> Result<&2, &1, String, Step>:
  match code:
    case 256:
      Done{Step{s, out, True{}}}
    case +other:
      decode_value(other, s, out, dist, U32.is_lt(other, 256))

def compressed_loop(fuel: Nat, +lit: Huffman, +dist: Huffman, r: Result<&2, &1, String, Step>) -> Result<&2, &1, String, Step>:
  match fuel r:
    case _ Fail{e}:
      Fail{e}
    case _ Done{Step{s, out, True{}}}:
      Done{Step{s, out, True{}}}
    case 0n Done{_}:
      Fail{"DEFLATE symbol work limit"}
    case 1n+p Done{Step{s, out, False{}}}:
      next = read_symbol(~Step, lit, s, code => s => decode_code(code, s, out, dist))
      compressed_loop(p, lit, dist, next)

def compressed(lit: Huffman, dist: Huffman, s: Bits, out: Output) -> Result<&2, &1, String, Step>:
  match out:
    case Output{data, used, +limit, a, b}:
      compressed_loop(U32.to_nat(U32.inc(limit)), lit, dist, Done{Step{s, Output{data, used, limit, a, b}, False{}}})

def stored_loop(n: Nat, r: Result<&2, &1, String, Step>) -> Result<&2, &1, String, Step>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{Step{s, out, _}}:
      Done{Step{s, out, True{}}}
    case 1n+p Done{Step{s, out, _}}:
      next = read(~Step, 8n, s, b => s => Result.map(&2, &1, String, Output, Step, pair_step(s), put(out, b)))
      stored_loop(p, next)

def stored(s: Bits, out: Output) -> Result<&2, &1, String, Step>:
  read(~Step, 16n, align(s), +length => s => (
    read(~Step, 16n, s, inverse => s => (
      do Result<&2, &1, String, Step>:
        u : Unit <- B.require(U32.is_eq(U32.xor(length, inverse), 65535), "DEFLATE stored length complement mismatch")
        stored_loop(U32.to_nat(length), Done{Step{s, out, False{}}})
    ))
  ))

type CodeLengths is Data:
  CodeLengths{bits: Bits, values: +List<U32>}

def code_lengths(n: Nat, +index: U32, r: Result<&2, &1, String, CodeLengths>) -> Result<&2, &1, String, CodeLengths>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{state}:
      Done{state}
    case 1n+p Done{CodeLengths{s, values}}:
      next = read(~CodeLengths, 3n, s, v => s => (
        order = at([16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15], U32.to_nat(index))
        Done{CodeLengths{s, List.set(&2, U32, values, U32.to_nat(order), v)}}
      ))
      code_lengths(p, U32.inc(index), next)

type LengthState is Data:
  LengthState{bits: Bits, reversed: +List<U32>, remaining: U32, previous: U32, has_previous: Bool}

def repeat_lengths(+count: U32, +value: U32, s: Bits, acc: +List<U32>, +remaining: U32) -> Result<&2, &1, String, LengthState>:
  do Result<&2, &1, String, LengthState>:
    u : Unit <- B.require((count <= remaining : U32), "Huffman repeat exceeds declared lengths")
    return LengthState{s, List.append(&2, U32, List.replicate(U32, U32.to_nat(count), value), acc), U32.sub(remaining, count), value, True{}}

def length_symbol(code: U32, s: Bits, acc: +List<U32>, remaining: U32, previous: U32, has_previous: Bool) -> Result<&2, &1, String, LengthState>:
  match code:
    case 16:
      do Result<&2, &1, String, LengthState>:
        u : Unit <- B.require(has_previous, "Huffman repeat without previous length")
        read(~LengthState, 2n, s, v => s => repeat_lengths(U32.add(v, 3), previous, s, acc, remaining))
    case 17:
      read(~LengthState, 3n, s, v => s => repeat_lengths(U32.add(v, 3), 0, s, acc, remaining))
    case 18:
      read(~LengthState, 7n, s, v => s => repeat_lengths(U32.add(v, 11), 0, s, acc, remaining))
    case value:
      repeat_lengths(1, value, s, acc, remaining)

def lengths_loop(fuel: Nat, +codes: Huffman, r: Result<&2, &1, String, LengthState>) -> Result<&2, &1, String, LengthState>:
  match fuel r:
    case _ Fail{e}:
      Fail{e}
    case _ Done{LengthState{s, acc, 0, previous, has_previous}}:
      Done{LengthState{s, acc, 0, previous, has_previous}}
    case 0n Done{_}:
      Fail{"Huffman length work limit"}
    case 1n+p Done{LengthState{s, acc, remaining, previous, has_previous}}:
      next = read_symbol(~LengthState, codes, s, code => s => length_symbol(code, s, acc, remaining, previous, has_previous))
      lengths_loop(p, codes, next)

def distance_tree(+lengths: +List<U32>, empty: Bool) -> Result<&2, &1, String, Huffman>:
  match empty:
    case True{}:
      Done{Huffman{Nil{}, Nil{}}}
    case False{}:
      tree(lengths, True{})

def dynamic_finish(nlit: U32, state: LengthState, out: Output) -> Result<&2, &1, String, Step>:
  match state:
    case LengthState{s, acc, _, _, _}:
      +values = List.reverse(&2, U32, acc)
      +n = U32.to_nat(nlit)
      +ls = List.take(&2, U32, values, n)
      +ds = List.drop(&2, U32, values, n)
      do Result<&2, &1, String, Step>:
        u : Unit <- B.require(U32.is_ne(at(ls, 256n), 0), "Huffman literal tree has no end-of-block")
        lit : Huffman <- tree(ls, True{})
        dist : Huffman <- distance_tree(ds, U32.is_eq(count_length(ds, 0, 0), U32.from_nat(List.length(&2, U32, ds))))
        compressed(lit, dist, s, out)

def dynamic_codes(+nlit: U32, ndist: U32, state: CodeLengths, out: Output) -> Result<&2, &1, String, Step>:
  match state:
    case CodeLengths{s, values}:
      +count = U32.add(nlit, ndist)
      do Result<&2, &1, String, Step>:
        codes : Huffman <- tree(values, False{})
        state : LengthState <- lengths_loop(U32.to_nat(count), codes, Done{LengthState{s, Nil{}, count, 0, False{}}})
        dynamic_finish(nlit, state, out)

def dynamic(s: Bits, out: Output) -> Result<&2, &1, String, Step>:
  read(~Step, 5n, s, +hlit => s => (
    read(~Step, 5n, s, hdist => s => (
      read(~Step, 4n, s, hclen => s => (
        do Result<&2, &1, String, Step>:
          u : Unit <- B.require((hlit <= 29 : U32), "reserved HLIT count")
          cls : CodeLengths <- code_lengths(U32.to_nat(U32.add(hclen, 4)), 0, Done{CodeLengths{s, List.replicate(U32, 19n, 0)}})
          dynamic_codes(U32.add(hlit, 257), U32.inc(hdist), cls, out)
      ))
    ))
  ))

def block(kind: U32, s: Bits, out: Output) -> Result<&2, &1, String, Step>:
  match kind:
    case 0:
      stored(s, out)
    case 1:
      do Result<&2, &1, String, Step>:
        lit : Huffman <- tree(fixed_lengths(), True{})
        dist : Huffman <- tree(List.replicate(U32, 32n, 5), True{})
        compressed(lit, dist, s, out)
    case 2:
      dynamic(s, out)
    case _:
      Fail{"reserved DEFLATE block type"}

def block_result(final: U32, r: Result<&2, &1, String, Step>) -> Result<&2, &1, String, Step>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{Step{s, out, _}}:
      Done{Step{s, out, U32.is_eq(final, 1)}}

def blocks(fuel: Nat, r: Result<&2, &1, String, Step>) -> Result<&2, &1, String, Step>:
  match fuel r:
    case _ Fail{e}:
      Fail{e}
    case _ Done{Step{s, out, True{}}}:
      Done{Step{s, out, True{}}}
    case 0n Done{_}:
      Fail{"DEFLATE block limit (65536)"}
    case 1n+p Done{Step{s, out, False{}}}:
      next = read(~Step, 1n, s, final => s => read(~Step, 2n, s, kind => s => block_result(final, block(kind, s, out))))
      blocks(p, next)

def finish(state: Step) -> Result<&2, &1, String, Array<U32>>:
  match state:
    case Step{Bits{a <> b <> c <> d <> Nil{}, _, _}, Output{data, used, limit, aa, ab}, _}:
      do Result<&2, &1, String, Array<U32>>:
        u : Unit <- B.require(U32.is_eq(used, limit), "DEFLATE output is shorter than image size")
        u : Unit <- B.require(U32.is_eq((a * 16777216 + b * 65536 + c * 256 + d : U32), (ab * 65536 + aa : U32)), "zlib Adler-32 mismatch")
        return data
    case _:
      Fail{"missing Adler-32 or trailing bytes after zlib stream"}

def inflate(bytes: +List<U32>, +size: U32) -> Result<&2, &1, String, Array<U32>>:
  match bytes:
    case +cmf <> +flg <> rest:
      do Result<&2, &1, String, Array<U32>>:
        u : Unit <- B.require((size > 0 : U32) && (size <= 1052672 : U32), "inflate allocation limit")
        u : Unit <- B.require(U32.is_eq(cmf, 120), "unsupported zlib header (requires DEFLATE, 32 KiB window)")
        u : Unit <- B.require(U32.is_eq(((cmf * 256 + flg) % 31 : U32), 0), "invalid zlib FCHECK")
        u : Unit <- B.require(U32.is_eq(U32.and(flg, 32), 0), "zlib preset dictionary is unsupported")
        state : Step <- blocks(U32.to_nat(65536), Done{Step{Bits{rest, 0, 0}, Output{B.allocate(size), 0, size, 1, 0}, False{}}})
        finish(state)
    case _:
      Fail{"truncated zlib header"}
