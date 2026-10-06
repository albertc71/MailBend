# UTF-8, base64 and quoted-printable codecs.

import Base
import ../../src/codec.bend as C

# Shows CR as "\r" so expectations stay on one line.
def vis(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ vis(t)
    case SCon{c, t}:
      SCon{c, vis(t)}

# Shows CR and LF as "\r" and "\n", so a whole wrapped text is one line.
def vis_all(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\n', t}:
      "\\n" ++ vis_all(t)
    case SCon{c, t}:
      vis(SCon{c, SNil{}}) ++ vis_all(t)

# The code point of every char, space-separated.
def codes(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, SNil{}}:
      U32.show(C.u(c))
    case SCon{c, t}:
      U32.show(C.u(c)) ++ " " ++ codes(t)

# A one-char string from a code point.
def ch(n: U32) -> String:
  SCon{C.chr(n), SNil{}}

def widths(ns: List<&2, U32>) -> String:
  match ns:
    case Nil{}:
      ""
    case n <> t:
      U32.show(C.utf8_width(n)) ++ widths(t)

def hex_vals(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      " " ++ U32.show(C.hex_val(c)) ++ hex_vals(t)

def hex_ups(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+(+p):
      hex_ups(p) ++ SCon{C.hex_up(U32.from_nat(p)), SNil{}}

def bracket(s: String) -> String:
  "[" ++ s ++ "]"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(C.b64_encode(C.utf8_encode("héllo wörld 😀"), False{}))
    IO.print(C.utf8_decode(C.b64_decode("aMOpbGxvIHfDtnJsZCDwn5iA")))
    IO.print(C.b64_encode("Ma", False{}) ++ " " ++ C.b64_encode("M", False{}) ++ " " ++ C.b64_encode("Man", False{}))
    IO.print(C.b64_decode("TWE=") ++ C.b64_decode("TQ==") ++ C.b64_decode("TW\r\nFu"))
    IO.print(C.b64_encode(C.utf8_encode("日本"), True{}))
    IO.print(C.utf8_decode(C.qp_decode("caf=C3=A9 =\r\nsoft =3D ok", False{})))
    IO.print(C.utf8_decode(C.qp_decode("Caf=C3=A9_au_lait", True{})))
    IO.print(vis(C.qp_encode(C.utf8_encode("café = crème \r\nend "), 0)))
    IO.print(vis(C.qp_encode("tab\t", 0)))
    IO.print(C.utf8_decode("ok \u{C3}\u{28} bad"))
    IO.print(C.utf8_decode("\u{E0}\u{82}\u{80}|\u{F0}\u{8F}\u{BF}\u{BF}|\u{E2}\u{82}\u{AC}"))
    IO.print(C.charset_decode("ISO-8859-1", "caf\u{E9}") ++ " " ++ C.charset_decode("windows-1252", "\u{93}q\u{94}"))
    IO.print(U32.show(C.utf8_len("aé日😀")))
    IO.print(Bool.show(C.is_plain("abc\tdef")) ++ " " ++ Bool.show(C.is_plain("a\r\n")) ++ " " ++ Bool.show(C.is_plain("é")))
    IO.print(vis(C.wrap76(String.repeat("x", 80n), 0)))
    # Small helpers.
    IO.print(U32.show(C.u('A')) ++ " " ++ codes(ch(233)) ++ " " ++ codes(SCon{C.repl(), SNil{}}))
    IO.print(Bool.show(C.between(5, 5, 9)) ++ " " ++ Bool.show(C.between(9, 5, 9)) ++ " " ++ Bool.show(C.between(4, 5, 9)) ++ " " ++ Bool.show(C.between(10, 5, 9)))
    # UTF-8 encoding at every width boundary.
    IO.print(widths([0, 127, 128, 2047, 2048, 65535, 65536, 1114111]))
    IO.print(codes(C.utf8_encode(ch(0) ++ ch(127) ++ ch(128) ++ ch(2047))))
    IO.print(codes(C.utf8_encode(ch(2048) ++ ch(65535) ++ ch(65536) ++ ch(1114111))))
    IO.print(bracket(C.utf8_encode("")) ++ " " ++ U32.show(C.utf8_len("")))
    # UTF-8 decoding: boundaries and every kind of bad input.
    IO.print(codes(C.utf8_decode("\u{7F}\u{C2}\u{80}\u{DF}\u{BF}\u{E0}\u{A0}\u{80}\u{EF}\u{BF}\u{BF}\u{F0}\u{90}\u{80}\u{80}\u{F4}\u{8F}\u{BF}\u{BF}")))
    IO.print(codes(C.utf8_decode("\u{80}a\u{BF}")))
    IO.print(codes(C.utf8_decode("\u{C0}\u{80}\u{C1}\u{BF}")))
    IO.print(codes(C.utf8_decode("\u{F5}\u{80}\u{FF}a")))
    IO.print(codes(C.utf8_decode("\u{ED}\u{A0}\u{80}\u{ED}\u{9F}\u{BF}")))
    IO.print(codes(C.utf8_decode("\u{F4}\u{90}\u{80}\u{80}")))
    IO.print(codes(C.utf8_decode("\u{E2}A\u{E2}\u{82}\u{E2}\u{82}\u{AC}")))
    IO.print(codes(C.utf8_decode("a\u{E2}\u{82}")) ++ " | " ++ codes(C.utf8_decode("\u{F0}")) ++ " | " ++ bracket(C.utf8_decode("")))
    # Charsets: names are case-insensitive, unknown ones decode as UTF-8.
    IO.print(codes(C.charset_decode("windows-1252", "\u{80}\u{81}\u{8D}\u{9F}\u{A0}\u{FF}")))
    IO.print(codes(C.charset_decode("CP1252", "\u{82}\u{83}\u{84}\u{85}\u{86}\u{87}\u{88}\u{89}\u{8A}\u{8B}\u{8C}\u{8E}")))
    IO.print(codes(C.charset_decode("cp1252", "\u{91}\u{92}\u{93}\u{94}\u{95}\u{96}\u{97}\u{98}\u{99}\u{9A}\u{9B}\u{9C}\u{9E}")))
    IO.print(codes(C.charset_decode("Latin1", "\u{80}\u{E9}")) ++ " | " ++ codes(C.charset_decode("US-ASCII", "\u{E9}")) ++ " | " ++ codes(C.charset_decode("ascii", "\u{93}")))
    IO.print(codes(C.charset_decode("UTF-8", "\u{C3}\u{A9}")) ++ " | " ++ codes(C.charset_decode("koi8-r", "\u{C3}\u{A9}\u{E9}")) ++ " | " ++ codes(C.charset_decode("", "\u{E9}")))
    # Base64 encoding: both alphabets, every padding case.
    IO.print(bracket(C.b64_encode("", False{})) ++ bracket(C.b64_encode("", True{})))
    IO.print(C.b64_encode(ch(251) ++ ch(239) ++ ch(190), False{}) ++ " " ++ C.b64_encode(ch(255) ++ ch(255) ++ ch(255), False{}) ++ " " ++ C.b64_encode(ch(255) ++ ch(255) ++ ch(255), True{}))
    IO.print(C.b64_encode("M", True{}) ++ " " ++ C.b64_encode("Ma", True{}) ++ " " ++ C.b64_encode("Man", True{}) ++ " " ++ C.b64_encode("Many", True{}))
    IO.print(C.b64_encode("Many", False{}) ++ " " ++ C.b64_encode("Many!", False{}) ++ " " ++ C.b64_encode("Many!?", False{}))
    IO.print(C.b64_encode(ch(0) ++ ch(16) ++ ch(131) ++ ch(16) ++ ch(81) ++ ch(135), False{}))
    # Base64 decoding: either alphabet, junk skipped, leftover bits dropped.
    IO.print(codes(C.b64_decode("++++")) ++ " | " ++ codes(C.b64_decode("////")) ++ " | " ++ codes(C.b64_decode(",,,,")))
    IO.print(C.b64_decode("T W*F\tu!") ++ " " ++ C.b64_decode("TWFueQ") ++ " " ++ C.b64_decode("TWFueSE") ++ " " ++ bracket(C.b64_decode("T")) ++ bracket(C.b64_decode("")))
    IO.print(codes(C.b64_decode("AZaz09+/")))
    IO.print(codes(C.b64_decode("TQ==TQ==")))
    # Wrapping at 76 columns.
    IO.print(bracket(C.wrap76("", 0)) ++ bracket(vis_all(C.wrap76("", 5))))
    IO.print(vis_all(C.wrap76(String.repeat("y", 76n), 0)))
    IO.print(vis_all(C.wrap76(String.repeat("z", 77n), 0)))
    IO.print(vis_all(C.wrap76("abc", 74)))
    IO.print(vis_all(C.wrap76(String.repeat("w", 153n), 0)))
    # Hex digits.
    IO.print(hex_vals("09AFafGg/:@`") ++ " " ++ hex_ups(16n))
    # Quoted-printable decoding.
    IO.print(C.qp_decode("a=G1b=4", False{}) ++ " " ++ C.qp_decode("x=", False{}) ++ " " ++ C.qp_decode("=1G", False{}))
    IO.print(codes(C.qp_decode("=c3=a9=Ff=00", False{})))
    IO.print(vis_all(C.qp_decode("soft=\nbreak=\r\nend\r\nline_x", False{})) ++ " " ++ C.qp_decode("a_b", True{}))
    IO.print(bracket(C.qp_decode("", True{})) ++ " " ++ bracket(C.qp_decode("=5F_=20", True{})))
    # Quoted-printable encoding: escapes, line breaks and soft breaks.
    IO.print(bracket(C.qp_encode("", 0)) ++ " " ++ C.qp_encode("a=b~", 0) ++ " " ++ C.qp_encode(ch(127) ++ ch(0) ++ ch(31) ++ ch(255), 0))
    IO.print(vis_all(C.qp_encode("a\tb\nc\rd", 0)))
    IO.print(vis_all(C.qp_encode("x \r\ny\t\r\nz\t", 0)) ++ " " ++ vis_all(C.qp_encode(" ", 0)) ++ " " ++ vis_all(C.qp_encode("\t", 0)))
    IO.print(vis_all(C.qp_encode(String.repeat("q", 75n), 0)))
    IO.print(vis_all(C.qp_encode(String.repeat("q", 76n), 0)))
    IO.print(vis_all(C.qp_encode(String.repeat("q", 73n) ++ "==", 0)))
    IO.print(vis_all(C.qp_encode(String.repeat("q", 73n) ++ " \r\n", 0)))
    IO.print(vis_all(C.qp_encode(String.repeat("q", 72n) ++ " \r\n", 0)))
    IO.print(vis_all(C.qp_encode(String.repeat("q", 74n) ++ "\t", 0)))
    IO.print(vis_all(C.qp_encode("ab", 74)) ++ " " ++ vis_all(C.qp_encode("a", 75)) ++ " " ++ vis_all(C.qp_encode("=", 73)))
    IO.print(vis_all(C.qp_encode(String.repeat("v", 160n), 0)))
    # Plain-text check.
    IO.print(Bool.show(C.is_plain("")) ++ " " ++ Bool.show(C.is_plain(" ~")) ++ " " ++ Bool.show(C.is_plain(ch(127))) ++ " " ++ Bool.show(C.is_plain(ch(31))) ++ " " ++ Bool.show(C.is_plain("ab" ++ ch(0))))
    # Digit strings and quoted strings.
    IO.print(Bool.show(C.all_digits("")) ++ " " ++ Bool.show(C.all_digits("0429")) ++ " " ++ Bool.show(C.all_digits("4a")) ++ " " ++ C.quoted("") ++ " " ++ C.quoted("say \"hi\" a\\b"))
    # Month abbreviations, and "" outside 1..12.
    IO.print(bracket(C.month_name(0)) ++ " " ++ C.month_name(1) ++ " " ++ C.month_name(6) ++ " " ++ C.month_name(12) ++ " " ++ bracket(C.month_name(13)))

#|aMOpbGxvIHfDtnJsZCDwn5iA
#|héllo wörld 😀
#|TWE= TQ== TWFu
#|MaMMan
#|5pel5pys
#|café soft = ok
#|Café au lait
#|caf=C3=A9 =3D cr=C3=A8me=20\r
#|end=20
#|tab=09
#|ok �( bad
#|�|�|€
#|café “q”
#|10
#|True False False
#|xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\r
#|xxxx\r
#|
#|65 233 65533
#|True True False False
#|11223344
#|0 127 194 128 223 191
#|224 160 128 239 191 191 240 144 128 128 244 143 191 191
#|[] 0
#|127 128 2047 2048 65535 65536 1114111
#|65533 97 65533
#|65533 65533 65533 65533
#|65533 65533 65533 97
#|65533 55295
#|65533
#|65533 65 65533 8364
#|97 65533 | 65533 | []
#|8364 129 141 376 160 255
#|8218 402 8222 8230 8224 8225 710 8240 352 8249 338 381
#|8216 8217 8220 8221 8226 8211 8212 732 8482 353 8250 339 382
#|128 233 | 233 | 147
#|233 | 233 65533 | 65533
#|[][]
#|++++ //// ,,,,
#|TQ TWE TWFu TWFueQ
#|TWFueQ== TWFueSE= TWFueSE/
#|ABCDEFGH
#|251 239 190 | 255 255 255 | 255 255 255
#|Man Many Many! [][]
#|1 150 179 211 223 191
#|77 4 208
#|[][\r\n]
#|yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\r\n
#|zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\r\nz\r\n
#|ab\r\nc\r\n
#|wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww\r\nwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww\r\nw\r\n
#| 0 9 10 15 10 15 16 16 16 16 16 16 0123456789ABCDEF
#|a=G1b=4 x= =1G
#|195 169 255 0
#|softbreakend\r\nline_x a b
#|[] [_  ]
#|[] a=3Db~ =7F=00=1F=FF
#|a	b=0Ac=0Dd
#|x=20\r\ny=09\r\nz=09 =20 =09
#|qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
#|qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq=\r\nq
#|qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq=\r\n=3D=3D
#|qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq=\r\n=20\r\n
#|qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq=20\r\n
#|qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq=\r\n=09
#|a=\r\nb =\r\na =\r\n=3D
#|vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv=\r\nvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv=\r\nvvvvvvvvvv
#|True True False False False
#|True True False "" "say \"hi\" a\\b"
#|[] Jan Jun Dec []
