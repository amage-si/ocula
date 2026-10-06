import Base
import ../main.bend as O
import ../pixels.bend as P
import ../file.bend as F

def save(output: String, r: Result<&2, &1, String, P.Raster>) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.die(Unit, 1, e)
    case Done{P.Raster{+w, +h, pixels}}:
      do IO<Unit>:
        IO.print("RGBA8 " ++ U32.show(w) ++ " " ++ U32.show(h))
        F.write(output, P.rgba_bytes(P.Raster{w, h, pixels}))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> input <> output <> Nil{}:
      do IO<Unit>:
        bytes : +List<U32> <- F.read(input)
        save(output, O.decode_png(bytes))
    case _:
      IO.die(Unit, 2, "usage: decode input.png output.rgba")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
