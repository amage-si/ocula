import Base
import ./main.bend as O
import ./pixels.bend as P
import ./bytes.bend as B
import ./inflate.bend as Z
import ./file.bend as F
import ./fixtures/cases.bend as Cases
import ./fixtures/reads.bend as Reads

def check(name: String, ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("PASS " ++ name)
    case False{}:
      IO.die(Unit,1,"FAIL " ++ name)

def valid_result(name: String, crc: U32, result: Result<&2,&1,String,P.Raster>) -> IO(Unit):
  match result:
    case Fail{e}:
      IO.die(Unit,1,name ++ ": " ++ e)
    case Done{raster}:
      check(name,U32.is_eq(B.crc32(P.rgba_bytes(raster)),crc))

def good_case(pair: String & U32) -> IO(Unit):
  (+name,crc) = pair
  do IO<Unit>:
    bytes : +List<U32> <- F.read("fixtures/" ++ name ++ ".png")
    valid_result(name,crc,O.decode_png(bytes))

def bad_case(+name: String) -> IO(Unit):
  do IO<Unit>:
    bytes : +List<U32> <- F.read("fixtures/" ++ name ++ ".png")
    check(name,Result.is_fail(&2,&1,String,P.Raster,O.decode_png(bytes)))

def capacity_result(pair: Array<U32> & U32, expected: U32) -> Bool:
  (_,actual) = pair
  U32.is_eq(actual,expected)

def capacity(size: U32, expected: U32) -> Bool:
  capacity_result(Array.size(U32,B.allocate(size)),expected)

def packed_sample() -> P.Raster:
  pixels = B.allocate(3)
  pixels = pixels[0] <- 4278190208
  pixels = pixels[1] <- 16711935
  pixels = pixels[2] <- 4294967040
  pixels = pixels[3] <- 305419896
  P.Raster{3,1,pixels}

def packed_values(xs: +List<U32>) -> Bool:
  match xs:
    case a <> b <> c <> Nil{}:
      U32.is_eq(a,4278190208) && U32.is_eq(b,16711935) && U32.is_eq(c,4294967040)
    case _:
      False{}

def read_case(pair: String & (U32 & U32)) -> IO(Unit):
  (+name,(size,crc)) = pair
  do IO<Unit>:
    +bytes : +List<U32> <- F.read("fixtures/" ++ name ++ ".bin")
    check("file EOF/limit " ++ name,U32.is_eq(U32.from_nat(List.length(&2,U32,bytes)),size) && U32.is_eq(B.crc32(bytes),crc))

# Inject a short nonempty read, then consume the actual file to EOF.
# This exercises the state transition without assuming OS read chunk sizes.
def short_read() -> IO(Unit):
  do IO<Unit>:
    file : File <- IO.try(File,File.open("fixtures/io-small.bin","r"))
    state : F.ReadState <- F.read_chunk((file,Done{[42,43]}),Nil{},0)
    bytes : +List<U32> <- F.read_loop(8n,state)
    check("short read continues until EOF",U32.is_eq(B.crc32(bytes),Reads.short_read_crc()))

def main() -> IO(Unit):
  do IO<Unit>:
    check("CRC32 standard vector",U32.is_eq(B.crc32([49,50,51,52,53,54,55,56,57]),3421780262))
    check("invalid byte value",Result.is_fail(&2,&1,String,P.Raster,O.decode_png([256])))
    check("oversubscribed Huffman tree",Result.is_fail(&2,&1,String,Z.Huffman,Z.tree([1,1,1],True{})))
    check("incomplete Huffman tree",Result.is_fail(&2,&1,String,Z.Huffman,Z.tree([2],True{})))
    check("out-of-range Huffman length",Result.is_fail(&2,&1,String,Z.Huffman,Z.tree([1,1,16],True{})))
    check("maximum U32 Huffman length",Result.is_fail(&2,&1,String,Z.Huffman,Z.tree([1,1,4294967295],True{})))
    check("valid complete tree reaches 15 bits",Result.is_done(&2,&1,String,Z.Huffman,Z.tree([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,15],True{})))
    check("single one-bit Huffman tree",Result.is_done(&2,&1,String,Z.Huffman,Z.tree([1],True{})))
    check("single code-length tree rejected",Result.is_fail(&2,&1,String,Z.Huffman,Z.tree([1],False{})))
    check("backref before start",Result.is_fail(&2,&1,String,Z.Output,Z.copy(Z.Output{B.allocate(8),0,8},3,1)))
    check("zero backref",Result.is_fail(&2,&1,String,Z.Output,Z.copy(Z.Output{B.allocate(8),4,8},3,0)))
    check("backref exceeds output",Result.is_fail(&2,&1,String,Z.Output,Z.copy(Z.Output{B.allocate(8),4,8},5,1)))
    check("pixel bounds",Result.is_fail(&2,&1,String,P.Raster & U32,P.pixel(P.Raster{1,1,B.allocate(1)},1,0)))
    check("array capacity 1",capacity(1,1))
    check("array capacity exact power of two",capacity(4,4))
    check("array capacity round up",capacity(5,8))
    check("packed pixels retain channels and exclude capacity tail",packed_values(P.packed_pixels(packed_sample())))
    check("RGBA bytes retain order and exclude capacity tail",U32.is_eq(B.crc32(P.rgba_bytes(packed_sample())),B.crc32([255,0,0,128,0,255,0,255,255,255,255,0])))
    List.for_each(~&1,~(String & (U32 & U32)),~read_case,Reads.cases())
    short_read()
    List.for_each(~&1,~(String & U32),~good_case,Cases.valid())
    List.for_each(~&2,~String,~(n => bad_case(n)),Cases.invalid())
    IO.print("Ocula: all checks passed; this is testing, not a whole-system proof")
