# Large framed images must retain exact coding bytes in both Bend runtimes.

import Base
import ../../src/codec.bend as C
import ../../src/image.bend as Image

def repeat(n: Nat, +byte: Char, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      repeat(p, byte, SCon{byte, acc})

def coding(n: Nat, +byte: U32, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      coding(p, ((byte + 1) .&. 127 : U32), SCon{C.chr(byte), acc})

def be32(+n: U32) -> String:
  C.bytes_str([(n >> 24n : U32), ((n >> 16n) .&. 255 : U32),
    ((n >> 8n) .&. 255 : U32), (n .&. 255 : U32)])

def chunk(kind: String, +body: String) -> String:
  be32(C.byte_len(body)) ++ kind ++ body ++ C.bytes_str([1, 2, 3, 4])

def png(metadata: String, coding: String) -> String:
  C.bytes_str([137, 80, 78, 71, 13, 10, 26, 10]) ++
    chunk("IHDR", C.bytes_str([0, 0, 1, 24, 0, 0, 1, 24, 8, 2, 0, 0, 0])) ++
    metadata ++ chunk("IDAT", coding) ++ chunk("IEND", "")

def segment(marker: U32, +body: String) -> String:
  +n = (C.byte_len(body) + 2 : U32)
  C.bytes_str([255, marker, (n >> 8n : U32), (n .&. 255 : U32)]) ++ body

def jpeg(metadata: String, coding: String) -> String:
  C.bytes_str([255, 216]) ++ segment(224, "JFIF") ++ metadata ++
    segment(192, C.bytes_str([8, 1, 24, 1, 24, 1, 1, 17, 0])) ++
    segment(218, C.bytes_str([1, 1, 0, 0, 63, 0])) ++ coding ++ C.bytes_str([255, 217])

def same_bytes(a: String, b: String, matched: Bool) -> Bool:
  match a b:
    case SNil{} SNil{}:
      matched
    case SCon{ha, ta} SCon{hb, tb}:
      same_bytes(ta, tb, matched && U32.is_eq(Char.to_u32(ha), Char.to_u32(hb)))
    case _ _:
      False{}

def exact(result: Image.Verdict, expected: String, removed: U32) -> Bool:
  match result:
    case Image.Keep{Image.Still{section, name, format, pixels, data, metadata_removed_bytes}}:
      same_bytes(data, expected, True{}) && U32.is_eq(metadata_removed_bytes, removed)
    case Image.VDrop{section, name, reason}:
      False{}

def check(name: String, format: Image.Format, +input: String, +expected: String) -> IO(Unit):
  IO.print(name ++ " " ++ Bool.show(exact(Image.judge([2], "large", format, input),
    expected, (C.byte_len(input) - C.byte_len(expected) : U32))))

def main() -> IO(Unit):
  +fill = repeat(100000n, C.chr(255), "") ++ C.bytes_str([1])
  +segment_fill = repeat(100000n, C.chr(255), "") ++ segment(224, "keep")
  do IO<Unit>:
    IO.print("byte comparison rejects changes " ++ Bool.show(
      Bool.not(same_bytes("abc", "abd", True{})) &&
      Bool.not(same_bytes("abc", "ab", True{}))))
    check("jpeg megabyte scan", Image.Jpeg{},
      jpeg(segment(225, "GPS"), coding(1048576n, 0, "")),
      jpeg("", coding(1048576n, 0, "")))
    check("png megabyte IDAT", Image.Png{},
      png(chunk("tEXt", "GPS"), coding(1048576n, 0, "")),
      png("", coding(1048576n, 0, "")))
    check("jpeg large discarded APP1", Image.Jpeg{},
      jpeg(segment(225, repeat(65533n, 'p', "")), "x"), jpeg("", "x"))
    check("png large discarded text", Image.Png{},
      png(chunk("tEXt", repeat(1048576n, 'p', "")), "x"), png("", "x"))
    check("jpeg large retained APP0", Image.Jpeg{},
      jpeg(segment(224, repeat(65533n, 'p', "")), "x"),
      jpeg(segment(224, repeat(65533n, 'p', "")), "x"))
    check("jpeg marker fill", Image.Jpeg{}, jpeg(fill, "x"), jpeg(fill, "x"))
    check("jpeg segment fill", Image.Jpeg{}, jpeg(segment_fill, "x"), jpeg(segment_fill, "x"))

#|byte comparison rejects changes True
#|jpeg megabyte scan True
#|png megabyte IDAT True
#|jpeg large discarded APP1 True
#|png large discarded text True
#|jpeg large retained APP0 True
#|jpeg marker fill True
#|jpeg segment fill True
