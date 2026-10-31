# Current-end checkpoint parsing and the EXAMINE-only command plan.

import Base
import ../../src/json.bend as J
import ../../src/imap.bend as I
import ../../src/ops.bend as Ops
import ../../src/tools.bend as T

def json(s: String) -> J.Json:
  Maybe.default(&2, J.Json, J.parse(s), J.JNull{})

def request(r: Result<&2, &2, String, Unit>) -> String:
  match r:
    case Done{u}:
      "valid"
    case Fail{m}:
      m

def result(o: T.Out) -> String:
  match o:
    case T.Ok{j}:
      J.show(j)
    case T.Err{m}:
      m
    case T.Partial{j}:
      J.show(j)

def checkpoint(codes: String) -> String:
  result(T.new_now(Done{I.frame(codes)}, "INBOX"))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.trim(I.script(Ops.plan_new_now("INBOX"))))
    IO.print(request(T.new_start_request(json("{\"start\":\"now\"}"))))
    IO.print(request(T.new_start_request(json("{\"start\":\"now\",\"since_uid\":0}"))))
    IO.print(request(T.new_start_request(json("{\"start\":\"later\"}"))))
    IO.print(request(T.new_start_request(json("{\"start\":\"\"}"))))
    IO.print(checkpoint("* OK [UIDNEXT 7] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 1] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 4294967295] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* ok [uidnext 7] next\r\n* ok [uidvalidity 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT not-a-number] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 0] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 4294967296] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 7\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 07] next\r\n* OK [UIDVALIDITY 42] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 7] next\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 7] next\r\n* OK [UIDVALIDITY 0] valid\r\n"))
    IO.print(checkpoint("* OK [UIDNEXT 7] next\r\n* OK [UIDVALIDITY 42\r\n"))
    IO.print(result(T.new_now(Fail{"connection failed"}, "INBOX")))

#|a1 EXAMINE "INBOX"
#|valid
#|"start" cannot be combined with "since_uid"
#|"start" must be "now"
#|"start" must be "now"
#|{"folder":"INBOX","uidvalidity":42,"uidvalidity_changed":false,"next_since_uid":6,"has_more":false,"messages":[]}
#|{"folder":"INBOX","uidvalidity":42,"uidvalidity_changed":false,"next_since_uid":0,"has_more":false,"messages":[]}
#|{"folder":"INBOX","uidvalidity":42,"uidvalidity_changed":false,"next_since_uid":4294967294,"has_more":false,"messages":[]}
#|{"folder":"INBOX","uidvalidity":42,"uidvalidity_changed":false,"next_since_uid":6,"has_more":false,"messages":[]}
#|EXAMINE did not report a valid UIDNEXT; no checkpoint was created
#|EXAMINE did not report a valid UIDNEXT; no checkpoint was created
#|EXAMINE did not report a valid UIDNEXT; no checkpoint was created
#|EXAMINE did not report a valid UIDNEXT; no checkpoint was created
#|EXAMINE did not report a valid UIDNEXT; no checkpoint was created
#|EXAMINE did not report a valid UIDNEXT; no checkpoint was created
#|EXAMINE did not report a valid UIDVALIDITY; no checkpoint was created
#|EXAMINE did not report a valid UIDVALIDITY; no checkpoint was created
#|EXAMINE did not report a valid UIDVALIDITY; no checkpoint was created
#|connection failed
