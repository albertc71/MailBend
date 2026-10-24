# Selected reads reject stale identity, changed metadata and incomplete bytes.

import Base
import ../../src/imap.bend as I
import ../../src/sections.bend as P
import ../../src/tools.bend as T
import ../../src/jev.bend as Jev

def part() -> P.Part:
  P.Part{[1], "text/plain", "", "7bit", 5}

def transcript(uidv: U32, uid: U32, size: U32, origin: U32, +body: String) -> String:
  "* OK [UIDVALIDITY " ++ U32.show(uidv) ++ "] ok\r\n" ++
  "* 1 FETCH (UID " ++ U32.show(uid) ++
  " BODYSTRUCTURE (\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" " ++
  U32.show(size) ++ " 1) BODY[1]<" ++ U32.show(origin) ++ "> {" ++
  Nat.show(String.length(body)) ++ "}\r\n" ++ body ++ ")\r\na1 OK done\r\n"

def show(r: Result<&2, &2, String, String>) -> String:
  match r:
    case Done{s}:
      s
    case Fail{why}:
      "error"

def read(raw: String) -> String:
  show(T.part_bytes(Done{I.frame(raw)}, 7, 9, part(), 1024))

def annotation(t: Jev.Text) -> String:
  match t:
    case Jev.Text{+text, Jev.Partial{}}:
      "partial " ++ Bool.show(String.contains(text, "hello")) ++ " " ++
        Bool.show(String.contains(text, "message incomplete"))
    case _:
      "unexpected complete message"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(read(transcript(9, 7, 5, 0, "hello")))
    IO.print(read(transcript(8, 7, 5, 0, "hello")))
    IO.print(read(transcript(9, 8, 5, 0, "hello")))
    IO.print(read(transcript(9, 7, 6, 0, "hello")))
    IO.print(read(transcript(9, 7, 5, 1, "hello")))
    IO.print(read(transcript(9, 7, 5, 0, "hell")))
    IO.print(read("* 1 FETCH (UID 7 FLAGS ())\r\n" ++ transcript(9, 7, 5, 0, "hello")))
    IO.print(annotation(T.part_get.text(part(), "hello")))
    IO.print(annotation(T.part_get.text(P.Part{[1], "text/plain", "attachment",
      "7bit", 5}, "hello")))
    IO.print(annotation(T.part_get.text(P.Part{[1], "application/octet-stream", "attachment",
      "binary", 5}, "hello")))

#|hello
#|error
#|error
#|error
#|error
#|error
#|hello
#|partial True True
#|partial True True
#|partial False False
