# Continuations are exact, bounded and tied to a folder, query and incarnation.

import Base
import ../../src/json.bend as J
import ../../src/search-cursor.bend as SC
import ../../src/ops.bend as Ops
import ../../src/imap.bend as I

def result(r: SC.ResultCursor()) -> String:
  match r:
    case Done{SC.Start{}}:
      "start"
    case Done{SC.Continue{v, b}}:
      U32.show(v) ++ ":" ++ U32.show(b)
    case Fail{m}:
      "invalid"

def parse(s: String) -> String:
  result(SC.read(Some{J.str(s)}, "[\"INBOX\",\"ALL\"]"))

def nums(xs: List<&2, U32>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case h <> t:
      J.num(h) <> nums(t)

def main() -> IO(Unit):
  +binding = SC.binding("INBOX", "ALL")
  do IO<Unit>:
    IO.print(result(SC.read(None{}, binding)))
    IO.print(parse(SC.token(binding, 7, 4294967295)))
    IO.print(parse("s1:7:2:[\"INBOX\",\"ALL\"]"))
    IO.print(parse("s1:7:1:[\"INBOX\",\"ALL\"]"))
    IO.print(parse("s1:0:2:[\"INBOX\",\"ALL\"]"))
    IO.print(parse("s1:7:4294967296:[\"INBOX\",\"ALL\"]"))
    IO.print(parse("s1:07:2:[\"INBOX\",\"ALL\"]"))
    IO.print(parse("s2:7:2:[\"INBOX\",\"ALL\"]"))
    IO.print(parse("s1:7:2:[\"Archive\",\"ALL\"]"))
    IO.print(parse("s1:7:2:[\"INBOX\",\"UNSEEN\"]"))
    IO.print(parse(""))
    IO.print(parse("s1:7:2:[\"INBOX\",\"ALL\"]junk"))
    IO.print(parse(String.join(List.replicate(String, 4097n, "x"), "")))
    IO.print(Bool.show(SC.fits("abc", 3n)) ++ " " ++ Bool.show(SC.fits("abcd", 3n)))
    IO.print(J.show(J.arr(nums(
      SC.eligible(SC.Continue{7, 4294967295}, [4294967295, 2, 1, 0])))))
    IO.print(J.show(SC.next(False{}, binding, 7, [1])))
    IO.print(J.show(SC.next(True{}, binding, 7, [9, 5])))
    IO.print(Bool.show(SC.same(SC.Continue{7, 2}, Some{8})))
    IO.print(Bool.show(SC.same(SC.Start{}, None{})))
    IO.print(J.show(J.str(I.script(Ops.plan_search_page("INBOX", [], SC.Continue{7, 2})))))

#|start
#|7:4294967295
#|7:2
#|invalid
#|invalid
#|invalid
#|invalid
#|invalid
#|invalid
#|invalid
#|invalid
#|invalid
#|invalid
#|True False
#|[2,1]
#|null
#|"s1:7:5:[\"INBOX\",\"ALL\"]"
#|False
#|False
#|"a1 EXAMINE \"INBOX\"\r\n=EXPECT * OK [UIDVALIDITY 7]\r\na2 UID SEARCH ALL\r\n"
