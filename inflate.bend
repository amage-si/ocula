import Base
import ./bytes.bend as B

type Huffman is Data:
  Huffman{counts: +List<U32>, symbols: +List<U32>}

type Output is Type:
  Output{data: Array<U32>, used: U32, limit: U32}

# Decoder state, threaded through first-order helpers (no closure per symbol).
#
# `src` holds the zlib payload (after the two header bytes) at [0, inlen),
# zeros at [inlen, tab), and the tables at `tab` (see `inflate_tables`):
#   tab + 0     literal/length Huffman table   (1024 slots)
#   tab + 1024  distance Huffman table          (1024 slots)
#   tab + 2048  code-length Huffman table       (1024 slots)
#   tab + 3072  length base/extra, codes 257..287
#   tab + 3104  distance base/extra, codes 0..31
# A Huffman table at `base` holds a 9-bit primary index at [base, base+512),
# the code count of each length L at base+512+L, and the symbols in
# canonical order from base+528.
#
# `buf` holds the unread bits, least significant first; `top` is 2^(number
# of bits in buf), so consuming k bits divides both by 2^k and no variable
# shift is needed. Bytes are read at min(pos, inlen), so a read past the end
# yields zeros from the padding; `pos` still counts them, and a refill that
# moves `pos` past `inlen` flags the stream as truncated (a valid stream
# never gets there, since its Adler-32 trailer follows the last block).
#
# `err` is 0 while decoding, 1 at the end of a block, else an error code (see
# `message`). The first code set wins, and work after an error is discarded.
type Inf is Type:
  Inf{src: Array<U32>, out: Array<U32>, pos: U32, buf: U32, top: U32, used: U32, err: U32}

def message(code: U32) -> String:
  match code:
    case 2:
      "invalid Huffman code"
    case 3:
      "reserved DEFLATE length symbol"
    case 4:
      "reserved DEFLATE distance symbol"
    case 5:
      "invalid DEFLATE backward distance"
    case 6:
      "DEFLATE match exceeds exact image size"
    case 7:
      "DEFLATE output exceeds exact image size"
    case 8:
      "DEFLATE symbol work limit"
    case 9:
      "truncated DEFLATE bitstream"
    case _:
      "DEFLATE decoder error " ++ U32.show(code)

def fail(+err: U32, +code: U32) -> U32:
  Bool.pick(U32, U32.is_eq(err, 0), code, err)

def flag(bad: Bool, +err: U32, +code: U32) -> U32:
  match bad:
    case True{}:
      fail(err, code)
    case False{}:
      err

# Bit input ------------------------------------------------------------------

def refill_done(+b0: U32, r: Array<U32> & U32, out: Array<U32>, +pos: U32, +buf: U32, +top: U32, used: U32, +err: U32, +inlen: U32) -> Inf:
  (src, +b1) = r
  +next = U32.add(pos, 2)
  Inf{src, out, next, (buf + b0 * top + b1 * top * 256 : U32), U32.mul(top, 65536), used, flag(U32.is_gt(next, inlen), err, 9)}

def refill_one(r: Array<U32> & U32, out: Array<U32>, +pos: U32, buf: U32, top: U32, used: U32, err: U32, +inlen: U32) -> Inf:
  (src, b0) = r
  refill_done(b0, src[U32.min(U32.inc(pos), inlen)], out, pos, buf, top, used, err, inlen)

def refill_when(need: Bool, src: Array<U32>, out: Array<U32>, +pos: U32, buf: U32, top: U32, used: U32, err: U32, +inlen: U32) -> Inf:
  match need:
    case False{}:
      Inf{src, out, pos, buf, top, used, err}
    case True{}:
      refill_one(src[U32.min(pos, inlen)], out, pos, buf, top, used, err, inlen)

# Guarantees at least 16 bits in `buf` (from fewer than 16, two bytes fit in
# 32 bits). Every take or decode below consumes at most 15 bits after one.
def refill(st: Inf, +inlen: U32) -> Inf:
  match st:
    case Inf{src, out, pos, buf, +top, used, err}:
      refill_when(U32.is_lt(top, 65536), src, out, pos, buf, top, used, err, inlen)

# Takes k bits, given pw = 2^k.
def take(st: Inf, +pw: U32) -> Inf & U32:
  match st:
    case Inf{src, out, pos, +buf, top, used, err}:
      (Inf{src, out, pos, U32.div(buf, pw), U32.div(top, pw), used, err}, U32.and(buf, U32.sub(pw, 1)))

# Huffman decoding -------------------------------------------------------------

# Canonical decode of codes longer than 9 bits (rare), one length at a time:
# `cur` holds the count of the current length, or the symbol once found.
# Answers sym * 65536 + 2^length, or 0 when no length matches.
def slow(n: Nat, hit: Bool, cur: Array<U32> & U32, +base: U32, +bits: U32, +code: U32, +first: U32, +index: U32, +slot: U32, +pw: U32) -> Array<U32> & U32:
  match n hit:
    case _ True{}:
      (src, sym) = cur
      (src, (sym * 65536 + pw : U32))
    case 0n False{}:
      (src, _) = cur
      (src, 0)
    case 1n+p False{}:
      (src, +count) = cur
      +c = (code * 2 + U32.and(bits, 1) : U32)
      +offset = U32.sub(c, first)
      +found = U32.is_lt(offset, count)
      +next = Bool.pick(U32, found, (base + 528 + index + offset : U32), slot)
      slow(p, found, src[next], base, U32.shr(bits), c, ((first + count) * 2 : U32), U32.add(index, count), U32.inc(slot), U32.mul(pw, 2))

def apply_entry(miss: Bool, src: Array<U32>, out: Array<U32>, pos: U32, +buf: U32, +top: U32, used: U32, +err: U32, +entry: U32) -> Inf & U32:
  match miss:
    case True{}:
      (Inf{src, out, pos, buf, top, used, fail(err, 2)}, 0)
    case False{}:
      +pw = U32.and(entry, 65535)
      (Inf{src, out, pos, U32.div(buf, pw), U32.div(top, pw), used, err}, U32.div(entry, 65536))

def slow_done(r: Array<U32> & U32, out: Array<U32>, pos: U32, buf: U32, top: U32, used: U32, err: U32) -> Inf & U32:
  (src, +entry) = r
  apply_entry(U32.is_eq(entry, 0), src, out, pos, buf, top, used, err, entry)

def decode_entry(miss: Bool, src: Array<U32>, out: Array<U32>, pos: U32, +buf: U32, top: U32, used: U32, err: U32, +base: U32, +entry: U32) -> Inf & U32:
  match miss:
    case False{}:
      apply_entry(False{}, src, out, pos, buf, top, used, err, entry)
    case True{}:
      slow_done(slow(15n, False{}, src[U32.add(base, 513)], base, buf, 0, 0, 0, U32.add(base, 514), 1), out, pos, buf, top, used, err)

def lookup(r: Array<U32> & U32, out: Array<U32>, pos: U32, buf: U32, top: U32, used: U32, err: U32, +base: U32) -> Inf & U32:
  (src, +entry) = r
  decode_entry(U32.is_eq(entry, 0), src, out, pos, buf, top, used, err, base, entry)

# Decodes one symbol with the table at `base`; needs a refill before it.
# The primary entry for the next 9 bits is sym * 65536 + 2^length, or 0 when
# the code is longer than 9 bits or not in the tree.
def decode(st: Inf, +base: U32) -> Inf & U32:
  match st:
    case Inf{src, out, pos, +buf, top, used, err}:
      lookup(src[U32.add(base, U32.and(buf, 511))], out, pos, buf, top, used, err, base)

# Table construction (once per block) -----------------------------------------

def at(xs: +List<U32>, n: Nat) -> U32:
  match xs n:
    case Nil{} _:
      0
    case h <> t 0n:
      h
    case h <> t 1n+p:
      at(t, p)

def clear(n: Nat, src: Array<U32>, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      src
    case 1n+p:
      src = src[i] <- 0
      clear(p, src, U32.inc(i))

def put_list(xs: +List<U32>, src: Array<U32>, +i: U32) -> Array<U32>:
  match xs:
    case Nil{}:
      src
    case +h <> t:
      src = src[i] <- h
      put_list(t, src, U32.inc(i))

def fill_rep(n: Nat, src: Array<U32>, +i: U32, +step: U32, +entry: U32) -> Array<U32>:
  match n:
    case 0n:
      src
    case 1n+p:
      src = src[i] <- entry
      fill_rep(p, src, U32.add(i, step), step, entry)

def reverse_bits(n: Nat, +c: U32, +r: U32) -> U32:
  match n:
    case 0n:
      r
    case 1n+p:
      reverse_bits(p, U32.shr(c), (r * 2 + U32.and(c, 1) : U32))

# A code of `length` <= 9 bits fills every primary slot whose low bits are the
# code, read in stream order (bit-reversed).
def fill_symbol(short: Bool, src: Array<U32>, +base: U32, +sym: U32, +length: U32, +code: U32) -> Array<U32>:
  match short:
    case False{}:
      src
    case True{}:
      +pw = U32.pow(2, U32.to_nat(length))
      fill_rep(U32.to_nat(U32.pow(2, U32.to_nat(U32.sub(9, length)))), src, U32.add(base, reverse_bits(U32.to_nat(length), code, 0)), pw, (sym * 65536 + pw : U32))

# Walks the symbols in canonical order, assigning consecutive codes per length.
def fill_codes(fuel: Nat, +left: U32, counts: +List<U32>, syms: +List<U32>, src: Array<U32>, +base: U32, +length: U32, +code: U32) -> Array<U32>:
  match fuel left counts syms:
    case 0n _ _ _:
      src
    case 1n+p 0 Nil{} _:
      src
    case 1n+p 0 +h <> t _:
      fill_codes(p, h, t, syms, src, base, U32.inc(length), U32.mul(code, 2))
    case 1n+p _ _ Nil{}:
      src
    case 1n+p _ _ +s <> rest:
      fill_codes(p, U32.sub(left, 1), counts, rest, fill_symbol(U32.is_le(length, 9), src, base, s, length, code), base, length, U32.inc(code))

def build(src: Array<U32>, +base: U32, h: Huffman) -> Array<U32>:
  match h:
    case Huffman{+counts, +symbols}:
      src = clear(528n, src, base)
      src = put_list(counts, src, U32.add(base, 513))
      src = put_list(symbols, src, U32.add(base, 528))
      fill_codes(320n, 0, counts, symbols, src, base, 0, 0)

def put_info(bases: +List<U32>, extras: +List<U32>, src: Array<U32>, +i: U32) -> Array<U32>:
  match bases extras:
    case +b <> bs +e <> es:
      src = src[i] <- (b * 65536 + U32.pow(2, U32.to_nat(e)) : U32)
      put_info(bs, es, src, U32.inc(i))
    case _ _:
      src

def inflate_tables(src: Array<U32>, +tab: U32) -> Array<U32>:
  src = put_info([3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258], [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0], src, U32.add(tab, 3072))
  put_info([1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577], [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13], src, U32.add(tab, 3104))

# Huffman tree validation ------------------------------------------------------

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

# Output -----------------------------------------------------------------------

# `cur` is the byte `distance` back from `used`. copy_checked has already
# checked 0 < distance <= used and length <= limit - used, so every index
# stays in the written part of the output and no step needs another check.
def copy_loop(n: Nat, cur: Array<U32> & U32, +used: U32, +distance: U32) -> Array<U32> & U32:
  match n:
    case 0n:
      (data, _) = cur
      (data, used)
    case 1n+p:
      (data, v) = cur
      data = data[used] <- v
      +next = U32.inc(used)
      copy_loop(p, data[U32.sub(next, distance)], next, distance)

def copied(+err: U32, pair: Array<U32> & U32) -> Array<U32> & (U32 & U32):
  (data, used) = pair
  (data, (used, err))

def copy_run(near: Bool, room: Bool, data: Array<U32>, +used: U32, +length: U32, +distance: U32, +err: U32) -> Array<U32> & (U32 & U32):
  match near room:
    case False{} _:
      (data, (used, fail(err, 5)))
    case True{} False{}:
      (data, (used, fail(err, 6)))
    case True{} True{}:
      copied(err, copy_loop(U32.to_nat(length), data[U32.sub(used, distance)], used, distance))

# Answers (data, (used, err)).
def copy_checked(data: Array<U32>, +used: U32, +limit: U32, +length: U32, +distance: U32, +err: U32) -> Array<U32> & (U32 & U32):
  copy_run((distance > 0 : U32) && (distance <= used : U32) && (distance <= 32768 : U32), (length <= limit - used : U32), data, used, length, distance, err)

def copy_result(+err: U32, data: Array<U32>, used: U32, limit: U32) -> Result<&2, &1, String, Output>:
  match err:
    case 0:
      Done{Output{data, used, limit}}
    case _:
      Fail{message(err)}

def copy_output(+limit: U32, r: Array<U32> & (U32 & U32)) -> Result<&2, &1, String, Output>:
  (data, pair) = r
  (used, err) = pair
  copy_result(err, data, used, limit)

def copy(out: Output, +length: U32, +distance: U32) -> Result<&2, &1, String, Output>:
  match out:
    case Output{data, +used, +limit}:
      copy_output(limit, copy_checked(data, used, limit, length, distance, 0))

# Compressed blocks ------------------------------------------------------------

def put_literal(room: Bool, src: Array<U32>, out: Array<U32>, pos: U32, buf: U32, top: U32, +used: U32, +err: U32, +sym: U32) -> Inf:
  match room:
    case True{}:
      out = out[used] <- sym
      Inf{src, out, pos, buf, top, U32.inc(used), err}
    case False{}:
      Inf{src, out, pos, buf, top, used, fail(err, 7)}

def literal(st: Inf, +sym: U32, +limit: U32) -> Inf:
  match st:
    case Inf{src, out, pos, buf, top, +used, err}:
      put_literal(U32.is_lt(used, limit), src, out, pos, buf, top, used, err, sym)

def copy_back(src: Array<U32>, pos: U32, buf: U32, top: U32, r: Array<U32> & (U32 & U32)) -> Inf:
  (out, pair) = r
  (used, err) = pair
  Inf{src, out, pos, buf, top, used, err}

def distance_done(r: Inf & U32, +base: U32, +length: U32, +limit: U32) -> Inf:
  (st, +extra) = r
  match st:
    case Inf{src, out, pos, buf, top, +used, +err}:
      copy_back(src, pos, buf, top, copy_checked(out, used, limit, length, U32.add(base, extra), err))

def distance_info(r: Array<U32> & U32, out: Array<U32>, pos: U32, buf: U32, top: U32, used: U32, err: U32, +length: U32, +inlen: U32, +limit: U32) -> Inf:
  (src, +e) = r
  distance_done(take(refill(Inf{src, out, pos, buf, top, used, err}, inlen), U32.and(e, 65535)), U32.div(e, 65536), length, limit)

def distance_symbol(r: Inf & U32, +length: U32, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  (st, +d) = r
  match st:
    case Inf{src, out, pos, buf, top, used, +err}:
      distance_info(src[(tab + 3104 + U32.and(d, 31) : U32)], out, pos, buf, top, used, flag(U32.is_ge(d, 30), err, 4), length, inlen, limit)

def length_done(r: Inf & U32, +base: U32, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  (st, +extra) = r
  distance_symbol(decode(refill(st, inlen), U32.add(tab, 1024)), U32.add(base, extra), inlen, limit, tab)

def length_info(r: Array<U32> & U32, out: Array<U32>, pos: U32, buf: U32, top: U32, used: U32, err: U32, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  (src, +e) = r
  length_done(take(refill(Inf{src, out, pos, buf, top, used, err}, inlen), U32.and(e, 65535)), U32.div(e, 65536), inlen, limit, tab)

def length_code(st: Inf, +sym: U32, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  match st:
    case Inf{src, out, pos, buf, top, used, +err}:
      length_info(src[(tab + 3072 + U32.and(U32.sub(sym, 257), 31) : U32)], out, pos, buf, top, used, flag(U32.is_gt(sym, 285), err, 3), inlen, limit, tab)

def block_end(st: Inf) -> Inf:
  match st:
    case Inf{src, out, pos, buf, top, used, +err}:
      Inf{src, out, pos, buf, top, used, fail(err, 1)}

def dispatch(lit: Bool, end: Bool, st: Inf, +sym: U32, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  match lit end:
    case True{} _:
      literal(st, sym, limit)
    case False{} True{}:
      block_end(st)
    case False{} False{}:
      length_code(st, sym, inlen, limit, tab)

def symbol_step(r: Inf & U32, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  (st, +sym) = r
  dispatch(U32.is_lt(sym, 256), U32.is_eq(sym, 256), st, sym, inlen, limit, tab)

# One literal/length symbol per step, until end-of-block or an error. Every
# symbol but end-of-block writes at least one byte, so limit + 1 steps suffice.
def run(n: Nat, st: Inf, +inlen: U32, +limit: U32, +tab: U32) -> Inf:
  match n st:
    case 0n Inf{src, out, pos, buf, top, used, 0}:
      Inf{src, out, pos, buf, top, used, 8}
    case 1n+p Inf{src, out, pos, buf, top, used, 0}:
      run(p, symbol_step(decode(refill(Inf{src, out, pos, buf, top, used, 0}, inlen), tab), inlen, limit, tab), inlen, limit, tab)
    case _ Inf{src, out, pos, buf, top, used, err}:
      Inf{src, out, pos, buf, top, used, err}

# Block level (once per block; closures are fine here) ---------------------------

def ended(+err: U32, src: Array<U32>, out: Array<U32>, pos: U32, buf: U32, top: U32, used: U32) -> Result<&2, &1, String, Inf>:
  match err:
    case 1:
      Done{Inf{src, out, pos, buf, top, used, 0}}
    case _:
      Fail{message(err)}

def block_done(st: Inf) -> Result<&2, &1, String, Inf>:
  match st:
    case Inf{src, out, pos, buf, top, used, err}:
      ended(err, src, out, pos, buf, top, used)

def compressed(st: Inf, lit: Huffman, dist: Huffman, +inlen: U32, +limit: U32, +tab: U32) -> Result<&2, &1, String, Inf>:
  match st:
    case Inf{src, out, pos, buf, top, used, err}:
      src = build(src, tab, lit)
      src = build(src, U32.add(tab, 1024), dist)
      block_done(run(U32.to_nat(U32.inc(limit)), Inf{src, out, pos, buf, top, used, err}, inlen, limit, tab))

def checked_value(+err: U32, st: Inf, v: U32) -> Result<&2, &1, String, Inf & U32>:
  match err:
    case 0:
      Done{(st, v)}
    case _:
      Fail{message(err)}

def checked(pair: Inf & U32) -> Result<&2, &1, String, Inf & U32>:
  (st, v) = pair
  match st:
    case Inf{src, out, pos, buf, top, used, +err}:
      checked_value(err, Inf{src, out, pos, buf, top, used, err}, v)

def apply_read(-T: Type, pair: Inf & U32, f: U32 -> Inf -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  (st, value) = pair
  f(value, st)

# Reads k bits, given pw = 2^k with k <= 15.
def read(~T: Type, +pw: U32, st: Inf, +inlen: U32, f: U32 -> Inf -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  Result.bind(&2, &1, String, Inf & U32, T, checked(take(refill(st, inlen), pw)), pair => apply_read(T, pair, f))

def read_symbol(~T: Type, +base: U32, st: Inf, +inlen: U32, f: U32 -> Inf -> Result<&2, &1, String, T>) -> Result<&2, &1, String, T>:
  Result.bind(&2, &1, String, Inf & U32, T, checked(decode(refill(st, inlen), base)), pair => apply_read(T, pair, f))

def log2(n: Nat, +x: U32, +acc: U32) -> U32:
  match n x:
    case 0n _:
      acc
    case _ 0:
      acc
    case _ 1:
      acc
    case 1n+p _:
      log2(p, U32.shr(x), U32.inc(acc))

# Drops the bits of a partly read byte and returns whole buffered bytes to the
# input, leaving `pos` at the next byte boundary.
def align(st: Inf) -> Inf:
  match st:
    case Inf{src, out, +pos, buf, +top, used, err}:
      Inf{src, out, U32.sub(pos, U32.div(log2(32n, top, 0), 8)), 0, 1, used, err}

# Copies stored bytes src[i..] to out[used..]; the caller checked both ranges.
def stored_loop(n: Nat, cur: Array<U32> & U32, out: Array<U32>, +i: U32, +used: U32) -> Inf:
  match n:
    case 0n:
      (src, _) = cur
      Inf{src, out, i, 0, 1, used, 0}
    case 1n+p:
      (src, v) = cur
      out = out[used] <- v
      +next = U32.inc(i)
      stored_loop(p, src[next], out, next, U32.inc(used))

def stored_copy(st: Inf, +length: U32, +inlen: U32, +limit: U32) -> Result<&2, &1, String, Inf>:
  match st:
    case Inf{src, out, +pos, _, _, +used, _}:
      do Result<&2, &1, String, Inf>:
        u : Unit <- B.require((length <= limit - used : U32), "DEFLATE output exceeds exact image size")
        u : Unit <- B.require((pos <= inlen : U32) && (length <= inlen - pos : U32), "truncated DEFLATE bitstream")
        return stored_loop(U32.to_nat(length), src[pos], out, pos, used)

def stored(st: Inf, +inlen: U32, +limit: U32) -> Result<&2, &1, String, Inf>:
  read(~Inf, 65536, align(st), inlen, +length => st => (
    read(~Inf, 65536, st, inlen, inverse => st => (
      do Result<&2, &1, String, Inf>:
        u : Unit <- B.require(U32.is_eq(U32.xor(length, inverse), 65535), "DEFLATE stored length complement mismatch")
        stored_copy(st, length, inlen, limit)
    ))
  ))

type CodeLengths is Type:
  CodeLengths{st: Inf, values: +List<U32>}

def code_lengths(n: Nat, +index: U32, +inlen: U32, r: Result<&2, &1, String, CodeLengths>) -> Result<&2, &1, String, CodeLengths>:
  match n r:
    case _ Fail{e}:
      Fail{e}
    case 0n Done{state}:
      Done{state}
    case 1n+p Done{CodeLengths{st, values}}:
      next = read(~CodeLengths, 8, st, inlen, v => st => (
        order = at([16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15], U32.to_nat(index))
        Done{CodeLengths{st, List.set(&2, U32, values, U32.to_nat(order), v)}}
      ))
      code_lengths(p, U32.inc(index), inlen, next)

type LengthState is Type:
  LengthState{st: Inf, reversed: +List<U32>, remaining: U32, previous: U32, has_previous: Bool}

def repeat_lengths(+count: U32, +value: U32, st: Inf, acc: +List<U32>, +remaining: U32) -> Result<&2, &1, String, LengthState>:
  do Result<&2, &1, String, LengthState>:
    u : Unit <- B.require((count <= remaining : U32), "Huffman repeat exceeds declared lengths")
    return LengthState{st, List.append(&2, U32, List.replicate(U32, U32.to_nat(count), value), acc), U32.sub(remaining, count), value, True{}}

def length_symbol(code: U32, st: Inf, +inlen: U32, acc: +List<U32>, remaining: U32, previous: U32, has_previous: Bool) -> Result<&2, &1, String, LengthState>:
  match code:
    case 16:
      do Result<&2, &1, String, LengthState>:
        u : Unit <- B.require(has_previous, "Huffman repeat without previous length")
        read(~LengthState, 4, st, inlen, v => st => repeat_lengths(U32.add(v, 3), previous, st, acc, remaining))
    case 17:
      read(~LengthState, 8, st, inlen, v => st => repeat_lengths(U32.add(v, 3), 0, st, acc, remaining))
    case 18:
      read(~LengthState, 128, st, inlen, v => st => repeat_lengths(U32.add(v, 11), 0, st, acc, remaining))
    case value:
      repeat_lengths(1, value, st, acc, remaining)

def lengths_loop(fuel: Nat, +tab: U32, +inlen: U32, r: Result<&2, &1, String, LengthState>) -> Result<&2, &1, String, LengthState>:
  match fuel r:
    case _ Fail{e}:
      Fail{e}
    case _ Done{LengthState{st, acc, 0, previous, has_previous}}:
      Done{LengthState{st, acc, 0, previous, has_previous}}
    case 0n Done{_}:
      Fail{"Huffman length work limit"}
    case 1n+p Done{LengthState{st, acc, remaining, previous, has_previous}}:
      next = read_symbol(~LengthState, U32.add(tab, 2048), st, inlen, code => st => length_symbol(code, st, inlen, acc, remaining, previous, has_previous))
      lengths_loop(p, tab, inlen, next)

def distance_tree(+lengths: +List<U32>, empty: Bool) -> Result<&2, &1, String, Huffman>:
  match empty:
    case True{}:
      Done{Huffman{Nil{}, Nil{}}}
    case False{}:
      tree(lengths, True{})

def dynamic_finish(nlit: U32, state: LengthState, +inlen: U32, +limit: U32, +tab: U32) -> Result<&2, &1, String, Inf>:
  match state:
    case LengthState{st, acc, _, _, _}:
      +values = List.reverse(&2, U32, acc)
      +n = U32.to_nat(nlit)
      +ls = List.take(&2, U32, values, n)
      +ds = List.drop(&2, U32, values, n)
      do Result<&2, &1, String, Inf>:
        u : Unit <- B.require(U32.is_ne(at(ls, 256n), 0), "Huffman literal tree has no end-of-block")
        lit : Huffman <- tree(ls, True{})
        dist : Huffman <- distance_tree(ds, U32.is_eq(count_length(ds, 0, 0), U32.from_nat(List.length(&2, U32, ds))))
        compressed(st, lit, dist, inlen, limit, tab)

def with_code_table(+tab: U32, codes: Huffman, st: Inf) -> Inf:
  match st:
    case Inf{src, out, pos, buf, top, used, err}:
      Inf{build(src, U32.add(tab, 2048), codes), out, pos, buf, top, used, err}

def dynamic_codes(+nlit: U32, ndist: U32, state: CodeLengths, +inlen: U32, +limit: U32, +tab: U32) -> Result<&2, &1, String, Inf>:
  match state:
    case CodeLengths{st, values}:
      +count = U32.add(nlit, ndist)
      do Result<&2, &1, String, Inf>:
        codes : Huffman <- tree(values, False{})
        state : LengthState <- lengths_loop(U32.to_nat(count), tab, inlen, Done{LengthState{with_code_table(tab, codes, st), Nil{}, count, 0, False{}}})
        dynamic_finish(nlit, state, inlen, limit, tab)

def dynamic(st: Inf, +inlen: U32, +limit: U32, +tab: U32) -> Result<&2, &1, String, Inf>:
  read(~Inf, 32, st, inlen, +hlit => st => (
    read(~Inf, 32, st, inlen, hdist => st => (
      read(~Inf, 16, st, inlen, hclen => st => (
        do Result<&2, &1, String, Inf>:
          u : Unit <- B.require((hlit <= 29 : U32), "reserved HLIT count")
          cls : CodeLengths <- code_lengths(U32.to_nat(U32.add(hclen, 4)), 0, inlen, Done{CodeLengths{st, List.replicate(U32, 19n, 0)}})
          dynamic_codes(U32.add(hlit, 257), U32.inc(hdist), cls, inlen, limit, tab)
      ))
    ))
  ))

def fixed_lengths() -> +List<U32>:
  List.concat(&2, U32, [List.replicate(U32, 144n, 8), List.replicate(U32, 112n, 9), List.replicate(U32, 24n, 7), List.replicate(U32, 8n, 8)])

def block(kind: U32, st: Inf, +inlen: U32, +limit: U32, +tab: U32) -> Result<&2, &1, String, Inf>:
  match kind:
    case 0:
      stored(st, inlen, limit)
    case 1:
      do Result<&2, &1, String, Inf>:
        lit : Huffman <- tree(fixed_lengths(), True{})
        dist : Huffman <- tree(List.replicate(U32, 32n, 5), True{})
        compressed(st, lit, dist, inlen, limit, tab)
    case 2:
      dynamic(st, inlen, limit, tab)
    case _:
      Fail{"reserved DEFLATE block type"}

type Step is Type:
  Step{st: Inf, ended: Bool}

def block_result(final: U32, r: Result<&2, &1, String, Inf>) -> Result<&2, &1, String, Step>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{st}:
      Done{Step{st, U32.is_eq(final, 1)}}

def blocks(fuel: Nat, +inlen: U32, +limit: U32, +tab: U32, r: Result<&2, &1, String, Step>) -> Result<&2, &1, String, Step>:
  match fuel r:
    case _ Fail{e}:
      Fail{e}
    case _ Done{Step{st, True{}}}:
      Done{Step{st, True{}}}
    case 0n Done{_}:
      Fail{"DEFLATE block limit (65536)"}
    case 1n+p Done{Step{st, False{}}}:
      next = read(~Step, 2, st, inlen, final => st => read(~Step, 4, st, inlen, kind => st => block_result(final, block(kind, st, inlen, limit, tab))))
      blocks(p, inlen, limit, tab, next)

# Adler-32 over data[0..n). The sums are reduced every 5552 bytes, as in zlib:
# 5552 is the largest run for which b cannot pass 2^32 starting from a, b <
# 65521, so `run` counts down the bytes left before the next reduction.
def adler_loop(n: Nat, +run: U32, cur: Array<U32> & U32, +index: U32, +a: U32, +b: U32) -> Array<U32> & U32:
  match n run:
    case 0n _:
      (data, _) = cur
      (data, (U32.mod(b, 65521) * 65536 + U32.mod(a, 65521) : U32))
    case 1n+p 0:
      (data, v) = cur
      +sa = U32.add(a, v)
      +next = U32.inc(index)
      adler_loop(p, 5551, data[next], next, U32.mod(sa, 65521), U32.mod(U32.add(b, sa), 65521))
    case 1n+p _:
      (data, v) = cur
      +sa = U32.add(a, v)
      +next = U32.inc(index)
      adler_loop(p, U32.sub(run, 1), data[next], next, sa, U32.add(b, sa))

def adler32(data: Array<U32>, +size: U32) -> Array<U32> & U32:
  adler_loop(U32.to_nat(size), 5551, data[0], 0, 1, 0)

def check_adler(+expected: U32, pair: Array<U32> & U32) -> Result<&2, &1, String, Array<U32>>:
  (data, +actual) = pair
  do Result<&2, &1, String, Array<U32>>:
    u : Unit <- B.require(U32.is_eq(expected, actual), "zlib Adler-32 mismatch")
    return data

def trailer(n: Nat, cur: Array<U32> & U32, +i: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      (src, v) = cur
      +next = U32.inc(i)
      trailer(p, src[next], next, (acc * 256 + v : U32))

def finish_aligned(st: Inf, +inlen: U32, +limit: U32) -> Result<&2, &1, String, Array<U32>>:
  match st:
    case Inf{src, out, +pos, _, _, +used, _}:
      do Result<&2, &1, String, Array<U32>>:
        u : Unit <- B.require((pos <= inlen : U32) && U32.is_eq(U32.sub(inlen, pos), 4), "missing Adler-32 or trailing bytes after zlib stream")
        u : Unit <- B.require(U32.is_eq(used, limit), "DEFLATE output is shorter than image size")
        check_adler(trailer(4n, src[pos], pos, 0), adler32(out, limit))

def finish(+inlen: U32, +limit: U32, state: Step) -> Result<&2, &1, String, Array<U32>>:
  match state:
    case Step{st, _}:
      finish_aligned(align(st), inlen, limit)

def start(rest: +List<U32>, +inlen: U32, +size: U32) -> Result<&2, &1, String, Array<U32>>:
  +tab = U32.add(inlen, 16)
  src = inflate_tables(put_list(rest, B.allocate(U32.add(tab, 3136)), 0), tab)
  Result.bind(&2, &1, String, Step, Array<U32>, blocks(65536n, inlen, size, tab, Done{Step{Inf{src, B.allocate(size), 0, 0, 1, 0, 0}, False{}}}), state => finish(inlen, size, state))

def inflate(bytes: +List<U32>, +size: U32) -> Result<&2, &1, String, Array<U32>>:
  match bytes:
    case +cmf <> +flg <> +rest:
      +inlen = U32.from_nat(List.length(&2, U32, rest))
      do Result<&2, &1, String, Array<U32>>:
        u : Unit <- B.require((size > 0 : U32) && (size <= 1052672 : U32), "inflate allocation limit")
        u : Unit <- B.require((inlen <= 2097152 : U32), "inflate input limit")
        u : Unit <- B.require(U32.is_eq(cmf, 120), "unsupported zlib header (requires DEFLATE, 32 KiB window)")
        u : Unit <- B.require(U32.is_eq(((cmf * 256 + flg) % 31 : U32), 0), "invalid zlib FCHECK")
        u : Unit <- B.require(U32.is_eq(U32.and(flg, 32), 0), "zlib preset dictionary is unsupported")
        start(rest, inlen, size)
    case _:
      Fail{"truncated zlib header"}
