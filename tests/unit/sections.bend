# Selected MIME sections: paths, decoding and response identity, and
# parts of image size decoded under the interpreter.

import Base
import ../../src/codec.bend as C
import ../../src/imap.bend as I
import ../../src/sections.bend as P

def shape(s: String) -> Result<&2, &2, String, List<&2, P.Part>>:
  P.parts(I.nth(I.tokens(s, []), 0n))

def paths(ps: List<&2, P.Part>) -> String:
  match ps:
    case Nil{}:
      ""
    case p <> Nil{}:
      I.section_str(P.path(p))
    case p <> t:
      I.section_str(P.path(p)) ++ " " ++ paths(t)

def show_parts(r: Result<&2, &2, String, List<&2, P.Part>>) -> String:
  match r:
    case Fail{why}:
      "error"
    case Done{ps}:
      paths(ps)

def decoded(r: Result<&2, &2, String, String>) -> String:
  match r:
    case Fail{why}:
      "error"
    case Done{s}:
      s

def decode(enc: String, size: U32, raw: String) -> String:
  decoded(P.decode(P.Part{[2], "application/octet-stream", "", enc, size}, raw, 1024))

def text() -> String:
  "(\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 5 1)"

def fetched(raw: String, uid: U32, key: String) -> String:
  Maybe.default(&2, String, P.fetched(I.frame(raw), uid, key), "missing")

# n bytes counting up from k, built as a loop.
def counting(n: Nat, +k: U32, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      counting(p, (k + 1 : U32), SCon{C.chr((k .&. 255 : U32)), acc})

# s with a CRLF after every 76 characters, as MIME writes base64.
def wrapped(s: String, col: Nat, acc: String) -> String:
  match s col:
    case SNil{} _:
      String.reverse(acc)
    case SCon{c, t} 0n:
      wrapped(t, 75n, SCon{c, SCon{'\n', SCon{'\r', acc}}})
    case SCon{c, t} 1n+k:
      wrapped(t, k, SCon{c, acc})

# n copies of `line` in front of acc.
def lines(n: Nat, +line: String, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      lines(p, line, line ++ acc)

def large(enc: String, +raw: String) -> String:
  +size = C.byte_len(raw)
  decoded(P.decode(P.Part{[2], "image/png", "", enc, size}, raw, (size + 1 : U32)))

def large_base64() -> String:
  +bytes = counting(100000n, 0, "")
  +out = large("base64", wrapped(C.b64_encode(bytes, False{}), 76n, ""))
  "base64 " ++ U32.show(C.byte_len(out)) ++ " " ++ Bool.show(P.same(out, bytes))

def large_qp() -> String:
  +out = large("quoted-printable", lines(12000n, "=41=62c=\r\n", ""))
  "quoted-printable " ++ U32.show(C.byte_len(out)) ++ " " ++
    Bool.show(P.same(out, lines(12000n, "Abc", "")))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_parts(shape(text())))
    IO.print(show_parts(shape("(" ++ text() ++ "(" ++ text() ++ text() ++
      " \"ALTERNATIVE\") \"MIXED\")")))
    IO.print(show_parts(shape("(" ++ text() ++ ")")))
    IO.print(show_parts(shape("(\"TEXT\")")))
    IO.print(show_parts(shape("(\"TEXT\" \"PLAIN\" NIL NIL NIL \"base64\" NIL)")))
    IO.print(decode("base64", 8, "aGVsbG8="))
    IO.print(decode("base64", 7, "aGVsbG8"))
    IO.print(decode("base64", 9, "aGVsbG8="))
    IO.print(decode("quoted-printable", 9, "hello=20!"))
    IO.print(decode("quoted-printable", 7, "hello=2"))
    IO.print(decoded(P.decode(P.Part{[1], "text/plain", "", "7bit", 1024}, "", 1024)))
    IO.print(I.item_str(I.IPart{[1, 2, 3], 1024}))
    IO.print(fetched("* 1 FETCH (UID 7 BODY[2]<0> {5}\r\nhello)\r\n", 7, "BODY[2]<0>"))
    IO.print(fetched("* 1 FETCH (UID 8 BODY[2]<0> {5}\r\nhello)\r\n", 7, "BODY[2]<0>"))
    IO.print(fetched("* 1 FETCH (UID 7 BODY[2]<1> {5}\r\nhello)\r\n", 7, "BODY[2]<0>"))
    IO.print(fetched("* 1 FETCH (UID 7 BODY[3]<0> {5}\r\nhello)\r\n", 7, "BODY[2]<0>"))
    IO.print(show_parts(shape("(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 8 NIL " ++
      text() ++ " 1 NIL (\"ATTACHMENT\" NIL))")))
    IO.print(large_base64())
    IO.print(large_qp())

#|1
#|1 2.1 2.2
#|error
#|error
#|error
#|hello
#|error
#|error
#|hello !
#|error
#|error
#|BODY.PEEK[1.2.3]<0.1024>
#|hello
#|missing
#|missing
#|missing
#|1
#|base64 100000 True
#|quoted-printable 36000 True
