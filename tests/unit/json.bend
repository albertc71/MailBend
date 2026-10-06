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

# Round trips each input and joins the results with spaces.
def round_trips(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{h, Nil{}}:
      round_trip(h)
    case Con{h, t}:
      round_trip(h) ++ " " ++ round_trips(t)

# Parses s, or falls back to null.
def parsed(s: String) -> J.Json:
  Maybe.default(&2, J.Json, J.parse(s), J.JNull{})

def shown(m: Maybe<&2, J.Json>) -> String:
  match m:
    case Some{j}:
      "Some(" ++ J.show(j) ++ ")"
    case None{}:
      "None"

def shown_str(m: Maybe<&2, String>) -> String:
  match m:
    case Some{s}:
      "Some(" ++ s ++ ")"
    case None{}:
      "None"

def shown_bool(m: Maybe<&2, Bool>) -> String:
  match m:
    case Some{b}:
      "Some(" ++ Bool.show(b) ++ ")"
    case None{}:
      "None"

def shown_u32(m: Maybe<&2, U32>) -> String:
  match m:
    case Some{n}:
      "Some(" ++ U32.show(n) ++ ")"
    case None{}:
      "None"

def shown_list(m: Maybe<&2, List<&2, J.Json>>) -> String:
  match m:
    case Some{xs}:
      "Some(" ++ J.show(J.arr(xs)) ++ ")"
    case None{}:
      "None"

def check_accessors(+o: J.Json) -> IO(Unit):
  do IO<Unit>:
    IO.print(Maybe.default(&2, String, J.as_str(J.get(o, "name")), "?"))
    IO.print(U32.show(Maybe.default(&2, U32, J.as_u32(J.get(o, "uid")), 0)))
    IO.print(Bool.show(Maybe.default(&2, Bool, J.as_bool(J.get(o, "flag")), False{})))
    IO.print(Nat.show(List.length(&2, J.Json, Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(o, "list")), []))))
    IO.print(Bool.show(Maybe.is_none(&2, J.Json, J.get(o, "missing"))))

# Builders and the serializer, escapes included.
def check_show() -> IO(Unit):
  do IO<Unit>:
    IO.print(J.show(J.obj([J.kv("s", J.str("x")), J.kv("n", J.num(0)),
      J.kv("max", J.num(4294967295)), J.kv("t", J.bool(True{})),
      J.kv("f", J.bool(False{}))])))
    IO.print(String.join([J.show(J.arr([])), J.show(J.obj([])), J.show(J.strs([])),
      J.show(J.strs(["a", "b\"c"])), J.show(J.JNull{})], " "))
    IO.print(String.join([J.show(J.chain([J.num(1), J.num(2)])), J.show(J.JEnd{}),
      J.show(J.kv("k", J.JNull{})), J.show(J.JNum{"-0.5"})], "|"))
    IO.print(J.show(J.str("q\" b\\ n\n r\r t\t nul\u{0} us\u{1F} vt\u{B} bs\u{8} ff\u{C} é 😀 /")))
    IO.print(J.show(J.str("")) ++ " " ++ J.show(J.kv("a\"b", J.str("\u{1A}"))))
    IO.print(Bool.show(String.eq(J.show(J.str("\u{7F}")), "\"\u{7F}\"")))

# Numbers, words and container structure.
def check_parse() -> IO(Unit):
  do IO<Unit>:
    IO.print(round_trips(["1", "-0", "0.0e0", "1E+2", "0e1", "12345678901234567890",
      "\"s\"", "true", "false", "null"]))
    IO.print(round_trips(["", "  ", "+1", "00", "-01", "1.5.5", "--1", ".5", "1e+", "1-",
      "0x1"]))
    IO.print(round_trips(["True", "nul", "truefalse", "[1true]", "[true1]", "[nullnull]",
      "@", "[1,@]"]))
    IO.print(round_trips(["[[[]]]", "{\"a\":{\"b\":[{}]}}", "{\"a\":1,\"a\":2}", "[\"a\":1]",
      "{\"a\":1 \"b\":2}", "{1:2}", "]", "}", "[}", "{]", "{\"a\"}", "{\"a\":}", "[\"k\"]"]))
    IO.print(round_trips(["\"a\" \"b\"", "[] 1",
      "{\"a\":[1,{\"b\":null}],\"c\":\"\"}"]))

# String escapes and UTF-16 surrogates.
def check_strings() -> IO(Unit):
  do IO<Unit>:
    IO.print(round_trips(["\"\\ud83d\"", "\"\\ud83dx\"", "\"\\ud83d\\ud83d\\ude00\"",
      "\"\\ude00\"", "\"\\ud83d\\n\"", "\"\\uD83D\\uDE00\"", "\"\\ud83d\\u0041\"",
      "\"\\u00C9\\u00c9\"", "\"\\u0000\""]))
    IO.print(round_trips(["\"\\b\\f\"", "\"unterminated", "\"esc\\", "\"\\u12", "\"\\u",
      "\"a\\\"", "\" sp  ace \"", "\"é😀\"", "\"\\/\""]))

# Lookups and the as_* views.
def check_access() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join([shown(J.get(parsed("{\"a\":1,\"a\":2}"), "a")),
      shown(J.get(parsed("[1]"), "a")), shown(J.get(parsed("{}"), "a")),
      shown(J.get(parsed("{\"A\":1}"), "a"))], " "))
    IO.print(String.join([
      shown(J.find(J.chain([J.num(1), J.kv("k", J.str("v")), J.kv("k", J.num(2))]), "k")),
      shown(J.find(J.JEnd{}, "k")), shown(J.find(J.str("k"), "k"))], " "))
    IO.print(String.join([shown_str(J.as_str(Some{J.str("x")})),
      shown_str(J.as_str(Some{J.num(1)})), shown_str(J.as_str(None{}))], " "))
    IO.print(String.join([shown_bool(J.as_bool(Some{J.bool(False{})})),
      shown_bool(J.as_bool(Some{J.str("true")})), shown_bool(J.as_bool(None{}))], " "))
    IO.print(String.join([shown_u32(J.as_u32(Some{J.JNum{"7"}})),
      shown_u32(J.as_u32(Some{J.str("42")})), shown_u32(J.as_u32(Some{J.JNum{"-1"}})),
      shown_u32(J.as_u32(Some{J.JNum{"1.5"}})), shown_u32(J.as_u32(Some{J.str("x")})),
      shown_u32(J.as_u32(Some{J.str("007")})), shown_u32(J.as_u32(Some{J.str("")})),
      shown_u32(J.as_u32(Some{J.bool(True{})})), shown_u32(J.as_u32(None{}))], " "))
    IO.print(String.join([shown_list(J.as_list(J.get(parsed("{\"l\":[1,[2],{}]}"), "l"))),
      shown_list(J.as_list(Some{J.obj([])})), shown_list(J.as_list(None{})),
      J.show(J.arr(J.unchain(J.str("x")))),
      J.show(J.arr(J.unchain(J.chain([J.num(1), J.num(2)]))))], " "))
    IO.print(String.join([Bool.show(J.is_ws(' ')), Bool.show(J.is_ws('\t')),
      Bool.show(J.is_ws('\r')), Bool.show(J.is_ws('\n')), Bool.show(J.is_ws('\u{B}')),
      Bool.show(J.is_ws('\u{C}')), Bool.show(J.is_ws('\u{A0}')), Bool.show(J.is_ws('x'))], " "))

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
    check_show()
    check_parse()
    check_strings()
    check_access()

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
#|{"s":"x","n":0,"max":4294967295,"t":true,"f":false}
#|[] {} [] ["a","b\"c"] null
#|1,2||"k":null|-0.5
#|"q\" b\\ n\n r\r t\t nul\u0000 us\u001f vt\u000b bs\u0008 ff\u000c é 😀 /"
#|"" "a\"b":"\u001a"
#|True
#|1 -0 0.0e0 1E+2 0e1 12345678901234567890 "s" true false null
#|PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR
#|PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR
#|[[[]]] {"a":{"b":[{}]}} {"a":1,"a":2} PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR ["k"]
#|PARSE-ERROR PARSE-ERROR {"a":[1,{"b":null}],"c":""}
#|"�" "�x" "�😀" "�" "�\n" "😀" "�A" "ÉÉ" "\u0000"
#|"\u0008\u000c" PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR PARSE-ERROR " sp  ace " "é😀" "/"
#|Some(1) None None None
#|Some("v") None None
#|Some(x) None None
#|Some(False) None None
#|Some(7) Some(42) None None None Some(7) None None None
#|Some([1,[2],{}]) None None [] [1,2]
#|True True True True False False False False
