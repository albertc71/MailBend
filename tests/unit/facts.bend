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
    IO.print(J.show(J.obj(Facts.fields("é😀 \nhttps://zoom.us/j/123456789", Facts.Complete{}))))
    IO.print(J.show(J.obj(Facts.fields("https://us02web.zoom.us/j/12345678901?pwd=Ab_C-0.1", Facts.Complete{}))))
    IO.print(J.show(J.obj(Facts.fields("https://example-org.zoom.us/j/1234567890?pwd=A%2fb%2BC&from=calendar", Facts.Complete{}))))
    IO.print(J.show(J.obj(Facts.fields("\"https://zoom.us/j/123456789?pwd=synthetic.\"", Facts.Prefix{}))))
    IO.print(J.show(J.obj(Facts.fields("https://zoom.us/j/123456789\nhttps://meet.google.com/abc-defg-hij", Facts.Complete{}))))
    say("reject hostile zoom tokens", rejected([
      "https://zoom.us/j/123456789.",
      "https://zoom.us/j/123456789,",
      "https://zoom.us/j/123456789/path",
      "https://zoom.us/j/123456789#fragment",
      "https://zoom.us/j/123456789?",
      "https://zoom.us/j/123456789?pwd=%",
      "https://zoom.us/j/123456789?pwd=%2",
      "https://zoom.us/j/123456789?pwd=%GG",
      "https://zoom.us/j/123456789?pwd=%2\"",
      "https://zoom.us/j/123456789?pwd=a#fragment",
      "https://zoom.us/j/123456789?pwd=a/b",
      "https://zoom.us/j/123456789?pwd=a?b",
      "https://zoom.us/j/123456789?pwd=a:b",
      "https://zoom.us/j/123456789?pwd=a@b",
      "https://zoom.us/j/123456789?pwd=a\\b",
      "https://zoom.us/j/123456789?pwd=é",
      "https://zoom.us/j/12345678",
      "https://zoom.us/j/123456789012",
      "https://zoom.us/j/１２３４５６７８９",
      "https://zoom.us/j/123456789é",
      "https://zoom.us/j/123456789%20",
      "https://zoom.us/j/123456789@evil.invalid",
      "https://zoom.us.evil.invalid/j/123456789",
      "https://zoom.us@evil.invalid/j/123456789",
      "https://zoom.us:443/j/123456789",
      "https://evilzoom.us/j/123456789",
      "https://a.b.zoom.us/j/123456789",
      "https://.zoom.us/j/123456789",
      "https://-a.zoom.us/j/123456789",
      "https://a-.zoom.us/j/123456789",
      "https://a_b.zoom.us/j/123456789",
      "https://US02web.zoom.us/j/123456789",
      "https://ZOOM.us/j/123456789",
      "https://zoom.us/my/123456789",
      "http://zoom.us/j/123456789",
      "HTTPS://zoom.us/j/123456789",
      "xhttps://zoom.us/j/123456789",
      "éhttps://zoom.us/j/123456789",
      "https://evil.invalid/https://zoom.us/j/123456789"]))
    say("one character zoom label", Nat.is_eq(count("https://a.zoom.us/j/123456789"), 1n))
    say("maximum zoom label", Nat.is_eq(count("https://" ++ String.repeat("a", 63n) ++ ".zoom.us/j/123456789"), 1n))
    say("overlong zoom label rejected", empty("https://" ++ String.repeat("a", 64n) ++ ".zoom.us/j/123456789", Facts.Complete{}))
    say("opaque zoom query accepted", Nat.is_eq(count("https://zoom.us/j/123456789?x=1&x=2&empty=&opaque+value~"), 1n))
    say("zoom prefix cannot end token", empty("https://zoom.us/j/123456789", Facts.Prefix{}))
    say("zoom prefix cannot end query", empty("https://zoom.us/j/123456789?pwd=abc", Facts.Prefix{}))
    say("maximum zoom URL accepted", Nat.is_eq(count("https://zoom.us/j/123456789?" ++ String.repeat("x", 484n)), 1n))
    say("overlong zoom URL rejected", empty("https://zoom.us/j/123456789?" ++ String.repeat("x", 485n), Facts.Complete{}))
    say("maximum zoom URL prefix rejected", empty("https://zoom.us/j/123456789?" ++ String.repeat("x", 484n), Facts.Prefix{}))
    say("maximum zoom URL delimiter accepted", Bool.not(empty("https://zoom.us/j/123456789?" ++ String.repeat("x", 484n) ++ ")", Facts.Prefix{})))
    say("zoom scan cap refuses cut token", empty(padding(65509n, "https://zoom.us/j/123456789?pwd=hidden"), Facts.Complete{}))
    say("zoom scan cap refuses complete EOF", empty(padding(65509n, "https://zoom.us/j/123456789"), Facts.Complete{}))
    say("zoom EOF within scan cap accepted", Nat.is_eq(count(padding(65508n, "https://zoom.us/j/123456789")), 1n))
    say("mixed fact cap is sixteen", Nat.is_eq(count(String.repeat("https://zoom.us/j/123456789\nhttps://meet.google.com/abc-defg-hij\n", 9n)), 16n))
    say("mixed fact cap is limited", limited(String.repeat("https://zoom.us/j/123456789\nhttps://meet.google.com/abc-defg-hij\n", 8n), Facts.Complete{}))

#|{"facts":[{"kind":"meeting_link","value":"https://meet.google.com/abc-defg-hij","source":"text","start":4,"end":40,"line":2,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":false}}
#|reject hostile boundaries: true
#|prefix cannot end token: true
#|closing wrapper ends token: true
#|fact cap is sixteen: true
#|fact cap is limited: true
#|scan cap refuses cut token: true
#|scan cap is limited: true
#|source prefix is limited: true
#|{"facts":[{"kind":"meeting_link","value":"https://zoom.us/j/123456789","source":"text","start":4,"end":31,"line":2,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":false}}
#|{"facts":[{"kind":"meeting_link","value":"https://us02web.zoom.us/j/12345678901?pwd=Ab_C-0.1","source":"text","start":0,"end":50,"line":1,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":false}}
#|{"facts":[{"kind":"meeting_link","value":"https://example-org.zoom.us/j/1234567890?pwd=A%2fb%2BC&from=calendar","source":"text","start":0,"end":68,"line":1,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":false}}
#|{"facts":[{"kind":"meeting_link","value":"https://zoom.us/j/123456789?pwd=synthetic.","source":"text","start":1,"end":43,"line":1,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":true}}
#|{"facts":[{"kind":"meeting_link","value":"https://zoom.us/j/123456789","source":"text","start":0,"end":27,"line":1,"untrusted":true},{"kind":"meeting_link","value":"https://meet.google.com/abc-defg-hij","source":"text","start":28,"end":64,"line":2,"untrusted":true}],"facts_scan":{"scope":"returned_text","limited":false}}
#|reject hostile zoom tokens: true
#|one character zoom label: true
#|maximum zoom label: true
#|overlong zoom label rejected: true
#|opaque zoom query accepted: true
#|zoom prefix cannot end token: true
#|zoom prefix cannot end query: true
#|maximum zoom URL accepted: true
#|overlong zoom URL rejected: true
#|maximum zoom URL prefix rejected: true
#|maximum zoom URL delimiter accepted: true
#|zoom scan cap refuses cut token: true
#|zoom scan cap refuses complete EOF: true
#|zoom EOF within scan cap accepted: true
#|mixed fact cap is sixteen: true
#|mixed fact cap is limited: true

