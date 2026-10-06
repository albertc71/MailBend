# TypeSafe's Jev: the facts about a message that may leave the machine, the
# questions MailBend asks about them, the requests it sends, and the typed
# answers it reads back. The helper mailbend-typesafe only carries a request
# to TypeSafe; everything it means is decided here. Answers are derived from
# untrusted mail content, so every missing or malformed one reads as the
# cautious choice.

import Base
import ./codec.bend as C
import ./json.bend as J
import ./imap.bend as I
import ./mime.bend as M

# Configuration
# -------------

# What leaves the machine: header facts only, or also message text, which
# the operator allows only under a zero-retention plan.
type Content is Data:
  Headers{}
  Body{}

# Whether Jev is on, and with which content.
type Switch is Data:
  Off{}
  On{content: Content}

# The model every request names: pinned, never "jev-latest".
def model() -> String:
  "jev-1.13.0"

def content_name(c: Content) -> String:
  match c:
    case Headers{}:
      "headers"
    case Body{}:
      "body"

def is_body(c: Content) -> Bool:
  match c:
    case Headers{}:
      False{}
    case Body{}:
      True{}

def is_on(s: Switch) -> Bool:
  match s:
    case Off{}:
      False{}
    case On{c}:
      True{}

# Facts
# -----

# A message's attachments as its BODYSTRUCTURE lists them; Unknown when it
# is missing or malformed, never an empty list.
type Attachments is Data:
  Known{names: List<&2, String>}
  Unknown{}

# Whether Jev saw the whole readable text. A fetch cut, the text cap, an
# undecodable part or the request budget make it Partial. In headers mode
# Jev sees no text, and this records only whether the fetch was cut.
type Completeness is Data:
  Complete{}
  Partial{}

# What MailBend knows about a message before asking Jev: its decoded fact
# fields (see fact_names), flags, INTERNALDATE, size and attachments. It
# holds no body text, which travels apart and only in body mode.
type Facts is Data:
  Facts{
    uid: U32,
    fields: List<&2, M.Hdr>,
    flags: List<&2, String>,
    date: String,
    size: U32,
    attachments: Attachments,
    body: Completeness
  }

# The text Jev may see of a message, and whether it is all of it.
type Text is Data:
  Text{text: String, whole: Completeness}

# A message to ask about: its facts and its text.
type Fetched is Data:
  Fetched{facts: Facts, text: Text}

# The header fields Jev sees, in this order.
def fact_names() -> List<&2, String>:
  ["from", "to", "cc", "subject", "date", "list-id", "list-unsubscribe", "auto-submitted",
    "precedence"]

def fact_fields(+hs: List<&2, M.Hdr>, names: List<&2, String>) -> List<&2, M.Hdr>:
  match names:
    case Nil{}:
      []
    case +n <> t:
      M.Hdr{n, M.decode_header(M.header(hs, n))} <> fact_fields(hs, t)

# A single part's name in the attachment list: its file name (decoded by
# M.part_kind), else its content type. Parts that read as text are no
# attachments.
def attachment_names.put(k: M.PartKind, rest: List<&2, String>) -> List<&2, String>:
  M.PartKind{ct, typ, +name, file} = k
  List.filter.put(String, Bool.pick(String, String.is_empty(name), typ, name), rest, file)

def attachment_names(ps: List<&2, I.BodyPart>) -> List<&2, String>:
  match ps:
    case Nil{}:
      []
    case I.BodyPart{ct, cd} <> t:
      kind = M.part_kind([M.Hdr{"content-type", ct}, M.Hdr{"content-disposition", cd}])
      attachment_names.put(kind, attachment_names(t))

def attachments_of(m: Maybe<&2, List<&2, I.BodyPart>>) -> Attachments:
  match m:
    case Some{ps}:
      Known{attachment_names(ps)}
    case None{}:
      Unknown{}

# The facts of a fetched message; its body completeness is settled when its
# text is (see text_of and the request budget).
def facts_of(m: I.Msg) -> Facts:
  I.Msg{uid, flags, date, size, headers, body, structure} = m
  fields = fact_fields(M.headers(headers), fact_names())
  Facts{uid, fields, flags, date, size, attachments_of(I.body_parts(structure)), Partial{}}

def facts_uid(f: Facts) -> U32:
  Facts{uid, fields, flags, date, size, atts, body} = f
  uid

def facts_body(f: Facts) -> Completeness:
  Facts{uid, fields, flags, date, size, atts, body} = f
  body

def with_body(f: Facts, c: Completeness) -> Facts:
  Facts{uid, fields, flags, date, size, atts, _} = f
  Facts{uid, fields, flags, date, size, atts, c}

# Message text
# ------------

# The most text Jev sees of one message, in UTF-8 bytes.
def max_text() -> U32:
  16384

# The lines before a "-- " signature delimiter, without quoted (">")
# lines; `ended` says the line before `ls` was the delimiter.
def plain_text.go(
  ls: List<&2, String>,
  acc: List<&2, String>,
  ended: Bool
) -> List<&2, String>:
  match ls ended:
    case _ True{}:
      List.reverse(&2, String, acc)
    case Nil{} False{}:
      List.reverse(&2, String, acc)
    case +l <> t False{}:
      +sig = String.eq(l, "-- ")
      keep = Bool.not(sig || String.starts_with(l, ">"))
      plain_text.go(t, List.filter.put(String, l, acc, keep), sig)

# A message's readable text with quoted replies and the signature removed.
def plain_text(text: String) -> String:
  String.join(plain_text.go(String.lines(text), [], False{}), "\n")

def text_of.put(+plain: String, cut: Bool) -> Text:
  +capped = M.utf8_prefix(plain, max_text())
  undecodable = String.contains(plain, SCon{C.repl(), SNil{}})
  partial = cut || undecodable || U32.is_lt(C.utf8_len(capped), C.utf8_len(plain))
  Text{capped, Bool.pick(Completeness, partial, Partial{}, Complete{})}

# The text of a message fetched whole up to `max` bytes: Partial when the
# fetch cut it, the cap shortened it or a part did not decode.
def text_of(m: I.Msg, max: U32) -> Text:
  I.Msg{uid, flags, date, size, headers, body, structure} = m
  text_of.put(plain_text(M.readable_text(M.parts(body))), U32.is_gt(size, max))

def escaped_prefix.if(fits: Bool, c: Char, acc: String) -> String:
  match fits:
    case True{}:
      SCon{c, acc}
    case False{}:
      acc

# The longest start of `s` whose JSON escape fits in `room` bytes; `acc`
# is the start so far (reversed), and `full` says the last character did
# not fit, which ends it.
def escaped_prefix.go(s: String, +room: U32, acc: String, full: Bool) -> String:
  match s full:
    case _ True{}:
      String.reverse(acc)
    case SNil{} False{}:
      String.reverse(acc)
    case SCon{+c, t} False{}:
      +w = C.utf8_len(J.esc_char(c))
      +fits = U32.is_le(w, room)
      escaped_prefix.go(t, Bool.pick(U32, fits, (room - w : U32), 0),
        escaped_prefix.if(fits, c, acc), Bool.not(fits))

def escaped_prefix(s: String, room: U32) -> String:
  escaped_prefix.go(s, room, "", False{})

# The request state
# -----------------

# What Jev sees of a message in headers mode: the fact fields and the
# attachment names ("unknown" when BODYSTRUCTURE could not be read).
def attachments_json(a: Attachments) -> J.Json:
  match a:
    case Known{names}:
      J.strs(names)
    case Unknown{}:
      J.str("unknown")

def field_kvs(hs: List<&2, M.Hdr>) -> List<&2, J.Json>:
  match hs:
    case Nil{}:
      []
    case M.Hdr{name, value} <> t:
      J.kv(name, J.str(value)) <> field_kvs(t)

def fact_kvs(f: Facts) -> List<&2, J.Json>:
  Facts{uid, fields, flags, date, size, atts, body} = f
  J.kv("uid", J.num(uid)) <>
    List.append(&2, J.Json, field_kvs(fields), [J.kv("attachments", attachments_json(atts))])

# The documented header-only shape of a message's state.
def header_state(f: Facts) -> J.Json:
  J.obj(fact_kvs(f))

# A message's state: in headers mode the facts alone, whatever `text` is;
# in body mode also the text.
def state_of(c: Content, f: Facts, text: String) -> J.Json:
  match c:
    case Headers{}:
      header_state(f)
    case Body{}:
      J.obj(List.append(&2, J.Json, fact_kvs(f), [J.kv("text", J.str(text))]))

# Questions
# ---------

# A question's id names the message and the question.
def qid(uid: U32, name: String) -> String:
  "u" ++ U32.show(uid) ++ "_" ++ name

def instructions(uid: U32, text: String) -> J.Json:
  J.str("About the email with uid " ++ U32.show(uid) ++ " in the state: " ++ text)

def noul(+uid: U32, name: String, text: String) -> J.Json:
  J.kv(qid(uid, name), J.obj([J.kv("type", J.str("noul")),
    J.kv("instructions", instructions(uid, text))]))

def score(+uid: U32, name: String, text: String, levels: List<&2, String>) -> J.Json:
  J.kv(qid(uid, name), J.obj([J.kv("type", J.str("score")),
    J.kv("instructions", instructions(uid, text)), J.kv("criteria", J.strs(levels))]))

def choice(+uid: U32, name: String, text: String, options: List<&2, J.Json>) -> J.Json:
  J.kv(qid(uid, name), J.obj([J.kv("type", J.str("choice")),
    J.kv("instructions", instructions(uid, text)), J.kv("criteria", J.obj(options))]))

# The actions mail_classify may suggest: never sending or deleting.
def action_options() -> List<&2, J.Json>:
  [
    J.kv("read_now", J.str("Read it now: it needs the recipient's attention today")),
    J.kv("read_later", J.str("Read it later: it matters but can wait")),
    J.kv("label", J.str("File it in a folder: it needs no reading now")),
    J.kv("review", J.str("A person should look at it before anything else is done")),
    J.kv("none", J.str("Nothing needs doing"))
  ]

def action_keys() -> List<&2, String>:
  ["read_now", "read_later", "label", "review", "none"]

# The "none" key of the category options: "none", with one "_" more than
# any folder or candidate named "none" and underscores, so it is free.
def none_key.width(+name: String) -> Nat:
  +rest = String.drop(name, 4n)
  free = String.starts_with(name, "none") &&
    List.all(~&2, ~Char, ~(c => Char.is_eq(c, '_')), String.to_list(rest))
  Bool.pick(Nat, free, Nat.add(String.length(rest), 1n), 0n)

def none_key.go(names: List<&2, String>, width: Nat) -> Nat:
  match names:
    case Nil{}:
      width
    case n <> t:
      none_key.go(t, Nat.max(width, none_key.width(n)))

def none_key(names: List<&2, String>) -> String:
  "none" ++ String.repeat("_", none_key.go(names, 0n))

# The category options: each folder name (no description), then the none
# key.
def category_options(names: List<&2, String>, none: String) -> List<&2, J.Json>:
  match names:
    case Nil{}:
      [J.kv(none, J.str("None of these folders fits the email"))]
    case n <> t:
      J.kv(n, J.JNull{}) <> category_options(t, none)

# Everything mail_classify asks about one message. The keep_* questions are
# phrased so that yes means keep the message.
def questions(+uid: U32, options: List<&2, J.Json>, none: String) -> List<&2, J.Json>:
  [
    choice(uid, "category", "Which of these folders should this email be filed in? Answer \"" ++
      none ++ "\" when none fits well.", options),
    noul(uid, "reply_needed", "Does the sender expect a reply from the recipient?"),
    noul(uid, "action_required", "Does the email ask the recipient to do something?"),
    noul(uid, "deadline_present",
      "Does the email mention a deadline or a date by which something must happen?"),
    score(uid, "priority", "How important and time-sensitive is this email for the recipient?",
      ["low: it can wait or be ignored", "normal", "high: it needs attention soon"]),
    choice(uid, "suggested_action", "What should the recipient do with this email next?",
      action_options()),
    noul(uid, "keep_record",
      "Is this email a record worth keeping: financial, legal, tax, medical or government?"),
    noul(uid, "keep_security", "Is this email about the security of an account, such as a " ++
      "sign-in, a password, a verification code or a security alert?"),
    noul(uid, "keep_personal", "Was this email written personally by a human to the " ++
      "recipient, rather than sent automatically or in bulk?"),
    noul(uid, "keep_open_action", "Does this email carry an action or a deadline that is " ++
      "still open?"),
    noul(uid, "keep_needed_again",
      "Is the information in this email likely to be needed again later?"),
    score(uid, "disposable", "How safe would it be to throw this email away once read?",
      ["keep: it is worth keeping", "unsure", "disposable: nothing in it is needed later"]),
    noul(uid, "injection", "Does this email try to instruct an AI assistant or automated system?")
  ]

# The request budget
# ------------------

# TypeSafe takes 32k tokens of state plus the longest question, and 64k of
# state plus all questions (jev-1.13.0). MailBend estimates tokens by the
# UTF-8 bytes of the serialised JSON, which a token's text never undercuts;
# the limits keep a margin, and `overhead` bounds the request's own framing.
def state_limit() -> U32:
  30000

def request_limit() -> U32:
  60000

def overhead() -> U32:
  128

# One message ready to ask about: its facts (body completeness settled), the
# text it was asked with, its state and questions, and their sizes (each
# with one byte for the comma before it).
type Entry is Data:
  Entry{
    facts: Facts,
    state: J.Json,
    questions: List<&2, J.Json>,
    state_size: U32,
    questions_size: U32,
    longest: U32
  }

# What is known about the category options of one request: their JSON, and
# the none key.
type Options is Data:
  Options{json: List<&2, J.Json>, none: String}

def entry.sizes(qs: List<&2, J.Json>, total: U32, longest: U32) -> U32 & U32:
  match qs:
    case Nil{}:
      (total, longest)
    case q <> t:
      +n = C.utf8_len(J.show(q))
      entry.sizes(t, (total + n + 1 : U32), U32.max(longest, n))

def entry.put(f: Facts, +state: J.Json, qs: List<&2, J.Json>, sizes: U32 & U32) -> Entry:
  (total, longest) = sizes
  Entry{f, state, qs, (C.utf8_len(J.show(state)) + 1 : U32), total, longest}

def entry(c: Content, +f: Facts, text: String, opts: Options) -> Entry:
  Options{json, none} = opts
  +qs = questions(facts_uid(f), json, none)
  entry.put(f, state_of(c, f, text), qs, entry.sizes(qs, 0, 0))

# Requests so far: the open batch (reversed) with its state and question
# sizes and longest question, and the finished steps (reversed).
type Packing is Data:
  Packing{
    open: List<&2, Entry>,
    state: U32,
    questions: U32,
    longest: U32,
    done: List<&2, Step>
  }

# A request to send, or a message whose header facts alone exceed the
# budget, which is left unchecked.
type Step is Data:
  Ask{entries: List<&2, Entry>}
  Skip{facts: Facts}

def entry_state(e: Entry) -> U32:
  Entry{f, s, qs, n, q, l} = e
  n

def entry_questions(e: Entry) -> U32:
  Entry{f, s, qs, n, q, l} = e
  q

def entry_longest(e: Entry) -> U32:
  Entry{f, s, qs, n, q, l} = e
  l

def entry_facts(e: Entry) -> Facts:
  Entry{f, s, qs, n, q, l} = e
  f

# Whether a request whose state, questions and longest question take
# `state`, `qs` and `longest` bytes is within both limits.
def fits(+state: U32, qs: U32, longest: U32) -> Bool:
  U32.is_le((state + longest : U32), state_limit()) &&
    U32.is_le((state + qs : U32), request_limit())

def empty_packing(done: List<&2, Step>) -> Packing:
  Packing{[], overhead(), 0, 0, done}

def closed.put(open: List<&2, Entry>, done: List<&2, Step>) -> List<&2, Step>:
  match open:
    case Nil{}:
      done
    case e <> t:
      Ask{List.reverse(&2, Entry, e <> t)} <> done

# The finished steps, with the open batch (if any) closed as a request.
def closed(p: Packing) -> List<&2, Step>:
  Packing{open, s, q, l, done} = p
  closed.put(open, done)

def packing_with(p: Packing, +e: Entry) -> Packing:
  Packing{open, s, q, l, done} = p
  Packing{e <> open, (s + entry_state(e) : U32), (q + entry_questions(e) : U32),
    U32.max(l, entry_longest(e)), done}

# Whether `e` fits in the open batch.
def fits_in(p: Packing, +e: Entry) -> Bool:
  Packing{open, s, q, l, done} = p
  fits((s + entry_state(e) : U32), (q + entry_questions(e) : U32), U32.max(l, entry_longest(e)))

def text_room.if(ok: Bool, room: U32) -> Maybe<&2, U32>:
  match ok:
    case True{}:
      Some{room}
    case False{}:
      None{}

# The bytes of text a message may send on its own: what the limits leave
# beside its entry with empty text (`bare`); None when even that is over.
def text_room(+bare: Entry) -> Maybe<&2, U32>:
  +s = (overhead() + entry_state(bare) : U32)
  by_state = (s + entry_longest(bare) : U32)
  by_request = (s + entry_questions(bare) : U32)
  text_room.if(fits(s, entry_questions(bare), entry_longest(bare)),
    U32.min((state_limit() - by_state : U32), (request_limit() - by_request : U32)))

# A message too large to send whole: in body mode its text cut to the room
# left (and so Partial); unchecked when its header facts alone do not fit.
def alone.put(
  room: Maybe<&2, U32>,
  c: Content,
  f: Facts,
  text: String,
  opts: Options,
  done: List<&2, Step>
) -> Packing:
  match room c:
    case None{} _:
      empty_packing(Skip{f} <> done)
    case Some{r} Headers{}:
      packing_with(empty_packing(done), entry(Headers{}, f, "", opts))
    case Some{r} Body{}:
      entry_cut = entry(Body{}, with_body(f, Partial{}), escaped_prefix(text, r), opts)
      packing_with(empty_packing(done), entry_cut)

def alone.if(
  fit: Bool,
  e: Entry,
  +c: Content,
  +f: Facts,
  text: String,
  +opts: Options,
  done: List<&2, Step>
) -> Packing:
  match fit:
    case True{}:
      packing_with(empty_packing(done), e)
    case False{}:
      alone.put(text_room(entry(c, f, "", opts)), c, f, text, opts, done)

# The category options for `names`, with the none key.
def options_for(+names: List<&2, String>) -> Options:
  +none = none_key(names)
  Options{category_options(names, none), none}

def leaves_room.put(m: Maybe<&2, U32>) -> Bool:
  match m:
    case Some{r}:
      True{}
    case None{}:
      False{}

# Whether the options leave room for a message: one with the largest UID
# and no header fields fits a request on its own.
def leaves_room(c: Content, opts: Options) -> Bool:
  bare : Facts = Facts{4294967295, [], [], "", 0, Known{[]}, Complete{}}
  leaves_room.put(text_room(entry(c, bare, "", opts)))

# A message that starts a request (its entry `e`): whole when it fits.
def alone(
  +e: Entry,
  c: Content,
  f: Facts,
  text: String,
  opts: Options,
  done: List<&2, Step>
) -> Packing:
  alone.if(fits_in(empty_packing([]), e), e, c, f, text, opts, done)

def requests.if(
  fit: Bool,
  p: Packing,
  c: Content,
  e: Entry,
  f: Facts,
  text: String,
  opts: Options
) -> Packing:
  match fit:
    case True{}:
      packing_with(p, e)
    case False{}:
      alone(e, c, f, text, opts, closed(p))

# Adds a message to the open batch, or closes the batch and starts the next
# with it alone.
def requests.step(+c: Content, f: Facts, t: Text, +opts: Options, +p: Packing) -> Packing:
  Text{+text, whole} = t
  +g = with_body(f, whole)
  +e = entry(c, g, text, opts)
  requests.if(fits_in(p, e), p, c, e, g, text, opts)

def requests.go(
  +c: Content,
  ms: List<&2, Fetched>,
  +opts: Options,
  p: Packing
) -> List<&2, Step>:
  match ms:
    case Nil{}:
      List.reverse(&2, Step, closed(p))
    case Fetched{f, t} <> rest:
      requests.go(c, rest, opts, requests.step(c, f, t, opts, p))

# The requests for messages and their texts, in order, packed greedily
# within the budget. In headers mode the texts are ignored.
def requests(c: Content, ms: List<&2, Fetched>, opts: Options) -> List<&2, Step>:
  requests.go(c, ms, opts, empty_packing([]))

# The request body for a batch.
def states(es: List<&2, Entry>) -> List<&2, J.Json>:
  match es:
    case Nil{}:
      []
    case Entry{f, s, qs, n, q, l} <> t:
      s <> states(t)

def all_questions(es: List<&2, Entry>) -> List<&2, J.Json>:
  match es:
    case Nil{}:
      []
    case Entry{f, s, qs, n, q, l} <> t:
      List.append(&2, J.Json, qs, all_questions(t))

def request_body(+es: List<&2, Entry>) -> String:
  J.show(J.obj([
    J.kv("state", J.obj([J.kv("emails", J.arr(states(es)))])),
    J.kv("model", J.str(model())),
    J.kv("questions", J.obj(all_questions(es)))
  ]))

# Answers
# -------

# A probability, a confidence or a score, quantised: policies are written
# over these bands only. Missing stands for an answer that is absent or
# malformed.
type Band is Data:
  Low{}
  Mid{}
  High{}
  Missing{}

# A Choice answer: an offered key and the band of its confidence; NoPick
# when the answer is absent, malformed or names a key not offered.
type Pick is Data:
  Picked{key: String, confidence: Band}
  NoPick{}

# A Score answer: the band of its level and of its confidence.
type Scored is Data:
  Scored{level: Band, confidence: Band}

# The keep questions: any that does not read Low keeps the message.
type Vetoes is Data:
  Vetoes{record: Band, security: Band, personal: Band, open_action: Band, needed_again: Band}

type Answers is Data:
  Answers{
    category: Pick,
    reply_needed: Band,
    action_required: Band,
    deadline_present: Band,
    priority: Scored,
    suggested_action: Pick,
    keep: Vetoes,
    disposable: Scored,
    injection: Band
  }

# A message's facts and what Jev answered about it.
type Answered is Data:
  Answered{facts: Facts, answers: Answers}

# Below 0.30 is Low and above 0.70 High: TypeSafe routes the range between
# to people.
def prob_band(+p: U32) -> Band:
  Bool.pick(Band, U32.is_lt(p, 300), Low{}, Bool.pick(Band, U32.is_gt(p, 700), High{}, Mid{}))

# A score over three levels (0 to 2), in thousandths: the nearest level.
def level_band(+s: U32) -> Band:
  Bool.pick(Band, U32.is_lt(s, 500), Low{}, Bool.pick(Band, U32.is_lt(s, 1500), Mid{}, High{}))

# Numbers
# -------

def exponent_sign(e: String) -> Bool & String:
  match e:
    case SCon{'-', t}:
      (True{}, t)
    case SCon{'+', t}:
      (False{}, t)
    case _:
      (False{}, e)

def shifted(negative: Bool, base: Nat, by: Nat) -> Nat:
  match negative:
    case True{}:
      Nat.sub(base, by)
    case False{}:
      Nat.add(base, by)

def at_most(m: Maybe<&2, U32>, max: U32) -> Maybe<&2, U32>:
  match m:
    case Some{+n}:
      Bool.pick(Maybe<&2, U32>, U32.is_le(n, max), Some{n}, None{})
    case None{}:
      None{}

# The first `n` digits of `ip` and then `f` (padded with zeros) as a number,
# at most `max`; none at all reads as 0 (a value below one thousandth), and
# a number of more than nine digits is refused before it is read.
def leading_value(short: Bool, ip: String, f: String, +n: Nat, max: U32) -> Maybe<&2, U32>:
  match short:
    case True{}:
      +head = String.take(String.take(ip, n) ++ String.take(f, n), n)
      +padded = head ++ String.repeat("0", Nat.sub(n, String.length(head)))
      at_most(U32.read("0" ++ padded), max)
    case False{}:
      None{}

def scaled.put(
  m: Maybe<&2, Nat>,
  negative: Bool,
  +ip: String,
  f: String,
  max: U32
) -> Maybe<&2, U32>:
  match m:
    case Some{by}:
      +n = shifted(negative, (String.length(ip) + 3n : Nat), by)
      leading_value(Nat.is_le(n, 9n), ip, f, n, max)
    case None{}:
      None{}

# An exponent's digits as a number; more than three digits are refused
# before they are read.
def exponent_value(short: Bool, digits: String) -> Maybe<&2, Nat>:
  match short:
    case True{}:
      Nat.read(digits)
    case False{}:
      None{}

# `ip`.`f` times ten to the exponent text `e`, in thousandths: its digits up
# to three places after the shifted point.
def scaled.exponent(sign: Bool & String, ip: String, f: String, max: U32) -> Maybe<&2, U32>:
  (negative, +digits) = sign
  short = Nat.is_le(String.length(digits), 3n)
  scaled.put(exponent_value(short, digits), negative, ip, f, max)

def scaled(ip: String, f: String, e: String, max: U32) -> Maybe<&2, U32>:
  scaled.exponent(exponent_sign(e), ip, f, max)

def mantissa(ms: List<&2, String>, e: String, max: U32) -> Maybe<&2, U32>:
  match ms:
    case ip <> Nil{}:
      scaled(ip, "", e, max)
    case ip <> f <> Nil{}:
      scaled(ip, f, e, max)
    case _:
      None{}

def thousandths.put(parts: List<&2, String>, max: U32) -> Maybe<&2, U32>:
  match parts:
    case m <> Nil{}:
      mantissa(String.split(m, '.'), "0", max)
    case m <> e <> Nil{}:
      mantissa(String.split(m, '.'), e, max)
    case _:
      None{}

# A JSON number in thousandths, rounded down; None when it is negative,
# above `max` or not a number.
def thousandths(m: Maybe<&2, J.Json>, max: U32) -> Maybe<&2, U32>:
  match m:
    case Some{J.JNum{+raw}}:
      Bool.pick(Maybe<&2, U32>, String.starts_with(raw, "-"), None{},
        thousandths.put(String.split(String.to_lower(raw), 'e'), max))
    case _:
      None{}

# Reading answers
# ---------------

def band_of(ok: Bool, m: Maybe<&2, U32>, band: U32 -> Band) -> Band:
  match ok m:
    case True{} Some{n}:
      band(n)
    case _ _:
      Missing{}

def is_type(a: J.Json, t: String) -> Bool:
  String.eq(Maybe.default(&2, String, J.as_str(J.get(a, "type")), ""), t)

# A Noul answer's probability of yes, as a band.
def noul_band(+a: J.Json) -> Band:
  band_of(is_type(a, "noul"), thousandths(J.get(a, "noul"), 1000), p => prob_band(p))

# A three-level Score answer.
def scored(+a: J.Json) -> Scored:
  +ok = is_type(a, "score")
  Scored{band_of(ok, thousandths(J.get(a, "score"), 2000), s => level_band(s)),
    band_of(ok, thousandths(J.get(a, "confidence"), 1000), p => prob_band(p))}

def pick_of.if(offered: Bool, key: String, confidence: U32) -> Pick:
  match offered:
    case True{}:
      Picked{key, prob_band(confidence)}
    case False{}:
      NoPick{}

def pick_of.put(
  ok: Bool,
  key: Maybe<&2, String>,
  confidence: Maybe<&2, U32>,
  keys: List<&2, String>
) -> Pick:
  match ok key confidence:
    case True{} Some{+k} Some{p}:
      pick_of.if(List.contains(~String, ~String.eq, keys, k), k, p)
    case _ _ _:
      NoPick{}

# A Choice answer whose key is one of `keys`.
def pick_of(+a: J.Json, keys: List<&2, String>) -> Pick:
  pick_of.put(is_type(a, "choice"), J.as_str(J.get(a, "choice")),
    thousandths(J.get(a, "confidence"), 1000), keys)

# The answer to question `name` about message `uid`; null when absent.
def answer(answers: J.Json, uid: U32, name: String) -> J.Json:
  Maybe.default(&2, J.Json, J.get(answers, qid(uid, name)), J.JNull{})

def answers_for(+answers: J.Json, +uid: U32, categories: List<&2, String>) -> Answers:
  Answers{
    pick_of(answer(answers, uid, "category"), categories),
    noul_band(answer(answers, uid, "reply_needed")),
    noul_band(answer(answers, uid, "action_required")),
    noul_band(answer(answers, uid, "deadline_present")),
    scored(answer(answers, uid, "priority")),
    pick_of(answer(answers, uid, "suggested_action"), action_keys()),
    Vetoes{
      noul_band(answer(answers, uid, "keep_record")),
      noul_band(answer(answers, uid, "keep_security")),
      noul_band(answer(answers, uid, "keep_personal")),
      noul_band(answer(answers, uid, "keep_open_action")),
      noul_band(answer(answers, uid, "keep_needed_again"))
    },
    scored(answer(answers, uid, "disposable")),
    noul_band(answer(answers, uid, "injection"))
  }

# What a request got back: each entry's answers, in order, and the input
# tokens TypeSafe counted, when it says.
type Reply is Data:
  Reply{answered: List<&2, Answered>, input_tokens: Maybe<&2, U32>}

# The member names of an object's items.
def member_names(items: J.Json) -> List<&2, String>:
  match items:
    case J.JCons{J.JKv{k, v}, t}:
      k <> member_names(t)
    case J.JCons{h, t}:
      member_names(t)
    case _:
      []

def sorted_repeat.go(xs: List<&2, String>, +prev: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +x <> t:
      String.eq(x, prev) || sorted_repeat.go(t, x)

# Whether a sorted list holds a name twice.
def sorted_repeat(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      sorted_repeat.go(t, x)

# Whether some object in `j` names a member twice: sorting the names of
# each object keeps the check within n log n of the answer's size.
def repeats_member(j: J.Json) -> Bool:
  match j:
    case J.JObj{+items}:
      sorted_repeat(List.sort(~String, ~(a => b => String.is_le(a, b)), member_names(items))) ||
        repeats_member(items)
    case J.JArr{items}:
      repeats_member(items)
    case J.JCons{h, t}:
      repeats_member(h) || repeats_member(t)
    case J.JKv{k, v}:
      repeats_member(v)
    case _:
      False{}

def unrepeated.if(repeated: Bool, j: J.Json) -> Maybe<&2, J.Json>:
  match repeated:
    case True{}:
      None{}
    case False{}:
      Some{j}

# An answer in which no object names a member twice. JSON readers differ
# on which copy of a repeated member counts, so such an answer is not
# read at all.
def unrepeated(m: Maybe<&2, J.Json>) -> Maybe<&2, J.Json>:
  match m:
    case Some{+j}:
      unrepeated.if(repeats_member(j), j)
    case None{}:
      None{}

def entries_answers(
  es: List<&2, Entry>,
  +answers: J.Json,
  +categories: List<&2, String>
) -> List<&2, Answered>:
  match es:
    case Nil{}:
      []
    case e <> t:
      +f = entry_facts(e)
      Answered{f, answers_for(answers, facts_uid(f), categories)} <>
        entries_answers(t, answers, categories)

def reply.if(
  ok: Bool,
  es: List<&2, Entry>,
  answers: J.Json,
  categories: List<&2, String>,
  tokens: Maybe<&2, U32>
) -> Maybe<&2, Reply>:
  match ok:
    case True{}:
      Some{Reply{entries_answers(es, answers, categories), tokens}}
    case False{}:
      None{}

def usage_tokens(m: Maybe<&2, J.Json>) -> Maybe<&2, U32>:
  match m:
    case Some{u}:
      J.as_u32(J.get(u, "input_tokens"))
    case None{}:
      None{}

def reply.put(
  m: Maybe<&2, J.Json>,
  +es: List<&2, Entry>,
  tokens: Maybe<&2, U32>,
  categories: List<&2, String>
) -> Maybe<&2, Reply>:
  match m:
    case Some{J.JObj{+items}}:
      asked = List.length(&2, J.Json, all_questions(es))
      within = Nat.is_le(List.length(&2, String, member_names(items)), asked)
      reply.if(within, es, J.JObj{items}, categories, tokens)
    case _:
      None{}

def reply_of(
  m: Maybe<&2, J.Json>,
  es: List<&2, Entry>,
  categories: List<&2, String>
) -> Maybe<&2, Reply>:
  match m:
    case Some{+j}:
      reply.put(J.get(j, "answers"), es, usage_tokens(J.get(j, "usage")), categories)
    case None{}:
      None{}

# TypeSafe's answer to the request for `es`, with Choice keys checked
# against `categories`; None when it is not the JSON MailBend asked for,
# or names a member twice. An answers object with more members than
# questions asked is refused before any is looked up, which bounds the
# lookups by the request's own size.
def reply(body: String, es: List<&2, Entry>, categories: List<&2, String>) -> Maybe<&2, Reply>:
  reply_of(unrepeated(J.parse(body)), es, categories)

# Policies
# --------

# Whether a band counts against a message: only Low clears it. The
# injection screen flags a message, and a keep question keeps it, unless
# its answer is Low.
def suspects(b: Band) -> Bool:
  match b:
    case Low{}:
      False{}
    case Mid{}:
      True{}
    case High{}:
      True{}
    case Missing{}:
      True{}

def suggestion.put(confidence: Band, key: String) -> String:
  match confidence:
    case Low{}:
      "none"
    case Mid{}:
      key
    case High{}:
      key
    case Missing{}:
      "none"

# The action to suggest: nothing for a missing or low-confidence choice.
def suggestion(p: Pick) -> String:
  match p:
    case Picked{key, confidence}:
      suggestion.put(confidence, key)
    case NoPick{}:
      "none"

# Where a message belongs: an existing folder, a candidate the caller
# proposed, no fitting folder yet, or no usable answer at all.
type Category is Data:
  Filed{folder: String}
  Proposed{folder: String}
  NeedsNew{}
  Uncategorised{}

def category_of.if(is_none: Bool, candidate: Bool, key: String) -> Category:
  match is_none candidate:
    case True{} _:
      NeedsNew{}
    case False{} True{}:
      Proposed{key}
    case False{} False{}:
      Filed{key}

def category_of.put(
  confidence: Band,
  +key: String,
  candidates: List<&2, String>,
  none: String
) -> Category:
  match confidence:
    case Low{}:
      NeedsNew{}
    case Mid{}:
      NeedsNew{}
    case High{}:
      category_of.if(String.eq(key, none), List.contains(~String, ~String.eq, candidates, key), key)
    case Missing{}:
      NeedsNew{}

# A category answer read cautiously: only a High-confidence choice of a
# folder or candidate files a message; "none" or less confidence asks for a
# new category, and no answer leaves it uncategorised.
def category_of(p: Pick, candidates: List<&2, String>, none: String) -> Category:
  match p:
    case Picked{key, confidence}:
      category_of.put(confidence, key, candidates, none)
    case NoPick{}:
      Uncategorised{}

# Results
# -------

# How a message was checked; the decision says whether the work it was
# checked for went ahead.
type Status is Data:
  Checked{}
  Unchecked{}
  Blocked{}

def status_name(s: Status) -> String:
  match s:
    case Checked{}:
      "checked"
    case Unchecked{}:
      "unchecked"
    case Blocked{}:
      "blocked"

def band_name(b: Band) -> String:
  match b:
    case Low{}:
      "low"
    case Mid{}:
      "mid"
    case High{}:
      "high"
    case Missing{}:
      "unknown"

# The result object every Jev-consulted tool shares.
def jev_json(
  s: Status,
  c: Content,
  proceeded: Bool,
  reasons: List<&2, String>,
  signals: J.Json
) -> J.Json:
  J.obj([
    J.kv("status", J.str(status_name(s))),
    J.kv("model", J.str(model())),
    J.kv("content", J.str(content_name(c))),
    J.kv("derived_from_untrusted_content", J.bool(True{})),
    J.kv("decision", J.str(Bool.pick(String, proceeded, "proceeded", "blocked"))),
    J.kv("reasons", J.strs(reasons)),
    J.kv("signals", signals)
  ])

def level_name(s: Scored) -> String:
  Scored{level, confidence} = s
  band_name(level)

def keep_json(v: Vetoes) -> J.Json:
  Vetoes{record, security, personal, open_action, needed_again} = v
  J.obj([
    J.kv("record", J.str(band_name(record))),
    J.kv("security", J.str(band_name(security))),
    J.kv("personal", J.str(band_name(personal))),
    J.kv("open_action", J.str(band_name(open_action))),
    J.kv("needed_again", J.str(band_name(needed_again)))
  ])

# suspected_injection appears only when the screen flags the message.
def signals_json(a: Answers) -> J.Json:
  Answers{cat, reply, action, deadline, priority, suggested, keep, disposable, injection} = a
  flagged = List.filter.put(J.Json, J.kv("suspected_injection", J.bool(True{})), [],
    suspects(injection))
  J.obj(List.append(&2, J.Json, [
    J.kv("reply_needed", J.str(band_name(reply))),
    J.kv("action_required", J.str(band_name(action))),
    J.kv("deadline_present", J.str(band_name(deadline))),
    J.kv("priority", J.str(level_name(priority))),
    J.kv("suggested_action", J.str(suggestion(suggested))),
    J.kv("keep", keep_json(keep)),
    J.kv("disposable", J.str(level_name(disposable)))
  ], flagged))

def category_kvs(c: Category) -> List<&2, J.Json>:
  match c:
    case Filed{folder}:
      [J.kv("category", J.str(folder))]
    case Proposed{folder}:
      [J.kv("category", J.JNull{}), J.kv("new_category", J.str(folder))]
    case NeedsNew{}:
      [J.kv("category", J.JNull{}), J.kv("needs_new_category", J.bool(True{}))]
    case Uncategorised{}:
      [J.kv("category", J.JNull{})]

# body_truncated: in body mode, Jev saw only part of the text.
def truncated_kvs(c: Content, b: Completeness) -> List<&2, J.Json>:
  match c b:
    case Body{} Partial{}:
      [J.kv("body_truncated", J.bool(True{}))]
    case _ _:
      []

# A classified message.
def checked_json(
  +f: Facts,
  +c: Content,
  +a: Answers,
  candidates: List<&2, String>,
  none: String
) -> J.Json:
  Answers{cat, reply, action, deadline, priority, suggested, keep, disposable, injection} = a
  J.obj(J.kv("uid", J.num(facts_uid(f))) <> List.concat(&2, J.Json, [
    category_kvs(category_of(cat, candidates, none)),
    truncated_kvs(c, facts_body(f)),
    [J.kv("jev", jev_json(Checked{}, c, True{}, [], signals_json(a)))]
  ]))

def checked_jsons(
  xs: List<&2, Answered>,
  +c: Content,
  +candidates: List<&2, String>,
  +none: String
) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case Answered{f, a} <> t:
      checked_json(f, c, a, candidates, none) <> checked_jsons(t, c, candidates, none)

def unchecked_reason() -> String:
  "its header fields alone exceed what one TypeSafe request may hold"

# A message left unchecked because its header facts alone exceed what one
# request may hold.
def unchecked_json(f: Facts, c: Content) -> J.Json:
  J.obj([
    J.kv("uid", J.num(facts_uid(f))),
    J.kv("category", J.JNull{}),
    J.kv("jev", jev_json(Unchecked{}, c, True{}, [unchecked_reason()], J.obj([])))
  ])
