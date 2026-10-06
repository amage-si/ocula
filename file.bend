import Base

type ReadState is Type:
  More{file: File, parts: +List<+List<U32>>, total: U32}
  Finished{bytes: +List<U32>}

def read_end(file: File, parts: +List<+List<U32>>) -> IO(ReadState):
  do IO<ReadState>:
    File.close(file)
    return Finished{List.concat(&2,U32,List.reverse(&2,+List<U32>,parts))}

def read_continue(file: File, parts: +List<+List<U32>>, total: U32, full: Bool) -> IO(ReadState):
  match full:
    case True{}:
      read_end(file,parts)
    case False{}:
      IO.pure(ReadState,More{file,parts,total})

def read_chunk(pair: File & Result<&1,&1,U32 & String,+List<U32>>, parts: +List<+List<U32>>, total: U32) -> IO(ReadState):
  match pair:
    case (file,Fail{(code,message)}):
      do IO<ReadState>:
        File.close(file)
        IO.die(ReadState,code,message)
    case (file,Done{Nil{}}):
      read_end(file,parts)
    case (file,Done{+head <> +tail}):
      +bytes = {head <> tail : +List<U32>}
      +next = U32.add(total,U32.from_nat(List.length(&2,U32,bytes)))
      read_continue(file,bytes <> parts,next,U32.is_ge(next,2097153))

def read_loop(fuel: Nat, state: ReadState) -> IO(+List<U32>):
  match fuel state:
    case _ Finished{bytes}:
      IO.pure(+List<U32>,bytes)
    case 0n More{file,_,_}:
      do IO<+List<U32>>:
        File.close(file)
        IO.die(+List<U32>,1,"input read operation limit")
    case 1n+p More{file,parts,+total}:
      do IO<+List<U32>>:
        result : File & Result<&1,&1,U32 & String,+List<U32>> <- File.read_bytes(file,U32.min(65536,U32.sub(2097153,total)))
        state : ReadState <- read_chunk(result,parts,total)
        read_loop(p,state)

def read(path: String) -> IO(+List<U32>):
  do IO<+List<U32>>:
    file : File <- IO.try(File, File.open(path, "r"))
    read_loop(2097154n,More{file,Nil{},0})

def write_finish(pair: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (file, result) = pair
  do IO<Unit>:
    File.close(file)
    IO.pass(Unit, result)

def write(path: String, bytes: +List<U32>) -> IO(Unit):
  do IO<Unit>:
    file : File <- IO.try(File, File.open(path, "w"))
    result : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(file, bytes)
    write_finish(result)
