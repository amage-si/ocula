import Base
import ../main.bend as O
import ../pixels.bend as P
import ../file.bend as F

# Decode timing harness: bench <repetitions> <file.png>...
# Every decode is forced (its pixel checksum is printed) before the next clock
# read, and starts only after the clock read that precedes it.

def sum_loop(n: Nat, +i: U32, read: Array<U32> & U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      (pixels, v) = read
      +next = U32.xor(U32.add(U32.mul(acc, 31), v), U32.shr(acc))
      sum_loop(p, U32.inc(i), pixels[i], next)

def checksum(r: Result<&2, &1, String, P.Raster>) -> String:
  match r:
    case Fail{e}:
      "error: " ++ e
    case Done{P.Raster{+w, +h, pixels}}:
      U32.show(w) ++ "x" ++ U32.show(h) ++ " sum " ++ U32.show(sum_loop(U32.to_nat(U32.mul(w, h)), 1, pixels[0], 0))

# Decoding depends on the start time, so it cannot be hoisted above it.
def decode_after(t: Nat, +bytes: +List<U32>) -> String:
  match t:
    case 0n:
      "clock at zero"
    case 1n+p:
      checksum(O.decode_png(bytes))

def report(name: String, +reps: Nat, +total: Nat, +best: Nat) -> IO(Unit):
  IO.print("BENCH " ++ name ++ " reps " ++ Nat.show(reps) ++ " mean_us " ++ Nat.show(Nat.div(Nat.mul(total, 1000n), reps)) ++ " min_ms " ++ Nat.show(best))

def bench_loop(n: Nat, name: String, +bytes: +List<U32>, +reps: Nat, +total: Nat, +best: Nat) -> IO(Unit):
  match n:
    case 0n:
      report(name, reps, total, best)
    case 1n+p:
      do IO<Unit>:
        +t0 : Nat <- IO.now()
        IO.print(decode_after(t0, bytes))
        +t1 : Nat <- IO.now()
        +dt : Nat = Nat.sub(t1, t0)
        bench_loop(p, name, bytes, reps, Nat.add(total, dt), Nat.min(best, dt))

def bench_file(+reps: Nat, +path: String) -> IO(Unit):
  do IO<Unit>:
    bytes : +List<U32> <- F.read(path)
    bench_loop(reps, path, bytes, reps, 0n, 1000000n)

def bench_files(+reps: Nat, paths: List<String>) -> IO(Unit):
  match paths:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +path <> rest:
      do IO<Unit>:
        bench_file(reps, path)
        bench_files(reps, rest)

def start(reps: Maybe<&2, U32>, paths: List<String>) -> IO(Unit):
  match reps:
    case Some{+n}:
      bench_files(Nat.max(U32.to_nat(n), 1n), paths)
    case None{}:
      IO.die(Unit, 2, "usage: bench <repetitions> <file.png>...")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> reps <> paths:
      start(U32.read(reps), paths)
    case _:
      IO.die(Unit, 2, "usage: bench <repetitions> <file.png>...")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
