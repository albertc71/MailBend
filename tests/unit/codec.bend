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
