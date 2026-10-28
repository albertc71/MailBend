# Latin-1 mail uses the Windows-1252 label family on every MIME text path.

import Base
import ../../src/codec.bend as C
import ../../src/mime.bend as M

def byte_range(n: Nat, +lo: U32) -> String:
  match n:
    case 0n:
      ""
    case 1n+p:
      SCon{C.chr(lo), byte_range(p, (lo + 1 : U32))}

# A literal, independent oracle for the complete changed 0x80..0x9F range.
# Undefined Windows-1252 entries retain their original control code points.
def high_expected() -> String:
  "€\u{81}‚ƒ„…†‡ˆ‰Š‹Œ\u{8d}Ž\u{8f}\u{90}‘’“”•–—˜™š›œ\u{9d}žŸ"

def label_cases(labels: List<&2, String>) -> Bool:
  match labels:
    case Nil{}:
      True{}
    case label <> rest:
      +bytes = byte_range(256n, 0)
      +expected = byte_range(128n, 0) ++ high_expected() ++ byte_range(96n, 160)
      String.eq(C.charset_decode(label, bytes), expected) && label_cases(rest)

def body_matches(p: M.Parts, expected: String) -> Bool:
  match p:
    case M.Parts{text, _, _}:
      String.eq(text, expected)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(label_cases([
      "ansi_x3.4-1968", "ASCII", "cp1252", "cp819", "csisolatin1", "ibm819",
      "ISO-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1",
      "iso_8859-1:1987", "l1", "LaTiN1", "us-ascii", "windows-1252", "x-cp1252",
      " \t\n\u{c}\rLaTiN1\r\u{c}\n\t "])))
    IO.print(Bool.show(String.eq(C.charset_decode("latin1", "a\u{85}b"), "a…b")) ++
      " " ++ Bool.show(String.eq(C.charset_decode("utf-8", "a\u{c2}\u{85}b"),
        "a\u{85}b")))
    IO.print(Bool.show(String.eq(C.charset_decode("\u{b}latin1", "\u{85}"), "�")) ++
      " " ++ Bool.show(String.eq(C.charset_decode("latin1\u{a0}", "\u{85}"), "�")) ++
      " " ++ Bool.show(String.eq(C.charset_decode("unknown", "\u{c3}\u{a9}"), "é")))
    IO.print(M.decode_header("=?ISO-8859-1?Q?Alice=85_=93hello=94?="))
    IO.print(M.param("attachment; filename*=latin1''report%85%92.txt", "filename"))
    IO.print(M.param("attachment; filename*0*=iso-8859-1''report%85; " ++
      "filename*1*=%92.txt", "filename"))
    IO.print(Bool.show(body_matches(M.parts("Content-Type: text/plain; charset=latin1\r\n" ++
      "Content-Transfer-Encoding: quoted-printable\r\n\r\na=85b =93hello=94"),
      "a…b “hello”")))

#|True
#|True True
#|True True True
#|Alice… “hello”
#|report…’.txt
#|report…’.txt
#|True
