# Evidence for bounded refresh: absence needs a complete, strict SEARCH.

import Base
import ../../src/json.bend as J
import ../../src/imap.bend as I
import ../../src/tools.bend as T

def show(o: T.Out) -> String:
  match o:
    case T.Ok{j}:
      J.show(j)
    case T.Err{m}:
      "error " ++ m
    case T.Partial{j}:
      "partial " ++ J.show(j)

def base() -> String:
  "* OK [UIDVALIDITY 7] valid\r\na1 OK examined\r\n"

def fetch() -> String:
  "* 1 FETCH (UID 1 FLAGS (\\Seen))\r\na2 OK fetched\r\n"

def result(out: String, code: U32) -> String:
  show(T.refresh_proc(T.ProcOk{code, out, "failure"}, [1, 2], "INBOX", 7))

def request.put(r: T.Uids()) -> String:
  match r:
    case Done{us}:
      J.show(T.uids_json(us))
    case Fail{m}:
      "error " ++ m

def request(j: J.Json) -> String:
  request.put(T.refresh_request(j))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(request(J.obj([J.kv("uids", T.uids_json([3, 1, 3])), J.kv("uidvalidity", J.num(7))])))
    IO.print(request(J.obj([J.kv("uids", T.uids_json([])), J.kv("uidvalidity", J.num(7))])))
    IO.print(request(J.obj([J.kv("uids", T.uids_json([4294967295])),
      J.kv("uidvalidity", J.num(7))])))
    IO.print(request(J.obj([J.kv("uids", J.arr([J.JNum{"4294967296"}])),
      J.kv("uidvalidity", J.num(7))])))
    IO.print(request(J.obj([J.kv("uids", T.uids_json([0])), J.kv("uidvalidity", J.num(7))])))
    IO.print(request(J.obj([J.kv("uids", T.uids_json(List.replicate(U32, 101n, 1))),
      J.kv("uidvalidity", J.num(7))])))
    IO.print(result(base() ++ "* 1 FETCH (UID 1 FLAGS ())\r\na2 OK fetched\r\n" ++
      "* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ "* 1 FETCH (UID 1 FLAGS ()\r\na2 OK fetched\r\n" ++
      "* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ "* 1 FETCH (UID 1 FLAGS NIL)\r\na2 OK fetched\r\n" ++
      "* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ "* 1 FETCH (UID 1 FLAGS (()))\r\na2 OK fetched\r\n" ++
      "* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH 1 2\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "a3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH broken\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH 3\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH\r\n* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH\r\n", 6))
    IO.print(result(base() ++ fetch() ++ "* SEARCH\r\na3 NO failed\r\n", 5))
    IO.print(result("* OK [UIDVALIDITY 8] valid\r\na1 OK examined\r\n", 5))
    IO.print(result(base() ++ fetch() ++ "* SEARCH\r\n", 0))
    IO.print(result(base() ++ "* 1 FETCH (UID 1 MODSEQ (7))\r\na2 OK fetched\r\n" ++
      "* SEARCH 1\r\na3 OK searched\r\n", 0))
    IO.print(result(base() ++ fetch() ++ "* SEARCH 4294967296\r\na3 OK searched\r\n", 0))

#|[1,3]
#|error "uids" must list at least one UID
#|[4294967295]
#|error "uids" must be an array of positive integer UIDs
#|error "uids" must be an array of positive integer UIDs
#|error mail_refresh takes at most 100 UIDs
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":true,"present":[{"uid":1,"flags":[]}],"absent":[2],"unknown":[],"reason":""}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[2],"unknown":[1],"reason":""}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[2],"unknown":[1],"reason":""}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[2],"unknown":[1],"reason":""}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":true,"present":[{"uid":1,"flags":["\\Seen"]}],"absent":[2],"unknown":[],"reason":""}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[{"uid":1,"flags":["\\Seen"]}],"absent":[],"unknown":[2],"reason":""}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":true,"present":[],"absent":[1,2],"unknown":[],"reason":""}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"incomplete SEARCH evidence"}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"incomplete SEARCH evidence"}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"incomplete SEARCH evidence"}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"incomplete SEARCH evidence"}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"mail server error: failure"}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"the server rejected a command: a3 NO failed"}
#|{"folder":"INBOX","uidvalidity":8,"reset_required":true,"complete":false,"present":[],"absent":[],"unknown":[],"reason":"discard this mailbox's cached UIDs"}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"incomplete protocol evidence"}
#|{"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[2],"unknown":[1],"reason":""}
#|partial {"folder":"INBOX","uidvalidity":7,"reset_required":false,"complete":false,"present":[],"absent":[],"unknown":[1,2],"reason":"incomplete SEARCH evidence"}
