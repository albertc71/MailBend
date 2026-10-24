# Selected MIME sections: paths, decoding and response identity.

import Base
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
