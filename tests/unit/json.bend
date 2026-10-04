# JSON parser and serializer round trips, including rejected inputs.
import Base
import ../../src/json.bend as J

def parsed_output(m: Maybe<&2, J.Json>) -> String:
  match m:
    case Some{j}:
      J.show(j)
    case None{}:
      "PARSE-ERROR"

def round_trip(s: String) -> String:
  parsed_output(J.parse(s))

def check_accessors(+o: J.Json) -> IO(Unit):
  do IO<Unit>:
    IO.print(Maybe.default(&2, String, J.as_str(J.get(o, "name")), "?"))
    IO.print(U32.show(Maybe.default(&2, U32, J.as_u32(J.get(o, "uid")), 0)))
    IO.print(Bool.show(Maybe.default(&2, Bool, J.as_bool(J.get(o, "flag")), False{})))
    IO.print(Nat.show(List.length(&2, J.Json, Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(o, "list")), []))))
    IO.print(Bool.show(Maybe.is_none(&2, J.Json, J.get(o, "missing"))))


def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(round_trip("{\"a\": [1, -2.5e3, true, false, null], \"b\": {\"c\": \"x\\\"y\\\\z\"}}"))
    IO.print(round_trip("  [ ]  "))
    IO.print(round_trip("{}"))
    IO.print(round_trip("\"tab\\tnl\\n\\u00e9\\ud83d\\ude00\""))
    IO.print(round_trip("[1, 2"))
    IO.print(round_trip("{\"a\" 1}"))
    IO.print(round_trip("[1] [2]"))
    IO.print(round_trip("nope"))
    IO.print(String.join([round_trip("[1 2]"), round_trip("[1,]"), round_trip("{\"a\":1,}"), round_trip("{,}"), round_trip("{\"a\"::1}"), round_trip("[,1]")], " "))
    IO.print(String.join([round_trip("\"a\\qb\""), round_trip("\"a\\x41\""), round_trip("\"ok\\/\\\"\""), round_trip("\"\\u00e9\"")], " "))
    IO.print(String.join([round_trip("01"), round_trip("1-2"), round_trip("-"), round_trip("1."), round_trip("1e"), round_trip("[-0.5e+3, 0, 10, 2E-2]")], " "))
    IO.print(J.show(J.str("ctl\u{1}")))
    IO.print(String.join([round_trip("\"a\u{1}b\""), round_trip("\"tab\u{9}raw\""), round_trip("\"\\u00g9\""), round_trip("\"\\u12\""), round_trip("\"\\u00E9\"")], " "))
    IO.print(String.join([round_trip("[1,\u{C}2]"), round_trip("\u{B}[]"), round_trip("\t[1,\r\n2]\n")], " "))
    check_accessors(Maybe.default(&2, J.Json, J.parse("{\"uid\": 42, \"name\": \"INBOX\", \"flag\": true, \"list\": [\"a\",\"b\"]}"), J.JNull{}))

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
