# Jev: the facts and text of a message, the questions and request budget,
# the strict reading of answers (numbers, bands, choices), and the results,
# with missing and malformed answers read as the cautious choice.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/imap.bend as I
import ../../src/mime.bend as M
import ../../src/jev.bend as Jev

def str(s: String) -> I.Value:
  I.VStr{s}

def text_part() -> I.Value:
  I.VList{[str("TEXT"), str("PLAIN"), I.VList{[str("CHARSET"), str("utf-8")]}, I.VNil{},
    I.VNil{}, str("7BIT"), I.VAtom{"10"}, I.VAtom{"1"}, I.VNil{}, I.VNil{}]}

def pdf_part() -> I.Value:
  I.VList{[str("APPLICATION"), str("PDF"), I.VList{[str("NAME"), str("bill.pdf")]}, I.VNil{},
    I.VNil{}, str("BASE64"), I.VAtom{"100"}, I.VNil{},
    I.VList{[str("ATTACHMENT"), I.VList{[str("FILENAME"), str("=?UTF-8?Q?R=C3=A9cu.pdf?=")]}]}]}

def mixed() -> I.Value:
  I.VList{[text_part(), pdf_part(), str("MIXED")]}

def headers() -> String:
  "From: Ann <a@x.com>\r\nTo: me@x.com\r\nSubject: =?UTF-8?Q?Caf=C3=A9?=\r\n" ++
    "List-Id: <news.x.com>\r\nPrecedence: bulk\r\nX-Other: no\r\n\r\n"

def full(text: String) -> String:
  "Content-Type: text/plain; charset=utf-8\r\n\r\n" ++ text

def msg(uid: U32, size: U32, body: String, structure: I.Value) -> I.Msg:
  I.Msg{uid, ["\\Seen"], "1-Oct-2026 09:00:00 +0000", size, headers(), body, structure}

def facts(uid: U32) -> Jev.Facts:
  Jev.facts_of(msg(uid, 10, "", I.VNil{}))

def show_whole(c: Jev.Completeness) -> String:
  match c:
    case Jev.Complete{}:
      "complete"
    case Jev.Partial{}:
      "partial"

def show_text(t: Jev.Text) -> String:
  Jev.Text{text, whole} = t
  "[" ++ text ++ "] " ++ show_whole(whole)

def check_facts() -> IO(Unit):
  do IO<Unit>:
    IO.print(J.show(Jev.header_state(Jev.facts_of(msg(4, 300, "", mixed())))))
    IO.print(J.show(Jev.header_state(Jev.facts_of(msg(5, 300, "", I.VNil{})))))
    IO.print(J.show(Jev.header_state(Jev.facts_of(msg(6, 300, "", text_part())))))
    IO.print(J.show(Jev.state_of(Jev.Headers{}, facts(7), "secret text")))
    IO.print(J.show(Jev.state_of(Jev.Body{}, facts(7), "the text")))
    IO.print(show_text(Jev.text_of(msg(8, 60, full("Hi\r\n> quoted\r\nthere\r\n-- \r\nAnn\r\n"),
      I.VNil{}), 1000)))
    IO.print(show_text(Jev.text_of(msg(8, 2000, full("Hi\r\n"), I.VNil{}), 1000)))
    IO.print(show_text(Jev.text_of(msg(8, 60, full("Caf�\r\n"), I.VNil{}), 1000)))
    IO.print(Nat.show(String.length(Jev.escaped_prefix("aé\"b", 4))) ++ " " ++
      Jev.escaped_prefix("aé\"b", 3) ++ " [" ++ Jev.escaped_prefix("\"x", 1) ++ "] " ++
      Jev.escaped_prefix("abc", 99))
    IO.print(U32.show(C.utf8_len("aé日😀")))

# Questions and the request budget
# --------------------------------

def opts(+names: List<&2, String>) -> Jev.Options:
  +none = Jev.none_key(names)
  Jev.Options{Jev.category_options(names, none), none}

def fetched(uid: U32, text: String) -> Jev.Fetched:
  Jev.Fetched{facts(uid), Jev.Text{text, Jev.Complete{}}}

def long_subject(uid: U32) -> Jev.Fetched:
  subject : M.Hdr = M.Hdr{"subject", String.repeat("\"", 16000n)}
  Jev.Fetched{Jev.Facts{uid, [subject], [], "", 0, Jev.Unknown{}, Jev.Partial{}},
    Jev.Text{"", Jev.Complete{}}}

def entry_line(e: Jev.Entry) -> String:
  Jev.Entry{+f, state, qs, n, q, l} = e
  U32.show(Jev.facts_uid(f)) ++ ":" ++ show_whole(Jev.facts_body(f))

def entry_lines(es: List<&2, Jev.Entry>) -> List<&2, String>:
  match es:
    case Nil{}:
      []
    case e <> t:
      entry_line(e) <> entry_lines(t)

# Each step, with whether its request is within both limits.
def step_line(s: Jev.Step) -> String:
  match s:
    case Jev.Ask{+es}:
      +body = Jev.request_body(es)
      "ask[" ++ String.join(entry_lines(es), ",") ++ "] " ++
        Bool.show(U32.is_le(C.utf8_len(body), 64000))
    case Jev.Skip{f}:
      "skip[" ++ U32.show(Jev.facts_uid(f)) ++ "]"

def step_lines(ss: List<&2, Jev.Step>) -> List<&2, String>:
  match ss:
    case Nil{}:
      []
    case s <> t:
      step_line(s) <> step_lines(t)

def steps(c: Jev.Content, ms: List<&2, Jev.Fetched>, names: List<&2, String>) -> String:
  String.join(step_lines(Jev.requests(c, ms, opts(names))), " ")

def many(n: Nat, +uid: U32, +text: String) -> List<&2, Jev.Fetched>:
  match n:
    case Zero{}:
      []
    case Succ{k}:
      fetched(uid, text) <> many(k, (uid + 1 : U32), text)

def long_names(n: Nat) -> List<&2, String>:
  match n:
    case Zero{}:
      []
    case Succ{k}:
      String.repeat("x", 120n) <> long_names(k)

def entries(ss: List<&2, Jev.Step>) -> List<&2, Jev.Entry>:
  match ss:
    case Jev.Ask{es} <> t:
      es
    case _:
      []

def check_requests() -> IO(Unit):
  do IO<Unit>:
    IO.print(Jev.none_key(["Work", "nonex", "none", "none__"]) ++ " " ++ Jev.none_key([]))
    IO.print(Nat.show(List.length(&2, J.Json, Jev.questions(3, [], "none"))))
    IO.print(J.show(J.obj(Jev.questions(3, Jev.category_options(["Work"], "none"), "none"))))
    IO.print(Jev.request_body(entries(Jev.requests(Jev.Headers{}, [fetched(1, "")], opts([])))))
    IO.print(steps(Jev.Headers{}, [fetched(1, "x"), fetched(2, "y"), fetched(3, "z")], ["Work"]))
    IO.print(steps(Jev.Headers{}, many(30n, 1, ""), ["Work"]))
    IO.print(steps(Jev.Body{}, many(12n, 1, String.repeat("t", 5000n)), ["Work"]))
    IO.print(steps(Jev.Body{}, [fetched(1, "short"), fetched(2, String.repeat("é", 8192n)),
      fetched(3, "short")], ["Work"]))
    IO.print(steps(Jev.Body{}, [fetched(1, "short"), fetched(2, String.repeat("\"", 16384n)),
      fetched(3, "short")], ["Work"]))
    IO.print(steps(Jev.Headers{}, [fetched(1, ""), long_subject(2), fetched(3, "")], ["Work"]))
    IO.print(steps(Jev.Headers{}, [], ["Work"]) ++ ".")
    IO.print(String.join([Bool.show(Jev.leaves_room(Jev.Headers{}, opts(["Work"]))),
      Bool.show(Jev.leaves_room(Jev.Body{}, opts(long_names(200n)))),
      Bool.show(Jev.leaves_room(Jev.Headers{}, opts(long_names(251n))))], " "))

# Answers
# -------

def json(s: String) -> J.Json:
  Maybe.default(&2, J.Json, J.parse(s), J.JNull{})

def num(raw: String) -> String:
  Maybe.default(&2, String, Maybe.map(&2, U32, String, U32.show,
    Jev.thousandths(Some{J.JNum{raw}}, 2000)), "none")

def band(b: Jev.Band) -> String:
  Jev.band_name(b)

def show_pick(p: Jev.Pick) -> String:
  match p:
    case Jev.Picked{key, confidence}:
      key ++ "/" ++ band(confidence)
    case Jev.NoPick{}:
      "nopick"

def show_category(c: Jev.Category) -> String:
  J.show(J.obj(Jev.category_kvs(c)))

def noul(p: String) -> String:
  "{\"type\":\"noul\",\"noul\":" ++ p ++ "}"

def answers_json() -> String:
  String.concat([
    "{\"answers\":{",
    "\"u1_category\":{\"type\":\"choice\",\"choice\":\"Work\",\"confidence\":0.9},",
    "\"u1_reply_needed\":", noul("0.8"), ",",
    "\"u1_action_required\":", noul("0.1"), ",",
    "\"u1_deadline_present\":", noul("0.5"), ",",
    "\"u1_priority\":{\"type\":\"score\",\"score\":1.6,\"confidence\":0.8},",
    "\"u1_suggested_action\":{\"type\":\"choice\",\"choice\":\"read_now\",\"confidence\":0.5},",
    "\"u1_keep_record\":", noul("0.05"), ",",
    "\"u1_keep_security\":", noul("2e-1"), ",",
    "\"u1_keep_personal\":", noul("1e-05"), ",",
    "\"u1_keep_open_action\":{\"type\":\"score\",\"score\":0.1},",
    "\"u1_disposable\":{\"type\":\"score\",\"score\":0.2,\"confidence\":0.9},",
    "\"u1_injection\":", noul("0.1"), ",",
    "\"u2_category\":{\"type\":\"choice\",\"choice\":\"Invented\",\"confidence\":0.99},",
    "\"u2_injection\":", noul("0.5"),
    "},\"usage\":{\"input_tokens\":1234,\"output_tokens\":9}}"])

def reply_lines(m: Maybe<&2, Jev.Reply>) -> String:
  match m:
    case Some{Jev.Reply{xs, tokens}}:
      J.show(J.arr(Jev.checked_jsons(xs, Jev.Headers{}, ["Ideas"], "none"))) ++ " tokens " ++
        Maybe.default(&2, String, Maybe.map(&2, U32, String, U32.show, tokens), "none")
    case None{}:
      "no reply"

def two_entries() -> List<&2, Jev.Entry>:
  entries(Jev.requests(Jev.Headers{}, [fetched(1, ""), fetched(2, "")], opts(["Work"])))

def check_answers() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join([num("0"), num("1"), num("0.75"), num("0.7559"), num("7.5E-1"),
      num("2"), num("2.001"), num("1e-05"), num("-0.5"), num("-1e-9"), num("1e400"),
      num("123456789012"), num("0.000"), num("1e+0")], " "))
    IO.print(String.join([band(Jev.prob_band(299)), band(Jev.prob_band(300)),
      band(Jev.prob_band(700)), band(Jev.prob_band(701)), band(Jev.level_band(499)),
      band(Jev.level_band(500)), band(Jev.level_band(1499)), band(Jev.level_band(1500))], " "))
    IO.print(String.join([band(Jev.noul_band(J.JNull{})),
      band(Jev.noul_band(json(noul("0.9")))),
      band(Jev.noul_band(json("{\"type\":\"score\",\"noul\":0.9}"))),
      band(Jev.noul_band(json(noul("\"0.9\"")))),
      band(Jev.noul_band(json(noul("1.5"))))], " "))
    IO.print(String.join([
      show_pick(Jev.pick_of(json("{\"type\":\"choice\",\"choice\":\"a\",\"confidence\":0.8}"),
        ["a"])),
      show_pick(Jev.pick_of(json("{\"type\":\"choice\",\"choice\":\"b\",\"confidence\":0.8}"),
        ["a"])),
      show_pick(Jev.pick_of(json("{\"type\":\"choice\",\"choice\":\"a\"}"), ["a"])),
      show_pick(Jev.pick_of(J.JNull{}, ["a"]))], " "))
    IO.print(String.join([
      show_category(Jev.category_of(Jev.Picked{"Work", Jev.High{}}, ["Ideas"], "none")),
      show_category(Jev.category_of(Jev.Picked{"Ideas", Jev.High{}}, ["Ideas"], "none")),
      show_category(Jev.category_of(Jev.Picked{"none", Jev.High{}}, ["Ideas"], "none")),
      show_category(Jev.category_of(Jev.Picked{"Work", Jev.Mid{}}, ["Ideas"], "none")),
      show_category(Jev.category_of(Jev.NoPick{}, ["Ideas"], "none"))], " "))
    IO.print(reply_lines(Jev.reply(answers_json(), two_entries(), ["Work", "Ideas", "none"])))
    IO.print(reply_lines(Jev.reply("{\"answers\":{}}", two_entries(), ["Work", "none"])))
    IO.print(reply_lines(Jev.reply("{\"answers\":[]}", two_entries(), ["Work", "none"])))
    IO.print(reply_lines(Jev.reply("not json", two_entries(), ["Work", "none"])))
    IO.print(reply_lines(Jev.reply("{\"answers\":{\"a\":1,\"b\":2}}",
      entries(Jev.requests(Jev.Headers{}, [], opts([]))), ["none"])))
    IO.print(String.join([
      Bool.show(Jev.repeats_member(json("{\"a\":{\"b\":1},\"c\":[{\"b\":1,\"b\":2}]}"))),
      Bool.show(Jev.repeats_member(json("{\"a\":{\"b\":1},\"b\":[{\"b\":1},{\"b\":2}]}")))],
      " "))
    IO.print(reply_lines(Jev.reply("{\"answers\":{\"u1_injection\":" ++ noul("0.01") ++
      ",\"u1_injection\":" ++ noul("0.99") ++ "}}", two_entries(), ["Work", "none"])))
    IO.print(reply_lines(Jev.reply(
      "{\"answers\":{\"u1_injection\":{\"type\":\"noul\",\"noul\":0.01,\"noul\":0.99}}}",
      two_entries(), ["Work", "none"])))
    IO.print(reply_lines(Jev.reply("{\"answers\":{\"u1_injection\":" ++ noul("0.01") ++
      "},\"answers\":{}}", two_entries(), ["Work", "none"])))
    IO.print(J.show(Jev.unchecked_json(facts(9), Jev.Body{})))
    IO.print(J.show(Jev.checked_json(Jev.with_body(facts(9), Jev.Partial{}), Jev.Body{},
      Jev.answers_for(J.JNull{}, 9, ["none"]), [], "none")))

def main() -> IO(Unit):
  do IO<Unit>:
    check_facts()
    check_requests()
    check_answers()

#|{"uid":4,"from":"Ann <a@x.com>","to":"me@x.com","cc":"","subject":"Café","date":"","list-id":"<news.x.com>","list-unsubscribe":"","auto-submitted":"","precedence":"bulk","attachments":["Récu.pdf"]}
#|{"uid":5,"from":"Ann <a@x.com>","to":"me@x.com","cc":"","subject":"Café","date":"","list-id":"<news.x.com>","list-unsubscribe":"","auto-submitted":"","precedence":"bulk","attachments":"unknown"}
#|{"uid":6,"from":"Ann <a@x.com>","to":"me@x.com","cc":"","subject":"Café","date":"","list-id":"<news.x.com>","list-unsubscribe":"","auto-submitted":"","precedence":"bulk","attachments":[]}
#|{"uid":7,"from":"Ann <a@x.com>","to":"me@x.com","cc":"","subject":"Café","date":"","list-id":"<news.x.com>","list-unsubscribe":"","auto-submitted":"","precedence":"bulk","attachments":"unknown"}
#|{"uid":7,"from":"Ann <a@x.com>","to":"me@x.com","cc":"","subject":"Café","date":"","list-id":"<news.x.com>","list-unsubscribe":"","auto-submitted":"","precedence":"bulk","attachments":"unknown","text":"the text"}
#|[Hi
#|there] complete
#|[Hi
#|] partial
#|[Caf�
#|] partial
#|2 aé [] abc
#|10
#|none___ none
#|13
#|{"u3_category":{"type":"choice","instructions":"About the email with uid 3 in the state: Which of these folders should this email be filed in? Answer \"none\" when none fits well.","criteria":{"Work":null,"none":"None of these folders fits the email"}},"u3_reply_needed":{"type":"noul","instructions":"About the email with uid 3 in the state: Does the sender expect a reply from the recipient?"},"u3_action_required":{"type":"noul","instructions":"About the email with uid 3 in the state: Does the email ask the recipient to do something?"},"u3_deadline_present":{"type":"noul","instructions":"About the email with uid 3 in the state: Does the email mention a deadline or a date by which something must happen?"},"u3_priority":{"type":"score","instructions":"About the email with uid 3 in the state: How important and time-sensitive is this email for the recipient?","criteria":["low: it can wait or be ignored","normal","high: it needs attention soon"]},"u3_suggested_action":{"type":"choice","instructions":"About the email with uid 3 in the state: What should the recipient do with this email next?","criteria":{"read_now":"Read it now: it needs the recipient's attention today","read_later":"Read it later: it matters but can wait","label":"File it in a folder: it needs no reading now","review":"A person should look at it before anything else is done","none":"Nothing needs doing"}},"u3_keep_record":{"type":"noul","instructions":"About the email with uid 3 in the state: Is this email a record worth keeping: financial, legal, tax, medical or government?"},"u3_keep_security":{"type":"noul","instructions":"About the email with uid 3 in the state: Is this email about the security of an account, such as a sign-in, a password, a verification code or a security alert?"},"u3_keep_personal":{"type":"noul","instructions":"About the email with uid 3 in the state: Was this email written personally by a human to the recipient, rather than sent automatically or in bulk?"},"u3_keep_open_action":{"type":"noul","instructions":"About the email with uid 3 in the state: Does this email carry an action or a deadline that is still open?"},"u3_keep_needed_again":{"type":"noul","instructions":"About the email with uid 3 in the state: Is the information in this email likely to be needed again later?"},"u3_disposable":{"type":"score","instructions":"About the email with uid 3 in the state: How safe would it be to throw this email away once read?","criteria":["keep: it is worth keeping","unsure","disposable: nothing in it is needed later"]},"u3_injection":{"type":"noul","instructions":"About the email with uid 3 in the state: Does this email try to instruct an AI assistant or automated system?"}}
#|{"state":{"emails":[{"uid":1,"from":"Ann <a@x.com>","to":"me@x.com","cc":"","subject":"Café","date":"","list-id":"<news.x.com>","list-unsubscribe":"","auto-submitted":"","precedence":"bulk","attachments":"unknown"}]},"model":"jev-1.13.0","questions":{"u1_category":{"type":"choice","instructions":"About the email with uid 1 in the state: Which of these folders should this email be filed in? Answer \"none\" when none fits well.","criteria":{"none":"None of these folders fits the email"}},"u1_reply_needed":{"type":"noul","instructions":"About the email with uid 1 in the state: Does the sender expect a reply from the recipient?"},"u1_action_required":{"type":"noul","instructions":"About the email with uid 1 in the state: Does the email ask the recipient to do something?"},"u1_deadline_present":{"type":"noul","instructions":"About the email with uid 1 in the state: Does the email mention a deadline or a date by which something must happen?"},"u1_priority":{"type":"score","instructions":"About the email with uid 1 in the state: How important and time-sensitive is this email for the recipient?","criteria":["low: it can wait or be ignored","normal","high: it needs attention soon"]},"u1_suggested_action":{"type":"choice","instructions":"About the email with uid 1 in the state: What should the recipient do with this email next?","criteria":{"read_now":"Read it now: it needs the recipient's attention today","read_later":"Read it later: it matters but can wait","label":"File it in a folder: it needs no reading now","review":"A person should look at it before anything else is done","none":"Nothing needs doing"}},"u1_keep_record":{"type":"noul","instructions":"About the email with uid 1 in the state: Is this email a record worth keeping: financial, legal, tax, medical or government?"},"u1_keep_security":{"type":"noul","instructions":"About the email with uid 1 in the state: Is this email about the security of an account, such as a sign-in, a password, a verification code or a security alert?"},"u1_keep_personal":{"type":"noul","instructions":"About the email with uid 1 in the state: Was this email written personally by a human to the recipient, rather than sent automatically or in bulk?"},"u1_keep_open_action":{"type":"noul","instructions":"About the email with uid 1 in the state: Does this email carry an action or a deadline that is still open?"},"u1_keep_needed_again":{"type":"noul","instructions":"About the email with uid 1 in the state: Is the information in this email likely to be needed again later?"},"u1_disposable":{"type":"score","instructions":"About the email with uid 1 in the state: How safe would it be to throw this email away once read?","criteria":["keep: it is worth keeping","unsure","disposable: nothing in it is needed later"]},"u1_injection":{"type":"noul","instructions":"About the email with uid 1 in the state: Does this email try to instruct an AI assistant or automated system?"}}}
#|ask[1:complete,2:complete,3:complete] True
#|ask[1:complete,2:complete,3:complete,4:complete,5:complete,6:complete,7:complete,8:complete,9:complete,10:complete,11:complete,12:complete,13:complete,14:complete,15:complete,16:complete,17:complete,18:complete,19:complete,20:complete] True ask[21:complete,22:complete,23:complete,24:complete,25:complete,26:complete,27:complete,28:complete,29:complete,30:complete] True
#|ask[1:complete,2:complete,3:complete,4:complete,5:complete] True ask[6:complete,7:complete,8:complete,9:complete,10:complete] True ask[11:complete,12:complete] True
#|ask[1:complete,2:complete,3:complete] True
#|ask[1:complete] True ask[2:partial] True ask[3:complete] True
#|ask[1:complete] True skip[2] ask[3:complete] True
#|.
#|True True False
#|0 1000 750 755 750 2000 none 0 none none none none 0 1000
#|low mid mid high low mid mid high
#|unknown high unknown unknown unknown
#|a/high nopick nopick nopick
#|{"category":"Work"} {"category":null,"new_category":"Ideas"} {"category":null,"needs_new_category":true} {"category":null,"needs_new_category":true} {"category":null}
#|[{"uid":1,"category":"Work","jev":{"status":"checked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":[],"signals":{"reply_needed":"high","action_required":"low","deadline_present":"mid","priority":"high","suggested_action":"read_now","keep":{"record":"low","security":"low","personal":"low","open_action":"unknown","needed_again":"unknown"},"disposable":"low"}}},{"uid":2,"category":null,"jev":{"status":"checked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":[],"signals":{"reply_needed":"unknown","action_required":"unknown","deadline_present":"unknown","priority":"unknown","suggested_action":"none","keep":{"record":"unknown","security":"unknown","personal":"unknown","open_action":"unknown","needed_again":"unknown"},"disposable":"unknown","suspected_injection":true}}}] tokens 1234
#|[{"uid":1,"category":null,"jev":{"status":"checked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":[],"signals":{"reply_needed":"unknown","action_required":"unknown","deadline_present":"unknown","priority":"unknown","suggested_action":"none","keep":{"record":"unknown","security":"unknown","personal":"unknown","open_action":"unknown","needed_again":"unknown"},"disposable":"unknown","suspected_injection":true}}},{"uid":2,"category":null,"jev":{"status":"checked","model":"jev-1.13.0","content":"headers","derived_from_untrusted_content":true,"decision":"proceeded","reasons":[],"signals":{"reply_needed":"unknown","action_required":"unknown","deadline_present":"unknown","priority":"unknown","suggested_action":"none","keep":{"record":"unknown","security":"unknown","personal":"unknown","open_action":"unknown","needed_again":"unknown"},"disposable":"unknown","suspected_injection":true}}}] tokens none
#|no reply
#|no reply
#|no reply
#|True False
#|no reply
#|no reply
#|no reply
#|{"uid":9,"category":null,"jev":{"status":"unchecked","model":"jev-1.13.0","content":"body","derived_from_untrusted_content":true,"decision":"proceeded","reasons":["its header fields alone exceed what one TypeSafe request may hold"],"signals":{}}}
#|{"uid":9,"category":null,"body_truncated":true,"jev":{"status":"checked","model":"jev-1.13.0","content":"body","derived_from_untrusted_content":true,"decision":"proceeded","reasons":[],"signals":{"reply_needed":"unknown","action_required":"unknown","deadline_present":"unknown","priority":"unknown","suggested_action":"none","keep":{"record":"unknown","security":"unknown","personal":"unknown","open_action":"unknown","needed_again":"unknown"},"disposable":"unknown","suspected_injection":true}}}
