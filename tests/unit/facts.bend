import Base
import ../../src/json.bend as J
import ../../src/facts.bend as Facts

def empty(+source: String, ending: Facts.SourceEnd) -> Bool:
  String.eq(J.show(Maybe.default(&2, J.Json,
    J.get(J.obj(Facts.fields(source, ending)), "facts"), J.JNull{})), "[]")

def rejected(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case text <> rest:
      empty(text, Facts.Complete{}) && rejected(rest)

def say(name: String, result: Bool) -> IO(Unit):
  IO.print(name ++ ": " ++ Bool.pick(String, result, "true", "false"))

def limited(source: String, ending: Facts.SourceEnd) -> Bool:
  +result = J.obj(Facts.fields(source, ending))
  notice = Maybe.default(&2, J.Json, J.get(result, "facts_scan"), J.JNull{})
  Maybe.default(&2, Bool, J.as_bool(J.get(notice, "limited")), False{})

def count(source: String) -> Nat:
  result = J.obj(Facts.fields(source, Facts.Complete{}))
  List.length(&2, J.Json, Maybe.default(&2, List<&2, J.Json>, J.as_list(J.get(result, "facts")), []))

def padding(n: Nat, tail: String) -> String:
  match n:
    case 0n:
      tail
    case 1n+k:
      padding(k, SCon{' ', tail})

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(J.show(J.obj(Facts.fields("é😀 \nhttps://meet.google.com/abc-defg-hij", Facts.Complete{}))))
    say("reject hostile boundaries", rejected([
      "https://meet.google.com/abc-defg-hij.evil",
      "https://meet.google.com/abc-defg-hij/path",
      "https://meet.google.com/abc-defg-hij?x=1",
      "https://meet.google.com/abc-defg-hij#fragment",
      "https://meet.google.com/abc-defg-hij@evil.invalid",
      "https://meet.google.com/abc-defg-hij%20",
      "https://meet.google.com/abc-defg-hij\\evil",
      "https://meet.google.com/abc-defg-hijx",
      "https://meet.google.com/abc-defg-hijé",
      "https://evil.invalid/https://meet.google.com/abc-defg-hij",
      "xhttps://meet.google.com/abc-defg-hij",
      "éhttps://meet.google.com/abc-defg-hij",
      "https://meet.google.com@evil.invalid/abc-defg-hij",
      "https://meet.google.com.evil.invalid/abc-defg-hij",
      "http://meet.google.com/abc-defg-hij",
      "https://MEET.google.com/abc-defg-hij",
      "https://meet.google.com/ABC-defg-hij",
      "https://meet.google.com/abcXdefg-hij",
      "https://meet.google.com/abc-defgXhij",
      "https://meet.google.com/abc-defg-hıj"]))
    say("prefix cannot end token", empty("https://meet.google.com/abc-defg-hij", Facts.Prefix{}))
    say("closing wrapper ends token", Bool.not(empty("(https://meet.google.com/abc-defg-hij)", Facts.Prefix{})))
    say("fact cap is sixteen", Nat.is_eq(count(String.repeat("https://meet.google.com/abc-defg-hij\n", 17n)), 16n))
    say("fact cap is limited", limited(String.repeat("https://meet.google.com/abc-defg-hij\n", 16n), Facts.Complete{}))
    say("scan cap refuses cut token", empty(padding(65500n, "https://meet.google.com/abc-defg-hij.evil"), Facts.Complete{}))
    say("scan cap is limited", limited(padding(65536n, ""), Facts.Complete{}))
    say("source prefix is limited", limited("", Facts.Prefix{}))

#|{"facts":[{"kind":"meeting_link","value":"https://meet.google.com/abc-defg-hij","source":"text","start":4,"end":40,"line":2,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":false}}
#|reject hostile boundaries: true
#|prefix cannot end token: true
#|closing wrapper ends token: true
#|fact cap is sixteen: true
#|fact cap is limited: true
#|scan cap refuses cut token: true
#|scan cap is limited: true
#|source prefix is limited: true
