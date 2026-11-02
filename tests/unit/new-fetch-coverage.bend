import Base
import ../../src/tools.bend as T
import ../../src/imap.bend as I
import ../../src/json.bend as J
import ../../src/policy.bend as Policy

def header(uid: U32) -> String:
  "* 1 FETCH (UID " ++ U32.show(uid) ++
    " BODY[HEADER.FIELDS (SUBJECT)] {12}\r\nSubject: X\r\n)\r\n"

def show_out(out: Policy.Out, ms: List<&2, I.Msg>) -> String:
  match out:
    case Policy.Err{m}:
      "error " ++ m ++ " messages=" ++ Nat.show(List.length(&2, I.Msg, ms))
    case Policy.Ok{j}:
      J.show(j)
    case Policy.Partial{j}:
      "partial " ++ J.show(j)

def shown(s: T.Shown) -> String:
  match s:
    case T.Listed{out, ms}:
      show_out(out, ms)
    case _:
      "unexpected variant"

def run(raw: String, selected: List<&2, U32>, uidv: U32) -> String:
  shown(T.new_headers(T.imap_code(0, I.frame(
    "* OK [UIDVALIDITY " ++ U32.show(uidv) ++ "] ok\r\n" ++ raw ++
    "a2 OK fetched\r\n"), ""), "INBOX", 7, 9, True{}, selected))

def empty_header(value: String) -> String:
  "* 1 FETCH (UID 9 BODY[HEADER.FIELDS (" ++ I.header_fields() ++ ")] " ++ value ++ ")\r\n"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(run(header(4) ++ header(9), [4, 5, 9], 7))
    IO.print(run(header(4), [4, 9], 7))
    IO.print(run("* 1 FETCH (UID 9 FLAGS ())\r\n", [9], 7))
    IO.print(run(header(9) ++ header(4) ++ header(9) ++ header(99), [4, 9], 7))
    IO.print(run(header(4), [4, 9], 8))
    IO.print(run(empty_header("\"\""), [9], 7))
    IO.print(run(empty_header("{0}\r\n"), [9], 7))
    IO.print(run(empty_header("NIL"), [9], 7))

#|error FETCH did not return every requested message; retry the same checkpoint messages=0
#|error FETCH did not return every requested message; retry the same checkpoint messages=0
#|error FETCH did not return every requested message; retry the same checkpoint messages=0
#|{"folder":"INBOX","uidvalidity":7,"uidvalidity_changed":false,"next_since_uid":9,"has_more":true,"messages":[{"uid":4,"date":"","from":"","to":"","cc":"","subject":"X","message_id":"","internal_date":"","size":0,"flags":[],"seen":false,"flagged":false,"list_id":null,"auto_submitted":null,"bulk":null,"unsubscribe":{"mailto":null,"https":null,"one_click":false},"answered":false,"forwarded":false},{"uid":9,"date":"","from":"","to":"","cc":"","subject":"X","message_id":"","internal_date":"","size":0,"flags":[],"seen":false,"flagged":false,"list_id":null,"auto_submitted":null,"bulk":null,"unsubscribe":{"mailto":null,"https":null,"one_click":false},"answered":false,"forwarded":false}]}
#|{"folder":"INBOX","uidvalidity":8,"uidvalidity_changed":true,"next_since_uid":0,"has_more":true,"messages":[]}
#|{"folder":"INBOX","uidvalidity":7,"uidvalidity_changed":false,"next_since_uid":9,"has_more":true,"messages":[{"uid":9,"date":"","from":"","to":"","cc":"","subject":"","message_id":"","internal_date":"","size":0,"flags":[],"seen":false,"flagged":false,"list_id":null,"auto_submitted":null,"bulk":null,"unsubscribe":{"mailto":null,"https":null,"one_click":false},"answered":false,"forwarded":false}]}
#|{"folder":"INBOX","uidvalidity":7,"uidvalidity_changed":false,"next_since_uid":9,"has_more":true,"messages":[{"uid":9,"date":"","from":"","to":"","cc":"","subject":"","message_id":"","internal_date":"","size":0,"flags":[],"seen":false,"flagged":false,"list_id":null,"auto_submitted":null,"bulk":null,"unsubscribe":{"mailto":null,"https":null,"one_click":false},"answered":false,"forwarded":false}]}
#|error FETCH did not return every requested message; retry the same checkpoint messages=0
