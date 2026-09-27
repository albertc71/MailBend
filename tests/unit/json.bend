# JSON parser and serializer round trips, including rejected inputs.
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
    IO.print(String.join([rt("[1 2]"), rt("[1,]"), rt("{\"a\":1,}"), rt("{,}"), rt("{\"a\"::1}"), rt("[,1]")], " "))
    IO.print(String.join([rt("\"a\\qb\""), rt("\"a\\x41\""), rt("\"ok\\/\\\"\""), rt("\"\\u00e9\"")], " "))
    IO.print(String.join([rt("01"), rt("1-2"), rt("-"), rt("1."), rt("1e"), rt("[-0.5e+3, 0, 10, 2E-2]")], " "))
    IO.print(J.show(J.str("ctl\u{1}")))
    IO.print(String.join([rt("\"a\u{1}b\""), rt("\"tab\u{9}raw\""), rt("\"\\u00g9\""), rt("\"\\u12\""), rt("\"\\u00E9\"")], " "))
    IO.print(String.join([rt("[1,\u{C}2]"), rt("\u{B}[]"), rt("\t[1,\r\n2]\n")], " "))
    checks(Maybe.default(&2, J.Json, J.parse("{\"uid\": 42, \"name\": \"INBOX\", \"flag\": true, \"list\": [\"a\",\"b\"]}"), J.JNull{}))

#|{"a":[1,-2.5e3,true,false,null],"b":{"c":"x\"y\\z"}}
#|[]
#|{}
#|"tab\tnl\né😀"
#|PARSE-ERROR
#|PARSE-ERROR
#|PARSE-ERROR
#|PARSE-ERROR
#|PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR
#|PARSE-ERROR PARSE-ERROR "ok/\"" "é"
#|PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR [-0.5e+3,0,10,2E-2]
#|"ctl\u0001"
#|PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR "é"
#|PARSE-ERROR PARSE-ERROR [1,2]
#|INBOX
#|42
#|True
#|2
#|True
