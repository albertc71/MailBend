# JSON parser and serializer round trips. The parser does not validate
# separators (":" and ","), so {"a" 1} reads as {"a":1}.
import Base
import ../../src/json.bend as J

def shown(m: Maybe<&2, J.Json>) -> String:
  match m:
    case Some{j}:
      J.show(j)
    case None{}:
      "PARSE-ERROR"

def rt(s: String) -> String:
  shown(J.parse(s))

def checks(+o: J.Json) -> IO(Unit):
  do IO<Unit>:
    IO.print(Maybe.default(&2, String, J.as_str(J.get(o, "name")), "?"))
    IO.print(U32.show(Maybe.default(&2, U32, J.as_u32(J.get(o, "uid")), 0)))
    IO.print(Bool.show(Maybe.default(&2, Bool, J.as_bool(J.get(o, "flag")), False{})))
    IO.print(Nat.show(List.length(&2, J.Json, Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(o, "list")), []))))
    IO.print(Bool.show(Maybe.is_none(&2, J.Json, J.get(o, "missing"))))


def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(rt("{\"a\": [1, -2.5e3, true, false, null], \"b\": {\"c\": \"x\\\"y\\\\z\"}}"))
    IO.print(rt("  [ ]  "))
    IO.print(rt("{}"))
    IO.print(rt("\"tab\\tnl\\n\\u00e9\\ud83d\\ude00\""))
    IO.print(rt("[1, 2"))
    IO.print(rt("{\"a\" 1}"))
    IO.print(rt("[1] [2]"))
    IO.print(rt("nope"))
    IO.print(J.show(J.str("ctl\u{1}")))
    checks(Maybe.default(&2, J.Json, J.parse("{\"uid\": 42, \"name\": \"INBOX\", \"flag\": true, \"list\": [\"a\",\"b\"]}"), J.JNull{}))

#|{"a":[1,-2.5e3,true,false,null],"b":{"c":"x\"y\\z"}}
#|[]
#|{}
#|"tab\tnl\né😀"
#|PARSE-ERROR
#|{"a":1}
#|PARSE-ERROR
#|PARSE-ERROR
#|"ctl\u0001"
#|INBOX
#|42
#|True
#|2
#|True
