import Base
import ./codec.bend as C

# Reading RFC 5322 / MIME messages (from byte strings) and composing new
# ones. Composed messages are 7-bit ASCII: headers use RFC 2047 encoded
# words, text is quoted-printable and attachments base64.

# ---- header and body ---------------------------------------------------------------

type Split is Data:
  Split{head: String, body: String}

type Hdr is Data:
  Hdr{name: String, value: String}

type Att is Data:
  Att{name: String, ctype: String, size: U32}

# What a message holds for the reader: the first text/plain part, the first
# text/html part, and every other part as an attachment.
type Parts is Data:
  Parts{text: String, html: String, atts: List<&2, Att>}

type Cut is Data:
  Cut{cur: List<&2, String>, parts: List<&2, String>, inside: Bool, done: Bool}

# ---- HTML to text (fallback when there is no text/plain part) ---------------------------------

type Strip is Data:
  Strip{out: String, tag: Bool}

# An attachment to send: file name, content type and the raw bytes.
type Attach is Data:
  Attach{name: String, ctype: String, data: String}

# A message to compose. `to`, `cc` may hold "Name <addr>" forms; Bcc is
# never written into the message.
type Draft is Data:
  Draft{from: String, to: List<&2, String>, cc: List<&2, String>, subject: String, text: String, date: String, msgid: String, in_reply_to: String, refs: String, atts: List<&2, Attach>}

# Splits at the first empty line (CRLF CRLF, or LF LF).
def split_go(+s: String, +acc: String) -> Split:
  match s:
    case SNil{}:
      Split{String.reverse(acc), ""}
    case SCon{'\r', SCon{'\n', SCon{'\r', SCon{'\n', t}}}}:
      Split{String.reverse(acc), t}
    case SCon{'\n', SCon{'\n', t}}:
      Split{String.reverse(acc), t}
    case SCon{c, t}:
      split_go(t, SCon{c, acc})

def split(+msg: String) -> Split:
  split_go(msg, "")

def head_of(+s: Split) -> String:
  match s:
    case Split{h, b}:
      h

def body_of(+s: Split) -> String:
  match s:
    case Split{h, b}:
      b

def strip_cr(+s: String) -> String:
  Bool.pick(String, String.ends_with(s, "\r"), String.take(s, Nat.sub(String.length(s), 1n)), s)

def is_cont(+line: String) -> Bool:
  String.starts_with(line, " ") || String.starts_with(line, "\t")

def before_colon(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{':', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_colon(t)}

def after_colon(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{':', t}:
      t
    case SCon{c, t}:
      after_colon(t)

def hdr_cont(+line: String, +acc: List<&2, Hdr>) -> List<&2, Hdr>:
  match acc:
    case Con{Hdr{n, v}, r}:
      Hdr{n, v ++ " " ++ String.trim(line)} <> r
    case Nil{}:
      []

def hdr_line(+line: String, +acc: List<&2, Hdr>) -> List<&2, Hdr>:
  Bool.pick(List<&2, Hdr>, is_cont(line), hdr_cont(line, acc),
    Bool.pick(List<&2, Hdr>, String.contains(line, ":"), Hdr{String.to_lower(String.trim(before_colon(line))), String.trim(after_colon(line))} <> acc, acc))

def hdr_fold(+lines: List<&2, String>, +acc: List<&2, Hdr>) -> List<&2, Hdr>:
  match lines:
    case Nil{}:
      List.reverse(&2, Hdr, acc)
    case Con{l, t}:
      hdr_fold(t, hdr_line(strip_cr(l), acc))

# The header fields, unfolded, with lower-case names and raw values.
def headers(+head: String) -> List<&2, Hdr>:
  hdr_fold(String.split(head, '\n'), [])

def header(+hs: List<&2, Hdr>, +name: String) -> String:
  match hs:
    case Nil{}:
      ""
    case Con{Hdr{n, v}, t}:
      Bool.pick(String, String.eq(n, name), v, header(t, name))

def ew_bytes(+enc: String, +text: String) -> String:
  Bool.pick(String, String.eq(enc, "B"), C.b64_decode(text), C.qp_decode(text, True{}))

# ---- RFC 2047 encoded words -----------------------------------------------------------

def ew_parts(+ps: List<&2, String>, +word: String) -> String:
  match ps:
    case Con{"=", Con{cs, Con{enc, Con{text, Con{"=", Nil{}}}}}}:
      C.charset_decode(cs, ew_bytes(String.to_upper(enc), text))
    case _:
      C.utf8_decode(word)

def is_ew(+w: String) -> Bool:
  String.starts_with(w, "=?") && String.ends_with(w, "?=")

def ew_word(+w: String) -> String:
  Bool.pick(String, is_ew(w), ew_parts(String.split(w, '?'), w), C.utf8_decode(w))

# Joins decoded words; the space between two encoded words is dropped.
def ew_join(+ws: List<&2, String>, +prev_ew: Bool, +first: Bool) -> String:
  match ws:
    case Nil{}:
      ""
    case Con{w, t}:
      Bool.pick(String, first || (prev_ew && is_ew(w)), "", " ") ++ ew_word(w) ++ ew_join(t, is_ew(w), False{})

# A raw header value to text: encoded words decoded, raw 8-bit read as UTF-8.
def decode_header(+v: String) -> String:
  ew_join(String.split(v, ' '), False{}, True{})

# ---- parameters (Content-Type, Content-Disposition) ----------------------------------------

def unescape(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\\', SCon{c, t}}:
      SCon{c, unescape(t)}
    case SCon{c, t}:
      SCon{c, unescape(t)}

def unquote(+s: String) -> String:
  +t = String.trim(s)
  Bool.pick(String, String.starts_with(t, "\"") && String.ends_with(t, "\"") && Nat.is_gt(String.length(t), 1n),
    unescape(String.take(String.drop(t, 1n), Nat.sub(String.length(t), 2n))), t)

def first_item(+xs: List<&2, String>) -> String:
  match xs:
    case Con{h, t}:
      h
    case Nil{}:
      ""

def sp_go(+s: String, +cur: String, +q: Bool, +esc: Bool, +acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, String.reverse(cur) <> acc)
    case SCon{c, t}:
      +cut = Bool.not(esc) && Bool.not(q) && Char.is_eq(c, ';')
      sp_go(t, Bool.pick(String, cut, "", SCon{c, cur}),
        Bool.pick(Bool, Bool.not(esc) && Char.is_eq(c, '"'), Bool.not(q), q),
        Bool.not(esc) && q && Char.is_eq(c, '\\'),
        Bool.pick(List<&2, String>, cut, String.reverse(cur) <> acc, acc))

# Splits a structured header value at ';' outside quoted strings (which may
# hold "\"" escapes), so 'filename="Q1; final.pdf"' stays one parameter.
def split_params(+s: String) -> List<&2, String>:
  sp_go(s, "", False{}, False{}, [])

# The main value before the first ';', lower-cased.
def main_value(+v: String) -> String:
  String.to_lower(String.trim(first_item(split_params(v))))

def pct_decode(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'%', SCon{a, SCon{b, t}}}:
      SCon{C.chr(((C.hex_val(a) * 16 + C.hex_val(b)) .&. 255 : U32)), pct_decode(t)}
    case SCon{c, t}:
      SCon{c, pct_decode(t)}

def ext_parts(+ps: List<&2, String>, +v: String) -> String:
  match ps:
    case Con{cs, Con{lang, Con{text, Nil{}}}}:
      C.charset_decode(cs, pct_decode(text))
    case _:
      v

# RFC 2231 "charset'lang'%XX..." to text.
def ext_value(+v: String) -> String:
  ext_parts(String.split(v, '\''), v)

def param_only(+key: String, +val: String, +name: String, +rest: String) -> String:
  Bool.pick(String, String.eq(key, name), val, rest)

def before_eq(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'=', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_eq(t)}

def after_eq(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'=', t}:
      t
    case SCon{c, t}:
      after_eq(t)

# The raw value of exactly the parameter `name`, or "".
def param_raw(+ps: List<&2, String>, +name: String) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{p, t}:
      param_only(String.to_lower(String.trim(before_eq(p))), after_eq(p), name, param_raw(t, name))

def param_one(+key: String, +val: String, +name: String, +rest: String) -> String:
  Bool.pick(String, String.eq(key, name), decode_header(unquote(val)),
    Bool.pick(String, String.eq(key, name ++ "*"), ext_value(unquote(val)), rest))

def param_go(+ps: List<&2, String>, +name: String) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{p, t}:
      param_one(String.to_lower(String.trim(before_eq(p))), after_eq(p), name, param_go(t, name))

def rest_items(+xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{h, t}:
      t
    case Nil{}:
      []

# An RFC 2231 attr-char: kept as is in an extended parameter value.
def attr_char(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '!') || Char.is_eq(c, '#') || Char.is_eq(c, '$') || Char.is_eq(c, '&') || Char.is_eq(c, '+') || Char.is_eq(c, '-') || Char.is_eq(c, '.') || Char.is_eq(c, '^') || Char.is_eq(c, '_') || Char.is_eq(c, '`') || Char.is_eq(c, '|') || Char.is_eq(c, '~')

def pct_char(+c: Char) -> String:
  Bool.pick(String, U32.is_lt(C.u(c), 128) && attr_char(c), SCon{c, SNil{}}, "%" ++ SCon{C.hex_up((C.u(c) >> 4n : U32)), SCon{C.hex_up((C.u(c) .&. 15 : U32)), SNil{}}})

def pct_encode(+bytes: String) -> String:
  match bytes:
    case SNil{}:
      ""
    case SCon{c, t}:
      pct_char(c) ++ pct_encode(t)

# An RFC 2231 continuation value ("name*0*=...;name*1*=..."), joined in
# order and percent-encoded throughout, so ext_value can decode it; "" when
# there is none. Plain (unencoded) segments are percent-encoded first.
def cont_join(fuel: Nat, +ps: List<&2, String>, +name: String, +n: U32) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+f:
      +enc = param_raw(ps, name ++ "*" ++ U32.show(n) ++ "*")
      +plain = unquote(param_raw(ps, name ++ "*" ++ U32.show(n)))
      Bool.pick(String, String.is_empty(enc) && String.is_empty(plain), "",
        Bool.pick(String, String.is_empty(enc), pct_encode(C.utf8_encode(plain)), unquote(enc)) ++ cont_join(f, ps, name, (n + 1 : U32)))

# A parameter of a structured header value, e.g. param(ct, "charset"). An
# RFC 2231 extended value ("name*=", or continuations "name*0*=", ...) wins
# over a plain fallback ("name=").
def param(+v: String, +name: String) -> String:
  +ps = rest_items(split_params(v))
  +ext = unquote(param_raw(ps, name ++ "*"))
  +cont = cont_join(64n, ps, name, 0)
  Bool.pick(String, Bool.not(String.is_empty(ext)), ext_value(ext),
    Bool.pick(String, Bool.not(String.is_empty(cont)), ext_value(cont), param_go(ps, name)))

# ---- bodies ----------------------------------------------------------------------

def transfer_decode(+cte: String, +body: String) -> String:
  +e = String.to_lower(String.trim(cte))
  Bool.pick(String, String.eq(e, "base64"), C.b64_decode(body),
    Bool.pick(String, String.eq(e, "quoted-printable"), C.qp_decode(body, False{}), body))

def default_cs(+cs: String) -> String:
  Bool.pick(String, String.is_empty(cs), "utf-8", cs)

def merge(+a: Parts, +b: Parts) -> Parts:
  match a:
    case Parts{t1, h1, a1}:
      match b:
        case Parts{t2, h2, a2}:
          Parts{Bool.pick(String, String.is_empty(t1), t2, t1), Bool.pick(String, String.is_empty(h1), h2, h1), List.append(&2, Att, a1, a2)}

def no_parts() -> Parts:
  Parts{"", "", []}

# Normalizes line breaks to LF (for text handed to agents).
def lf_lines(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      "\n" ++ lf_lines(t)
    case SCon{c, t}:
      SCon{c, lf_lines(t)}

def leaf_hs(+hs: List<&2, Hdr>, +body: String) -> Parts:
  +ct = header(hs, "content-type")
  +cd = header(hs, "content-disposition")
  +typ = Bool.pick(String, String.is_empty(ct), "text/plain", main_value(ct))
  +fname = Bool.pick(String, String.is_empty(param(cd, "filename")), param(ct, "name"), param(cd, "filename"))
  +bytes = transfer_decode(header(hs, "content-transfer-encoding"), body)
  +attached = String.eq(main_value(cd), "attachment") || Bool.not(String.is_empty(fname))
  Bool.pick(Parts, Bool.not(attached) && String.eq(typ, "text/plain"), Parts{lf_lines(C.charset_decode(default_cs(param(ct, "charset")), bytes)), "", []},
    Bool.pick(Parts, Bool.not(attached) && String.eq(typ, "text/html"), Parts{"", lf_lines(C.charset_decode(default_cs(param(ct, "charset")), bytes)), []},
      Parts{"", "", [Att{fname, typ, U32.from_nat(String.length(bytes))}]}))

# One non-multipart entity (its header and body).
def leaf(+part: String) -> Parts:
  leaf_hs(headers(head_of(split(part))), body_of(split(part)))

# The boundary of a multipart entity, or "" for a single part.
def boundary_of(+part: String) -> String:
  +ct = header(headers(head_of(split(part))), "content-type")
  Bool.pick(String, String.starts_with(main_value(ct), "multipart/"), param(ct, "boundary"), "")

def cut_push(+cur: List<&2, String>, +parts: List<&2, String>, +inside: Bool) -> List<&2, String>:
  Bool.pick(List<&2, String>, inside, String.join(List.reverse(&2, String, cur), "\r\n") <> parts, parts)

def cut_line(+line: String, +b: String, +c: Cut) -> Cut:
  match c:
    case Cut{cur, parts, inside, done}:
      Bool.pick(Cut, done, c,
        Bool.pick(Cut, String.eq(String.trim_end(line), "--" ++ b ++ "--"), Cut{[], cut_push(cur, parts, inside), False{}, True{}},
          Bool.pick(Cut, String.eq(String.trim_end(line), "--" ++ b), Cut{[], cut_push(cur, parts, inside), True{}, False{}},
            Cut{Bool.pick(List<&2, String>, inside, line <> cur, cur), parts, inside, done})))

def cut_go(+lines: List<&2, String>, +b: String, +c: Cut) -> Cut:
  match lines:
    case Nil{}:
      c
    case Con{l, t}:
      cut_go(t, b, cut_line(strip_cr(l), b, c))

def cut_end(+c: Cut) -> List<&2, String>:
  match c:
    case Cut{cur, parts, inside, done}:
      List.reverse(&2, String, cut_push(cur, parts, inside && Bool.not(done)))

# The body parts of a multipart entity (without the preamble and epilogue).
# A truncated message keeps its last, partial part.
def subparts(+part: String) -> List<&2, String>:
  +b = boundary_of(part)
  Bool.pick(List<&2, String>, String.is_empty(b), [], cut_end(cut_go(String.split(body_of(split(part)), '\n'), b, Cut{[], [], False{}, False{}})))

# Walks nested multiparts up to `depth` levels.
def walk(+depth: Nat, +parts: List<&2, String>) -> Parts:
  match depth:
    case 0n:
      no_parts()
    case 1n+p:
      match parts:
        case Nil{}:
          no_parts()
        case Con{part, rest}:
          merge(Bool.pick(Parts, String.is_empty(boundary_of(part)), leaf(part), walk(p, subparts(part))), walk(1n+p, rest))

# The readable content of a whole message.
def parts(+msg: String) -> Parts:
  walk(8n, [msg])

def strip_set(+st: Strip, +c: Char, +mode: U32) -> Strip:
  match st:
    case Strip{out, tag}:
      Bool.pick(Strip, U32.is_eq(mode, 0), Strip{out, True{}},
        Bool.pick(Strip, U32.is_eq(mode, 1), Strip{Bool.pick(String, tag, SCon{' ', out}, SCon{c, out}), False{}},
          Strip{Bool.pick(String, tag, out, SCon{c, out}), tag}))

# mode 0: '<' opens a tag; 1: '>' closes it; 2: any other char.
def strip_step(+c: Char, +st: Strip) -> Strip:
  match c:
    case '<':
      strip_set(st, c, 0)
    case '>':
      strip_set(st, c, 1)
    case _:
      strip_set(st, c, 2)

def strip_go(+s: String, +st: Strip) -> Strip:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      strip_go(t, strip_step(c, st))

# Decodes the common HTML entities.
def entities(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'&', SCon{'a', SCon{'m', SCon{'p', SCon{';', t}}}}}:
      "&" ++ entities(t)
    case SCon{'&', SCon{'l', SCon{'t', SCon{';', t}}}}:
      "<" ++ entities(t)
    case SCon{'&', SCon{'g', SCon{'t', SCon{';', t}}}}:
      ">" ++ entities(t)
    case SCon{'&', SCon{'q', SCon{'u', SCon{'o', SCon{'t', SCon{';', t}}}}}}:
      "\"" ++ entities(t)
    case SCon{'&', SCon{'#', SCon{'3', SCon{'9', SCon{';', t}}}}}:
      "'" ++ entities(t)
    case SCon{'&', SCon{'n', SCon{'b', SCon{'s', SCon{'p', SCon{';', t}}}}}}:
      " " ++ entities(t)
    case SCon{c, t}:
      SCon{c, entities(t)}

def strip_out(+st: Strip) -> String:
  match st:
    case Strip{out, tag}:
      String.reverse(out)

def is_blank(+c: Char) -> Bool:
  Char.is_eq(c, ' ') || Char.is_eq(c, '\t')

# Collapses runs of spaces and tabs into one space.
def squeeze(+s: String, +sp: Bool) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      Bool.pick(String, is_blank(c), Bool.pick(String, sp, "", " "), SCon{c, SNil{}}) ++ squeeze(t, is_blank(c))

# A rough plain-text view of HTML: tags removed, common entities decoded.
def html_text(+html: String) -> String:
  squeeze(entities(strip_out(strip_go(html, Strip{"", False{}}))), False{})

# ---- composing ---------------------------------------------------------------------

# Splits text into chunks of at most 45 UTF-8 bytes (60 base64 chars), at
# character boundaries, for encoded words.
def ew_chunks(+s: String, +cur: String, +n: U32) -> List<&2, String>:
  match s:
    case SNil{}:
      Bool.pick(List<&2, String>, String.is_empty(cur), [], [String.reverse(cur)])
    case SCon{c, t}:
      +w = C.utf8_width(C.u(c))
      +full = U32.is_gt((n + w : U32), 45)
      List.append(&2, String, Bool.pick(List<&2, String>, full, [String.reverse(cur)], []),
        ew_chunks(t, Bool.pick(String, full, SCon{c, SNil{}}, SCon{c, cur}), Bool.pick(U32, full, w, (n + w : U32))))

def ew_encode(+chunks: List<&2, String>) -> String:
  match chunks:
    case Nil{}:
      ""
    case Con{c, Nil{}}:
      "=?UTF-8?B?" ++ C.b64_encode(C.utf8_encode(c), False{}) ++ "?="
    case Con{c, t}:
      "=?UTF-8?B?" ++ C.b64_encode(C.utf8_encode(c), False{}) ++ "?=\r\n " ++ ew_encode(t)

def encode_as(+raw: Bool, +s: String) -> String:
  match raw:
    case True{}:
      s
    case False{}:
      ew_encode(ew_chunks(s, "", 0))

# Header text as-is when it is short plain ASCII, else as encoded words,
# which fold into lines of at most 76 characters (a header line may not
# pass 998).
def encode_header(+s: String) -> String:
  encode_as(C.is_plain(s) && Nat.is_le(String.length(s), 900n), s)

def before_lt(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'<', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_lt(t)}

def before_gt(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'>', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_gt(t)}

# The text inside the last "<...>" (a display name may itself contain "<").
def last_angle(+s: String, +found: String) -> String:
  match s:
    case SNil{}:
      found
    case SCon{'<', t}:
      last_angle(t, before_gt(t))
    case SCon{c, t}:
      last_angle(t, found)

def inside_angle(+s: String) -> String:
  last_angle(s, "")

# The text without "(comments)" (nested, outside quotes).
def strip_comments(+s: String, +depth: U32, +q: Bool) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      +open = Bool.not(q) && Char.is_eq(c, '(')
      +close = Bool.not(q) && Char.is_eq(c, ')') && Bool.not(U32.is_zero(depth))
      +keep = U32.is_zero(depth) && Bool.not(open)
      Bool.pick(String, keep, SCon{c, SNil{}}, "") ++ strip_comments(t,
        Bool.pick(U32, open, (depth + 1 : U32), Bool.pick(U32, close, (depth - 1 : U32), depth)),
        Bool.pick(Bool, U32.is_zero(depth) && Char.is_eq(c, '"'), Bool.not(q), q))

# The bare address of "Name <addr>" or "addr (comment)".
def addr_spec(+a: String) -> String:
  Bool.pick(String, String.contains(a, "<"), String.trim(inside_angle(a)), String.trim(strip_comments(a, 0, False{})))

def addr_char_ok(+c: Char) -> Bool:
  C.between(C.u(c), 33, 126) && Bool.not(Char.is_eq(c, '<') || Char.is_eq(c, '>') || Char.is_eq(c, '"') || Char.is_eq(c, ',') || Char.is_eq(c, ';') || Char.is_eq(c, '\\'))

def addr_chars_ok(+s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      addr_char_ok(c) && addr_chars_ok(t)

# No control characters (CR, LF, NUL, ...) anywhere.
def no_ctl(+s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Bool.not(U32.is_lt(C.u(c), 32) || U32.is_eq(C.u(c), 127)) && no_ctl(t)

def count_at(+s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{'@', t}:
      1n+count_at(t)
    case SCon{c, t}:
      count_at(t)

# A usable envelope address: printable, no specials, one '@' with text on
# both sides. This keeps CR/LF and SMTP syntax out of MAIL/RCPT lines.
def addr_ok(+a: String) -> Bool:
  +s = addr_spec(a)
  no_ctl(a) && addr_chars_ok(s) && Nat.is_eq(count_at(s), 1n) && Bool.not(String.starts_with(s, "@")) && Bool.not(String.ends_with(s, "@"))

def all_addrs_ok(+xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{x, t}:
      addr_ok(x) && all_addrs_ok(t)

def quote_esc(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'"', t}:
      "\\\"" ++ quote_esc(t)
    case SCon{'\\', t}:
      "\\\\" ++ quote_esc(t)
    case SCon{c, t}:
      SCon{c, quote_esc(t)}

def encode_display(+name: String) -> String:
  Bool.pick(String, C.is_plain(name) && Nat.is_le(String.length(name), 200n), "\"" ++ quote_esc(name) ++ "\"", encode_as(False{}, name))

# "Name <addr>" with the display name encoded when needed.
def encode_addr(+a: String) -> String:
  +name = String.trim(before_lt(a))
  Bool.pick(String, String.contains(a, "<") && Bool.not(String.is_empty(name)),
    encode_display(unquote(name)) ++ " <" ++ addr_spec(a) ++ ">", addr_spec(a))

def encode_addrs(+xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, Nil{}}:
      encode_addr(x)
    case Con{x, t}:
      encode_addr(x) ++ ",\r\n " ++ encode_addrs(t)

# Normalizes line breaks to CRLF.
def crlf_lines(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      "\r\n" ++ crlf_lines(t)
    case SCon{'\r', t}:
      "\r\n" ++ crlf_lines(t)
    case SCon{'\n', t}:
      "\r\n" ++ crlf_lines(t)
    case SCon{c, t}:
      SCon{c, crlf_lines(t)}

# Anything but printable ASCII (CR, LF, controls, 8-bit) becomes a space, so
# a value can never start a new header line or break 7-bit transport.
def one_line(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      SCon{Bool.pick(Char, C.between(C.u(c), 32, 126), c, ' '), one_line(t)}

# A one-line header value that fits a header line, or "" (dropped).
def short_line(+s: String) -> String:
  Bool.pick(String, Nat.is_le(String.length(s), 900n), s, "")

# Message IDs folded one per line, so References never passes 998 chars.
def fold_ids(+ids: List<&2, String>) -> String:
  match ids:
    case Nil{}:
      ""
    case Con{i, t}:
      +rest = fold_ids(t)
      Bool.pick(String, String.is_empty(i), "", short_line(i) ++ Bool.pick(String, String.is_empty(rest), "", "\r\n ")) ++ rest

def opt_header(+name: String, +v: String) -> String:
  Bool.pick(String, String.is_empty(v), "", name ++ ": " ++ v ++ "\r\n")

def ctype_char(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '/') || Char.is_eq(c, '-') || Char.is_eq(c, '+') || Char.is_eq(c, '.') || Char.is_eq(c, '_')

def ctype_chars(+s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      ctype_char(c) && ctype_chars(t)

# A content type as "type/subtype" with safe characters, else
# application/octet-stream.
def safe_ctype(+t: String) -> String:
  Bool.pick(String, ctype_chars(t) && Nat.is_eq(List.length(&2, String, String.split(t, '/')), 2n) && Bool.not(String.starts_with(t, "/")) && Bool.not(String.ends_with(t, "/")), String.to_lower(t), "application/octet-stream")

def text_part_headers() -> String:
  "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n"

def text_body(+text: String) -> String:
  C.qp_encode(C.utf8_encode(crlf_lines(text)), 0)

# Whether bytes can travel as 7bit: ASCII, no NUL or bare CR/LF, and no
# line longer than 998 characters.
def seven_bit(+s: String, +col: U32) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{'\r', SCon{'\n', t}}:
      seven_bit(t, 0)
    case SCon{c, t}:
      Bool.not(U32.is_gt(C.u(c), 126) || U32.is_zero(C.u(c)) || Char.is_eq(c, '\r') || Char.is_eq(c, '\n') || U32.is_ge(col, 998)) && seven_bit(t, (col + 1 : U32))

# An ASCII stand-in for a non-ASCII name (for readers without RFC 2231).
def ascii_name(+s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      SCon{Bool.pick(Char, C.between(C.u(c), 32, 126) && Bool.not(Char.is_eq(c, '"') || Char.is_eq(c, '\\')), c, '_'), ascii_name(t)}

def pct_tokens(+bytes: String) -> List<&2, String>:
  match bytes:
    case SNil{}:
      []
    case SCon{c, t}:
      pct_char(c) <> pct_tokens(t)

# Groups percent-encoded tokens into pieces of at most 50 characters,
# never splitting a %XX escape.
def pct_pieces(+ts: List<&2, String>, +cur: String, +n: U32) -> List<&2, String>:
  match ts:
    case Nil{}:
      Bool.pick(List<&2, String>, String.is_empty(cur), [], [cur])
    case Con{tok, t}:
      +w = U32.from_nat(String.length(tok))
      +full = U32.is_gt((n + w : U32), 50)
      List.append(&2, String, Bool.pick(List<&2, String>, full, [cur], []),
        pct_pieces(t, Bool.pick(String, full, tok, cur ++ tok), Bool.pick(U32, full, w, (n + w : U32))))

def cont_params(+key: String, +pieces: List<&2, String>, +i: U32) -> String:
  match pieces:
    case Nil{}:
      ""
    case Con{p, t}:
      ";\r\n " ++ key ++ "*" ++ U32.show(i) ++ "*=" ++ Bool.pick(String, U32.is_zero(i), "utf-8''", "") ++ p ++ cont_params(key, t, (i + 1 : U32))

# A file name parameter: quoted when it is short plain ASCII, else an ASCII
# fallback plus RFC 2231 continuations of the UTF-8 name, percent-encoded,
# one short line each (encoded words are not allowed inside parameters).
def name_param(+key: String, +name: String) -> String:
  Bool.pick(String, C.is_plain(name) && Nat.is_le(String.length(name), 200n),
    key ++ "=\"" ++ quote_esc(name) ++ "\"",
    key ++ "=\"" ++ ascii_name(String.take(name, 60n)) ++ "\"" ++ cont_params(key, pct_pieces(pct_tokens(C.utf8_encode(name)), "", 0), 0))

def att_head(+b: String, +ctype: String, +name: String, +cte: String) -> String:
  "--" ++ b ++ "\r\nContent-Type: " ++ ctype ++ "; " ++ name_param("name", name) ++ "\r\nContent-Disposition: attachment; " ++ name_param("filename", name) ++ "\r\nContent-Transfer-Encoding: " ++ cte ++ "\r\n\r\n"

# RFC 2046 allows only 7bit/8bit/binary for message/rfc822: a 7-bit clean
# message is included as is; anything else goes as an opaque base64 file.
def att_part(+b: String, +a: Attach) -> String:
  match a:
    case Attach{name, ctype, data}:
      Bool.pick(String, String.eq(safe_ctype(ctype), "message/rfc822") && seven_bit(data, 0),
        att_head(b, "message/rfc822", name, "7bit") ++ data ++ Bool.pick(String, String.ends_with(data, "\r\n"), "", "\r\n"),
        att_head(b, Bool.pick(String, String.eq(safe_ctype(ctype), "message/rfc822"), "application/octet-stream", safe_ctype(ctype)), name, "base64") ++ C.wrap76(C.b64_encode(data, False{}), 0))

def att_parts(+b: String, +xs: List<&2, Attach>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{a, t}:
      att_part(b, a) ++ att_parts(b, t)

def body_section(+b: String, +text: String, +atts: List<&2, Attach>) -> String:
  match atts:
    case Nil{}:
      text_part_headers() ++ "\r\n" ++ text_body(text)
    case Con{h, t}:
      "Content-Type: multipart/mixed; boundary=\"" ++ b ++ "\"\r\n\r\nThis is a multi-part message in MIME format.\r\n--" ++ b ++ "\r\n" ++ text_part_headers() ++ "\r\n" ++ text_body(text) ++ "\r\n" ++ att_parts(b, atts) ++ "--" ++ b ++ "--\r\n"

# The whole message, 7-bit ASCII with CRLF line breaks. `b` is the
# multipart boundary to use when there are attachments.
def compose(+d: Draft, +b: String) -> String:
  match d:
    case Draft{from, to, cc, subject, text, date, msgid, irt, refs, atts}:
      "From: " ++ encode_addr(from) ++ "\r\n" ++
      opt_header("To", encode_addrs(to)) ++
      opt_header("Cc", encode_addrs(cc)) ++
      "Subject: " ++ encode_header(subject) ++ "\r\n" ++
      "Date: " ++ date ++ "\r\n" ++
      "Message-ID: " ++ msgid ++ "\r\n" ++
      opt_header("In-Reply-To", short_line(String.trim(one_line(irt)))) ++
      opt_header("References", fold_ids(String.split(String.trim(one_line(refs)), ' '))) ++
      "MIME-Version: 1.0\r\n" ++
      body_section(b, text, atts)

# ---- dates ---------------------------------------------------------------------------

def pad2(+n: U32) -> String:
  Bool.pick(String, U32.is_lt(n, 10), "0", "") ++ U32.show(n)

def day_name(+n: U32) -> String:
  match n:
    case 0: "Sun"
    case 1: "Mon"
    case 2: "Tue"
    case 3: "Wed"
    case 4: "Thu"
    case 5: "Fri"
    case _: "Sat"

def wday(+days: U32) -> String:
  day_name(((days + 4) % 7 : U32))

def mon(+m: U32) -> String:
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
    case _: "Dec"

# Days since 1970-01-01 to "D Mon YYYY" (civil-from-days, H. Hinnant),
# shifted by 719468 days so all arithmetic stays unsigned.
def civil(+days: U32) -> String:
  +z = (days + 719468 : U32)
  +era = (z / 146097 : U32)
  +doe = (z - era * 146097 : U32)
  +yoe = ((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 : U32)
  +doy = (doe - (365 * yoe + yoe / 4 - yoe / 100) : U32)
  +mp = ((5 * doy + 2) / 153 : U32)
  +d = (doy - (153 * mp + 2) / 5 + 1 : U32)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), (mp + 3 : U32), (mp - 9 : U32))
  +y = (yoe + era * 400 + Bool.to_u32(U32.is_le(m, 2)) : U32)
  U32.show(d) ++ " " ++ mon(m) ++ " " ++ U32.show(y)

# Seconds since the epoch to an RFC 5322 date in UTC.
def rfc5322_date(+secs: U32) -> String:
  +days = (secs / 86400 : U32)
  +rem = (secs % 86400 : U32)
  wday(days) ++ ", " ++ civil(days) ++ " " ++ pad2((rem / 3600 : U32)) ++ ":" ++ pad2(((rem % 3600) / 60 : U32)) ++ ":" ++ pad2((rem % 60 : U32)) ++ " +0000"
