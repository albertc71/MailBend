# New views retain selected-message identity checks and legacy terminal-QP recovery.

import Base
import ../../src/imap.bend as I
import ../../src/json.bend as J
import ../../src/sections.bend as P
import ../../src/tools.bend as T
import ../../src/policy.bend as Policy

def part() -> P.Part:
  P.Part{[1], "message/rfc822", "", "7bit", 23}

def transcript(uidv: U32, uid: U32, size: U32, origin: U32, +body: String) -> String:
  "* OK [UIDVALIDITY " ++ U32.show(uidv) ++ "] ok\r\n" ++
  "* 1 FETCH (UID " ++ U32.show(uid) ++
  " BODYSTRUCTURE (\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" " ++
  U32.show(size) ++ " NIL NIL 1 NIL NIL NIL NIL) BODY[1]<" ++ U32.show(origin) ++ "> {" ++
  Nat.show(String.length(body)) ++ "}\r\n" ++ body ++ ")\r\na1 OK done\r\n"

def shown(s: T.Shown) -> String:
  match s:
    case T.Selected{Policy.Ok{j}, f}:
      J.show(j)
    case _:
      "error"

def read(raw: String) -> String:
  shown(T.nested_get.fetched(Done{I.frame(raw)}, part(), "INBOX", 7, 9, 1024))

def request(r: Result<&2, &2, String, Bool>) -> String:
  match r:
    case Fail{why}:
      "error"
    case Done{b}:
      Bool.show(b)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(read(transcript(9, 7, 23, 0, "Subject: inner\r\n\r\nhello")))
    IO.print(read(transcript(8, 7, 23, 0, "Subject: inner\r\n\r\nhello")))
    IO.print(read(transcript(9, 8, 23, 0, "Subject: inner\r\n\r\nhello")))
    IO.print(read(transcript(9, 7, 24, 0, "Subject: inner\r\n\r\nhello")))
    IO.print(read(transcript(9, 7, 23, 1, "Subject: inner\r\n\r\nhello")))
    IO.print(read(transcript(9, 7, 23, 0, "Subject: inner\r\n\r\nhell")))
    IO.print(request(T.nested_request(J.obj([]))))
    IO.print(request(T.nested_request(J.obj([J.kv("nested_message", J.bool(False{}))]))))
    IO.print(request(T.nested_request(J.obj([J.kv("nested_message", J.str("true"))]))))
    IO.print(request(T.nested_request(J.obj([J.kv("nested_message", J.bool(True{})),
      J.kv("section", J.str("1.2")), J.kv("uidvalidity", J.num(9))]))))
    IO.print(request(T.nested_request(J.obj([J.kv("nested_message", J.bool(True{})),
      J.kv("section", J.str("1.2")), J.kv("uidvalidity", J.num(9)),
      J.kv("projection", J.str("text"))]))))

#|{"folder":"INBOX","uid":7,"uidvalidity":9,"section":"1","content_type":"message/rfc822","complete":true,"scope":"selected_part","message_complete":false,"content":{"headers":{"from":"","to":"","subject":"inner","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]},"content_encoding":"message"}
#|error
#|error
#|error
#|error
#|error
#|False
#|False
#|error
#|True
#|error
