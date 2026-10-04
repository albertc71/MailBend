import Base
import ./codec.bend as C

# IMAP commands as data, their wire form, and the parsing of server
# transcripts. The helper (native/mailbend-tls.c) logs in and out; the
# commands here are everything in between.

# ---- the command model -----------------------------------------------------------

type Flag is Data:
  FSeen{}
  FDeleted{}
  FDraft{}
  FFlagged{}
  FAnswered{}

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
  CExamine{mbox: String}
  CSelect{mbox: String}
  CSearch{keys: List<&2, Key>}
  CFetch{uids: List<&2, U32>, items: List<&2, Item>}
  CStore{uids: List<&2, U32>, add: Bool, flag: Flag}
  CCopy{uids: List<&2, U32>, dest: String}
  CMove{uids: List<&2, U32>, dest: String}
  CExpunge{uids: List<&2, U32>}
  CAppend{mbox: String, flags: List<&2, Flag>, msg: String}
  CExpect{text: String}
  CExpectWord{word: String}

type M7 is Data:
  M7{out: String, run: String}

type D7 is Data:
  D7{out: String, b64: String, inb: Bool}

# ---- transcript framing ------------------------------------------------------------

# One logical response line. Each literal in it is replaced by lit_mark()
# in `text`, and its bytes are in `lits`, in order.
type RLine is Data:
  RLine{text: String, lits: List<&2, String>}

type LitHit is Data:
  LitHit{n: U32, rest: String}
  LitNone{}

# The framer: the current line (reversed), its literals so far, the finished
# lines, the bytes left in an open literal, and whether the current line is
# untagged ("* ..."): only those carry literals, exactly as in the helper.
type Frm is Data:
  Frm{line: String, lits: List<&2, String>, lines: List<&2, RLine>, left: U32, lit: String, star: Bool}

# ---- tokens ----------------------------------------------------------------------

type IV is Data:
  IAtom{s: String}
  IStr{s: String}
  INil{}
  IList{items: List<&2, IV>}

type TkMode is Data:
  TNorm{}
  TAtom{acc: String, depth: U32}
  TQuo{acc: String}
  TQEsc{acc: String}

# The builder: open lists (innermost first, each reversed) and the literals
# still to be placed.
type Tk is Data:
  Tk{mode: TkMode, stack: List<&2, List<&2, IV>>, lits: List<&2, String>}

type Folder is Data:
  Folder{name: String, delim: String, attrs: List<&2, String>}

# A FETCH response for one message.
type Msg is Data:
  Msg{uid: U32, flags: List<&2, String>, date: String, size: U32, headers: String, body: String}

# Whether a command can change the mailbox: open it read-write, change
# flags, or add or remove messages. EXAMINE, SEARCH and FETCH cannot.
def writes(+c: Cmd) -> Bool:
  match c:
    case CCapability{}:
      False{}
    case CList{}:
      False{}
    case CListRoles{}:
      False{}
    case CExamine{m}:
      False{}
    case CSelect{m}:
      True{}
    case CSearch{k}:
      False{}
    case CFetch{u, i}:
      False{}
    case CStore{u, a, f}:
      True{}
    case CCopy{u, d}:
      True{}
    case CMove{u, d}:
      True{}
    case CExpunge{u}:
      True{}
    case CAppend{m, f, b}:
      True{}
    case CExpect{e}:
      False{}
    case CExpectWord{w}:
      False{}

# Whether a command permanently removes messages (UID EXPUNGE).
def expunges(+c: Cmd) -> Bool:
  match c:
    case CExpunge{u}:
      True{}
    case _:
      False{}

# Whether a command marks messages \Deleted.
def marks_deleted(+c: Cmd) -> Bool:
  match c:
    case CStore{u, True{}, FDeleted{}}:
      True{}
    case _:
      False{}

def any_writes(+cs: List<&2, Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      writes(c) || any_writes(t)

def any_expunges(+cs: List<&2, Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      expunges(c) || any_expunges(t)

def any_marks_deleted(+cs: List<&2, Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      marks_deleted(c) || any_marks_deleted(t)

# ---- modified UTF-7 mailbox names (RFC 3501 5.1.3) -----------------------------

def utf16_pair(+m: U32) -> String:
  +hi = (55296 + (m >> 10n) : U32)
  +lo = (56320 + (m .&. 1023) : U32)
  SCon{C.chr((hi >> 8n : U32)), SCon{C.chr((hi .&. 255 : U32)), SCon{C.chr((lo >> 8n : U32)), SCon{C.chr((lo .&. 255 : U32)), SNil{}}}}}

def utf16be(+n: U32) -> String:
  Bool.pick(String, U32.is_lt(n, 65536),
    SCon{C.chr((n >> 8n : U32)), SCon{C.chr((n .&. 255 : U32)), SNil{}}},
    utf16_pair((n - 65536 : U32)))

def m7_flush(+out: String, +run: String) -> String:
  match run:
    case SNil{}:
      out
    case SCon{h, t}:
      String.reverse("&" ++ C.b64_encode(String.reverse(run), True{}) ++ "-") ++ out

def m7_put(+ascii: Bool, +c: Char, +out: String, +run: String) -> M7:
  match ascii:
    case True{}:
      M7{Bool.pick(String, Char.is_eq(c, '&'), "-&", SCon{c, SNil{}}) ++ m7_flush(out, run), ""}
    case False{}:
      M7{out, String.reverse(utf16be(C.u(c))) ++ run}

def m7_step(+c: Char, +st: M7) -> M7:
  match st:
    case M7{out, run}:
      m7_put(C.between(C.u(c), 32, 126), c, out, run)

def m7_go(+s: String, +st: M7) -> M7:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      m7_go(t, m7_step(c, st))

def m7_end(+st: M7) -> String:
  match st:
    case M7{out, run}:
      String.reverse(m7_flush(out, run))

# Mailbox name to its modified UTF-7 wire form.
def mutf7_encode(+name: String) -> String:
  m7_end(m7_go(name, M7{"", ""}))

def u16_char(+bad: Bool, +n: U32, +out: String) -> String:
  match bad:
    case True{}:
      SCon{C.repl(), out}
    case False{}:
      SCon{C.chr(n), out}

def u16_low(+pair: Bool, +n: U32, +hi: U32, +out: String) -> String:
  match pair:
    case True{}:
      SCon{C.chr((65536 + (hi - 55296) * 1024 + (n - 56320) : U32)), out}
    case False{}:
      u16_char(C.between(n, 55296, 57343), n, Bool.pick(String, U32.is_zero(hi), out, SCon{C.repl(), out}))

# Output for one UTF-16 unit given a pending high surrogate (or 0).
def u16_emit(+high: Bool, +n: U32, +hi: U32, +out: String) -> String:
  match high:
    case True{}:
      Bool.pick(String, U32.is_zero(hi), out, SCon{C.repl(), out})
    case False{}:
      u16_low(C.between(n, 56320, 57343) && Bool.not(U32.is_zero(hi)), n, hi, out)

# UTF-16BE bytes to text; `hi` is a pending high surrogate or 0, `out` the
# reversed text so far.
def utf16_decode(+bytes: String, +hi: U32, +out: String) -> String:
  match bytes:
    case SCon{a, SCon{b, t}}:
      +n = ((C.u(a) << 8n) .|. C.u(b) : U32)
      +high = C.between(n, 55296, 56319)
      utf16_decode(t, Bool.pick(U32, high, n, 0), u16_emit(high, n, hi, out))
    case _:
      String.reverse(Bool.pick(String, U32.is_zero(hi), out, SCon{C.repl(), out}))

def d7_close(+b64: String, +out: String) -> String:
  match b64:
    case SNil{}:
      SCon{'&', out}
    case SCon{h, t}:
      String.reverse(utf16_decode(C.b64_decode(String.reverse(b64)), 0, "")) ++ out

def d7_in(+c: Char, +out: String, +b64: String) -> D7:
  match c:
    case '-':
      D7{d7_close(b64, out), "", False{}}
    case _:
      D7{out, SCon{c, b64}, True{}}

def d7_out(+c: Char, +out: String, +b64: String) -> D7:
  match c:
    case '&':
      D7{out, "", True{}}
    case _:
      D7{SCon{c, out}, b64, False{}}

def d7_step(+c: Char, +st: D7) -> D7:
  match st:
    case D7{out, b64, True{}}:
      d7_in(c, out, b64)
    case D7{out, b64, False{}}:
      d7_out(c, out, b64)

def d7_go(+s: String, +st: D7) -> D7:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      d7_go(t, d7_step(c, st))

def d7_end(+st: D7) -> String:
  match st:
    case D7{out, b64, inb}:
      String.reverse(out)

# Modified UTF-7 wire form to the mailbox name.
def mutf7_decode(+s: String) -> String:
  d7_end(d7_go(s, D7{"", "", False{}}))

# ---- rendering ------------------------------------------------------------------

def crlf() -> String:
  "\r\n"

def esc_quoted(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'"', t}:
      "\\\"" ++ esc_quoted(t)
    case SCon{'\\', t}:
      "\\\\" ++ esc_quoted(t)
    case SCon{c, t}:
      SCon{c, esc_quoted(t)}

def astring_as(+plain: Bool, +s: String) -> String:
  match plain:
    case True{}:
      "\"" ++ esc_quoted(s) ++ "\""
    case False{}:
      "{" ++ U32.show(C.utf8_len(s)) ++ "}" ++ crlf() ++ s

# An IMAP string: quoted when it is printable ASCII, else a literal
# ({bytes} CRLF then the UTF-8 bytes; the command continues after it).
def astring(+s: String) -> String:
  astring_as(C.is_plain(s), s)

def mailbox(+name: String) -> String:
  astring(mutf7_encode(name))

def uid_set(+uids: List<&2, U32>) -> String:
  match uids:
    case Nil{}:
      ""
    case Con{u, Nil{}}:
      U32.show(u)
    case Con{u, t}:
      U32.show(u) ++ "," ++ uid_set(t)

def flag_name(+f: Flag) -> String:
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

def flag_list(+fs: List<&2, Flag>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{f, Nil{}}:
      flag_name(f)
    case Con{f, t}:
      flag_name(f) ++ " " ++ flag_list(t)

def key_str(+k: Key) -> String:
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
    case KUidFrom{n}:
      "UID " ++ U32.show(n) ++ ":*"
    case KUids{us}:
      "UID " ++ uid_set(us)

def key_plain(+k: Key) -> Bool:
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
    case _:
      True{}

def keys_plain(+ks: List<&2, Key>) -> Bool:
  match ks:
    case Nil{}:
      True{}
    case Con{k, t}:
      key_plain(k) && keys_plain(t)

def keys_str(+ks: List<&2, Key>) -> String:
  match ks:
    case Nil{}:
      ""
    case Con{k, Nil{}}:
      key_str(k)
    case Con{k, t}:
      key_str(k) ++ " " ++ keys_str(t)

def search_args(+ks: List<&2, Key>) -> String:
  match ks:
    case Nil{}:
      "ALL"
    case Con{h, t}:
      Bool.pick(String, keys_plain(ks), "", "CHARSET UTF-8 ") ++ keys_str(ks)

# The header fields fetched for message summaries.
def header_fields() -> String:
  "FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES"

def item_str(+i: Item) -> String:
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

def items_str(+xs: List<&2, Item>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{i, Nil{}}:
      item_str(i)
    case Con{i, t}:
      item_str(i) ++ " " ++ items_str(t)

def store_op(+add: Bool) -> String:
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
    case CAppend{m, fs, msg}:
      "APPEND " ++ mailbox(m) ++ " (" ++ flag_list(fs) ++ ") {" ++ U32.show(C.utf8_len(msg)) ++ "}" ++ crlf() ++ msg
    case CExpect{e}:
      e
    case CExpectWord{w}:
      w

def tag(+n: U32) -> String:
  "a" ++ U32.show(n)

# An expectation is not a command: the helper checks it against the
# previous command's untagged replies, so it takes no tag.
def is_expect(+c: Cmd) -> Bool:
  match c:
    case CExpect{e}:
      True{}
    case CExpectWord{w}:
      True{}
    case _:
      False{}

def expect_kw(+c: Cmd) -> String:
  match c:
    case CExpectWord{w}:
      "=EXPECT-WORD "
    case _:
      "=EXPECT "

def line_of(+expect: Bool, +c: Cmd, +n: U32) -> String:
  match expect:
    case True{}:
      expect_kw(c) ++ cmd_str(c)
    case False{}:
      tag(n) ++ " " ++ cmd_str(c)

def script_go(+cs: List<&2, Cmd>, +n: U32) -> String:
  match cs:
    case Nil{}:
      ""
    case Con{c, t}:
      +expect = is_expect(c)
      line_of(expect, c, n) ++ crlf() ++ script_go(t, Bool.pick(U32, expect, n, (n + 1 : U32)))

def script(+cs: List<&2, Cmd>) -> String:
  script_go(cs, 1)

# ---- dates -------------------------------------------------------------------

def month_name(+m: U32) -> String:
  match m:
    case 1: "Jan"
    case 2: "Feb"
    case 3: "Mar"
    case 4: "Apr"
    case 5: "May"
    case 6: "Jun"
    case 7: "Jul"
    case 8: "Aug"
    case 9: "Sep"
    case 10: "Oct"
    case 11: "Nov"
    case 12: "Dec"
    case _: ""

def all_digits(+s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Char.is_digit(c) && all_digits(t)

def date_ok(+y: String, +m: U32, +d: U32) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, C.between(m, 1, 12) && C.between(d, 1, 31) && Nat.is_eq(String.length(y), 4n) && all_digits(y),
    Some{U32.show(d) ++ "-" ++ month_name(m) ++ "-" ++ y}, None{})

def date_nums(+y: String, +m: Maybe<&2, U32>, +d: Maybe<&2, U32>) -> Maybe<&2, String>:
  match m:
    case Some{mm}:
      match d:
        case Some{dd}:
          date_ok(y, mm, dd)
        case None{}:
          None{}
    case None{}:
      None{}

def date_parts(+ps: List<&2, String>) -> Maybe<&2, String>:
  match ps:
    case Con{y, Con{m, Con{d, Nil{}}}}:
      date_nums(y, U32.read(m), U32.read(d))
    case _:
      None{}

# "2026-02-01" to the IMAP date "1-Feb-2026".
def imap_date(+iso: String) -> Maybe<&2, String>:
  date_parts(String.split(iso, '-'))

# A private-use character: it cannot occur in the transcript, whose
# characters are all bytes (0..255).
def lit_mark() -> Char:
  C.chr(57344)

# Reads "{N}" backwards off a reversed line that ended in "{N}\r\n":
# digits come least significant first.
def lit_scan(+r: String, +acc: U32, +mul: U32, +any: Bool) -> LitHit:
  match r:
    case SCon{'{', t}:
      Bool.pick(LitHit, any, LitHit{acc, t}, LitNone{})
    case SCon{+c, t}:
      Bool.pick(LitHit, Char.is_digit(c), lit_scan(t, (acc + (C.u(c) - 48) * mul : U32), (mul * 10 : U32), True{}), LitNone{})
    case SNil{}:
      LitNone{}

def lit_len(+rev: String) -> LitHit:
  match rev:
    case SCon{'\n', SCon{'\r', SCon{'}', t}}}:
      lit_scan(t, 0, 1, False{})
    case _:
      LitNone{}

def strip_crlf(+rev: String) -> String:
  match rev:
    case SCon{'\n', SCon{'\r', t}}:
      t
    case SCon{'\n', t}:
      t
    case _:
      rev

def frm_lit_start(+empty: Bool, +n: U32, +line: String, +lits: List<&2, String>, +lines: List<&2, RLine>) -> Frm:
  match empty:
    case True{}:
      Frm{line, "" <> lits, lines, 0, "", True{}}
    case False{}:
      Frm{line, lits, lines, n, "", True{}}

def frm_line_end(+hit: LitHit, +line: String, +lits: List<&2, String>, +lines: List<&2, RLine>) -> Frm:
  match hit:
    case LitHit{n, rest}:
      frm_lit_start(U32.is_zero(n), n, SCon{lit_mark(), rest}, lits, lines)
    case LitNone{}:
      Frm{"", [], RLine{String.reverse(strip_crlf(line)), List.reverse(&2, String, lits)} <> lines, 0, "", False{}}

def frm_text(+c: Char, +line: String, +lits: List<&2, String>, +lines: List<&2, RLine>, +star: Bool) -> Frm:
  match c:
    case '\n':
      frm_line_end(Bool.pick(LitHit, star, lit_len(SCon{c, line}), LitNone{}), SCon{c, line}, lits, lines)
    case _:
      Frm{SCon{c, line}, lits, lines, 0, "", Bool.pick(Bool, String.is_empty(line), Char.is_eq(c, '*'), star)}

def frm_lit(+last: Bool, +c: Char, +line: String, +lits: List<&2, String>, +lines: List<&2, RLine>, +left: U32, +lit: String) -> Frm:
  match last:
    case True{}:
      Frm{line, String.reverse(SCon{c, lit}) <> lits, lines, 0, "", True{}}
    case False{}:
      Frm{line, lits, lines, (left - 1 : U32), SCon{c, lit}, True{}}

def frm_any(+text: Bool, +c: Char, +line: String, +lits: List<&2, String>, +lines: List<&2, RLine>, +left: U32, +lit: String, +star: Bool) -> Frm:
  match text:
    case True{}:
      frm_text(c, line, lits, lines, star)
    case False{}:
      frm_lit(U32.is_eq(left, 1), c, line, lits, lines, left, lit)

def frm_step(+c: Char, +f: Frm) -> Frm:
  match f:
    case Frm{line, lits, lines, +left, lit, star}:
      frm_any(U32.is_zero(left), c, line, lits, lines, left, lit, star)

def frm_go(+s: String, +f: Frm) -> Frm:
  match s:
    case SNil{}:
      f
    case SCon{c, t}:
      frm_go(t, frm_step(c, f))

def frm_last(+line: String, +lits: List<&2, String>, +lines: List<&2, RLine>) -> List<&2, RLine>:
  match line:
    case SNil{}:
      List.reverse(&2, RLine, lines)
    case SCon{h, t}:
      List.reverse(&2, RLine, RLine{String.reverse(line), List.reverse(&2, String, lits)} <> lines)

def frm_end(+f: Frm) -> List<&2, RLine>:
  match f:
    case Frm{line, lits, lines, left, lit, star}:
      frm_last(line, lits, lines)

# Splits a transcript into response lines, keeping literals exact.
def frame(+transcript: String) -> List<&2, RLine>:
  frm_end(frm_go(transcript, Frm{"", [], [], 0, "", False{}}))

def push(+v: IV, +stack: List<&2, List<&2, IV>>) -> List<&2, List<&2, IV>>:
  match stack:
    case Con{top, rest}:
      (v <> top) <> rest
    case Nil{}:
      [[v]]

def close_list(+stack: List<&2, List<&2, IV>>) -> List<&2, List<&2, IV>>:
  match stack:
    case Con{top, Con{up, rest}}:
      (IList{List.reverse(&2, IV, top)} <> up) <> rest
    case _:
      stack

def atom_val(+s: String) -> IV:
  Bool.pick(IV, String.eq(String.to_upper(s), "NIL"), INil{}, IAtom{s})

def next_lit(+stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match lits:
    case Con{l, rest}:
      Tk{TNorm{}, push(IStr{l}, stack), rest}
    case Nil{}:
      Tk{TNorm{}, push(IStr{""}, stack), []}

def tk_mark(+mark: Bool, +c: Char, +stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match mark:
    case True{}:
      next_lit(stack, lits)
    case False{}:
      Tk{TAtom{SCon{c, SNil{}}, 0}, stack, lits}

def tk_norm(+c: Char, +stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match c:
    case ' ':
      Tk{TNorm{}, stack, lits}
    case '(':
      Tk{TNorm{}, [] <> stack, lits}
    case ')':
      Tk{TNorm{}, close_list(stack), lits}
    case '"':
      Tk{TQuo{""}, stack, lits}
    case '[':
      Tk{TAtom{"[", 1}, stack, lits}
    case _:
      tk_mark(Char.is_eq(c, lit_mark()), c, stack, lits)

def atom_end(+acc: String, +stack: List<&2, List<&2, IV>>) -> List<&2, List<&2, IV>>:
  push(atom_val(String.reverse(acc)), stack)

def tk_atom_top(+c: Char, +acc: String, +stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match c:
    case ' ':
      Tk{TNorm{}, atom_end(acc, stack), lits}
    case '(':
      Tk{TNorm{}, [] <> atom_end(acc, stack), lits}
    case ')':
      Tk{TNorm{}, close_list(atom_end(acc, stack)), lits}
    case _:
      Tk{TAtom{SCon{c, acc}, 0}, stack, lits}

def tk_atom_other(+top: Bool, +c: Char, +acc: String, +depth: U32, +stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match top:
    case True{}:
      tk_atom_top(c, acc, stack, lits)
    case False{}:
      Tk{TAtom{SCon{c, acc}, depth}, stack, lits}

def tk_atom(+c: Char, +acc: String, +depth: U32, +stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match c:
    case '[':
      Tk{TAtom{SCon{c, acc}, (depth + 1 : U32)}, stack, lits}
    case ']':
      Tk{TAtom{SCon{c, acc}, Bool.pick(U32, U32.is_zero(depth), 0, (depth - 1 : U32))}, stack, lits}
    case _:
      tk_atom_other(U32.is_zero(depth), c, acc, depth, stack, lits)

def tk_quo(+c: Char, +acc: String, +stack: List<&2, List<&2, IV>>, +lits: List<&2, String>) -> Tk:
  match c:
    case '"':
      Tk{TNorm{}, push(IStr{String.reverse(acc)}, stack), lits}
    case '\\':
      Tk{TQEsc{acc}, stack, lits}
    case _:
      Tk{TQuo{SCon{c, acc}}, stack, lits}

def tk_step(+c: Char, +t: Tk) -> Tk:
  match t:
    case Tk{TNorm{}, stack, lits}:
      tk_norm(c, stack, lits)
    case Tk{TAtom{acc, depth}, stack, lits}:
      tk_atom(c, acc, depth, stack, lits)
    case Tk{TQuo{acc}, stack, lits}:
      tk_quo(c, acc, stack, lits)
    case Tk{TQEsc{acc}, stack, lits}:
      Tk{TQuo{SCon{c, acc}}, stack, lits}

def tk_go(+s: String, +t: Tk) -> Tk:
  match s:
    case SNil{}:
      t
    case SCon{c, r}:
      tk_go(r, tk_step(c, t))

# Closes every open list: `done` is the finished inner list, in order.
def flatten_go(+rest: List<&2, List<&2, IV>>, +done: List<&2, IV>) -> List<&2, IV>:
  match rest:
    case Nil{}:
      done
    case Con{up, r}:
      flatten_go(r, List.reverse(&2, IV, IList{done} <> up))

def flatten(+stack: List<&2, List<&2, IV>>) -> List<&2, IV>:
  match stack:
    case Nil{}:
      []
    case Con{top, rest}:
      flatten_go(rest, List.reverse(&2, IV, top))

def tk_end(+t: Tk) -> List<&2, IV>:
  match t:
    case Tk{TAtom{acc, depth}, stack, lits}:
      flatten(atom_end(acc, stack))
    case Tk{TQuo{acc}, stack, lits}:
      flatten(push(IStr{String.reverse(acc)}, stack))
    case Tk{m, stack, lits}:
      flatten(stack)

# The values of a response text, with its literals put back in place.
def tokens(+text: String, +lits: List<&2, String>) -> List<&2, IV>:
  tk_end(tk_go(text, Tk{TNorm{}, [[]], lits}))

def iv_str(+v: IV) -> String:
  match v:
    case IAtom{s}:
      s
    case IStr{s}:
      s
    case INil{}:
      ""
    case IList{xs}:
      ""

def iv_strs(+vs: List<&2, IV>) -> List<&2, String>:
  match vs:
    case Nil{}:
      []
    case Con{v, t}:
      iv_str(v) <> iv_strs(t)

# ---- response lines ------------------------------------------------------------------

def upper_starts(+s: String, +p: String) -> Bool:
  String.starts_with(String.to_upper(s), p)

# The text after the first space, or "".
def after_space(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{' ', t}:
      t
    case SCon{c, t}:
      after_space(t)

def before_space(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{' ', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_space(t)}

def code_body(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{']', t}:
      ""
    case SCon{c, t}:
      SCon{c, code_body(t)}

# The response code inside "[...]" at the start of a status text, or "".
def resp_code(+s: String) -> String:
  match s:
    case SCon{'[', t}:
      code_body(t)
    case _:
      ""

# Capabilities announced by "* CAPABILITY" lines, upper-cased.
def caps(+lines: List<&2, RLine>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, l}, t}:
      List.append(&2, String, Bool.pick(List<&2, String>, upper_starts(text, "* CAPABILITY "),
        String.split(String.to_upper(String.drop(text, 13n)), ' '), []), caps(t))

def has_cap(+cs: List<&2, String>, +name: String) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      String.eq(c, name) || has_cap(t, name)

def folder_of(+vs: List<&2, IV>) -> List<&2, Folder>:
  match vs:
    case Con{IList{attrs}, Con{d, Con{n, Nil{}}}}:
      [Folder{mutf7_decode(iv_str(n)), iv_str(d), iv_strs(attrs)}]
    case _:
      []

def folder_line(+is_list: Bool, +text: String, +lits: List<&2, String>) -> List<&2, Folder>:
  match is_list:
    case True{}:
      folder_of(tokens(String.drop(text, 7n), lits))
    case False{}:
      []

# Mailboxes from "* LIST" lines.
def folders(+lines: List<&2, RLine>) -> List<&2, Folder>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, lits}, t}:
      List.append(&2, Folder, folder_line(upper_starts(text, "* LIST "), text, lits), folders(t))

def has_attr_lowered(+attrs: List<&2, String>, +want: String) -> Bool:
  match attrs:
    case Nil{}:
      False{}
    case Con{attr, rest}:
      String.eq(String.to_lower(attr), want) || has_attr_lowered(rest, want)

def has_attr(+attrs: List<&2, String>, +a: String) -> Bool:
  has_attr_lowered(attrs, String.to_lower(a))

# The first mailbox carrying a special-use attribute such as "\\Trash".
def special(+fs: List<&2, Folder>, +attr: String) -> Maybe<&2, String>:
  match fs:
    case Nil{}:
      None{}
    case Con{Folder{name, d, +attrs}, t}:
      Bool.pick(Maybe<&2, String>, has_attr(attrs, attr), Some{name}, special(t, attr))

# The mailbox with exactly this name; only INBOX is matched in any case, as
# IMAP requires (other names may differ only in case, e.g. trash and Trash).
def same_name(+a: String, +b: String) -> Bool:
  String.eq(a, b) || (String.eq(String.to_upper(a), "INBOX") && String.eq(String.to_upper(b), "INBOX"))

def named(+fs: List<&2, Folder>, +want: String) -> Maybe<&2, String>:
  match fs:
    case Nil{}:
      None{}
    case Con{Folder{+name, d, a}, t}:
      Bool.pick(Maybe<&2, String>, same_name(name, want), Some{name}, named(t, want))

def num_or_skip(+m: Maybe<&2, U32>, +rest: List<&2, U32>) -> List<&2, U32>:
  match m:
    case Some{n}:
      n <> rest
    case None{}:
      rest

def nums(+ws: List<&2, String>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      []
    case Con{w, t}:
      num_or_skip(U32.read(w), nums(t))

# UIDs from "* SEARCH" lines.
def search_uids(+lines: List<&2, RLine>) -> List<&2, U32>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, l}, t}:
      List.append(&2, U32, Bool.pick(List<&2, U32>, upper_starts(text, "* SEARCH"), nums(String.split(String.drop(text, 8n), ' ')), []), search_uids(t))

def resp_code_value(+code: String) -> String:
  after_space(code)

def code_hit(+hit: Bool, +text: String, +name: String, +rest: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match hit:
    case True{}:
      U32.read(resp_code_value(resp_code(String.drop(text, 5n))))
    case False{}:
      rest

# The value of a "* OK [NAME value]" response code, e.g. UIDVALIDITY.
def ok_code(+lines: List<&2, RLine>, +name: String) -> Maybe<&2, U32>:
  match lines:
    case Nil{}:
      None{}
    case Con{RLine{+text, l}, t}:
      code_hit(upper_starts(text, "* OK [" ++ name ++ " "), text, name, ok_code(t, name))

def exists_hit(+hit: Bool, +text: String, +rest: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match hit:
    case True{}:
      U32.read(before_space(String.drop(text, 2n)))
    case False{}:
      rest

# "* <n> EXISTS"
def exists(+lines: List<&2, RLine>) -> Maybe<&2, U32>:
  match lines:
    case Nil{}:
      None{}
    case Con{RLine{+text, l}, t}:
      exists_hit(String.ends_with(String.to_upper(text), " EXISTS") && String.starts_with(text, "* "), text, exists(t))

def msg_empty() -> Msg:
  Msg{0, [], "", 0, "", ""}

def msg_scalar(+k: String, +s: String, +uid: U32, +flags: List<&2, String>, +date: String, +size: U32, +headers: String, +body: String) -> Msg:
  Bool.pick(Msg, String.eq(k, "UID"), Msg{Maybe.default(&2, U32, U32.read(s), 0), flags, date, size, headers, body},
    Bool.pick(Msg, String.eq(k, "INTERNALDATE"), Msg{uid, flags, s, size, headers, body},
      Bool.pick(Msg, String.eq(k, "RFC822.SIZE"), Msg{uid, flags, date, Maybe.default(&2, U32, U32.read(s), 0), headers, body},
        Bool.pick(Msg, String.starts_with(k, "BODY[HEADER"), Msg{uid, flags, date, size, s, body},
          Bool.pick(Msg, String.starts_with(k, "BODY[]"), Msg{uid, flags, date, size, headers, s},
            Msg{uid, flags, date, size, headers, body})))))

def msg_key(+k: String, +v: IV, +uid: U32, +flags: List<&2, String>, +date: String, +size: U32, +headers: String, +body: String) -> Msg:
  match v:
    case IList{xs}:
      Bool.pick(Msg, String.eq(k, "FLAGS"), Msg{uid, iv_strs(xs), date, size, headers, body}, Msg{uid, flags, date, size, headers, body})
    case _:
      msg_scalar(k, iv_str(v), uid, flags, date, size, headers, body)

def msg_set(+m: Msg, +k: String, +v: IV) -> Msg:
  match m:
    case Msg{uid, flags, date, size, headers, body}:
      msg_key(String.to_upper(k), v, uid, flags, date, size, headers, body)

def msg_pairs(+vs: List<&2, IV>, +m: Msg) -> Msg:
  match vs:
    case Con{IAtom{k}, Con{v, rest}}:
      msg_pairs(rest, msg_set(m, k, v))
    case _:
      m

def msg_of(+vs: List<&2, IV>) -> List<&2, Msg>:
  match vs:
    case Con{n, Con{IAtom{f}, Con{IList{items}, Nil{}}}}:
      [msg_pairs(items, msg_empty())]
    case _:
      []

def fetch_line(+is_fetch: Bool, +text: String, +lits: List<&2, String>) -> List<&2, Msg>:
  match is_fetch:
    case True{}:
      msg_of(tokens(String.drop(text, 2n), lits))
    case False{}:
      []

def before_paren(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'(', t}:
      "("
    case SCon{c, t}:
      SCon{c, before_paren(t)}

# Messages from "* <n> FETCH (...)" lines.
def fetched(+lines: List<&2, RLine>) -> List<&2, Msg>:
  match lines:
    case Nil{}:
      []
    case Con{RLine{+text, lits}, t}:
      List.append(&2, Msg, fetch_line(String.starts_with(text, "* ") && String.contains(String.to_upper(before_paren(text)), " FETCH "), text, lits), fetched(t))

# The untagged reply that pins a folder's UIDVALIDITY after SELECT.
def uidv_line(+v: U32) -> String:
  "* OK [UIDVALIDITY " ++ U32.show(v) ++ "]"

# The tagged status of command n: "OK", "NO", "BAD", or "" if it never ran.
def status(+lines: List<&2, RLine>, +n: U32) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{RLine{+text, l}, t}:
      Bool.pick(String, String.starts_with(text, tag(n) ++ " "), String.to_upper(before_space(after_space(text))), status(t, n))

# The status text (after OK/NO/BAD) of command n.
def status_text(+lines: List<&2, RLine>, +n: U32) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{RLine{+text, l}, t}:
      Bool.pick(String, String.starts_with(text, tag(n) ++ " "), after_space(after_space(text)), status_text(t, n))

def is_failure(+text: String) -> Bool:
  +st = String.to_upper(before_space(after_space(text)))
  String.starts_with(text, "a") && (String.eq(st, "NO") || String.eq(st, "BAD"))

# The first rejected command's status line, or "" when every command ran.
def first_failure(+lines: List<&2, RLine>) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{RLine{+text, l}, t}:
      Bool.pick(String, is_failure(text), text, first_failure(t))
