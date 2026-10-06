# Reading RFC 5322 / MIME messages (from byte strings) and composing new
# ones. Composed messages are 7-bit ASCII: headers use RFC 2047 encoded
# words, text is quoted-printable and attachments base64.
#
# An argument is built before the call, so Bool.pick builds both of its
# branches. Where a branch decodes, encodes or scans a body, a helper
# (`.if`, `.put`) matches the Bool instead and builds only the branch taken.

import Base
import ./codec.bend as C

# Types
# =====

# A message cut at its first empty line.
type Split is Data:
  Split{head: String, body: String}

# A header field: the lower-case name and the raw, unfolded value.
type Hdr is Data:
  Hdr{name: String, value: String}

# An attachment as the reader sees it: file name, content type and the
# size of the transfer-decoded bytes.
type Att is Data:
  Att{name: String, ctype: String, size: U32}

# What a message holds for the reader: the first text/plain part, the first
# text/html part, and every other part as an attachment.
type Parts is Data:
  Parts{text: String, html: String, atts: List<&2, Att>}

# Cutting a multipart body: the open part's lines and the finished parts
# (both newest first), whether a part is open, and whether the closing
# boundary has passed.
type Cut is Data:
  Cut{cur: List<&2, String>, parts: List<&2, String>, inside: Bool, done: Bool}

# Stripping HTML: the text so far (reversed) and whether inside a tag.
type Strip is Data:
  Strip{out: String, tag: Bool}

# An attachment to send: file name, content type and the raw bytes.
type Attach is Data:
  Attach{name: String, ctype: String, data: String}

# A message to compose. Recipient lists may hold "Name <addr>" forms.
# Callers retain Bcc for drafts and remove it before SMTP composition.
type Draft is Data:
  Draft{
    from: String, to: List<&2, String>, cc: List<&2, String>,
    bcc: List<&2, String>, subject: String, text: String, date: String,
    msgid: String, in_reply_to: String, refs: String,
    atts: List<&2, Attach>
  }

# Text helpers
# ============

# Whether c is one of the characters of `set`.
def char_in(c: Char, set: String) -> Bool:
  String.contains(set, SCon{c, SNil{}})

# Whether s is plain ASCII of at most `max` characters.
def is_short_plain(+s: String, max: Nat) -> Bool:
  C.is_plain(s) && Nat.is_le(String.length(s), max)

# The item `cur` (built reversed) pushed onto `acc` when `push`.
def push_rev(
  cur: String, acc: List<&2, String>, push: Bool
) -> List<&2, String>:
  match push:
    case True{}:
      String.reverse(cur) <> acc
    case False{}:
      acc

# Reading
# =======

# Header and body
# ---------------

# Splits at the first empty line (CRLF CRLF, or LF LF).
def split.go(s: String, acc: String) -> Split:
  match s:
    case SNil{}:
      Split{String.reverse(acc), ""}
    case SCon{'\r', SCon{'\n', SCon{'\r', SCon{'\n', t}}}}:
      Split{String.reverse(acc), t}
    case SCon{'\n', SCon{'\n', t}}:
      Split{String.reverse(acc), t}
    case SCon{c, t}:
      split.go(t, SCon{c, acc})

def split(msg: String) -> Split:
  split.go(msg, "")

def head_of(s: Split) -> String:
  Split{head, body} = s
  head

def body_of(s: Split) -> String:
  Split{head, body} = s
  body

def strip_cr.if(+s: String, cr: Bool) -> String:
  match cr:
    case True{}:
      String.take(s, Nat.sub(String.length(s), 1n))
    case False{}:
      s

# A line without its trailing CR, if any.
def strip_cr(+s: String) -> String:
  strip_cr.if(s, String.ends_with(s, "\r"))

def is_cont(+line: String) -> Bool:
  String.starts_with(line, " ") || String.starts_with(line, "\t")

def before_colon(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{':', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_colon(t)}

def after_colon(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{':', t}:
      t
    case SCon{c, t}:
      after_colon(t)

# A continuation line extends the last field; with no field yet it is
# ignored.
def hdr_cont(line: String, acc: List<&2, Hdr>) -> List<&2, Hdr>:
  match acc:
    case Hdr{n, v} <> r:
      Hdr{n, v ++ " " ++ String.trim(line)} <> r
    case Nil{}:
      []

# Folds one line into the fields so far (newest first): a continuation
# extends the last field, "name: value" adds one, anything else is ignored.
def hdr_line.if(
  +line: String, acc: List<&2, Hdr>, cont: Bool, colon: Bool
) -> List<&2, Hdr>:
  match cont colon:
    case True{} _:
      hdr_cont(line, acc)
    case False{} True{}:
      name = String.to_lower(String.trim(before_colon(line)))
      Hdr{name, String.trim(after_colon(line))} <> acc
    case False{} False{}:
      acc

def hdr_line(+line: String, acc: List<&2, Hdr>) -> List<&2, Hdr>:
  hdr_line.if(line, acc, is_cont(line), String.contains(line, ":"))

def hdr_fold(lines: List<&2, String>, acc: List<&2, Hdr>) -> List<&2, Hdr>:
  match lines:
    case Nil{}:
      List.reverse(&2, Hdr, acc)
    case l <> t:
      hdr_fold(t, hdr_line(strip_cr(l), acc))

# The header fields, unfolded, with lower-case names and raw values.
def headers(head: String) -> List<&2, Hdr>:
  hdr_fold(String.split(head, '\n'), [])

# The value of the first field `name` (lower-case), or "".
def header(hs: List<&2, Hdr>, +name: String) -> String:
  match hs:
    case Nil{}:
      ""
    case Hdr{n, v} <> t:
      Bool.pick(String, String.eq(n, name), v, header(t, name))

# RFC 2047 encoded words
# ----------------------

def ew_bytes(b64: Bool, text: String) -> String:
  match b64:
    case True{}:
      C.b64_decode(text)
    case False{}:
      C.qp_decode(text, True{})

# "=?charset?enc?text?=" split at '?' to text; anything else is the raw
# word read as UTF-8.
def ew_parts(ps: List<&2, String>, word: String) -> String:
  match ps:
    case "=" <> cs <> enc <> text <> "=" <> Nil{}:
      C.charset_decode(cs, ew_bytes(String.eq(String.to_upper(enc), "B"), text))
    case _:
      C.utf8_decode(word)

def is_ew(+w: String) -> Bool:
  String.starts_with(w, "=?") && String.ends_with(w, "?=")

# A word to text; `encoded` says whether it looks like an encoded word.
def ew_word(+w: String, encoded: Bool) -> String:
  match encoded:
    case True{}:
      ew_parts(String.split(w, '?'), w)
    case False{}:
      C.utf8_decode(w)

# Joins decoded words; the space between two encoded words is dropped.
def ew_join(ws: List<&2, String>, prev_ew: Bool, first: Bool) -> String:
  match ws:
    case Nil{}:
      ""
    case +w <> t:
      +encoded = is_ew(w)
      sep = Bool.pick(String, first || (prev_ew && encoded), "", " ")
      sep ++ ew_word(w, encoded) ++ ew_join(t, encoded, False{})

def tab_to_space(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\t', t}:
      SCon{' ', tab_to_space(t)}
    case SCon{c, t}:
      SCon{c, tab_to_space(t)}

# A raw header value to text: encoded words decoded, raw 8-bit read as UTF-8.
# Space and tab are both linear whitespace between words.
def decode_header(v: String) -> String:
  ew_join(String.split(tab_to_space(v), ' '), False{}, True{})

# Parameters (Content-Type, Content-Disposition)
# ----------------------------------------------

def unescape(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\\', SCon{c, t}}:
      SCon{c, unescape(t)}
    case SCon{c, t}:
      SCon{c, unescape(t)}

def unquote.if(+t: String, quoted: Bool) -> String:
  match quoted:
    case True{}:
      unescape(String.take(String.drop(t, 1n), Nat.sub(String.length(t), 2n)))
    case False{}:
      t

# A trimmed value without its surrounding quotes and "\" escapes.
def unquote(s: String) -> String:
  +t = String.trim(s)
  quoted = String.starts_with(t, "\"") && String.ends_with(t, "\"")
  unquote.if(t, quoted && Nat.is_gt(String.length(t), 1n))

def split_params.go(
  s: String, +cur: String, +q: Bool, +esc: Bool, acc: List<&2, String>
) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, String.reverse(cur) <> acc)
    case SCon{+c, t}:
      +cut = Bool.not(esc) && Bool.not(q) && Char.is_eq(c, ';')
      quote = Bool.not(esc) && Char.is_eq(c, '"')
      split_params.go(t, Bool.pick(String, cut, "", SCon{c, cur}),
        Bool.pick(Bool, quote, Bool.not(q), q),
        Bool.not(esc) && q && Char.is_eq(c, '\\'),
        push_rev(cur, acc, cut))

# Splits a structured header value at ';' outside quoted strings (which may
# hold "\"" escapes), so 'filename="Q1; final.pdf"' stays one parameter.
def split_params(s: String) -> List<&2, String>:
  split_params.go(s, "", False{}, False{}, [])

# The main value before the first ';', lower-cased.
def main_value(v: String) -> String:
  first = Maybe.default(&2, String, List.head(&2, String, split_params(v)), "")
  String.to_lower(String.trim(first))

def pct_decode(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'%', SCon{a, SCon{b, t}}}:
      byte = ((C.hex_val(a) * 16 + C.hex_val(b)) .&. 255 : U32)
      SCon{C.chr(byte), pct_decode(t)}
    case SCon{c, t}:
      SCon{c, pct_decode(t)}

def ext_parts(ps: List<&2, String>, v: String) -> String:
  match ps:
    case cs <> lang <> text <> Nil{}:
      C.charset_decode(cs, pct_decode(text))
    case _:
      v

# RFC 2231 "charset'lang'%XX..." to text.
def ext_value(+v: String) -> String:
  ext_parts(String.split(v, '\''), v)

def before_eq(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'=', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_eq(t)}

def after_eq(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'=', t}:
      t
    case SCon{c, t}:
      after_eq(t)

# The key of a "key=value" parameter, trimmed and lower-cased.
def param_key(p: String) -> String:
  String.to_lower(String.trim(before_eq(p)))

# The raw value of exactly the parameter `name`, or "".
def param_raw(+ps: List<&2, String>, +name: String) -> String:
  match ps:
    case Nil{}:
      ""
    case p <> t:
      Bool.pick(String, String.eq(param_key(p), name), after_eq(p),
        param_raw(t, name))

def param_first.if(
  val: String, rest: String, plain: Bool, ext: Bool
) -> String:
  match plain ext:
    case True{} _:
      decode_header(unquote(val))
    case False{} True{}:
      ext_value(unquote(val))
    case False{} False{}:
      rest

# The value of the first parameter `name` or `name*`, decoded, or "".
def param_first(+ps: List<&2, String>, +name: String) -> String:
  match ps:
    case Nil{}:
      ""
    case p <> t:
      +key = param_key(p)
      param_first.if(after_eq(p), param_first(t, name),
        String.eq(key, name), String.eq(key, name ++ "*"))

# An RFC 2231 attr-char: kept as is in an extended parameter value.
def attr_char(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c) || char_in(c, "!#$&+-.^_`|~")

def pct_char(+c: Char) -> String:
  +u = C.u(c)
  escaped = "%" ++ SCon{C.hex_up((u >> 4n : U32)),
    SCon{C.hex_up((u .&. 15 : U32)), SNil{}}}
  Bool.pick(String, U32.is_lt(u, 128) && attr_char(c), SCon{c, SNil{}}, escaped)

# Bytes as RFC 2231 tokens: an attr-char, or a "%XX" escape.
def pct_tokens(bytes: String) -> List<&2, String>:
  match bytes:
    case SNil{}:
      []
    case SCon{c, t}:
      pct_char(c) <> pct_tokens(t)

def pct_encode(bytes: String) -> String:
  String.concat(pct_tokens(bytes))

def cont_seg.if(
  enc: String, plain: String, has_enc: Bool, has_plain: Bool
) -> Maybe<&2, String>:
  match has_enc has_plain:
    case True{} _:
      Some{unquote(enc)}
    case False{} True{}:
      Some{pct_encode(C.utf8_encode(plain))}
    case False{} False{}:
      None{}

# Continuation segment n, percent-encoded: "name*n*=" as is, else a plain
# "name*n=" encoded here; None when there is neither.
def cont_seg(
  +ps: List<&2, String>, name: String, n: U32
) -> Maybe<&2, String>:
  +key = name ++ "*" ++ U32.show(n)
  +enc = param_raw(ps, key ++ "*")
  +plain = unquote(param_raw(ps, key))
  cont_seg.if(enc, plain,
    Bool.not(String.is_empty(enc)), Bool.not(String.is_empty(plain)))

# An RFC 2231 continuation value ("name*0*=...;name*1*=..."), joined in
# order and percent-encoded throughout, so ext_value can decode it; "" when
# there is none. `seg` is segment n; the fuel bounds the segments read.
def cont_join(
  fuel: Nat, +ps: List<&2, String>, +name: String, n: U32,
  seg: Maybe<&2, String>
) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+f:
      match seg:
        case None{}:
          ""
        case Some{s}:
          +next = (n + 1 : U32)
          s ++ cont_join(f, ps, name, next, cont_seg(ps, name, next))

# A joined continuation to text. Only an encoded first segment ("name*0*=")
# carries the charset'lang' prefix; without it the value is plain text
# (encoded segments decoded as UTF-8).
def cont_value(first_enc: Bool, cont: String) -> String:
  match first_enc:
    case True{}:
      ext_value(cont)
    case False{}:
      C.utf8_decode(pct_decode(cont))

def param.cont(
  ps: List<&2, String>, name: String, cont: String, none: Bool
) -> String:
  match none:
    case True{}:
      param_first(ps, name)
    case False{}:
      first_enc = Bool.not(String.is_empty(param_raw(ps, name ++ "*0*")))
      cont_value(first_enc, cont)

def param.ext(
  +ps: List<&2, String>, +name: String, ext: String, none: Bool
) -> String:
  match none:
    case True{}:
      +cont = cont_join(64n, ps, name, 0, cont_seg(ps, name, 0))
      param.cont(ps, name, cont, String.is_empty(cont))
    case False{}:
      ext_value(ext)

# A parameter of a structured header value, e.g. param(ct, "charset"). An
# RFC 2231 extended value ("name*=", or continuations "name*0*=", ...) wins
# over a plain fallback ("name=").
def param(v: String, +name: String) -> String:
  +ps = List.tail(&2, String, split_params(v))
  +ext = unquote(param_raw(ps, name ++ "*"))
  param.ext(ps, name, ext, String.is_empty(ext))

# Bodies
# ------

def transfer_decode.if(body: String, b64: Bool, qp: Bool) -> String:
  match b64 qp:
    case True{} _:
      C.b64_decode(body)
    case False{} True{}:
      C.qp_decode(body, False{})
    case False{} False{}:
      body

# A body with its Content-Transfer-Encoding undone.
def transfer_decode(cte: String, body: String) -> String:
  +e = String.to_lower(String.trim(cte))
  transfer_decode.if(body,
    String.eq(e, "base64"), String.eq(e, "quoted-printable"))

def default_cs(+cs: String) -> String:
  Bool.pick(String, String.is_empty(cs), "utf-8", cs)

# Two parts' content as one: the first text and html win, attachments add up.
def merge(+a: Parts, +b: Parts) -> Parts:
  Parts{t1, h1, a1} = a
  Parts{t2, h2, a2} = b
  text = Bool.pick(String, String.is_empty(t1), t2, t1)
  html = Bool.pick(String, String.is_empty(h1), h2, h1)
  Parts{text, html, List.append(&2, Att, a1, a2)}

def no_parts() -> Parts:
  Parts{"", "", []}

# Normalizes line breaks to LF (for text handed to agents).
def lf_lines(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      "\n" ++ lf_lines(t)
    case SCon{c, t}:
      SCon{c, lf_lines(t)}

# The text of an inline part: decoded from its charset, with LF line breaks.
def leaf.text(ct: String, bytes: String) -> String:
  lf_lines(C.charset_decode(default_cs(param(ct, "charset")), bytes))

def leaf.if(
  ct: String, typ: String, name: String, bytes: String,
  attached: Bool, plain: Bool, html: Bool
) -> Parts:
  match attached plain html:
    case False{} True{} _:
      Parts{leaf.text(ct, bytes), "", []}
    case False{} False{} True{}:
      Parts{"", leaf.text(ct, bytes), []}
    case _ _ _:
      Parts{"", "", [Att{name, typ, U32.from_nat(String.length(bytes))}]}

def file_name.if(ct: String, from_cd: String, none: Bool) -> String:
  match none:
    case True{}:
      param(ct, "name")
    case False{}:
      from_cd

# A part's file name: the Content-Disposition filename, else the
# Content-Type name.
def file_name(ct: String, cd: String) -> String:
  +from_cd = param(cd, "filename")
  file_name.if(ct, from_cd, String.is_empty(from_cd))

# One non-multipart entity (its header fields and body). Unless attached,
# text/plain and text/html are read as text; anything else is an attachment.
def leaf(+hs: List<&2, Hdr>, body: String) -> Parts:
  +ct = header(hs, "content-type")
  +cd = header(hs, "content-disposition")
  +typ = Bool.pick(String, String.is_empty(ct), "text/plain", main_value(ct))
  +name = file_name(ct, cd)
  attached = String.eq(main_value(cd), "attachment")
    || Bool.not(String.is_empty(name))
  bytes = transfer_decode(header(hs, "content-transfer-encoding"), body)
  leaf.if(ct, typ, name, bytes, attached,
    String.eq(typ, "text/plain"), String.eq(typ, "text/html"))

# A single part's content; a multipart has none of its own.
def walk.if(hs: List<&2, Hdr>, body: String, single: Bool) -> Parts:
  match single:
    case True{}:
      leaf(hs, body)
    case False{}:
      no_parts()

# Multipart
# ---------

# The boundary of a multipart entity, or "" for a single part.
def boundary(hs: List<&2, Hdr>) -> String:
  +ct = header(hs, "content-type")
  multipart = String.starts_with(main_value(ct), "multipart/")
  Bool.pick(String, multipart, param(ct, "boundary"), "")

# The open part's lines, joined, pushed onto the finished parts when
# `inside` a part.
def cut_push(
  cur: List<&2, String>, parts: List<&2, String>, inside: Bool
) -> List<&2, String>:
  match inside:
    case True{}:
      String.join(List.reverse(&2, String, cur), "\r\n") <> parts
    case False{}:
      parts

# Feeds one line to the cut: a boundary line (`open`) finishes the open
# part and opens the next, the closing boundary (`close`) finishes it and
# ends the body, and any other line joins the open part. Lines after the
# closing boundary are ignored.
def cut_line.put(+line: String, +c: Cut, close: Bool, open: Bool) -> Cut:
  match c:
    case Cut{cur, parts, inside, done}:
      match done close open:
        case True{} _ _:
          Cut{cur, parts, inside, True{}}
        case False{} True{} _:
          Cut{[], cut_push(cur, parts, inside), False{}, True{}}
        case False{} False{} True{}:
          Cut{[], cut_push(cur, parts, inside), True{}, False{}}
        case False{} False{} False{}:
          kept = Bool.pick(List<&2, String>, inside, line <> cur, cur)
          Cut{kept, parts, inside, False{}}

def cut_line(+line: String, b: String, c: Cut) -> Cut:
  +l = String.trim_end(line)
  +delimiter = "--" ++ b
  cut_line.put(line, c,
    String.eq(l, delimiter ++ "--"), String.eq(l, delimiter))

def subparts.go(lines: List<&2, String>, +b: String, c: Cut) -> Cut:
  match lines:
    case Nil{}:
      c
    case l <> t:
      subparts.go(t, b, cut_line(strip_cr(l), b, c))

def subparts.fin(c: Cut) -> List<&2, String>:
  Cut{cur, parts, inside, done} = c
  List.reverse(&2, String, cut_push(cur, parts, inside && Bool.not(done)))

# The parts of a multipart body cut at boundary `b` (without the preamble
# and epilogue); a truncated message keeps its last, partial part. A
# `single` part has none.
def subparts(body: String, b: String, single: Bool) -> List<&2, String>:
  match single:
    case True{}:
      []
    case False{}:
      lines = String.split(body, '\n')
      subparts.fin(subparts.go(lines, b, Cut{[], [], False{}, False{}}))

# Walks nested multiparts up to `depth` levels. A single part reads as a
# leaf and a multipart as its subparts; the side not taken is empty, which
# merge ignores, so each part is parsed once and nothing is built twice.
def walk(+depth: Nat, +parts: List<&2, String>) -> Parts:
  match depth:
    case 0n:
      no_parts()
    case 1n+p:
      match parts:
        case Nil{}:
          no_parts()
        case part <> rest:
          +entity = split(part)
          +hs = headers(head_of(entity))
          +body = body_of(entity)
          +b = boundary(hs)
          +single = String.is_empty(b)
          here = merge(walk.if(hs, body, single),
            walk(p, subparts(body, b, single)))
          merge(here, walk(1n+p, rest))

# The readable content of a whole message.
def parts(msg: String) -> Parts:
  walk(8n, [msg])

# HTML to text (when there is no text/plain part)
# -----------------------------------------------

# One character of HTML: '<' opens a tag, '>' closes it and leaves a space,
# and other characters are kept outside tags. A '>' outside a tag is kept.
def html_text.step(+c: Char, +st: Strip) -> Strip:
  match c:
    case '<':
      Strip{out, tag} = st
      Strip{out, True{}}
    case '>':
      Strip{out, tag} = st
      Strip{Bool.pick(String, tag, SCon{' ', out}, SCon{'>', out}), False{}}
    case _:
      Strip{out, tag} = st
      Strip{Bool.pick(String, tag, out, SCon{c, out}), tag}

def html_text.go(s: String, st: Strip) -> Strip:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      html_text.go(t, html_text.step(c, st))

def html_text.fin(st: Strip) -> String:
  Strip{out, tag} = st
  String.reverse(out)

# Decodes the common HTML entities.
def entities(s: String) -> String:
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

def is_blank(+c: Char) -> Bool:
  Char.is_eq(c, ' ') || Char.is_eq(c, '\t')

# Collapses runs of spaces and tabs into one space.
def squeeze(s: String, sp: Bool) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      +blank = is_blank(c)
      gap = Bool.pick(String, sp, "", " ")
      here = Bool.pick(String, blank, gap, SCon{c, SNil{}})
      here ++ squeeze(t, blank)

# A rough plain-text view of HTML: tags removed, common entities decoded.
def html_text(html: String) -> String:
  squeeze(entities(html_text.fin(html_text.go(html, Strip{"", False{}}))), False{})

# A def, not a Bool.pick, so the HTML is stripped only when there is no
# text/plain part.
def readable_text.if(no_text: Bool, text: String, html: String) -> String:
  match no_text:
    case True{}:
      html_text(html)
    case False{}:
      text

# A message's readable text: its text/plain part, else its HTML as text.
def readable_text(p: Parts) -> String:
  Parts{+text, html, _} = p
  readable_text.if(String.is_empty(text), text, html)

# Composing
# =========

# Header text
# -----------

# Splits text into chunks of at most 45 UTF-8 bytes (60 base64 chars), at
# character boundaries, for encoded words.
def ew_chunks(s: String, +cur: String, +n: U32) -> List<&2, String>:
  match s:
    case SNil{}:
      push_rev(cur, [], Bool.not(String.is_empty(cur)))
    case SCon{+c, t}:
      +w = C.utf8_width(C.u(c))
      +full = U32.is_gt((n + w : U32), 45)
      next = Bool.pick(String, full, SCon{c, SNil{}}, SCon{c, cur})
      rest = ew_chunks(t, next, Bool.pick(U32, full, w, (n + w : U32)))
      push_rev(cur, rest, full)

def encoded_word(text: String) -> String:
  "=?UTF-8?B?" ++ C.b64_encode(C.utf8_encode(text), False{}) ++ "?="

def ew_encode(chunks: List<&2, String>) -> String:
  match chunks:
    case Nil{}:
      ""
    case c <> Nil{}:
      encoded_word(c)
    case c <> t:
      encoded_word(c) ++ "\r\n " ++ ew_encode(t)

# Text as encoded words, folded into lines of at most 76 characters.
def encoded_words(s: String) -> String:
  ew_encode(ew_chunks(s, "", 0))

def encode_header.if(s: String, plain: Bool) -> String:
  match plain:
    case True{}:
      s
    case False{}:
      encoded_words(s)

# Header text as-is when it is short plain ASCII, else as encoded words
# (a header line may not pass 998 characters).
def encode_header(+s: String) -> String:
  encode_header.if(s, is_short_plain(s, 900n))

# Addresses
# ---------

def before_gt(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'>', t}:
      ""
    case SCon{c, t}:
      SCon{c, before_gt(t)}

# The text inside the last "<...>" (a display name may itself contain "<").
def last_angle(s: String, found: String) -> String:
  match s:
    case SNil{}:
      found
    case SCon{'<', +t}:
      last_angle(t, before_gt(t))
    case SCon{c, t}:
      last_angle(t, found)

def inside_angle(s: String) -> String:
  last_angle(s, "")

# The text without "(comments)" (nested, outside quotes).
def strip_comments(s: String, +depth: U32, +q: Bool) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      +open = Bool.not(q) && Char.is_eq(c, '(')
      close = Bool.not(q) && Char.is_eq(c, ')') && Bool.not(U32.is_zero(depth))
      keep = U32.is_zero(depth) && Bool.not(open)
      quote = U32.is_zero(depth) && Char.is_eq(c, '"')
      depth_next = Bool.pick(U32, open, (depth + 1 : U32),
        Bool.pick(U32, close, (depth - 1 : U32), depth))
      q_next = Bool.pick(Bool, quote, Bool.not(q), q)
      here = Bool.pick(String, keep, SCon{c, SNil{}}, "")
      here ++ strip_comments(t, depth_next, q_next)

def addr_spec.if(a: String, angle: Bool) -> String:
  match angle:
    case True{}:
      String.trim(inside_angle(a))
    case False{}:
      String.trim(strip_comments(a, 0, False{}))

# The bare address of "Name <addr>" or "addr (comment)".
def addr_spec(+a: String) -> String:
  addr_spec.if(a, String.contains(a, "<"))

def addr_char_ok(+c: Char) -> Bool:
  C.between(C.u(c), 33, 126) && Bool.not(char_in(c, "<>\",;\\"))

def addr_chars_ok(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      addr_char_ok(c) && addr_chars_ok(t)

# No control characters (CR, LF, NUL, ...) anywhere.
def no_ctl(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      +u = C.u(c)
      Bool.not(U32.is_lt(u, 32) || U32.is_eq(u, 127)) && no_ctl(t)

def count_at(s: String) -> Nat:
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
  one_at = Nat.is_eq(count_at(s), 1n)
  inner_at = Bool.not(String.starts_with(s, "@"))
    && Bool.not(String.ends_with(s, "@"))
  no_ctl(a) && addr_chars_ok(s) && one_at && inner_at

def all_addrs_ok(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      addr_ok(x) && all_addrs_ok(t)

def encode_display.if(name: String, plain: Bool) -> String:
  match plain:
    case True{}:
      C.quoted(name)
    case False{}:
      encoded_words(name)

# A display name: quoted when it is short plain ASCII, else encoded words.
def encode_display(+name: String) -> String:
  encode_display.if(name, is_short_plain(name, 200n))

# The text before the last "<" outside a quoted string: the display name
# that goes with the address addr_spec takes (so "Sales < Europe" stays
# whole).
def display_part.go(
  s: String, +cur: String, best: String, +q: Bool, +esc: Bool
) -> String:
  match s:
    case SNil{}:
      String.reverse(best)
    case SCon{+c, t}:
      angle = Bool.not(q) && Char.is_eq(c, '<')
      best_next = Bool.pick(String, angle, cur, best)
      display_part.go(t, SCon{c, cur}, best_next,
        Bool.pick(Bool, Bool.not(esc) && Char.is_eq(c, '"'), Bool.not(q), q),
        Bool.not(esc) && q && Char.is_eq(c, '\\'))

def display_part(a: String) -> String:
  display_part.go(a, "", "", False{}, False{})

def encode_addr.if(name: String, address: String, named: Bool) -> String:
  match named:
    case True{}:
      encode_display(unquote(name)) ++ " <" ++ address ++ ">"
    case False{}:
      address

# "Name <addr>" with the display name encoded when needed.
def encode_addr(+a: String) -> String:
  +name = String.trim(display_part(a))
  named = String.contains(a, "<") && Bool.not(String.is_empty(name))
  encode_addr.if(name, addr_spec(a), named)

def encode_addrs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      encode_addr(x)
    case x <> t:
      encode_addr(x) ++ ",\r\n " ++ encode_addrs(t)

# Header lines
# ------------

# Normalizes line breaks to CRLF.
def crlf_lines(s: String) -> String:
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
def one_line(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      SCon{Bool.pick(Char, C.between(C.u(c), 32, 126), c, ' '), one_line(t)}

# A one-line header value that fits a header line, or "" (dropped).
def short_line(+s: String) -> String:
  Bool.pick(String, Nat.is_le(String.length(s), 900n), s, "")

# Message IDs folded one per line, so References never passes 998 chars.
def fold_ids(ids: List<&2, String>) -> String:
  match ids:
    case Nil{}:
      ""
    case +i <> t:
      +rest = fold_ids(t)
      sep = Bool.pick(String, String.is_empty(rest), "", "\r\n ")
      Bool.pick(String, String.is_empty(i), "", short_line(i) ++ sep) ++ rest

def opt_header(name: String, +v: String) -> String:
  Bool.pick(String, String.is_empty(v), "", name ++ ": " ++ v ++ "\r\n")

# Attachments
# -----------

def ctype_char(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c) || char_in(c, "/-+._")

def ctype_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      ctype_char(c) && ctype_chars(t)

# A content type as "type/subtype" with safe characters, else
# application/octet-stream.
def safe_ctype(+t: String) -> String:
  one_slash = Nat.is_eq(List.length(&2, String, String.split(t, '/')), 2n)
  inner_slash = Bool.not(String.starts_with(t, "/"))
    && Bool.not(String.ends_with(t, "/"))
  ok = ctype_chars(t) && one_slash && inner_slash
  Bool.pick(String, ok, String.to_lower(t), "application/octet-stream")

# Whether bytes can travel as 7bit: ASCII, no NUL or bare CR/LF, and no
# line longer than 998 characters.
def seven_bit(+s: String, +col: U32) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{'\r', SCon{'\n', t}}:
      seven_bit(t, 0)
    case SCon{c, t}:
      +u = C.u(c)
      bad = U32.is_gt(u, 126) || U32.is_zero(u)
        || Char.is_eq(c, '\r') || Char.is_eq(c, '\n')
      Bool.not(bad || U32.is_ge(col, 998)) && seven_bit(t, (col + 1 : U32))

# An ASCII stand-in for a non-ASCII name (for readers without RFC 2231).
def ascii_name(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      keep = C.between(C.u(c), 32, 126) && Bool.not(char_in(c, "\"\\"))
      SCon{Bool.pick(Char, keep, c, '_'), ascii_name(t)}

# Groups percent-encoded tokens into pieces of at most 50 characters,
# never splitting a %XX escape.
def pct_pieces(
  ts: List<&2, String>, +cur: String, +n: U32
) -> List<&2, String>:
  match ts:
    case Nil{}:
      Bool.pick(List<&2, String>, String.is_empty(cur), [], [cur])
    case +tok <> t:
      +w = U32.from_nat(String.length(tok))
      +full = U32.is_gt((n + w : U32), 50)
      +rest = pct_pieces(t, Bool.pick(String, full, tok, cur ++ tok),
        Bool.pick(U32, full, w, (n + w : U32)))
      Bool.pick(List<&2, String>, full, cur <> rest, rest)

def cont_params(+key: String, pieces: List<&2, String>, +i: U32) -> String:
  match pieces:
    case Nil{}:
      ""
    case p <> t:
      charset = Bool.pick(String, U32.is_zero(i), "utf-8''", "")
      ";\r\n " ++ key ++ "*" ++ U32.show(i) ++ "*=" ++ charset ++ p
        ++ cont_params(key, t, (i + 1 : U32))

def name_param.if(+key: String, +name: String, plain: Bool) -> String:
  match plain:
    case True{}:
      key ++ "=" ++ C.quoted(name)
    case False{}:
      fallback = ascii_name(String.take(name, 60n))
      pieces = pct_pieces(pct_tokens(C.utf8_encode(name)), "", 0)
      key ++ "=\"" ++ fallback ++ "\"" ++ cont_params(key, pieces, 0)

# A file name parameter: quoted when it is short plain ASCII, else an ASCII
# fallback plus RFC 2231 continuations of the UTF-8 name, percent-encoded,
# one short line each (encoded words are not allowed inside parameters).
def name_param(key: String, +name: String) -> String:
  name_param.if(key, name, is_short_plain(name, 200n))

def att_head(b: String, ctype: String, +name: String, cte: String) -> String:
  "--" ++ b ++ "\r\n"
    ++ "Content-Type: " ++ ctype ++ "; " ++ name_param("name", name) ++ "\r\n"
    ++ "Content-Disposition: attachment; " ++ name_param("filename", name)
    ++ "\r\n"
    ++ "Content-Transfer-Encoding: " ++ cte ++ "\r\n\r\n"

# RFC 2046 allows only 7bit/8bit/binary for message/rfc822: a 7-bit clean
# message is included as is; anything else goes as an opaque base64 file.
# The CRLF after a raw message always belongs to the next boundary, so the
# message's own final CRLF survives decoding. `ctype` is already safe.
def att_body(
  raw: Bool, b: String, +ctype: String, name: String, data: String
) -> String:
  match raw:
    case True{}:
      att_head(b, "message/rfc822", name, "7bit") ++ data ++ "\r\n"
    case False{}:
      rfc822 = String.eq(ctype, "message/rfc822")
      opaque = Bool.pick(String, rfc822, "application/octet-stream", ctype)
      att_head(b, opaque, name, "base64")
        ++ C.wrap76(C.b64_encode(data, False{}), 0)

# Whether a message/rfc822 attachment can travel raw (it is 7-bit clean).
# Other types never do, and their data is not scanned.
def att_part.raw(data: String, rfc822: Bool) -> Bool:
  match rfc822:
    case True{}:
      seven_bit(data, 0)
    case False{}:
      False{}

def att_part(+b: String, +a: Attach) -> String:
  Attach{name, ctype, data} = a
  +safe = safe_ctype(ctype)
  raw = att_part.raw(data, String.eq(safe, "message/rfc822"))
  att_body(raw, b, safe, name, data)

def att_parts(+b: String, xs: List<&2, Attach>) -> String:
  match xs:
    case Nil{}:
      ""
    case a <> t:
      att_part(b, a) ++ att_parts(b, t)

# Message
# -------

# The text part: its headers, a blank line, then quoted-printable UTF-8.
def text_part(text: String) -> String:
  "Content-Type: text/plain; charset=utf-8\r\n"
    ++ "Content-Transfer-Encoding: quoted-printable\r\n\r\n"
    ++ C.qp_encode(C.utf8_encode(crlf_lines(text)), 0)

def body_section(+b: String, text: String, +atts: List<&2, Attach>) -> String:
  match atts:
    case Nil{}:
      text_part(text)
    case h <> t:
      "Content-Type: multipart/mixed; boundary=\"" ++ b ++ "\"\r\n\r\n"
        ++ "This is a multi-part message in MIME format.\r\n"
        ++ "--" ++ b ++ "\r\n" ++ text_part(text) ++ "\r\n"
        ++ att_parts(b, atts) ++ "--" ++ b ++ "--\r\n"

# The whole message, 7-bit ASCII with CRLF line breaks. `b` is the
# multipart boundary to use when there are attachments.
def compose(d: Draft, b: String) -> String:
  Draft{from, to, cc, bcc, subject, text, date, msgid, irt, refs, atts} = d
  in_reply_to = short_line(String.trim(one_line(irt)))
  ids = String.split(String.trim(one_line(refs)), ' ')
  "From: " ++ encode_addr(from) ++ "\r\n"
    ++ opt_header("To", encode_addrs(to))
    ++ opt_header("Cc", encode_addrs(cc))
    ++ opt_header("Bcc", encode_addrs(bcc))
    ++ "Subject: " ++ encode_header(subject) ++ "\r\n"
    ++ "Date: " ++ date ++ "\r\n"
    ++ "Message-ID: " ++ msgid ++ "\r\n"
    ++ opt_header("In-Reply-To", in_reply_to)
    ++ opt_header("References", fold_ids(ids))
    ++ "MIME-Version: 1.0\r\n"
    ++ body_section(b, text, atts)

# Dates
# =====

def pad2(+n: U32) -> String:
  Bool.pick(String, U32.is_lt(n, 10), "0", "") ++ U32.show(n)

def day_name(n: U32) -> String:
  match n:
    case 0:
      "Sun"
    case 1:
      "Mon"
    case 2:
      "Tue"
    case 3:
      "Wed"
    case 4:
      "Thu"
    case 5:
      "Fri"
    case _:
      "Sat"

def wday(days: U32) -> String:
  day_name(((days + 4) % 7 : U32))

# Days since 1970-01-01 to "D Mon YYYY" (civil-from-days, H. Hinnant),
# shifted by 719468 days so all arithmetic stays unsigned.
def civil(days: U32) -> String:
  +z = (days + 719468 : U32)
  +era = (z / 146097 : U32)
  +doe = (z - era * 146097 : U32)
  +yoe = ((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 : U32)
  +doy = (doe - (365 * yoe + yoe / 4 - yoe / 100) : U32)
  +mp = ((5 * doy + 2) / 153 : U32)
  d = (doy - (153 * mp + 2) / 5 + 1 : U32)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), (mp + 3 : U32), (mp - 9 : U32))
  y = (yoe + era * 400 + Bool.to_u32(U32.is_le(m, 2)) : U32)
  U32.show(d) ++ " " ++ C.month_name(m) ++ " " ++ U32.show(y)

# Seconds since the epoch to an RFC 5322 date in UTC.
def rfc5322_date(+secs: U32) -> String:
  +days = (secs / 86400 : U32)
  +rem = (secs % 86400 : U32)
  time = pad2((rem / 3600 : U32)) ++ ":" ++ pad2(((rem % 3600) / 60 : U32))
    ++ ":" ++ pad2((rem % 60 : U32))
  wday(days) ++ ", " ++ civil(days) ++ " " ++ time ++ " +0000"
