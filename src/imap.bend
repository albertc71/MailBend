# IMAP commands as data, their wire form, and the parsing of server
# transcripts. The helper (native/mailbend-tls/) logs in and out; the
# commands here are everything in between.

import Base
import ./codec.bend as C

# The command model
# -----------------

type Flag is Data:
  FSeen{}
  FDeleted{}
  FDraft{}
  FFlagged{}
  FAnswered{}
  FColourBit0{}
  FColourBit1{}
  FColourBit2{}

# Apple Mail's flag colours: a 3-bit index over $MailFlagBit0..2, meaningful
# only while \Flagged is set.
type Colour is Data:
  ColRed{}
  ColOrange{}
  ColYellow{}
  ColGreen{}
  ColBlue{}
  ColPurple{}
  ColGrey{}

# Which of $MailFlagBit0..2 a colour sets.
type Bits is Data:
  Bits{b0: Bool, b1: Bool, b2: Bool}

# Search keys. Strings are matched by the server (substring, case-insensitive
# for ASCII); dates are IMAP dates such as "1-Feb-2026".
type Key is Data:
  KAll{}
  KFrom{s: String}
  KTo{s: String}
  KCc{s: String}
  KSubject{s: String}
  KBody{s: String}
  KText{s: String}
  KSince{d: String}
  KBefore{d: String}
  KSeen{}
  KUnseen{}
  KFlagged{}
  KUnflagged{}
  KUndeleted{}
  KHeader{name: String, value: String}
  KUidFrom{n: U32}
  KUids{uids: List<&2, U32>}

# Fetch items. None of them can set \Seen: message content is only ever
# fetched with BODY.PEEK.
type Item is Data:
  IUid{}
  IFlags{}
  IDate{}
  ISize{}
  IHeaders{}
  IFull{max: U32}

type Cmd is Data:
  CCapability{}
  CList{}
  CListRoles{}
  CLsub{}
  CExamine{mbox: String}
  CSelect{mbox: String}
  CSearch{keys: List<&2, Key>}
  CFetch{uids: List<&2, U32>, items: List<&2, Item>}
  CStore{uids: List<&2, U32>, add: Bool, flag: Flag}
  CCopy{uids: List<&2, U32>, dest: String}
  CMove{uids: List<&2, U32>, dest: String}
  CExpunge{uids: List<&2, U32>}
  CCreate{mbox: String}
  CRename{from: String, to: String}
  CSubscribe{mbox: String}
  CUnsubscribe{mbox: String}
  CAppend{mbox: String, flags: List<&2, Flag>, msg: String}
  CExpect{text: String}
  CExpectWord{word: String}

# Effects
# -------

# What a command does to the account. Every command is named in `effect`,
# with no catch-all case, so a new command cannot be added without deciding
# how the laws see it.
type Effect is Data:
  ENone{}
  ESelect{}
  EMail{}
  ECopy{}
  EExpunge{}
  EFolder{}

# ENone: reads and expectations. ESelect: opens a mailbox read-write.
# EMail: flags, moves or appends messages. ECopy: adds copies. EExpunge:
# permanently removes messages. EFolder: creates, renames, subscribes or
# unsubscribes a folder.
def effect(c: Cmd) -> Effect:
  match c:
    case CCapability{}:
      ENone{}
    case CList{}:
      ENone{}
    case CListRoles{}:
      ENone{}
    case CLsub{}:
      ENone{}
    case CExamine{m}:
      ENone{}
    case CSelect{m}:
      ESelect{}
    case CSearch{k}:
      ENone{}
    case CFetch{u, i}:
      ENone{}
    case CStore{u, a, f}:
      EMail{}
    case CCopy{u, d}:
      ECopy{}
    case CMove{u, d}:
      EMail{}
    case CExpunge{u}:
      EExpunge{}
    case CCreate{m}:
      EFolder{}
    case CRename{a, b}:
      EFolder{}
    case CSubscribe{m}:
      EFolder{}
    case CUnsubscribe{m}:
      EFolder{}
    case CAppend{m, f, b}:
      EMail{}
    case CExpect{e}:
      ENone{}
    case CExpectWord{w}:
      ENone{}

# Whether an effect can change the mailbox: EXAMINE, SEARCH and FETCH cannot.
def writes(e: Effect) -> Bool:
  match e:
    case ENone{}:
      False{}
    case ESelect{}:
      True{}
    case EMail{}:
      True{}
    case ECopy{}:
      True{}
    case EExpunge{}:
      True{}
    case EFolder{}:
      True{}

# The predicates below name every Effect, with no catch-all case, so a new
# kind of effect must be classified here too.

# Whether an effect adds, removes or flags messages.
def changes_mail(e: Effect) -> Bool:
  match e:
    case ENone{}:
      False{}
    case ESelect{}:
      False{}
    case EMail{}:
      True{}
    case ECopy{}:
      True{}
    case EExpunge{}:
      True{}
    case EFolder{}:
      False{}

# Whether an effect creates, renames, subscribes or unsubscribes a folder.
def changes_mailbox(e: Effect) -> Bool:
  match e:
    case ENone{}:
      False{}
    case ESelect{}:
      False{}
    case EMail{}:
      False{}
    case ECopy{}:
      False{}
    case EExpunge{}:
      False{}
    case EFolder{}:
      True{}

# Whether an effect permanently removes messages: only UID EXPUNGE does.
def destroys_mail(e: Effect) -> Bool:
  match e:
    case ENone{}:
      False{}
    case ESelect{}:
      False{}
    case EMail{}:
      False{}
    case ECopy{}:
      False{}
    case EExpunge{}:
      True{}
    case EFolder{}:
      False{}

# Whether an effect only adds copies of messages: UID COPY.
def copies_mail(e: Effect) -> Bool:
  match e:
    case ENone{}:
      False{}
    case ESelect{}:
      False{}
    case EMail{}:
      False{}
    case ECopy{}:
      True{}
    case EExpunge{}:
      False{}
    case EFolder{}:
      False{}

# Whether a command permanently removes messages (UID EXPUNGE).
def expunges(c: Cmd) -> Bool:
  destroys_mail(effect(c))

# Whether a command marks messages \Deleted.
def marks_deleted(c: Cmd) -> Bool:
  match c:
    case CStore{u, add, FDeleted{}}:
      add
    case _:
      False{}

def any_writes(cs: List<&2, Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      writes(effect(c)) || any_writes(t)

def any_expunges(cs: List<&2, Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      expunges(c) || any_expunges(t)

def any_marks_deleted(cs: List<&2, Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      marks_deleted(c) || any_marks_deleted(t)

# Modified UTF-7 mailbox names (RFC 3501 5.1.3)
# ---------------------------------------------

# Encoding so far: the finished text and the pending run of non-ASCII text
# as UTF-16BE bytes, both reversed.
type Utf7Encoder is Data:
  Utf7Encoder{out: String, run: String}

# Decoding so far: the finished text and the pending base64, both reversed,
# and whether the input is inside a "&...-" run.
type Utf7Decoder is Data:
  Utf7Decoder{out: String, b64: String, shifted: Bool}

# A code point past U+FFFF as a UTF-16BE surrogate pair.
def utf16be.pair(+m: U32) -> String:
  +hi = (55296 + (m >> 10n) : U32)
  +lo = (56320 + (m .&. 1023) : U32)
  SCon{C.chr((hi >> 8n : U32)), SCon{C.chr((hi .&. 255 : U32)),
    SCon{C.chr((lo >> 8n : U32)), SCon{C.chr((lo .&. 255 : U32)), SNil{}}}}}

def utf16be.if(bmp: Bool, +n: U32) -> String:
  match bmp:
    case True{}:
      SCon{C.chr((n >> 8n : U32)), SCon{C.chr((n .&. 255 : U32)), SNil{}}}
    case False{}:
      utf16be.pair((n - 65536 : U32))

# A code point as UTF-16BE bytes.
def utf16be(+n: U32) -> String:
  utf16be.if(U32.is_lt(n, 65536), n)

# `out` with the pending run, if any, closed as "&<base64>-".
def mutf7_encode.flush(out: String, +run: String) -> String:
  match run:
    case SNil{}:
      out
    case SCon{h, t}:
      String.reverse("&" ++ C.b64_encode(String.reverse(run), True{}) ++ "-") ++ out

# A printable ASCII character, reversed: "&" is escaped as "&-".
def mutf7_encode.ascii(+c: Char) -> String:
  match c:
    case '&':
      "-&"
    case _:
      SCon{c, SNil{}}

def mutf7_encode.put(
  printable: Bool,
  c: Char,
  out: String,
  run: String
) -> Utf7Encoder:
  match printable:
    case True{}:
      Utf7Encoder{mutf7_encode.ascii(c) ++ mutf7_encode.flush(out, run), ""}
    case False{}:
      Utf7Encoder{out, String.reverse(utf16be(C.u(c))) ++ run}

def mutf7_encode.step(+c: Char, st: Utf7Encoder) -> Utf7Encoder:
  Utf7Encoder{out, run} = st
  mutf7_encode.put(C.between(C.u(c), 32, 126), c, out, run)

def mutf7_encode.go(s: String, st: Utf7Encoder) -> Utf7Encoder:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      mutf7_encode.go(t, mutf7_encode.step(c, st))

def mutf7_encode.finish(st: Utf7Encoder) -> String:
  Utf7Encoder{out, run} = st
  String.reverse(mutf7_encode.flush(out, run))

# Mailbox name to its modified UTF-7 wire form.
def mutf7_encode(name: String) -> String:
  mutf7_encode.finish(mutf7_encode.go(name, Utf7Encoder{"", ""}))

# `out` with U+FFFD for the unpaired high surrogate `hi`, if any (0 is none).
def utf16_decode.unpaired(hi: U32, +out: String) -> String:
  Bool.pick(String, U32.is_zero(hi), out, SCon{C.repl(), out})

def utf16_decode.char(bad: Bool, n: U32, out: String) -> String:
  match bad:
    case True{}:
      SCon{C.repl(), out}
    case False{}:
      SCon{C.chr(n), out}

def utf16_decode.low(pair: Bool, +n: U32, hi: U32, out: String) -> String:
  match pair:
    case True{}:
      SCon{C.chr((65536 + (hi - 55296) * 1024 + (n - 56320) : U32)), out}
    case False{}:
      utf16_decode.char(C.between(n, 55296, 57343), n,
        utf16_decode.unpaired(hi, out))

# Output for the UTF-16 unit `n` given a pending high surrogate `hi` (or 0);
# `high` says `n` is itself a high surrogate.
def utf16_decode.unit(high: Bool, +n: U32, +hi: U32, out: String) -> String:
  match high:
    case True{}:
      utf16_decode.unpaired(hi, out)
    case False{}:
      utf16_decode.low(C.between(n, 56320, 57343) && Bool.not(U32.is_zero(hi)),
        n, hi, out)

# UTF-16BE bytes to text; `hi` is a pending high surrogate or 0, `out` the
# reversed text so far. A trailing odd byte is dropped.
def utf16_decode(bytes: String, hi: U32, out: String) -> String:
  match bytes:
    case SCon{a, SCon{b, t}}:
      +n = ((C.u(a) << 8n) .|. C.u(b) : U32)
      +high = C.between(n, 55296, 56319)
      utf16_decode(t, Bool.pick(U32, high, n, 0),
        utf16_decode.unit(high, n, hi, out))
    case _:
      String.reverse(utf16_decode.unpaired(hi, out))

# `out` with a closed "&...-" run: "&-" is a literal "&", anything else is
# base64 of UTF-16BE.
def mutf7_decode.close(+b64: String, out: String) -> String:
  match b64:
    case SNil{}:
      SCon{'&', out}
    case SCon{h, t}:
      String.reverse(utf16_decode(C.b64_decode(String.reverse(b64)), 0, "")) ++
        out

def mutf7_decode.shifted(+c: Char, out: String, b64: String) -> Utf7Decoder:
  match c:
    case '-':
      Utf7Decoder{mutf7_decode.close(b64, out), "", False{}}
    case _:
      Utf7Decoder{out, SCon{c, b64}, True{}}

def mutf7_decode.plain(+c: Char, out: String, b64: String) -> Utf7Decoder:
  match c:
    case '&':
      Utf7Decoder{out, "", True{}}
    case _:
      Utf7Decoder{SCon{c, out}, b64, False{}}

def mutf7_decode.step(c: Char, st: Utf7Decoder) -> Utf7Decoder:
  match st:
    case Utf7Decoder{out, b64, True{}}:
      mutf7_decode.shifted(c, out, b64)
    case Utf7Decoder{out, b64, False{}}:
      mutf7_decode.plain(c, out, b64)

def mutf7_decode.go(s: String, st: Utf7Decoder) -> Utf7Decoder:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      mutf7_decode.go(t, mutf7_decode.step(c, st))

# The decoded text; an unterminated run is dropped.
def mutf7_decode.finish(st: Utf7Decoder) -> String:
  Utf7Decoder{out, _, _} = st
  String.reverse(out)

# Modified UTF-7 wire form to the mailbox name.
def mutf7_decode(s: String) -> String:
  mutf7_decode.finish(mutf7_decode.go(s, Utf7Decoder{"", "", False{}}))

# Rendering
# ---------

def crlf() -> String:
  "\r\n"

def esc_quoted(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'"', t}:
      "\\\"" ++ esc_quoted(t)
    case SCon{'\\', t}:
      "\\\\" ++ esc_quoted(t)
    case SCon{c, t}:
      SCon{c, esc_quoted(t)}

def astring.if(plain: Bool, +s: String) -> String:
  match plain:
    case True{}:
      "\"" ++ esc_quoted(s) ++ "\""
    case False{}:
      "{" ++ U32.show(C.utf8_len(s)) ++ "}" ++ crlf() ++ s

# An IMAP string: quoted when it is printable ASCII, else a literal
# ({bytes} CRLF then the UTF-8 bytes; the command continues after it).
def astring(+s: String) -> String:
  astring.if(C.is_plain(s), s)

def mailbox(name: String) -> String:
  astring(mutf7_encode(name))

def uid_set(uids: List<&2, U32>) -> String:
  match uids:
    case Nil{}:
      ""
    case Con{u, Nil{}}:
      U32.show(u)
    case Con{u, t}:
      U32.show(u) ++ "," ++ uid_set(t)

def flag_name(f: Flag) -> String:
  match f:
    case FSeen{}:
      "\\Seen"
    case FDeleted{}:
      "\\Deleted"
    case FDraft{}:
      "\\Draft"
    case FFlagged{}:
      "\\Flagged"
    case FAnswered{}:
      "\\Answered"
    case FColourBit0{}:
      "$MailFlagBit0"
    case FColourBit1{}:
      "$MailFlagBit1"
    case FColourBit2{}:
      "$MailFlagBit2"

def colour_name(c: Colour) -> String:
  match c:
    case ColRed{}:
      "red"
    case ColOrange{}:
      "orange"
    case ColYellow{}:
      "yellow"
    case ColGreen{}:
      "green"
    case ColBlue{}:
      "blue"
    case ColPurple{}:
      "purple"
    case ColGrey{}:
      "grey"

def colours() -> List<&2, Colour>:
  [ColRed{}, ColOrange{}, ColYellow{}, ColGreen{}, ColBlue{}, ColPurple{}, ColGrey{}]

def colour_names.go(cs: List<&2, Colour>) -> List<&2, String>:
  match cs:
    case Nil{}:
      []
    case Con{c, t}:
      colour_name(c) <> colour_names.go(t)

def colour_names() -> List<&2, String>:
  colour_names.go(colours())

# Walks all seven colours, keeping the match in `found`: a fold is simpler
# than an early-stop `.if` helper.
def colour_from_name.go(
  cs: List<&2, Colour>,
  +n: String,
  found: Maybe<&2, Colour>
) -> Maybe<&2, Colour>:
  match cs:
    case Nil{}:
      found
    case Con{+c, t}:
      colour_from_name.go(t, n,
        Bool.pick(Maybe<&2, Colour>, String.eq(colour_name(c), n), Some{c}, found))

def colour_from_name(n: String) -> Maybe<&2, Colour>:
  colour_from_name.go(colours(), n, None{})

# The index is Bit0 x 1 + Bit1 x 2 + Bit2 x 4, with red 0 and grey 6.
def colour_bits(c: Colour) -> Bits:
  match c:
    case ColRed{}:
      Bits{False{}, False{}, False{}}
    case ColOrange{}:
      Bits{True{}, False{}, False{}}
    case ColYellow{}:
      Bits{False{}, True{}, False{}}
    case ColGreen{}:
      Bits{True{}, True{}, False{}}
    case ColBlue{}:
      Bits{False{}, False{}, True{}}
    case ColPurple{}:
      Bits{True{}, False{}, True{}}
    case ColGrey{}:
      Bits{False{}, True{}, True{}}

def flag_list(fs: List<&2, Flag>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{f, Nil{}}:
      flag_name(f)
    case Con{f, t}:
      flag_name(f) ++ " " ++ flag_list(t)

def key_str(k: Key) -> String:
  match k:
    case KAll{}:
      "ALL"
    case KFrom{s}:
      "FROM " ++ astring(s)
    case KTo{s}:
      "TO " ++ astring(s)
    case KCc{s}:
      "CC " ++ astring(s)
    case KSubject{s}:
      "SUBJECT " ++ astring(s)
    case KBody{s}:
      "BODY " ++ astring(s)
    case KText{s}:
      "TEXT " ++ astring(s)
    case KSince{d}:
      "SINCE " ++ d
    case KBefore{d}:
      "BEFORE " ++ d
    case KSeen{}:
      "SEEN"
    case KUnseen{}:
      "UNSEEN"
    case KFlagged{}:
      "FLAGGED"
    case KUnflagged{}:
      "UNFLAGGED"
    case KUndeleted{}:
      "UNDELETED"
    case KHeader{n, v}:
      "HEADER " ++ astring(n) ++ " " ++ astring(v)
    case KUidFrom{n}:
      "UID " ++ U32.show(n) ++ ":*"
    case KUids{us}:
      "UID " ++ uid_set(us)

# Whether a key's strings are all printable ASCII.
def key_plain(k: Key) -> Bool:
  match k:
    case KFrom{s}:
      C.is_plain(s)
    case KTo{s}:
      C.is_plain(s)
    case KCc{s}:
      C.is_plain(s)
    case KSubject{s}:
      C.is_plain(s)
    case KBody{s}:
      C.is_plain(s)
    case KText{s}:
      C.is_plain(s)
    case KHeader{n, v}:
      C.is_plain(n) && C.is_plain(v)
    case _:
      True{}

def keys_str(ks: List<&2, Key>) -> String:
  match ks:
    case Nil{}:
      ""
    case Con{k, Nil{}}:
      key_str(k)
    case Con{k, t}:
      key_str(k) ++ " " ++ keys_str(t)

# The SEARCH criteria: ALL when there are none, and CHARSET UTF-8 when a
# string is not printable ASCII.
def search_args(+ks: List<&2, Key>) -> String:
  match ks:
    case Nil{}:
      "ALL"
    case Con{h, t}:
      Bool.pick(String, List.all(~&2, ~Key, ~key_plain, ks), "", "CHARSET UTF-8 ") ++
        keys_str(ks)

# The header fields fetched for message summaries.
def header_fields() -> String:
  "FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES"

def item_str(i: Item) -> String:
  match i:
    case IUid{}:
      "UID"
    case IFlags{}:
      "FLAGS"
    case IDate{}:
      "INTERNALDATE"
    case ISize{}:
      "RFC822.SIZE"
    case IHeaders{}:
      "BODY.PEEK[HEADER.FIELDS (" ++ header_fields() ++ ")]"
    case IFull{max}:
      "BODY.PEEK[]<0." ++ U32.show(max) ++ ">"

def items_str(xs: List<&2, Item>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{i, Nil{}}:
      item_str(i)
    case Con{i, t}:
      item_str(i) ++ " " ++ items_str(t)

def store_op(add: Bool) -> String:
  Bool.pick(String, add, "+FLAGS.SILENT (", "-FLAGS.SILENT (")

# The wire form of one command, without tag and CRLF.
def cmd_str(+c: Cmd) -> String:
  match c:
    case CCapability{}:
      "CAPABILITY"
    case CList{}:
      "LIST \"\" \"*\""
    case CListRoles{}:
      "LIST \"\" \"*\" RETURN (SPECIAL-USE)"
    case CLsub{}:
      "LSUB \"\" \"*\""
    case CExamine{m}:
      "EXAMINE " ++ mailbox(m)
    case CSelect{m}:
      "SELECT " ++ mailbox(m)
    case CSearch{ks}:
      "UID SEARCH " ++ search_args(ks)
    case CFetch{us, xs}:
      "UID FETCH " ++ uid_set(us) ++ " (" ++ items_str(xs) ++ ")"
    case CStore{us, add, f}:
      "UID STORE " ++ uid_set(us) ++ " " ++ store_op(add) ++ flag_name(f) ++ ")"
    case CCopy{us, d}:
      "UID COPY " ++ uid_set(us) ++ " " ++ mailbox(d)
    case CMove{us, d}:
      "UID MOVE " ++ uid_set(us) ++ " " ++ mailbox(d)
    case CExpunge{us}:
      "UID EXPUNGE " ++ uid_set(us)
    case CCreate{m}:
      "CREATE " ++ mailbox(m)
    case CRename{a, b}:
      "RENAME " ++ mailbox(a) ++ " " ++ mailbox(b)
    case CSubscribe{m}:
      "SUBSCRIBE " ++ mailbox(m)
    case CUnsubscribe{m}:
      "UNSUBSCRIBE " ++ mailbox(m)
    case CAppend{m, fs, msg}:
      "APPEND " ++ mailbox(m) ++ " (" ++ flag_list(fs) ++ ") {" ++
        U32.show(C.utf8_len(msg)) ++ "}" ++ crlf() ++ msg
    case CExpect{e}:
      e
    case CExpectWord{w}:
      w

# Scripts
# -------

def tag(n: U32) -> String:
  "a" ++ U32.show(n)

# An expectation is not a command: the helper checks it against the
# previous command's untagged replies, so it takes no tag.
def is_expect(c: Cmd) -> Bool:
  match c:
    case CExpect{e}:
      True{}
    case CExpectWord{w}:
      True{}
    case _:
      False{}

# The tag after command `c`, given that `n` is the next free one.
def next_tag(c: Cmd, +n: U32) -> U32:
  Bool.pick(U32, is_expect(c), n, (n + 1 : U32))

# One script line: a tagged command, or an expectation after its keyword.
def script.line(+c: Cmd, n: U32) -> String:
  match c:
    case CExpect{e}:
      "=EXPECT " ++ e
    case CExpectWord{w}:
      "=EXPECT-WORD " ++ w
    case _:
      tag(n) ++ " " ++ cmd_str(c)

def script.go(cs: List<&2, Cmd>, +n: U32) -> String:
  match cs:
    case Nil{}:
      ""
    case Con{+c, t}:
      script.line(c, n) ++ crlf() ++ script.go(t, next_tag(c, n))

def script(cs: List<&2, Cmd>) -> String:
  script.go(cs, 1)

# How many commands of a script carry a tag (expectations carry none).
def tag_count(cs: List<&2, Cmd>) -> U32:
  match cs:
    case Nil{}:
      0
    case Con{c, t}:
      (Bool.pick(U32, is_expect(c), 0, 1) + tag_count(t) : U32)

# How many commands of a script are UNSUBSCRIBEs.
def unsubscribe_count(cs: List<&2, Cmd>) -> U32:
  match cs:
    case Nil{}:
      0
    case Con{CUnsubscribe{m}, t}:
      (1 + unsubscribe_count(t) : U32)
    case Con{c, t}:
      unsubscribe_count(t)

# The tag number script() gives the first UID COPY, from tag `n` on; 0 when
# the script has none.
def copy_tag(cs: List<&2, Cmd>, n: U32) -> U32:
  match cs:
    case Nil{}:
      0
    case Con{CCopy{u, d}, t}:
      n
    case Con{c, t}:
      copy_tag(t, next_tag(c, n))

# Dates
# -----

def all_digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Char.is_digit(c) && all_digits(t)

def imap_date.if(ok: Bool, y: String, m: U32, d: U32) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{U32.show(d) ++ "-" ++ C.month_name(m) ++ "-" ++ y}
    case False{}:
      None{}

# The date when the year has four digits, the month is 1-12 and the day 1-31.
def imap_date.check(+y: String, +m: U32, +d: U32) -> Maybe<&2, String>:
  ok = C.between(m, 1, 12) && C.between(d, 1, 31) &&
    Nat.is_eq(String.length(y), 4n) && all_digits(y)
  imap_date.if(ok, y, m, d)

def imap_date.nums(
  y: String,
  m: Maybe<&2, U32>,
  d: Maybe<&2, U32>
) -> Maybe<&2, String>:
  match m d:
    case Some{mm} Some{dd}:
      imap_date.check(y, mm, dd)
    case _ _:
      None{}

def imap_date.parts(ps: List<&2, String>) -> Maybe<&2, String>:
  match ps:
    case Con{y, Con{m, Con{d, Nil{}}}}:
      imap_date.nums(y, U32.read(m), U32.read(d))
    case _:
      None{}

# "2026-02-01" to the IMAP date "1-Feb-2026".
def imap_date(iso: String) -> Maybe<&2, String>:
  imap_date.parts(String.split(iso, '-'))

# Transcript framing
# ------------------

# One logical response line. Each literal in it is replaced by lit_mark()
# in `text`, and its bytes are in `lits`, in order.
type RLine is Data:
  RLine{text: String, lits: List<&2, String>}

# The size N of a "{N}" literal announcement and the reversed line before it.
type LitHit is Data:
  LitHit{n: U32, rest: String}
  LitNone{}

# The framer: the current line (reversed), its literals so far, the finished
# lines, the bytes left in an open literal, and whether the current line is
# untagged ("* ..."): only those carry literals, exactly as in the helper.
type Framer is Data:
  Framer{
    line: String,
    lits: List<&2, String>,
    lines: List<&2, RLine>,
    left: U32,
    lit: String,
    star: Bool
  }

# A private-use character: it cannot occur in the transcript, whose
# characters are all bytes (0..255).
def lit_mark() -> Char:
  C.chr(57344)

# Reads "{N}" backwards off a reversed line that ended in "{N}\r\n": digits
# come least significant first. `more` is false once a non-digit was read,
# which ends the scan early; `any` says a digit was read.
def lit_scan(r: String, more: Bool, acc: U32, +mul: U32, any: Bool) -> LitHit:
  match r more:
    case SCon{'{', t} True{}:
      Bool.pick(LitHit, any, LitHit{acc, t}, LitNone{})
    case SCon{+c, t} True{}:
      lit_scan(t, Char.is_digit(c), (acc + (C.u(c) - 48) * mul : U32),
        (mul * 10 : U32), True{})
    case _ _:
      LitNone{}

# The literal announced at the end of a reversed line, if any.
def lit_len(rev: String) -> LitHit:
  match rev:
    case SCon{'\n', SCon{'\r', SCon{'}', t}}}:
      lit_scan(t, True{}, 0, 1, False{})
    case _:
      LitNone{}

# The literal an ended line announces: only untagged lines carry them.
def lit_of(star: Bool, rev: String) -> LitHit:
  match star:
    case True{}:
      lit_len(rev)
    case False{}:
      LitNone{}

def strip_crlf(+rev: String) -> String:
  match rev:
    case SCon{'\n', SCon{'\r', t}}:
      t
    case SCon{'\n', t}:
      t
    case _:
      rev

def frame.lit_start(
  empty: Bool,
  n: U32,
  line: String,
  lits: List<&2, String>,
  lines: List<&2, RLine>
) -> Framer:
  match empty:
    case True{}:
      Framer{line, "" <> lits, lines, 0, "", True{}}
    case False{}:
      Framer{line, lits, lines, n, "", True{}}

def frame.line_end(
  hit: LitHit,
  line: String,
  lits: List<&2, String>,
  lines: List<&2, RLine>
) -> Framer:
  match hit:
    case LitHit{+n, rest}:
      frame.lit_start(U32.is_zero(n), n, SCon{lit_mark(), rest}, lits, lines)
    case LitNone{}:
      Framer{"", [],
        RLine{String.reverse(strip_crlf(line)), List.reverse(&2, String, lits)} <> lines,
        0, "", False{}}

def frame.text(
  +c: Char,
  +line: String,
  lits: List<&2, String>,
  lines: List<&2, RLine>,
  star: Bool
) -> Framer:
  match c:
    case '\n':
      +rev = {SCon{c, line} : String}
      frame.line_end(lit_of(star, rev), rev, lits, lines)
    case _:
      first = String.is_empty(line)
      Framer{SCon{c, line}, lits, lines, 0, "",
        Bool.pick(Bool, first, Char.is_eq(c, '*'), star)}

def frame.lit(
  last: Bool,
  c: Char,
  line: String,
  lits: List<&2, String>,
  lines: List<&2, RLine>,
  left: U32,
  lit: String
) -> Framer:
  match last:
    case True{}:
      Framer{line, String.reverse(SCon{c, lit}) <> lits, lines, 0, "", True{}}
    case False{}:
      Framer{line, lits, lines, (left - 1 : U32), SCon{c, lit}, True{}}

# One byte: line text, or the next byte of an open literal.
def frame.byte(
  text: Bool,
  c: Char,
  line: String,
  lits: List<&2, String>,
  lines: List<&2, RLine>,
  +left: U32,
  lit: String,
  star: Bool
) -> Framer:
  match text:
    case True{}:
      frame.text(c, line, lits, lines, star)
    case False{}:
      frame.lit(U32.is_eq(left, 1), c, line, lits, lines, left, lit)

def frame.step(c: Char, f: Framer) -> Framer:
  Framer{line, lits, lines, +left, lit, star} = f
  frame.byte(U32.is_zero(left), c, line, lits, lines, left, lit, star)

def frame.go(s: String, f: Framer) -> Framer:
  match s:
    case SNil{}:
      f
    case SCon{c, t}:
      frame.go(t, frame.step(c, f))

# The finished lines, with an unterminated last line kept.
def frame.last(
  +line: String,
  lits: List<&2, String>,
  lines: List<&2, RLine>
) -> List<&2, RLine>:
  match line:
    case SNil{}:
      List.reverse(&2, RLine, lines)
    case SCon{h, t}:
      List.reverse(&2, RLine,
        RLine{String.reverse(line), List.reverse(&2, String, lits)} <> lines)

def frame.finish(f: Framer) -> List<&2, RLine>:
  Framer{line, lits, lines, _, _, _} = f
  frame.last(line, lits, lines)

# Splits a transcript into response lines, keeping literals exact.
def frame(transcript: String) -> List<&2, RLine>:
  frame.finish(frame.go(transcript, Framer{"", [], [], 0, "", False{}}))

# Tokens
# ------

# A response value: an atom, a quoted or literal string, NIL, or a list.
type Value is Data:
  VAtom{s: String}
  VStr{s: String}
  VNil{}
  VList{items: List<&2, Value>}

# What the tokenizer is inside: nothing, an atom (with its "[...]" nesting
# depth), a quoted string, or a quoted string right after a backslash. Each
# accumulator is reversed.
type TokenMode is Data:
  TPlain{}
  TAtom{acc: String, depth: U32}
  TQuoted{acc: String}
  TEscaped{acc: String}

# The tokenizer: its mode, the open lists (innermost first, each reversed)
# and the literals still to be placed.
type Tokenizer is Data:
  Tokenizer{
    mode: TokenMode,
    stack: List<&2, List<&2, Value>>,
    lits: List<&2, String>
  }

def tokens.push(
  v: Value,
  stack: List<&2, List<&2, Value>>
) -> List<&2, List<&2, Value>>:
  match stack:
    case Con{top, rest}:
      (v <> top) <> rest
    case Nil{}:
      [[v]]

def tokens.close(
  +stack: List<&2, List<&2, Value>>
) -> List<&2, List<&2, Value>>:
  match stack:
    case Con{top, Con{up, rest}}:
      (VList{List.reverse(&2, Value, top)} <> up) <> rest
    case _:
      stack

def tokens.atom_value(+s: String) -> Value:
  Bool.pick(Value, String.eq(String.to_upper(s), "NIL"), VNil{}, VAtom{s})

def tokens.atom_end(
  acc: String,
  stack: List<&2, List<&2, Value>>
) -> List<&2, List<&2, Value>>:
  tokens.push(tokens.atom_value(String.reverse(acc)), stack)

# Places the next literal; a missing one reads as "".
def tokens.literal(
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match lits:
    case Con{l, rest}:
      Tokenizer{TPlain{}, tokens.push(VStr{l}, stack), rest}
    case Nil{}:
      Tokenizer{TPlain{}, tokens.push(VStr{""}, stack), []}

def tokens.atom_start(
  mark: Bool,
  c: Char,
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match mark:
    case True{}:
      tokens.literal(stack, lits)
    case False{}:
      Tokenizer{TAtom{SCon{c, SNil{}}, 0}, stack, lits}

def tokens.plain(
  +c: Char,
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match c:
    case ' ':
      Tokenizer{TPlain{}, stack, lits}
    case '(':
      Tokenizer{TPlain{}, [] <> stack, lits}
    case ')':
      Tokenizer{TPlain{}, tokens.close(stack), lits}
    case '"':
      Tokenizer{TQuoted{""}, stack, lits}
    case '[':
      Tokenizer{TAtom{"[", 1}, stack, lits}
    case _:
      tokens.atom_start(Char.is_eq(c, lit_mark()), c, stack, lits)

# A character of an atom outside "[...]": a space or parenthesis ends it.
def tokens.atom_top(
  +c: Char,
  acc: String,
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match c:
    case ' ':
      Tokenizer{TPlain{}, tokens.atom_end(acc, stack), lits}
    case '(':
      Tokenizer{TPlain{}, [] <> tokens.atom_end(acc, stack), lits}
    case ')':
      Tokenizer{TPlain{}, tokens.close(tokens.atom_end(acc, stack)), lits}
    case _:
      Tokenizer{TAtom{SCon{c, acc}, 0}, stack, lits}

def tokens.atom_char(
  top: Bool,
  c: Char,
  acc: String,
  depth: U32,
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match top:
    case True{}:
      tokens.atom_top(c, acc, stack, lits)
    case False{}:
      Tokenizer{TAtom{SCon{c, acc}, depth}, stack, lits}

def tokens.atom(
  +c: Char,
  acc: String,
  +depth: U32,
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match c:
    case '[':
      Tokenizer{TAtom{SCon{c, acc}, (depth + 1 : U32)}, stack, lits}
    case ']':
      up = Bool.pick(U32, U32.is_zero(depth), 0, (depth - 1 : U32))
      Tokenizer{TAtom{SCon{c, acc}, up}, stack, lits}
    case _:
      tokens.atom_char(U32.is_zero(depth), c, acc, depth, stack, lits)

def tokens.quoted(
  +c: Char,
  acc: String,
  stack: List<&2, List<&2, Value>>,
  lits: List<&2, String>
) -> Tokenizer:
  match c:
    case '"':
      Tokenizer{TPlain{}, tokens.push(VStr{String.reverse(acc)}, stack), lits}
    case '\\':
      Tokenizer{TEscaped{acc}, stack, lits}
    case _:
      Tokenizer{TQuoted{SCon{c, acc}}, stack, lits}

def tokens.step(c: Char, t: Tokenizer) -> Tokenizer:
  match t:
    case Tokenizer{TPlain{}, stack, lits}:
      tokens.plain(c, stack, lits)
    case Tokenizer{TAtom{acc, depth}, stack, lits}:
      tokens.atom(c, acc, depth, stack, lits)
    case Tokenizer{TQuoted{acc}, stack, lits}:
      tokens.quoted(c, acc, stack, lits)
    case Tokenizer{TEscaped{acc}, stack, lits}:
      Tokenizer{TQuoted{SCon{c, acc}}, stack, lits}

def tokens.go(s: String, t: Tokenizer) -> Tokenizer:
  match s:
    case SNil{}:
      t
    case SCon{c, r}:
      tokens.go(r, tokens.step(c, t))

# Closes every open list: `done` is the finished inner list, in order.
def tokens.flatten.go(
  rest: List<&2, List<&2, Value>>,
  done: List<&2, Value>
) -> List<&2, Value>:
  match rest:
    case Nil{}:
      done
    case Con{up, r}:
      tokens.flatten.go(r, List.reverse(&2, Value, VList{done} <> up))

def tokens.flatten(stack: List<&2, List<&2, Value>>) -> List<&2, Value>:
  match stack:
    case Nil{}:
      []
    case Con{top, rest}:
      tokens.flatten.go(rest, List.reverse(&2, Value, top))

# The values once the text ends: an open atom or quoted string is kept.
def tokens.finish(t: Tokenizer) -> List<&2, Value>:
  match t:
    case Tokenizer{TAtom{acc, depth}, stack, lits}:
      tokens.flatten(tokens.atom_end(acc, stack))
    case Tokenizer{TQuoted{acc}, stack, lits}:
      tokens.flatten(tokens.push(VStr{String.reverse(acc)}, stack))
    case Tokenizer{m, stack, lits}:
      tokens.flatten(stack)

# The values of a response text, with its literals put back in place.
def tokens(text: String, lits: List<&2, String>) -> List<&2, Value>:
  tokens.finish(tokens.go(text, Tokenizer{TPlain{}, [[]], lits}))

# The text of an atom or string; "" for NIL and lists.
def Value.text(v: Value) -> String:
  match v:
    case VAtom{s}:
      s
    case VStr{s}:
      s
    case VNil{}:
      ""
    case VList{xs}:
      ""

def Value.texts(vs: List<&2, Value>) -> List<&2, String>:
  match vs:
    case Nil{}:
      []
    case Con{v, t}:
      Value.text(v) <> Value.texts(t)

# Response lines
# --------------

def upper_starts(s: String, p: String) -> Bool:
  String.starts_with(String.to_upper(s), p)

# The text after the first space, or "".
def after_space(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{' ', t}:
      t
    case SCon{c, t}:
      after_space(t)

def before_space(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{' ', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_space(t)}

def code_body(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{']', t}:
      ""
    case SCon{c, t}:
      SCon{c, code_body(t)}

# The response code inside "[...]" at the start of a status text, or "".
def resp_code(s: String) -> String:
  match s:
    case SCon{'[', t}:
      code_body(t)
    case _:
      ""

# `hit` says the line before `lines`, whose text is `last`, was accepted:
# the walk stops there instead of reading the rest of the transcript.
def first_line.go(
  ~is_hit: String -> String -> Bool,
  lines: List<&2, RLine>,
  +key: String,
  last: String,
  hit: Bool
) -> Maybe<&2, String>:
  match lines hit:
    case _ True{}:
      Some{last}
    case Nil{} False{}:
      None{}
    case Con{RLine{+text, lits}, t} False{}:
      first_line.go(~is_hit, t, key, text, is_hit(text, key))

# The text of the first line that `is_hit(text, key)` accepts.
def first_line(
  ~is_hit: String -> String -> Bool,
  lines: List<&2, RLine>,
  key: String
) -> Maybe<&2, String>:
  first_line.go(~is_hit, lines, key, "", False{})

# The first line that starts with `p`, or "".
def line_starting(lines: List<&2, RLine>, p: String) -> String:
  Maybe.default(&2, String, first_line(~String.starts_with, lines, p), "")

def caps.line(hit: Bool, text: String) -> List<&2, String>:
  match hit:
    case True{}:
      String.split(String.to_upper(String.drop(text, 13n)), ' ')
    case False{}:
      []

# Capabilities announced by "* CAPABILITY " (13 characters) lines,
# upper-cased.
def caps(lines: List<&2, RLine>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, l}, t}:
      List.append(&2, String, caps.line(upper_starts(text, "* CAPABILITY "), text),
        caps(t))

def has_cap(cs: List<&2, String>, name: String) -> Bool:
  List.contains(~String, ~String.eq, cs, name)

# Folders
# -------

type Folder is Data:
  Folder{name: String, delim: String, attrs: List<&2, String>}

def folder_of(vs: List<&2, Value>) -> List<&2, Folder>:
  match vs:
    case Con{VList{attrs}, Con{d, Con{n, Nil{}}}}:
      [Folder{mutf7_decode(Value.text(n)), Value.text(d), Value.texts(attrs)}]
    case _:
      []

def listed.line(
  is_list: Bool,
  text: String,
  lits: List<&2, String>
) -> List<&2, Folder>:
  match is_list:
    case True{}:
      folder_of(tokens(String.drop(text, 7n), lits))
    case False{}:
      []

# Mailboxes from the untagged lines that start with `prefix` ("* LIST " or
# "* LSUB ", both 7 characters long).
def listed(+prefix: String, lines: List<&2, RLine>) -> List<&2, Folder>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, lits}, t}:
      List.append(&2, Folder, listed.line(upper_starts(text, prefix), text, lits),
        listed(prefix, t))

# Mailboxes from "* LIST" lines.
def folders(lines: List<&2, RLine>) -> List<&2, Folder>:
  listed("* LIST ", lines)

# The subscribed mailboxes, from "* LSUB" lines.
def subscribed(lines: List<&2, RLine>) -> List<&2, Folder>:
  listed("* LSUB ", lines)

def has_attr.lowered(attrs: List<&2, String>, +want: String) -> Bool:
  match attrs:
    case Nil{}:
      False{}
    case Con{attr, rest}:
      String.eq(String.to_lower(attr), want) || has_attr.lowered(rest, want)

# Whether a folder's attributes include `a`, in any case.
def has_attr(attrs: List<&2, String>, a: String) -> Bool:
  has_attr.lowered(attrs, String.to_lower(a))

# The first mailbox carrying a special-use attribute such as "\\Trash".
def special(fs: List<&2, Folder>, +attr: String) -> Maybe<&2, String>:
  match fs:
    case Nil{}:
      None{}
    case Con{Folder{name, d, attrs}, t}:
      Bool.pick(Maybe<&2, String>, has_attr(attrs, attr), Some{name},
        special(t, attr))

# Whether two mailbox names are the same mailbox: only INBOX is matched in
# any case, as IMAP requires (other names may differ only in case, e.g.
# trash and Trash).
def same_name(+a: String, +b: String) -> Bool:
  String.eq(a, b) ||
    (String.eq(String.to_upper(a), "INBOX") && String.eq(String.to_upper(b), "INBOX"))

# The mailbox with exactly this name, as same_name() compares them.
def named(fs: List<&2, Folder>, +want: String) -> Maybe<&2, String>:
  match fs:
    case Nil{}:
      None{}
    case Con{Folder{+name, d, a}, t}:
      Bool.pick(Maybe<&2, String>, same_name(name, want), Some{name},
        named(t, want))

# Status and data responses
# -------------------------

def nums.put(m: Maybe<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  match m:
    case Some{n}:
      n <> rest
    case None{}:
      rest

# The words that are numbers, as numbers.
def nums(ws: List<&2, String>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      []
    case Con{w, t}:
      nums.put(U32.read(w), nums(t))

def search_uids.line(hit: Bool, text: String) -> List<&2, U32>:
  match hit:
    case True{}:
      nums(String.split(String.drop(text, 8n), ' '))
    case False{}:
      []

# UIDs from "* SEARCH" (8 characters) lines.
def search_uids(lines: List<&2, RLine>) -> List<&2, U32>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, l}, t}:
      List.append(&2, U32, search_uids.line(upper_starts(text, "* SEARCH"), text),
        search_uids(t))

# The value of the "[NAME value]" code of a "* OK " (5 characters) line.
def ok_code.value(line: String) -> String:
  after_space(resp_code(String.drop(line, 5n)))

# The raw value of the first "* OK [NAME value]" response code.
def ok_code_text(lines: List<&2, RLine>, name: String) -> Maybe<&2, String>:
  Maybe.map(&2, String, String, ok_code.value,
    first_line(~upper_starts, lines, "* OK [" ++ name ++ " "))

# The number of a "* OK [NAME n]" response code, e.g. UIDVALIDITY.
def ok_code(lines: List<&2, RLine>, name: String) -> Maybe<&2, U32>:
  Maybe.bind(&2, String, U32, ok_code_text(lines, name), U32.read)

# Whether a line is a "* <n> EXISTS" reply.
def is_exists(+text: String) -> Bool:
  String.ends_with(String.to_upper(text), " EXISTS") &&
    String.starts_with(text, "* ")

# The count of the first "* <n> EXISTS" line.
def exists(lines: List<&2, RLine>) -> Maybe<&2, U32>:
  Maybe.bind(&2, String, U32,
    first_line(~(text => key => is_exists(text)), lines, ""),
    text => U32.read(before_space(String.drop(text, 2n))))

# Fetched messages
# ----------------

# A FETCH response for one message.
type Msg is Data:
  Msg{
    uid: U32,
    flags: List<&2, String>,
    date: String,
    size: U32,
    headers: String,
    body: String
  }

# The Msg field a FETCH item with a non-list value sets, if any.
type Field is Data:
  FieldUid{}
  FieldDate{}
  FieldSize{}
  FieldHeaders{}
  FieldBody{}
  FieldNone{}

def msg_empty() -> Msg:
  Msg{0, [], "", 0, "", ""}

# The field an upper-cased item name sets. Every branch is a constant, so
# Bool.pick building all of them costs nothing.
def field_of(+k: String) -> Field:
  Bool.pick(Field, String.eq(k, "UID"), FieldUid{},
    Bool.pick(Field, String.eq(k, "INTERNALDATE"), FieldDate{},
      Bool.pick(Field, String.eq(k, "RFC822.SIZE"), FieldSize{},
        Bool.pick(Field, String.starts_with(k, "BODY[HEADER"), FieldHeaders{},
          Bool.pick(Field, String.starts_with(k, "BODY[]"), FieldBody{},
            FieldNone{})))))

# Sets a field from an item's text; a number that does not read is 0.
def msg_scalar(f: Field, s: String, +m: Msg) -> Msg:
  match f m:
    case FieldUid{} Msg{_, flags, date, size, headers, body}:
      Msg{Maybe.default(&2, U32, U32.read(s), 0), flags, date, size, headers, body}
    case FieldDate{} Msg{uid, flags, _, size, headers, body}:
      Msg{uid, flags, s, size, headers, body}
    case FieldSize{} Msg{uid, flags, date, _, headers, body}:
      Msg{uid, flags, date, Maybe.default(&2, U32, U32.read(s), 0), headers, body}
    case FieldHeaders{} Msg{uid, flags, date, size, _, body}:
      Msg{uid, flags, date, size, s, body}
    case FieldBody{} Msg{uid, flags, date, size, headers, _}:
      Msg{uid, flags, date, size, headers, s}
    case FieldNone{} _:
      m

def msg_flags(is_flags: Bool, xs: List<&2, Value>, +m: Msg) -> Msg:
  match is_flags m:
    case True{} Msg{uid, _, date, size, headers, body}:
      Msg{uid, Value.texts(xs), date, size, headers, body}
    case False{} _:
      m

# Sets the field one FETCH item names: a list value can only be FLAGS.
def msg_set(m: Msg, k: String, +v: Value) -> Msg:
  match v:
    case VList{xs}:
      msg_flags(String.eq(String.to_upper(k), "FLAGS"), xs, m)
    case _:
      msg_scalar(field_of(String.to_upper(k)), Value.text(v), m)

def msg_pairs(vs: List<&2, Value>, m: Msg) -> Msg:
  match vs:
    case Con{VAtom{k}, Con{v, rest}}:
      msg_pairs(rest, msg_set(m, k, v))
    case _:
      m

# Whether a FETCH response's items name `key` (upper case).
def has_item(vs: List<&2, Value>, +key: String) -> Bool:
  match vs:
    case Con{VAtom{k}, Con{v, rest}}:
      String.eq(String.to_upper(k), key) || has_item(rest, key)
    case _:
      False{}

def msg_of.if(keep: Bool, items: List<&2, Value>) -> List<&2, Msg>:
  match keep:
    case True{}:
      [msg_pairs(items, msg_empty())]
    case False{}:
      []

# Whether to keep a FETCH response: any, or with `need_flags` only one that
# carries FLAGS. One without them (e.g. only MODSEQ) says nothing about the
# flags.
def msg_of.need(need_flags: Bool, items: List<&2, Value>) -> Bool:
  match need_flags:
    case True{}:
      has_item(items, "FLAGS")
    case False{}:
      True{}

def msg_of(vs: List<&2, Value>, need_flags: Bool) -> List<&2, Msg>:
  match vs:
    case Con{n, Con{VAtom{f}, Con{VList{+items}, Nil{}}}}:
      msg_of.if(msg_of.need(need_flags, items), items)
    case _:
      []

def fetches.line(
  is_fetch: Bool,
  text: String,
  lits: List<&2, String>,
  need_flags: Bool
) -> List<&2, Msg>:
  match is_fetch:
    case True{}:
      msg_of(tokens(String.drop(text, 2n), lits), need_flags)
    case False{}:
      []

def before_paren(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'(', t}:
      "("
    case SCon{c, t}:
      SCon{c, before_paren(t)}

# Messages from FETCH lines; with `need_flags`, only those that carry FLAGS.
def fetches(lines: List<&2, RLine>, +need_flags: Bool) -> List<&2, Msg>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, lits}, t}:
      is_fetch = String.starts_with(text, "* ") &&
        String.contains(String.to_upper(before_paren(text)), " FETCH ")
      List.append(&2, Msg, fetches.line(is_fetch, text, lits, need_flags),
        fetches(t, need_flags))

# Messages from "* <n> FETCH (...)" lines.
def fetched(lines: List<&2, RLine>) -> List<&2, Msg>:
  fetches(lines, False{})

# Messages from the FETCH lines that carry FLAGS. A line without UID names
# only a sequence number, so its message has UID 0, which no request has.
def flag_fetches(lines: List<&2, RLine>) -> List<&2, Msg>:
  fetches(lines, True{})

# Tagged replies
# --------------

# The untagged reply that pins a folder's UIDVALIDITY after SELECT.
def uidv_line(v: U32) -> String:
  "* OK [UIDVALIDITY " ++ U32.show(v) ++ "]"

# The tagged status of command n: "OK", "NO", "BAD", or "" if it never ran.
def status(lines: List<&2, RLine>, n: U32) -> String:
  String.to_upper(before_space(after_space(line_starting(lines, tag(n) ++ " "))))

# The status text (after OK/NO/BAD) of command n.
def status_text(lines: List<&2, RLine>, n: U32) -> String:
  after_space(after_space(line_starting(lines, tag(n) ++ " ")))

# Whether a tagged status is a refusal.
def is_refusal(+st: String) -> Bool:
  String.eq(st, "NO") || String.eq(st, "BAD")

# Whether a line is a tagged refusal.
def is_failure(+text: String) -> Bool:
  String.starts_with(text, "a") &&
    is_refusal(String.to_upper(before_space(after_space(text))))

# Whether command n was refused (NO or BAD).
def refused(lines: List<&2, RLine>, n: U32) -> Bool:
  is_refusal(status(lines, n))

# The first rejected command's status line, or "" when every command ran.
def first_failure(lines: List<&2, RLine>) -> String:
  Maybe.default(&2, String,
    first_line(~(text => key => is_failure(text)), lines, ""), "")

# The lines after the first that starts with `p` (none if no line does).
# `hit` says the line before `lines` did, which ends the walk.
def after_line(lines: List<&2, RLine>, +p: String, hit: Bool) -> List<&2, RLine>:
  match lines hit:
    case Nil{} _:
      []
    case Con{l, t} True{}:
      l <> t
    case Con{RLine{text, lits}, t} False{}:
      after_line(t, p, String.starts_with(text, p))

# The untagged ("* ") lines before the first that starts with `p`. `hit`
# says the line before `lines` did, which ends the walk.
def untagged_until(
  lines: List<&2, RLine>,
  +p: String,
  hit: Bool
) -> List<&2, RLine>:
  match lines hit:
    case Nil{} _:
      []
    case Con{l, t} True{}:
      []
    case Con{RLine{+text, lits}, t} False{}:
      List.filter.put(RLine, RLine{text, lits},
        untagged_until(t, p, String.starts_with(text, p)),
        String.starts_with(text, "* "))

# The untagged replies to command n: the "* " lines after command n-1's
# tagged reply (from the start, for the first command) and before n's own
# (or the end, if n got none). The helper runs one command at a time, so no
# other command's replies fall in between.
def replies(lines: List<&2, RLine>, +n: U32) -> List<&2, RLine>:
  from = after_line(lines, tag((n - 1 : U32)) ++ " ", U32.is_eq(n, 1))
  untagged_until(from, tag(n) ++ " ", False{})

def listed_flags(vs: List<&2, Value>) -> List<&2, String>:
  match vs:
    case Con{VList{xs}, rest}:
      Value.texts(xs)
    case _:
      []

# The flags of a "* OK [PERMANENTFLAGS (...)]" reply: the flags the client
# can change for good (RFC 3501 7.1). None when there is no such reply.
def permanent_flags(lines: List<&2, RLine>) -> Maybe<&2, List<&2, String>>:
  Maybe.map(&2, String, List<&2, String>, v => listed_flags(tokens(v, [])),
    ok_code_text(lines, "PERMANENTFLAGS"))
