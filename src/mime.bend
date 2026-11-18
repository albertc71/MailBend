# Reading RFC 5322 / MIME messages (from byte strings) and composing new
# ones. Composed messages are 7-bit ASCII: headers use RFC 2047 encoded
# words, text is quoted-printable and attachments base64.
#
# An argument is built before the call, so Bool.pick builds both of its
# branches. Where a branch decodes, encodes or scans a body, a helper
# (`.if`, `.put`) matches the Bool instead and builds only the branch taken.

import Base
import ./codec.bend as C
import ./unicode_tags.bend as Tag

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

# The text between tags: markup; the content of an element that holds no
# markup and ends only at its end tag `closer` (as "</title"); script,
# whose end tag a "<!--" in it can hide, with the last characters `seen`
# (lower case, reversed); plaintext, which runs to the end of the input;
# or, once reading is simple, simple text and its CDATA sections, with
# the ']' just read (at most two).
type HtmlMode is Data:
  Markup{}
  Raw{closer: String, keep: HtmlKeep}
  Script{at: HtmlScript, seen: String}
  Plain{}
  Loose{}
  Cdata{brackets: U32}

# What raw content shows: nothing (title, style, iframe, noembed and
# noframes), its text, or its text with character references decoded
# (textarea).
type HtmlKeep is Data:
  Drop{}
  Keep{}
  KeepRefs{}

# Where script is, after the tokenizer's script data states: in plain
# script data, in an escape that "<!--" opens and "-->" closes, or in a
# "<script" inside an escape, where "</script" goes back to the escape.
type HtmlScript is Data:
  ScriptData{}
  Escaped{}
  DoubleEscaped{}

# What a tag does besides the gap it leaves: nothing more, a line break,
# line breaks kept until </pre>, or, as a start tag, where the scanner
# goes next.
type HtmlTag is Data:
  Other{}
  LineBreak{}
  Pre{}
  Opens{scan: HtmlScan}

# Where a tag is: in its name, before an attribute name, in one, before
# its value, or in an unquoted or quoted value.
type HtmlAttr is Data:
  TagName{}
  BeforeName{}
  AttrName{}
  BeforeValue{}
  Unquoted{}
  Quoted{quote: Char}

# The comment states that decide where a comment ends.
type HtmlComment is Data:
  CommentStart{}
  CommentStartDash{}
  CommentText{}
  CommentEndDash{}
  CommentEnd{}
  CommentEndBang{}

# Where the HTML scanner is, after the tokenizer states that decide what
# is text: in text of a mode; right after a start tag whose first line
# feed HTML drops; in a character reference (name reversed) that returns
# to its mode; after '<' or "</"; in a tag (`close` marks an end tag; the
# name is lower case, reversed and cut short); in what may be raw
# content's end tag, with what was `read` (reversed) and `left` of
# `closer` still to match; after "<!" or "<!-"; in a comment; up to the
# '>' that ends a bogus comment, or a tag in simple text, with `cdata`
# left to match of a "[CDATA[" that follows "<!" ("" once it cannot); or
# after '<' in simple text. `tail` is the input from the tag's '<'.
type HtmlScan is Data:
  InText{mode: HtmlMode}
  LineStart{mode: HtmlMode}
  InRef{name: String, mode: HtmlMode}
  TagOpen{tail: String}
  EndTagOpen{tail: String}
  InTag{close: Bool, name: String, at: HtmlAttr, tail: String}
  RawEnd{closer: String, keep: HtmlKeep, read: String, left: String}
  Bang{}
  BangDash{}
  InComment{at: HtmlComment}
  Bogus{cdata: String, mode: HtmlMode}
  LooseOpen{}

# HTML read as text: the text so far (reversed), the gap waiting for the
# next visible character (0 none, 1 a space, 2 a line break, 3 a blank
# line), and whether whitespace is kept as written, as in <pre>.
type HtmlOut is Data:
  HtmlOut{text: String, gap: U32, pre: Bool}

# A single (non-multipart) part of a message: its header fields and body.
type Leaf is Data:
  Leaf{hs: List<&2, Hdr>, body: String}

# What a single part's header says: its Content-Type, its main type, its
# file name, and whether it reads as an attachment rather than as text.
type PartKind is Data:
  PartKind{ct: String, typ: String, name: String, file: Bool}

# The immediate multipart parent's rules for its children.
type PartContext is Data:
  Ordinary{}
  Alternative{}
  Digest{}

# A range of code points, both ends included.
type Range is Data:
  Range{lo: U32, hi: U32}

# An attachment: file name, content type and the raw bytes, to send or as
# saved from a message.
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
  match msg:
    case SCon{'\r', SCon{'\n', t}}:
      Split{"", t}
    case SCon{'\n', t}:
      Split{"", t}
    case _:
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

# Empty fields preserve the existing whitespace and malformed-word behavior.
def header_split.go(s: String, +sep: Char, +cur: String, +parts: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      cur <> parts
    case SCon{+c, t}:
      +cut = Char.is_eq(c, sep)
      header_split.go(t, sep, Bool.pick(String, cut, "", SCon{c, cur}),
        Bool.pick(List<&2, String>, cut, cur <> parts, parts))

def header_split(s: String, sep: Char) -> List<&2, String>:
  header_split.go(String.reverse(s), sep, "", [])

def ew_bytes(b64: Bool, text: String) -> String:
  match b64:
    case True{}:
      C.b64_decode(text)
    case False{}:
      C.qp_decode(text, True{})

def ew_charset.language_tail(s: String, need_char: Bool, valid: Bool) -> Bool:
  match s:
    case SNil{}:
      valid && Bool.not(need_char)
    case SCon{'-', t}:
      ew_charset.language_tail(t, True{}, valid && Bool.not(need_char))
    case SCon{+c, t}:
      ew_charset.language_tail(t, False{}, valid && (Char.is_alpha(c) || Char.is_digit(c)))

def ew_charset.language(s: String) -> Bool:
  match s:
    case SCon{c, t}:
      Char.is_alpha(c) && ew_charset.language_tail(t, False{}, True{})
    case SNil{}:
      False{}

# RFC 2231 separates language metadata from the encoded word's charset.
def ew_charset(ps: List<&2, String>, original: String) -> String:
  match ps:
    case +cs <> lang <> Nil{}:
      Bool.pick(String, Bool.not(String.is_empty(cs)) && ew_charset.language(lang), cs, original)
    case _:
      original

# "=?charset?enc?text?=" split at '?' to text; anything else is the raw
# word read as UTF-8.
def ew_parts(ps: List<&2, String>, word: String) -> String:
  match ps:
    case "=" <> +cs <> +enc <> text <> "=" <> Nil{}:
      C.charset_decode(ew_charset(header_split(cs, '*'), cs),
        ew_bytes(String.eq(enc, "B") || String.eq(enc, "b"), text))
    case _:
      C.utf8_decode(word)

def is_ew(+w: String) -> Bool:
  String.starts_with(w, "=?") && String.ends_with(w, "?=")

# A word to text; `encoded` says whether it looks like an encoded word.
def ew_word(+w: String, encoded: Bool) -> String:
  match encoded:
    case True{}:
      ew_parts(header_split(w, '?'), w)
    case False{}:
      C.utf8_decode(w)

def ew_join.go(ws: List<&2, String>, prev_ew: Bool, first: Bool, +out: String) -> String:
  match ws:
    case Nil{}:
      String.reverse(out)
    case +w <> t:
      +encoded = is_ew(w)
      out = Bool.pick(String, first || (prev_ew && encoded), out, SCon{' ', out})
      ew_join.go(t, encoded, False{}, String.reverse.go(ew_word(w, encoded), out))

def ew_join(ws: List<&2, String>, prev_ew: Bool, first: Bool) -> String:
  ew_join.go(ws, prev_ew, first, "")

def tab_to_space.go(s: String, out: String) -> String:
  match s:
    case SNil{}:
      String.reverse(out)
    case SCon{+c, t}:
      tab_to_space.go(t, SCon{Bool.pick(Char, Char.is_eq(c, '\t'), ' ', c), out})

def tab_to_space(s: String) -> String:
  tab_to_space.go(s, "")

# A raw header value to text: encoded words decoded, raw 8-bit read as UTF-8.
# Space and tab are both linear whitespace between words.
def decode_header(v: String) -> String:
  ew_join(header_split(tab_to_space(v), ' '), False{}, True{})

# Text copied from an untrusted header into one visible line. Decode once,
# replace C0/C1 and line separators with spaces, and drop zero-width bidi
# controls. Trim and bound the display text to 998 code points. Never an addr-spec.
def header_line.clean.put(drop: Bool, c: Char, rest: String) -> String:
  match drop:
    case True{}:
      rest
    case False{}:
      SCon{c, rest}

def header_line.clean.go(s: String, out: String) -> String:
  match s:
    case SNil{}:
      String.reverse(out)
    case SCon{+c, t}:
      +u = C.u(c)
      control = U32.is_lt(u, 32) || C.between(u, 127, 159)
        || U32.is_eq(u, 8232) || U32.is_eq(u, 8233)
      bidi = U32.is_eq(u, 1564) || C.between(u, 8206, 8207) || C.between(u, 8234, 8238)
        || C.between(u, 8294, 8297)
      header_line.clean.go(t, header_line.clean.put(bidi, Bool.pick(Char, control, ' ', c), out))

def header_line.clean(s: String) -> String:
  header_line.clean.go(s, "")

def header_line.text(s: String) -> String:
  String.take(String.trim(header_line.clean(s)), 998n)

def header_line(v: String) -> String:
  header_line.text(decode_header(v))

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

def lf_lines.go(s: String, out: String) -> String:
  match s:
    case SNil{}:
      String.reverse(out)
    case SCon{'\r', SCon{'\n', t}}:
      lf_lines.go(t, SCon{'\n', out})
    case SCon{c, t}:
      lf_lines.go(t, SCon{c, out})

# Normalizes line breaks to LF (for text handed to agents).
def lf_lines(s: String) -> String:
  lf_lines.go(s, "")

# The text of an inline part: decoded from its charset, with LF line breaks.
def leaf.text(ct: String, bytes: String) -> String:
  lf_lines(C.charset_decode(default_cs(param(ct, "charset")), bytes))

def file_name.if(ct: String, from_cd: String, none: Bool) -> String:
  match none:
    case True{}:
      param(ct, "name")
    case False{}:
      from_cd

# The filename, or the media type when the filename is empty. Attachment
# lists and image rows use this one rule.
def part_label(k: PartKind) -> String:
  PartKind{ct, typ, +name, file} = k
  Bool.pick(String, String.is_empty(name), typ, name)

# A part's file name: the Content-Disposition filename, else the
# Content-Type name.
def file_name(ct: String, cd: String) -> String:
  +from_cd = param(cd, "filename")
  file_name.if(ct, from_cd, String.is_empty(from_cd))

# A single part is an attachment when it says so or has a file name; else
# text/plain and text/html read as text, and any other type is an
# attachment.
def part_kind(+hs: List<&2, Hdr>) -> PartKind:
  +ct = header(hs, "content-type")
  +cd = header(hs, "content-disposition")
  +typ = Bool.pick(String, String.is_empty(ct), "text/plain", main_value(ct))
  +name = file_name(ct, cd)
  file = String.eq(main_value(cd), "attachment") || Bool.not(String.is_empty(name))
    || Bool.not(String.eq(typ, "text/plain") || String.eq(typ, "text/html"))
  PartKind{ct, typ, name, file}

# A single part's bytes, its Content-Transfer-Encoding undone.
def leaf_bytes(hs: List<&2, Hdr>, body: String) -> String:
  transfer_decode(header(hs, "content-transfer-encoding"), body)

def leaf.if(
  ct: String, typ: String, name: String, bytes: String, file: Bool, plain: Bool
) -> Parts:
  match file plain:
    case True{} _:
      Parts{"", "", [Att{name, typ, U32.from_nat(String.length(bytes))}]}
    case False{} True{}:
      Parts{leaf.text(ct, bytes), "", []}
    case False{} False{}:
      Parts{"", leaf.text(ct, bytes), []}

def leaf.content(k: PartKind, bytes: String) -> Parts:
  PartKind{ct, +typ, name, file} = k
  leaf.if(ct, typ, name, bytes, file, String.eq(typ, "text/plain"))

# What one single part holds for the reader: its text, its HTML, or an
# attachment.
def leaf(l: Leaf) -> Parts:
  Leaf{+hs, body} = l
  leaf.content(part_kind(hs), leaf_bytes(hs, body))

# A single part as a leaf; a multipart is no leaf itself.
def leaves.one(hs: List<&2, Hdr>, body: String, single: Bool) -> List<&2, Leaf>:
  match single:
    case True{}:
      [Leaf{hs, body}]
    case False{}:
      []

# Multipart
# ---------

# The boundary of a multipart entity, or "" for a single part.
def boundary(hs: List<&2, Hdr>) -> String:
  +ct = header(hs, "content-type")
  multipart = String.starts_with(main_value(ct), "multipart/")
  Bool.pick(String, multipart, param(ct, "boundary"), "")

# The open part's lines, joined, pushed onto the finished parts when
# `inside` a part. The lines keep their CRs, so the part keeps its bytes
# (a binary part may hold a bare LF); only the CR of the line break before
# the next boundary is dropped, as that break belongs to the boundary.
def subparts.push(
  cur: List<&2, String>, parts: List<&2, String>, inside: Bool
) -> List<&2, String>:
  match inside:
    case True{}:
      strip_cr(String.join(List.reverse(&2, String, cur), "\n")) <> parts
    case False{}:
      parts

# Feeds one line to the cut: a boundary line (`open`) finishes the open
# part and opens the next, the closing boundary (`close`) finishes it and
# ends the body, and any other line joins the open part. Lines after the
# closing boundary are ignored.
def subparts.line.if(line: String, +c: Cut, close: Bool, open: Bool) -> Cut:
  match c:
    case Cut{cur, parts, inside, done}:
      match done close open:
        case True{} _ _:
          Cut{cur, parts, inside, True{}}
        case False{} True{} _:
          Cut{[], subparts.push(cur, parts, inside), False{}, True{}}
        case False{} False{} True{}:
          Cut{[], subparts.push(cur, parts, inside), True{}, False{}}
        case False{} False{} False{}:
          kept = Bool.pick(List<&2, String>, inside, line <> cur, cur)
          Cut{kept, parts, inside, False{}}

def subparts.line(+line: String, b: String, c: Cut) -> Cut:
  +l = String.trim_end(line)
  +delimiter = "--" ++ b
  subparts.line.if(line, c,
    String.eq(l, delimiter ++ "--"), String.eq(l, delimiter))

def subparts.go(lines: List<&2, String>, +b: String, c: Cut) -> Cut:
  match lines:
    case Nil{}:
      c
    case l <> t:
      subparts.go(t, b, subparts.line(l, b, c))

def subparts.fin(c: Cut) -> List<&2, String>:
  Cut{cur, parts, inside, done} = c
  List.reverse(&2, String, subparts.push(cur, parts, inside && Bool.not(done)))

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

# The most levels of nested parts a message is read to: past them, its
# parts are left out.
def multipart_limit() -> Nat:
  8n

def part_context(typ: String) -> PartContext:
  match typ:
    case "multipart/alternative":
      Alternative{}
    case "multipart/digest":
      Digest{}
    case _:
      Ordinary{}

def part_context.alternative(c: PartContext) -> Bool:
  match c:
    case Alternative{}:
      True{}
    case _:
      False{}

def part_context.has_type(h: Hdr) -> Bool:
  Hdr{name, value} = h
  String.eq(name, "content-type")

# RFC 2046 5.1.5 defaults only a digest child's absent Content-Type.
# Normalize the parsed fields once; the enclosed message's bytes stay intact.
def part_context.headers(c: PartContext, +hs: List<&2, Hdr>) -> List<&2, Hdr>:
  match c:
    case Digest{}:
      present = List.any(~&2, ~Hdr, ~part_context.has_type, hs)
      Bool.pick(List<&2, Hdr>, present, hs, Hdr{"content-type", "message/rfc822"} <> hs)
    case _:
      hs

# A part's own leaf, then those of its subparts and of the parts after it,
# with whether the bound left a part out.
def leaves.fin(
  one: List<&2, Leaf>, inner: List<&2, Leaf> & Bool, more: List<&2, Leaf> & Bool
) -> List<&2, Leaf> & Bool:
  (a, a_cut) = inner
  (b, b_cut) = more
  (List.concat(&2, Leaf, [one, a, b]), a_cut || b_cut)

# The single parts of `parts`, in order, walking nested multiparts up to
# `depth` levels, and whether the bound left a part out; `context`
# describes their immediate multipart parent. A single part is a leaf and
# a multipart gives its subparts; the side not taken is empty, so each part
# is parsed once.
def leaves(
  +depth: Nat, +context: PartContext, parts: List<&2, String>
) -> List<&2, Leaf> & Bool:
  match depth:
    case 0n:
      ([], Bool.not(List.is_empty(&2, String, parts)))
    case 1n+p:
      match parts:
        case Nil{}:
          ([], False{})
        case part <> rest:
          +entity = split(part)
          +hs = part_context.headers(context, headers(head_of(entity)))
          +body = body_of(entity)
          +b = boundary(hs)
          +single = String.is_empty(b)
          inner = part_context(main_value(header(hs, "content-type")))
          leaves.fin(leaves.one(hs, body, single),
            leaves(p, inner, subparts(body, b, single)), leaves(1n+p, context, rest))

# A message's single parts, and whether multipart_limit left any out.
def message_leaves.cut(msg: String) -> List<&2, Leaf> & Bool:
  leaves(multipart_limit(), Ordinary{}, [msg])

def message_leaves(msg: String) -> List<&2, Leaf>:
  Pair.fst(List<&2, Leaf>, Bool, message_leaves.cut(msg))

# Whether neither text is empty.
def both_filled(+a: String, +b: String) -> Bool:
  Bool.not(String.is_empty(a)) && Bool.not(String.is_empty(b))

# A part's content `a` merged before the content after it (`rest`), and
# whether the merge left a text or an HTML out.
def parts_kept.fin(+a: Parts, rest: Parts & Bool) -> Parts & Bool:
  Parts{t1, h1, a1} = a
  (+b, cut) = rest
  Parts{t2, h2, a2} = b
  (merge(a, b), cut || both_filled(t1, t2) || both_filled(h1, h2))

# The readable content of single parts, and whether it left out a second
# text/plain part, or a second text/html part, that holds text.
def parts_kept(ls: List<&2, Leaf>) -> Parts & Bool:
  match ls:
    case Nil{}:
      (no_parts(), False{})
    case l <> t:
      parts_kept.fin(leaf(l), parts_kept(t))

def parts_of(ls: List<&2, Leaf>) -> Parts:
  Pair.fst(Parts, Bool, parts_kept(ls))

# The readable content of a whole message.
def parts(msg: String) -> Parts:
  parts_of(message_leaves(msg))

# Saving attachments
# ------------------

def is_file.kind(k: PartKind) -> Bool:
  PartKind{ct, typ, name, file} = k
  file

def is_file(l: Leaf) -> Bool:
  Leaf{hs, body} = l
  is_file.kind(part_kind(hs))

def attachment_of.attach(k: PartKind, bytes: String) -> Attach:
  PartKind{ct, typ, name, file} = k
  Attach{name, typ, bytes}

def attachment_of(m: Maybe<&2, Leaf>) -> Maybe<&2, Attach>:
  match m:
    case None{}:
      None{}
    case Some{Leaf{+hs, body}}:
      Some{attachment_of.attach(part_kind(hs), leaf_bytes(hs, body))}

# Attachment `n` (from 0) of a message, in the order `parts` lists them,
# with its bytes decoded (base64, quoted-printable, or 7bit/8bit as is).
def attachment_at(msg: String, n: U32) -> Maybe<&2, Attach>:
  files = List.filter(~Leaf, ~is_file, message_leaves(msg))
  attachment_of(List.get(&2, Leaf, files, U32.to_nat(n)))

# The text after the last "/" or "\" (a name from a Windows client may
# carry a "\" path), `acc` holding the current component reversed.
def last_component(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{'/', t}:
      last_component(t, "")
    case SCon{'\\', t}:
      last_component(t, "")
    case SCon{c, t}:
      last_component(t, SCon{c, acc})

# Hidden Unicode classes are shared by incoming file-name sanitization and
# outgoing checks. Counts include allowed characters, including emoji tags.
type Hidden is Data:
  Hidden{tag: U32, bidi: U32, zero_width: U32}

def tag_ranges() -> List<&2, Range>:
  [Range{917505, 917505}, Range{917536, 917631}]

def bidi_ranges() -> List<&2, Range>:
  [Range{1564, 1564}, Range{8206, 8207}, Range{8234, 8238}, Range{8294, 8303}]

def zero_width_ranges() -> List<&2, Range>:
  [Range{8203, 8207}, Range{8288, 8288}, Range{65279, 65279}]

# The Unicode format characters (general category Cf), as ranges of code
# points: invisible, and some, such as U+202E, reorder the text around
# them, so a name can show an extension it does not have.
def format_ranges() -> List<&2, Range>:
  List.concat(&2, Range, [[
    Range{173, 173}, Range{1536, 1541}, Range{1564, 1564}, Range{1757, 1757},
    Range{1807, 1807}, Range{2192, 2193}, Range{2274, 2274}, Range{6158, 6158},
    Range{8203, 8207}, Range{8288, 8292},
    Range{65279, 65279}, Range{65529, 65531}, Range{69821, 69821},
    Range{69837, 69837}, Range{78896, 78911}, Range{113824, 113827},
    Range{119155, 119162}
  ], bidi_ranges(), tag_ranges()])

def in_ranges(rs: List<&2, Range>, +n: U32) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case Range{lo, hi} <> t:
      C.between(n, lo, hi) || in_ranges(t, n)

def hidden_count.go(s: String, tag: U32, bidi: U32, zw: U32) -> Hidden:
  match s:
    case SNil{}:
      Hidden{tag, bidi, zw}
    case SCon{c, t}:
      +u = C.u(c)
      hidden_count.go(t,
        (tag + Bool.pick(U32, in_ranges(tag_ranges(), u), 1, 0) : U32),
        (bidi + Bool.pick(U32, in_ranges(bidi_ranges(), u), 1, 0) : U32),
        (zw + Bool.pick(U32, in_ranges(zero_width_ranges(), u), 1, 0) : U32))

def hidden_count(s: String) -> Hidden:
  hidden_count.go(s, 0, 0, 0)

# UTS #51 Annex C bounds the whole sequence to 32 code points. The
# pinned CLDR table accepts valid subdivisions and numeric macroregions.
def emoji_tag.go(fuel: Nat, s: String, code: String, valid: Bool, size: U32) -> U32:
  match fuel s:
    case 0n _:
      0
    case 1n+f SCon{'\u{E007F}', t}:
      Bool.pick(U32, valid && Tag.valid(String.reverse(code)), (size + 1 : U32), 0)
    case 1n+f SCon{c, t}:
      +u = C.u(c)
      +ok = C.between(u, 917552, 917561) || C.between(u, 917601, 917626)
      emoji_tag.go(f, t, SCon{C.chr(Bool.pick(U32, ok, (u - 917504 : U32), 0)), code}, valid && ok,
        (size + 1 : U32))
    case _ _:
      0

def emoji_tag(s: String) -> U32:
  emoji_tag.go(31n, s, "", True{}, 0)

# A valid flag preserves its entire sequence. Every other tag is removed
# only from inherited text, without changing visible characters.
def strip_tags.go(s: String, +allowed: U32, +out: String) -> String:
  match s:
    case SNil{}:
      String.reverse(out)
    case SCon{'\u{1F3F4}', +t}:
      strip_tags.go(t, emoji_tag(t), SCon{'\u{1F3F4}', out})
    case SCon{+c, t}:
      +keep = Bool.not(U32.is_zero(allowed))
      strip_tags.go(t, Bool.pick(U32, keep, (allowed - 1 : U32), 0),
        Bool.pick(String, keep || Bool.not(in_ranges(tag_ranges(), C.u(c))),
          SCon{c, out}, out))

def strip_tags(s: String) -> String:
  strip_tags.go(s, 0, "")

def refused_tags.go(s: String, +allowed: U32, n: U32) -> U32:
  match s:
    case SNil{}:
      n
    case SCon{'\u{1F3F4}', +t}:
      refused_tags.go(t, emoji_tag(t), n)
    case SCon{c, t}:
      +keep = Bool.not(U32.is_zero(allowed))
      refused = Bool.not(keep) && in_ranges(tag_ranges(), C.u(c))
      refused_tags.go(t, Bool.pick(U32, keep, (allowed - 1 : U32), 0),
        (n + Bool.pick(U32, refused, 1, 0) : U32))

def refused_tags(s: String) -> U32:
  refused_tags.go(s, 0, 0)

# Whether a character is a control character (Cc, NUL included) or a
# Unicode format character (Cf).
def is_hidden(c: Char) -> Bool:
  +n = C.u(c)
  U32.is_lt(n, 32) || C.between(n, 127, 159) || in_ranges(format_ranges(), n)

def drop_hidden(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      +rest = drop_hidden(t)
      Bool.pick(String, is_hidden(c), rest, SCon{c, rest})

def drop_leading_dots(s: String) -> String:
  match s:
    case SCon{'.', t}:
      drop_leading_dots(t)
    case _:
      s

# `c` and then the longest start of `t` that fits in the rest of `room`
# UTF-8 bytes, when `fits` says `c` fits in `room`; else "".
def utf8_prefix.if(t: String, +c: Char, room: U32, fits: Bool) -> String:
  match t fits:
    case SNil{} True{}:
      SCon{c, ""}
    case SCon{+d, u} True{}:
      +left = (room - C.utf8_width(C.u(c)) : U32)
      SCon{c, utf8_prefix.if(u, d, left, U32.is_le(C.utf8_width(C.u(d)), left))}
    case _ _:
      ""

# The longest start of `s` that fits in `room` UTF-8 bytes.
def utf8_prefix(s: String, +room: U32) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      utf8_prefix.if(t, c, room, U32.is_le(C.utf8_width(C.u(c)), room))

# A file name from a message, made safe to create in a directory: its last
# path component, without control or format characters, without leading
# dots (so neither hidden, "." nor ".."), and at most 255 UTF-8 bytes. ""
# when nothing is left.
def local_name(name: String) -> String:
  utf8_prefix(drop_leading_dots(drop_hidden(last_component(name, ""))), 255)

# HTML to text (when there is no text/plain part)
# -----------------------------------------------

# Elements that start on a new line, and those that also leave a blank line.
def html_text.blocks() -> List<&2, String>:
  ["address", "article", "aside", "center", "dd", "div", "dl", "dt",
    "figcaption", "figure", "footer", "form", "header", "li", "main", "nav",
    "section", "tr"]

def html_text.paragraphs() -> List<&2, String>:
  ["blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "listing", "ol",
    "p", "plaintext", "pre", "table", "ul", "xmp"]

# The gap an element leaves around it: a blank line, a line break, a space
# between table cells, or nothing for inline elements such as <b> and <a>.
def html_text.gap_of(+name: String) -> U32:
  Bool.pick(U32, List.contains(~String, ~String.eq, html_text.paragraphs(), name), 3,
    Bool.pick(U32, List.contains(~String, ~String.eq, html_text.blocks(), name), 2,
      Bool.pick(U32, String.eq(name, "td") || String.eq(name, "th"), 1, 0)))

def html_text.raw(name: String, keep: HtmlKeep) -> HtmlMode:
  Raw{"</" ++ name, keep}

def html_text.opens(mode: HtmlMode) -> HtmlTag:
  Opens{InText{mode}}

# What a tag does besides its gap, by its lower-case name. A browser does
# not show the content of title, style, script, iframe, noembed and
# noframes. What it shows from svg, math, select and noscript on depends
# on the element tree, which a tokenizer does not build, so reading turns
# simple there.
def html_text.tag(+name: String) -> HtmlTag:
  match name:
    case "br":
      LineBreak{}
    case "pre":
      Pre{}
    case "listing":
      Pre{}
    case "title":
      html_text.opens(html_text.raw("title", Drop{}))
    case "style":
      html_text.opens(html_text.raw("style", Drop{}))
    case "script":
      html_text.opens(Script{ScriptData{}, ""})
    case "textarea":
      Opens{LineStart{html_text.raw("textarea", KeepRefs{})}}
    case "xmp":
      html_text.opens(html_text.raw("xmp", Keep{}))
    case "iframe":
      html_text.opens(html_text.raw("iframe", Drop{}))
    case "noembed":
      html_text.opens(html_text.raw("noembed", Drop{}))
    case "noframes":
      html_text.opens(html_text.raw("noframes", Drop{}))
    case "plaintext":
      html_text.opens(Plain{})
    case "svg":
      html_text.opens(Loose{})
    case "math":
      html_text.opens(Loose{})
    case "select":
      html_text.opens(Loose{})
    case "noscript":
      html_text.opens(Loose{})
    case _:
      Other{}

# The named references mail commonly uses, with their code points. &nbsp;
# reads as an ordinary space, so it collapses like one.
def html_text.names() -> List<(String & U32)>:
  [("amp", 38), ("apos", 39), ("bull", 8226), ("copy", 169), ("euro", 8364),
    ("gt", 62), ("hellip", 8230), ("laquo", 171), ("ldquo", 8220),
    ("lsquo", 8216), ("lt", 60), ("mdash", 8212), ("middot", 183),
    ("nbsp", 32), ("ndash", 8211), ("pound", 163), ("quot", 34),
    ("raquo", 187), ("rdquo", 8221), ("reg", 174), ("rsquo", 8217),
    ("trade", 8482), ("zwnj", 8204)]

# The code point of a named reference, or 0 when the name is unknown.
def html_text.named(+name: String, xs: List<(String & U32)>) -> U32:
  match xs:
    case Nil{}:
      0
    case entry <> t:
      (key, cp) = entry
      Bool.pick(U32, String.eq(key, name), cp, html_text.named(name, t))

def html_text.known(+cp: U32) -> Maybe<&2, Char>:
  Bool.pick(Maybe<&2, Char>, U32.is_eq(cp, 0), None{}, Some{C.chr(cp)})

# The value of the digits of `s` in `base`, at most one past the last code
# point; None when a character is not a digit.
def html_text.number(s: String, +base: U32, +acc: U32) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      Some{acc}
    case SCon{+c, t}:
      +d = C.hex_val(c)
      Bool.pick(Maybe<&2, U32>, U32.is_lt(d, base),
        html_text.number(t, base, U32.min((acc * base + d : U32), 1114112)), None{})

# A numeric reference's character, as HTML reads it: U+FFFD for 0,
# surrogates and values past U+10FFFF, and Windows-1252 for 128 to 159.
def html_text.code_point(m: Maybe<&2, U32>) -> Maybe<&2, Char>:
  match m:
    case None{}:
      None{}
    case Some{+n}:
      bad = U32.is_eq(n, 0) || C.between(n, 55296, 57343) || U32.is_gt(n, 1114111)
      Some{C.chr(Bool.pick(U32, bad, 65533,
        Bool.pick(U32, C.between(n, 128, 159), C.cp1252_decode.code(n), n)))}

# The character that a reference, the text between '&' and ';', stands for.
def html_text.decode(+name: String) -> Maybe<&2, Char>:
  match name:
    case "#":
      None{}
    case "#x":
      None{}
    case "#X":
      None{}
    case SCon{'#', SCon{'x', digits}}:
      html_text.code_point(html_text.number(digits, 16, 0))
    case SCon{'#', SCon{'X', digits}}:
      html_text.code_point(html_text.number(digits, 16, 0))
    case SCon{'#', digits}:
      html_text.code_point(html_text.number(digits, 10, 0))
    case _:
      html_text.known(html_text.named(name, html_text.names()))

# The text with the waiting gap written in front of the next character.
def html_text.gap(text: String, gap: U32) -> String:
  match gap:
    case 0:
      text
    case 1:
      SCon{' ', text}
    case 2:
      SCon{'\n', text}
    case _:
      SCon{'\n', SCon{'\n', text}}

# One more line break than is waiting, up to a blank line.
def html_text.more_lines(+gap: U32) -> U32:
  U32.min((U32.max(gap, 1) + 1 : U32), 3)

def html_text.widen(level: U32, out: HtmlOut) -> HtmlOut:
  HtmlOut{text, gap, pre} = out
  HtmlOut{text, U32.max(gap, level), pre}

def html_text.line_break(out: HtmlOut) -> HtmlOut:
  HtmlOut{text, gap, pre} = out
  HtmlOut{text, html_text.more_lines(gap), pre}

def html_text.keep_lines(pre: Bool, out: HtmlOut) -> HtmlOut:
  HtmlOut{text, gap, was} = out
  HtmlOut{text, gap, pre}

# Writes a character as it is, after the waiting gap, which the text never
# starts with.
def html_text.write(+c: Char, out: HtmlOut) -> HtmlOut:
  HtmlOut{+text, gap, pre} = out
  HtmlOut{SCon{c, html_text.gap(text, Bool.pick(U32, String.is_empty(text), 0, gap))}, 0, pre}

# Writes a character whose whitespace collapses. Whitespace, like the gaps
# tags leave, only waits for the next visible character, so runs of it
# collapse and the text neither starts nor ends with it.
def html_text.collapse(+c: Char, +out: HtmlOut) -> HtmlOut:
  Bool.pick(HtmlOut, Char.is_space(c), html_text.widen(1, out), html_text.write(c, out))

def html_text.put.if(pre: Bool, +c: Char, out: HtmlOut) -> HtmlOut:
  match pre:
    case True{}:
      html_text.write(c, out)
    case False{}:
      html_text.collapse(c, out)

# Writes a character of markup text: as it is in <pre>, collapsing elsewhere.
def html_text.put(+c: Char, out: HtmlOut) -> HtmlOut:
  HtmlOut{text, gap, +pre} = out
  html_text.put.if(pre, c, HtmlOut{text, gap, pre})

# Writes a character of raw content or plaintext as it is, unless the
# content is dropped. The tokenizer reads a NUL there as U+FFFD.
def html_text.show(keep: HtmlKeep, +c: Char, out: HtmlOut) -> HtmlOut:
  match keep:
    case Drop{}:
      out
    case _:
      html_text.write(Bool.pick(Char, Char.is_eq(c, C.chr(0)), C.repl(), c), out)

# Writes a character of simple text: a line feed breaks the line, up to a
# blank line, and other whitespace collapses, even in <pre>.
def html_text.simple(+c: Char, out: HtmlOut) -> HtmlOut:
  match c:
    case '\n':
      html_text.line_break(out)
    case _:
      html_text.collapse(c, out)

# Writes a character read in `mode` as that mode shows it: raw content
# that is kept and plaintext as they are, simple text with its line
# breaks, and dropped content not at all.
def html_text.emit(mode: HtmlMode, +c: Char, out: HtmlOut) -> HtmlOut:
  match mode:
    case Markup{}:
      html_text.put(c, out)
    case Raw{closer, keep}:
      html_text.show(keep, c, out)
    case Script{at, seen}:
      out
    case Plain{}:
      html_text.show(Keep{}, c, out)
    case Loose{}:
      html_text.simple(c, out)
    case Cdata{brackets}:
      html_text.simple(c, out)

def html_text.emit_all(+mode: HtmlMode, s: String, out: HtmlOut) -> HtmlOut:
  match s:
    case SNil{}:
      out
    case SCon{c, t}:
      html_text.emit_all(mode, t, html_text.emit(mode, c, out))

# Writes an unresolved reference as text: '&' and the name read so far.
def html_text.literal(+mode: HtmlMode, name: String, out: HtmlOut) -> HtmlOut:
  html_text.emit_all(mode, String.reverse(name), html_text.emit(mode, '&', out))

# What a tag does at the '>' that ends it, after its gap. </br> breaks a
# line too, as browsers read it.
def html_text.act(tag: HtmlTag, +close: Bool, out: HtmlOut) -> HtmlScan & HtmlOut:
  match tag:
    case Other{}:
      (InText{Markup{}}, out)
    case LineBreak{}:
      (InText{Markup{}}, html_text.line_break(out))
    case Pre{}:
      (Bool.pick(HtmlScan, close, InText{Markup{}}, LineStart{Markup{}}),
        html_text.keep_lines(Bool.not(close), out))
    case Opens{scan}:
      (Bool.pick(HtmlScan, close, InText{Markup{}}, scan), out)

def html_text.end(close: Bool, +name: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  html_text.act(html_text.tag(name), close, html_text.widen(html_text.gap_of(name), out))

# HTML whitespace: tab, line feed, form feed, carriage return and space,
# without the vertical tab that Char.is_space also accepts.
def html_text.is_space(+c: Char) -> Bool:
  Char.is_space(c) && Bool.not(Char.is_eq(c, C.chr(11)))

def html_text.is_quote(+c: Char) -> Bool:
  Char.is_eq(c, '"') || Char.is_eq(c, C.chr(39))

# '>' ends a tag outside a quoted value.
def html_text.attr.next(+c: Char, at: HtmlAttr) -> Maybe<&2, HtmlAttr>:
  Bool.pick(Maybe<&2, HtmlAttr>, Char.is_eq(c, '>'), None{}, Some{at})

# Whitespace and '/' lead to the next attribute name, anything else to
# `other`.
def html_text.attr.after(+c: Char, other: HtmlAttr) -> HtmlAttr:
  Bool.pick(HtmlAttr, html_text.is_space(c) || Char.is_eq(c, '/'), BeforeName{}, other)

# Where a tag is after `c`, or None when `c` ends it. A quote opens a value
# only right after '=' and any whitespace, and only with `quotes`; an '='
# anywhere else is part of a name or an unquoted value. The tokenizer's
# after-name state reads every character as AttrName does, and its
# self-closing and after-value states as BeforeName does.
def html_text.attr(at: HtmlAttr, +c: Char, quotes: Bool) -> Maybe<&2, HtmlAttr>:
  match at:
    case TagName{}:
      html_text.attr.next(c, html_text.attr.after(c, TagName{}))
    case BeforeName{}:
      html_text.attr.next(c, html_text.attr.after(c, AttrName{}))
    case AttrName{}:
      html_text.attr.next(c, Bool.pick(HtmlAttr, Char.is_eq(c, '/'), BeforeName{},
        Bool.pick(HtmlAttr, Char.is_eq(c, '='), BeforeValue{}, AttrName{})))
    case BeforeValue{}:
      html_text.attr.next(c, Bool.pick(HtmlAttr, html_text.is_space(c), BeforeValue{},
        Bool.pick(HtmlAttr, quotes && html_text.is_quote(c), Quoted{c}, Unquoted{})))
    case Unquoted{}:
      html_text.attr.next(c, Bool.pick(HtmlAttr, html_text.is_space(c), BeforeName{},
        Unquoted{}))
    case Quoted{+quote}:
      Some{Bool.pick(HtmlAttr, Char.is_eq(c, quote), BeforeName{}, Quoted{quote})}

# A tag name grows while the tag is in its name, to at most eleven letters:
# one past the longest name that does anything, so a longer name costs
# nothing more and matches none.
def html_text.grow(+c: Char, +name: String, at: HtmlAttr) -> String:
  match at:
    case TagName{}:
      Bool.pick(String, String.is_empty(String.drop(name, 10n)),
        SCon{Char.to_lower(c), name}, name)
    case _:
      name

def html_text.in_tag(next: Maybe<&2, HtmlAttr>, +c: Char, close: Bool, name: String,
  tail: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  match next:
    case None{}:
      html_text.end(close, String.reverse(name), out)
    case Some{+at}:
      (InTag{close, html_text.grow(c, name, at), at, tail}, out)

# A character of markup text: '<' may start a tag and '&' a reference.
def html_text.markup(+c: Char, rest: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  match c:
    case '<':
      (TagOpen{SCon{'<', rest}}, out)
    case '&':
      (InRef{"", Markup{}}, out)
    case _:
      (InText{Markup{}}, html_text.put(c, out))

# '&' starts a reference only in content whose references are decoded.
def html_text.raw_ref(+closer: String, +keep: HtmlKeep, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match keep:
    case KeepRefs{}:
      (InRef{"", Raw{closer, keep}}, out)
    case _:
      (InText{Raw{closer, keep}}, html_text.show(keep, '&', out))

# A character of raw content: '<' may start its end tag, and anything else
# is content.
def html_text.raw_char(+c: Char, +closer: String, +keep: HtmlKeep, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match c:
    case '<':
      (RawEnd{closer, keep, "<", String.drop(closer, 1n)}, out)
    case '&':
      html_text.raw_ref(closer, keep, out)
    case _:
      (InText{Raw{closer, keep}}, html_text.show(keep, c, out))

# An end tag that does not match leaves raw content as it was: what it read
# is content, and `c` is read again as content.
def html_text.raw_miss(+c: Char, +closer: String, +keep: HtmlKeep, read: String,
  out: HtmlOut) -> HtmlScan & HtmlOut:
  html_text.raw_char(c, closer, keep,
    html_text.emit_all(Raw{closer, keep}, String.reverse(read), out))

# After the full name of raw content's end tag, the tag name state decides:
# the tag ends or goes on to attributes, and a longer name is no end tag.
def html_text.raw_close(next: Maybe<&2, HtmlAttr>, +c: Char, rest: String,
  closer: String, keep: HtmlKeep, read: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  match next:
    case None{}:
      html_text.end(True{}, String.drop(closer, 2n), out)
    case Some{TagName{}}:
      html_text.raw_miss(c, closer, keep, read, out)
    case Some{at}:
      (InTag{True{}, String.reverse(String.drop(closer, 2n)), at,
        String.reverse(SCon{c, read}) ++ rest}, out)

def html_text.raw_end.next(hit: Bool, +c: Char, +closer: String, +keep: HtmlKeep,
  read: String, more: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  match hit:
    case True{}:
      (RawEnd{closer, keep, SCon{c, read}, more}, out)
    case False{}:
      html_text.raw_miss(c, closer, keep, read, out)

# A character of what may be raw content's end tag, matched in any case,
# with `left` of `closer` still to match. What was read stays in the state,
# so a miss never reads the input again.
def html_text.raw_end(+c: Char, rest: String, closer: String, keep: HtmlKeep,
  read: String, left: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  match left:
    case SNil{}:
      html_text.raw_close(html_text.attr(TagName{}, c, True{}), c, rest, closer, keep,
        read, out)
    case SCon{d, more}:
      html_text.raw_end.next(Char.is_eq(Char.to_lower(c), d), c, closer, keep, read,
        more, out)

# Whether the last characters read, `seen` (reversed), end with `s`.
def html_text.saw(seen: String, s: String) -> Bool:
  String.starts_with(seen, String.reverse(s))

# Where script goes after a character, or None when the character
# completes the script's end tag. `ends` and `opens` say whether it
# completes "</script" or "<script" and a delimiter; `seen` ends with it.
def html_text.script.next(at: HtmlScript, ends: Bool, opens: Bool, seen: String)
  -> Maybe<&2, HtmlScript>:
  match at:
    case ScriptData{}:
      Bool.pick(Maybe<&2, HtmlScript>, ends, None{},
        Some{Bool.pick(HtmlScript, html_text.saw(seen, "<!--"), Escaped{}, ScriptData{})})
    case Escaped{}:
      Bool.pick(Maybe<&2, HtmlScript>, ends, None{},
        Some{Bool.pick(HtmlScript, opens, DoubleEscaped{},
          Bool.pick(HtmlScript, html_text.saw(seen, "-->"), ScriptData{}, Escaped{}))})
    case DoubleEscaped{}:
      Some{Bool.pick(HtmlScript, ends, Escaped{},
        Bool.pick(HtmlScript, html_text.saw(seen, "-->"), ScriptData{}, DoubleEscaped{}))}

# A completed end tag goes on from its delimiter `c` as any end tag does.
def html_text.script.after(next: Maybe<&2, HtmlScript>, +c: Char, rest: String,
  seen: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  match next:
    case None{}:
      html_text.in_tag(html_text.attr(TagName{}, c, True{}), c, True{},
        String.reverse("script"), "</script" ++ SCon{c, rest}, out)
    case Some{at}:
      (InText{Script{at, seen}}, out)

def html_text.is_delimiter(+c: Char) -> Bool:
  html_text.is_space(c) || Char.is_eq(c, '/') || Char.is_eq(c, '>')

# A character of script, which shows nothing. The last eight characters
# are enough to tell "</script", "<script", "<!--" and "-->" apart.
def html_text.script(+c: Char, rest: String, at: HtmlScript, +seen: String,
  out: HtmlOut) -> HtmlScan & HtmlOut:
  +delimits = html_text.is_delimiter(c)
  +now = String.take(SCon{Char.to_lower(c), seen}, 8n)
  html_text.script.after(html_text.script.next(at,
    delimits && html_text.saw(seen, "</script"), delimits && html_text.saw(seen, "<script"),
    now), c, rest, now, out)

# A character of simple text: '<' may start a tag and '&' a reference.
def html_text.loose(+c: Char, out: HtmlOut) -> HtmlScan & HtmlOut:
  match c:
    case '<':
      (LooseOpen{}, out)
    case '&':
      (InRef{"", Loose{}}, out)
    case _:
      (InText{Loose{}}, html_text.simple(c, out))

def html_text.loose_open.tag(tag: Bool, +c: Char, out: HtmlOut) -> HtmlScan & HtmlOut:
  match tag:
    case True{}:
      (Bogus{"", Loose{}}, out)
    case False{}:
      html_text.loose(c, html_text.collapse('<', out))

# The character after '<' in simple text: a letter, '/' or '?' starts a
# tag, and '!' a tag or a CDATA section. Anything else shows the '<' as
# text.
def html_text.loose_open(+c: Char, out: HtmlOut) -> HtmlScan & HtmlOut:
  match c:
    case '!':
      (Bogus{"[CDATA[", Loose{}}, out)
    case _:
      html_text.loose_open.tag(Char.is_alpha(c) || Char.is_eq(c, '/') || Char.is_eq(c, '?'),
        c, out)

# Writes the ']' a CDATA section held back.
def html_text.brackets(n: U32, out: HtmlOut) -> HtmlOut:
  match n:
    case 0:
      out
    case 1:
      html_text.collapse(']', out)
    case _:
      html_text.collapse(']', html_text.collapse(']', out))

# A character of a CDATA section, which "]]>" ends. Up to two ']' wait
# until the next character shows whether they end it.
def html_text.cdata(+c: Char, +brackets: U32, +out: HtmlOut) -> HtmlScan & HtmlOut:
  match c:
    case ']':
      (InText{Cdata{U32.min((brackets + 1 : U32), 2)}},
        html_text.brackets(Bool.pick(U32, U32.is_eq(brackets, 2), 1, 0), out))
    case '>':
      Bool.pick(HtmlScan & HtmlOut, U32.is_eq(brackets, 2), (InText{Loose{}}, out),
        (InText{Cdata{0}}, html_text.collapse('>', html_text.brackets(brackets, out))))
    case _:
      (InText{Cdata{0}}, html_text.simple(c, html_text.brackets(brackets, out)))

# A character of text in `mode`.
def html_text.text(+c: Char, rest: String, mode: HtmlMode, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match mode:
    case Markup{}:
      html_text.markup(c, rest, out)
    case Raw{closer, keep}:
      html_text.raw_char(c, closer, keep, out)
    case Script{at, seen}:
      html_text.script(c, rest, at, seen, out)
    case Plain{}:
      (InText{Plain{}}, html_text.show(Keep{}, c, out))
    case Loose{}:
      html_text.loose(c, out)
    case Cdata{brackets}:
      html_text.cdata(c, brackets, out)

# Right after a <pre>, <listing> or <textarea> start tag, HTML drops a
# line feed.
def html_text.line_start(+c: Char, rest: String, mode: HtmlMode, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match c:
    case '\n':
      (InText{mode}, out)
    case _:
      html_text.text(c, rest, mode, out)

def html_text.ref.end(m: Maybe<&2, Char>, +mode: HtmlMode, name: String, out: HtmlOut)
  -> HtmlOut:
  match m:
    case Some{c}:
      html_text.emit(mode, c, out)
    case None{}:
      html_text.emit(mode, ';', html_text.literal(mode, name, out))

def html_text.ref.more(more: Bool, +c: Char, rest: String, name: String,
  +mode: HtmlMode, out: HtmlOut) -> HtmlScan & HtmlOut:
  match more:
    case True{}:
      (InRef{SCon{c, name}, mode}, out)
    case False{}:
      html_text.text(c, rest, mode, html_text.literal(mode, name, out))

# A character of a reference: letters, digits and '#' extend it and ';'
# ends it. Anything else shows the '&' and the name as text.
def html_text.ref(+c: Char, rest: String, +name: String, +mode: HtmlMode, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match c:
    case ';':
      (InText{mode}, html_text.ref.end(html_text.decode(String.reverse(name)), mode, name,
        out))
    case _:
      html_text.ref.more(Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '#'),
        c, rest, name, mode, out)

def html_text.open.letter(letter: Bool, +c: Char, rest: String, tail: String,
  out: HtmlOut) -> HtmlScan & HtmlOut:
  match letter:
    case True{}:
      (InTag{False{}, SCon{Char.to_lower(c), ""}, TagName{}, tail}, out)
    case False{}:
      html_text.markup(c, rest, html_text.put('<', out))

# The character after '<': a letter starts a tag name, '/' an end tag, '!'
# a comment or declaration and '?' a bogus comment. Anything else shows
# the '<' as text.
def html_text.open(+c: Char, rest: String, tail: String, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match c:
    case '/':
      (EndTagOpen{tail}, out)
    case '!':
      (Bang{}, out)
    case '?':
      (Bogus{"", Markup{}}, out)
    case _:
      html_text.open.letter(Char.is_alpha(c), c, rest, tail, out)

# A tag in simple text leaves a space where it was, a bogus comment
# nothing.
def html_text.tag_gap(mode: HtmlMode) -> U32:
  match mode:
    case Loose{}:
      1
    case _:
      0

# A "[CDATA[" right after "<!" opens a CDATA section, and reading is
# simple from there on.
def html_text.bogus.step(left: String, +c: Char, +mode: HtmlMode) -> HtmlScan:
  match left:
    case SCon{d, SNil{}}:
      Bool.pick(HtmlScan, Char.is_eq(c, d), InText{Cdata{0}}, Bogus{"", mode})
    case SCon{d, more}:
      Bool.pick(HtmlScan, Char.is_eq(c, d), Bogus{more, mode}, Bogus{"", mode})
    case SNil{}:
      Bogus{"", mode}

# A character up to the '>' that ends a bogus comment or a tag in simple
# text.
def html_text.bogus(+c: Char, left: String, +mode: HtmlMode, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match c:
    case '>':
      (InText{mode}, html_text.widen(html_text.tag_gap(mode), out))
    case _:
      (html_text.bogus.step(left, c, mode), out)

def html_text.end_open.letter(letter: Bool, +c: Char, tail: String, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match letter:
    case True{}:
      (InTag{True{}, SCon{Char.to_lower(c), ""}, TagName{}, tail}, out)
    case False{}:
      html_text.bogus(c, "", Markup{}, out)

# The character after "</": a letter starts an end tag name and '>' ends
# an empty one. Anything else starts a bogus comment.
def html_text.end_open(+c: Char, tail: String, out: HtmlOut) -> HtmlScan & HtmlOut:
  html_text.end_open.letter(Char.is_alpha(c), c, tail, out)

# The character after "<!": "--" starts a comment, "[CDATA[" a CDATA
# section, and anything else a bogus comment, which is how HTML reads a
# doctype.
def html_text.bang(+c: Char, out: HtmlOut) -> HtmlScan & HtmlOut:
  match c:
    case '-':
      (BangDash{}, out)
    case _:
      html_text.bogus(c, "[CDATA[", Markup{}, out)

def html_text.bang_dash(+c: Char, out: HtmlOut) -> HtmlScan & HtmlOut:
  match c:
    case '-':
      (InComment{CommentStart{}}, out)
    case _:
      html_text.bogus(c, "", Markup{}, out)

# '-' moves a comment to `dash` and '>' ends it; anything else is comment
# text.
def html_text.comment.edge(+c: Char, dash: HtmlComment) -> Maybe<&2, HtmlComment>:
  match c:
    case '-':
      Some{dash}
    case '>':
      None{}
    case _:
      Some{CommentText{}}

def html_text.comment.end(+c: Char) -> Maybe<&2, HtmlComment>:
  match c:
    case '-':
      Some{CommentEnd{}}
    case '!':
      Some{CommentEndBang{}}
    case _:
      html_text.comment.edge(c, CommentEnd{})

# Where a comment is after `c`, or None when `c` ends it: at "-->" and
# "--!>", and at once in "<!-->" and "<!--->".
def html_text.comment(+c: Char, at: HtmlComment) -> Maybe<&2, HtmlComment>:
  match at:
    case CommentStart{}:
      html_text.comment.edge(c, CommentStartDash{})
    case CommentStartDash{}:
      html_text.comment.edge(c, CommentEnd{})
    case CommentText{}:
      Some{Bool.pick(HtmlComment, Char.is_eq(c, '-'), CommentEndDash{}, CommentText{})}
    case CommentEndDash{}:
      Some{Bool.pick(HtmlComment, Char.is_eq(c, '-'), CommentEnd{}, CommentText{})}
    case CommentEnd{}:
      html_text.comment.end(c)
    case CommentEndBang{}:
      html_text.comment.edge(c, CommentEndDash{})

def html_text.after_comment(m: Maybe<&2, HtmlComment>) -> HtmlScan:
  match m:
    case None{}:
      InText{Markup{}}
    case Some{at}:
      InComment{at}

# One character of HTML; `rest` is the input after it.
def html_text.step(+c: Char, rest: String, quotes: Bool, scan: HtmlScan, out: HtmlOut)
  -> HtmlScan & HtmlOut:
  match scan:
    case InText{mode}:
      html_text.text(c, rest, mode, out)
    case LineStart{mode}:
      html_text.line_start(c, rest, mode, out)
    case InRef{name, mode}:
      html_text.ref(c, rest, name, mode, out)
    case TagOpen{tail}:
      html_text.open(c, rest, tail, out)
    case EndTagOpen{tail}:
      html_text.end_open(c, tail, out)
    case InTag{close, name, at, tail}:
      html_text.in_tag(html_text.attr(at, c, quotes), c, close, name, tail, out)
    case RawEnd{closer, keep, read, left}:
      html_text.raw_end(c, rest, closer, keep, read, left, out)
    case Bang{}:
      html_text.bang(c, out)
    case BangDash{}:
      html_text.bang_dash(c, out)
    case InComment{at}:
      (html_text.after_comment(html_text.comment(c, at)), out)
    case Bogus{cdata, mode}:
      html_text.bogus(c, cdata, mode, out)
    case LooseOpen{}:
      html_text.loose_open(c, out)

def html_text.feed(+c: Char, rest: String, quotes: Bool, st: HtmlScan & HtmlOut)
  -> HtmlScan & HtmlOut:
  (scan, out) = st
  html_text.step(c, rest, quotes, scan, out)

# The input is read as HTML reads it, with each CRLF and lone CR as a line
# feed.
def html_text.go(s: String, +quotes: Bool, st: HtmlScan & HtmlOut) -> HtmlScan & HtmlOut:
  match s:
    case SNil{}:
      st
    case SCon{'\r', SCon{'\n', +t}}:
      html_text.go(t, quotes, html_text.feed('\n', t, quotes, st))
    case SCon{'\r', +t}:
      html_text.go(t, quotes, html_text.feed('\n', t, quotes, st))
    case SCon{c, +t}:
      html_text.go(t, quotes, html_text.feed(c, t, quotes, st))

# At the end of the input, an open '<', "</" or reference is text, and so
# are what may have been raw content's end tag and a CDATA section's held
# back ']'. Other unfinished markup is dropped.
def html_text.close(scan: HtmlScan, out: HtmlOut) -> HtmlOut:
  match scan:
    case TagOpen{tail}:
      html_text.put('<', out)
    case EndTagOpen{tail}:
      html_text.emit_all(Markup{}, "</", out)
    case InRef{name, mode}:
      html_text.literal(mode, name, out)
    case RawEnd{closer, keep, read, left}:
      html_text.emit_all(Raw{closer, keep}, String.reverse(read), out)
    case LooseOpen{}:
      html_text.collapse('<', out)
    case InText{Cdata{brackets}}:
      html_text.brackets(brackets, out)
    case _:
      out

def html_text.close.st(st: HtmlScan & HtmlOut) -> HtmlOut:
  (scan, out) = st
  html_text.close(scan, out)

# A tag still open at the end is dropped, as a browser drops it. So that
# a quote that never closes cannot hide the words after it, the input from
# the tag's '<' is read once more with quotes ignored, after the text
# already written.
def html_text.fin(+scan: HtmlScan, out: HtmlOut) -> HtmlOut:
  match scan:
    case InTag{close, name, at, tail}:
      html_text.close.st(html_text.go(tail, False{}, (InText{Markup{}}, out)))
    case _:
      html_text.close(scan, out)

def html_text.written(out: HtmlOut) -> String:
  HtmlOut{text, gap, pre} = out
  String.reverse(text)

def html_text.result(st: HtmlScan & HtmlOut) -> String:
  (scan, out) = st
  html_text.written(html_text.fin(scan, out))

# HTML as plain text, in one pass (and once more over an unfinished last
# tag). Up to the first svg, math, select or noscript start tag or CDATA
# section, it is read as a browser's tokenizer reads it: the content of
# title, style and script, comments and attribute values are left out,
# block elements and <br> start new lines, <pre> keeps its whitespace,
# character references are decoded and other whitespace collapses. From
# there on, what a browser shows depends on the element tree, so reading is
# simple and stays so: only tags, each from a '<' before a letter, '/', '!'
# or '?' to the next '>', and the brackets around CDATA content are left
# out, line feeds break lines and other whitespace collapses, even in <pre>.
def html_text(html: String) -> String:
  html_text.result(html_text.go(html, True{}, (InText{Markup{}}, HtmlOut{"", 0, False{}})))

def is_blank(+c: Char) -> Bool:
  Char.is_eq(c, ' ') || Char.is_eq(c, '\t')

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

# Splits text into chunks of at most 39 UTF-8 bytes (52 base64 chars), at
# character boundaries, for encoded words.
def ew_chunks(s: String, +cur: String, +n: U32) -> List<&2, String>:
  match s:
    case SNil{}:
      push_rev(cur, [], Bool.not(String.is_empty(cur)))
    case SCon{+c, t}:
      +w = C.utf8_width(C.u(c))
      +full = U32.is_gt((n + w : U32), 39)
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

def has_encoded_word(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{'=', SCon{'?', t}}:
      String.contains(t, "?=")
    case SCon{c, t}:
      has_encoded_word(t)

def header_plain(+s: String, max: Nat) -> Bool:
  is_short_plain(s, max) && Bool.not(has_encoded_word(s))

def fold_plain.width(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{' ', t}:
      0
    case SCon{'\t', t}:
      0
    case SCon{c, t}:
      (1 + fold_plain.width(t) : U32)

def fold_plain.cut(blank: Bool, t: String, col: U32) -> Bool:
  match blank:
    case False{}:
      False{}
    case True{}:
      U32.is_gt((col + 1 + fold_plain.width(t) : U32), 78)

# Folding inserts only CRLF, preserving the original whitespace and text.
def fold_plain(s: String, +col: U32) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, +t}:
      +cut = fold_plain.cut(is_blank(c), t, col)
      Bool.pick(String, cut, "\r\n", "") ++ SCon{c,
        fold_plain(t, Bool.pick(U32, cut, 1, (col + 1 : U32)))}

def encode_header.if(s: String, plain: Bool) -> String:
  match plain:
    case True{}:
      fold_plain(s, 9)
    case False{}:
      encoded_words(s)

# Header text as-is when it is short plain ASCII, else as encoded words
# (a header line may not pass 998 characters).
def encode_header(+s: String) -> String:
  +first = fold_plain.width(s)
  fits = U32.is_le(first, 69) || U32.is_gt(first, 78)
  encode_header.if(s, header_plain(s, 900n) && fits)

# Addresses
# ---------

def addr_push(cur: String, +acc: List<&2, String>) -> List<&2, String>:
  +a = String.trim(String.reverse(cur))
  Bool.pick(List<&2, String>, String.is_empty(a), acc, a <> acc)

def addr_split(
  s: String,
  +cur: String,
  +q: Bool,
  +depth: U32,
  +esc: Bool,
  +ang: Bool,
  +acc: List<&2, String>
) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, addr_push(cur, acc))
    case SCon{+c, t}:
      +top = Bool.not(esc) && Bool.not(q) && U32.is_zero(depth)
      +cut = top && (Char.is_eq(c, ',') || Char.is_eq(c, ';'))
      label = top && Bool.not(ang) && Char.is_eq(c, ':')
      open = Bool.not(esc) && Bool.not(q) && Char.is_eq(c, '(')
      close = Bool.not(esc) && Bool.not(q) && Char.is_eq(c, ')') && Bool.not(U32.is_zero(depth))
      addr_split(t, Bool.pick(String, cut || label, "", SCon{c, cur}),
        Bool.pick(Bool, Bool.not(esc) && U32.is_zero(depth) && Char.is_eq(c, '"'), Bool.not(q), q),
        Bool.pick(U32, open, (depth + 1 : U32), Bool.pick(U32, close, (depth - 1 : U32), depth)),
        Bool.not(esc) && (q || Bool.not(U32.is_zero(depth))) && Char.is_eq(c, '\\'),
        Bool.pick(Bool, top && Char.is_eq(c, '<'), True{},
          Bool.pick(Bool, top && Char.is_eq(c, '>'), False{}, ang)),
        Bool.pick(List<&2, String>, cut, addr_push(cur, acc), acc))

# Splits a header address list at commas outside quoted strings and
# "(comments)", honouring "\\" escapes in both. Groups ("Team: a@x, b@y;")
# give their members only; the label and an empty group
# ("undisclosed-recipients:;") give nothing.
def addr_list(s: String) -> List<&2, String>:
  addr_split(s, "", False{}, 0, False{}, False{}, [])

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
  encode_display.if(name, header_plain(name, 200n))

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

def encode_addr.if(name: String, +address: String, named: Bool) -> String:
  match named:
    case True{}:
      +display = encode_display(unquote(name))
      fold = String.starts_with(display, "=?") ||
        Nat.is_gt((String.length(display) + String.length(address) + 10n : Nat), 78n)
      display ++ Bool.pick(String, fold, "\r\n <", " <") ++ address ++ ">"
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

def msg_id.atom.go(s: String, need: Bool, ok: Bool) -> Bool:
  match s ok:
    case _ False{}:
      False{}
    case SNil{} True{}:
      Bool.not(need)
    case SCon{'.', t} True{}:
      msg_id.atom.go(t, True{}, Bool.not(need))
    case SCon{+c, t} True{}:
      +n = C.u(c)
      valid = C.between(n, 48, 57) || C.between(n, 65, 90) || C.between(n, 97, 122)
        || char_in(c, "!#$%&'*+-/=?^_`{|}~")
      msg_id.atom.go(t, False{}, valid)

def msg_id.atom(s: String) -> Bool:
  msg_id.atom.go(s, True{}, True{})

def msg_id.literal(s: String, ok: Bool) -> Bool:
  match s ok:
    case _ False{}:
      False{}
    case SCon{']', SNil{}} True{}:
      True{}
    case SCon{c, t} True{}:
      +n = C.u(c)
      msg_id.literal(t, C.between(n, 33, 90) || C.between(n, 94, 126))
    case SNil{} True{}:
      False{}

def msg_id.right(s: String) -> Bool:
  match s:
    case SCon{'[', t}:
      msg_id.literal(t, True{})
    case _:
      msg_id.atom(s)

def msg_id.parts(xs: List<&2, String>) -> Bool:
  match xs:
    case left <> right <> rest:
      msg_id.atom(left) && msg_id.right(String.join(right <> rest, "@"))
    case _:
      False{}

def msg_ids.put(rev: String, +acc: List<&2, String>) -> List<&2, String>:
  +id = String.reverse(rev)
  Bool.pick(List<&2, String>, msg_id.parts(String.split(id, '@')),
    ("<" ++ id ++ ">") <> acc, acc)

type IdMode is Data:
  IdText{}
  IdQuoted{escaped: Bool}
  IdComment{depth: U32, escaped: Bool}
  IdToken{reversed: String}

def msg_ids.go(s: String, mode: IdMode, acc: List<&2, String>) -> List<&2, String>:
  match s mode:
    case SNil{} _:
      List.reverse(&2, String, acc)
    case SCon{'<', t} IdText{}:
      msg_ids.go(t, IdToken{""}, acc)
    case SCon{'(', t} IdText{}:
      msg_ids.go(t, IdComment{1, False{}}, acc)
    case SCon{'"', t} IdText{}:
      msg_ids.go(t, IdQuoted{False{}}, acc)
    case SCon{c, t} IdText{}:
      msg_ids.go(t, IdText{}, acc)
    case SCon{+c, t} IdQuoted{+esc}:
      close = Bool.not(esc) && Char.is_eq(c, '"')
      next : IdMode = IdQuoted{Bool.not(esc) && Char.is_eq(c, '\\')}
      msg_ids.go(t, Bool.pick(IdMode, close, IdText{}, next), acc)
    case SCon{+c, t} IdComment{+depth, +esc}:
      open = Bool.not(esc) && Char.is_eq(c, '(')
      +close = Bool.not(esc) && Char.is_eq(c, ')')
      next : IdMode = IdComment{Bool.pick(U32, open, (depth + 1 : U32),
        Bool.pick(U32, close, (depth - 1 : U32), depth)),
        Bool.not(esc) && Char.is_eq(c, '\\')}
      msg_ids.go(t, Bool.pick(IdMode, close && U32.is_eq(depth, 1), IdText{}, next), acc)
    case SCon{'>', t} IdToken{rev}:
      msg_ids.go(t, IdText{}, msg_ids.put(rev, acc))
    case SCon{c, t} IdToken{rev}:
      msg_ids.go(t, IdToken{SCon{c, rev}}, acc)

# Only complete modern msg-id tokens outside comments and quoted text survive.
def msg_ids(s: String) -> List<&2, String>:
  msg_ids.go(s, IdText{}, [])

def ids_size.go(xs: List<&2, String>, size: Nat) -> Nat:
  match xs:
    case Nil{}:
      Nat.sub(size, 1n)
    case x <> t:
      ids_size.go(t, (size + String.length(x) + 1n : Nat))

def ids_size(xs: List<&2, String>) -> Nat:
  ids_size.go(xs, 0n)

# Remove the oldest middle ID until the unfolded field fits 998 characters.
# If its mandatory IDs alone cannot fit, omit the optional field.
def bounded_ids.go(
  root: String, rest: List<&2, String>, +room: Nat, size: Nat, over: Bool
) -> List<&2, String>:
  match rest over:
    case a <> b <> c <> t True{}:
      +left = Nat.sub(size, (String.length(a) + 1n : Nat))
      bounded_ids.go(root, b <> c <> t, room, left, Nat.is_gt(left, room))
    case _ False{}:
      root <> rest
    case _ True{}:
      []

def bounded_ids(ids: List<&2, String>, +room: Nat) -> List<&2, String>:
  match ids:
    case Nil{}:
      []
    case +root <> +rest:
      +size = ids_size(root <> rest)
      bounded_ids.go(root, rest, room, size, Nat.is_gt(size, room))

# One ID per physical line. A single long ID remains an indivisible token.
def fold_ids(ids: List<&2, String>) -> String:
  String.join(ids, "\r\n ")

def field_line.width(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{'\r', SCon{'\n', t}}:
      0n
    case SCon{c, t}:
      1n+field_line.width(t)

def field_line(+name: String, +v: String) -> String:
  fold = Nat.is_gt((String.length(name) + 2n + field_line.width(v) : Nat), 78n)
  name ++ ":" ++ Bool.pick(String, fold, "\r\n ", " ") ++ v ++ "\r\n"

def opt_header(name: String, +v: String) -> String:
  Bool.pick(String, String.is_empty(v), "", field_line(name, v))

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
      separator = Bool.pick(String, U32.is_zero(i), "", ";\r\n ")
      separator ++ key ++ "*" ++ U32.show(i) ++ "*=" ++ charset ++ p
        ++ cont_params(key, t, (i + 1 : U32))

def name_param.literal(+key: String, pieces: List<&2, String>) -> String:
  match pieces:
    case Nil{}:
      key ++ "=\"attachment\""
    case first <> rest:
      key ++ "*0*=utf-8''" ++ first ++ cont_params(key, rest, 1)
        ++ ";\r\n " ++ key ++ "=\"attachment\""

def name_param.if(+key: String, +name: String, plain: Bool, literal: Bool) -> String:
  match plain literal:
    case True{} False{}:
      key ++ "=" ++ C.quoted(name)
    case _ True{}:
      pieces = pct_pieces(pct_tokens(C.utf8_encode(name)), "", 0)
      name_param.literal(key, pieces)
    case _ False{}:
      fallback = ascii_name(String.take(name, 60n))
      pieces = pct_pieces(pct_tokens(C.utf8_encode(name)), "", 0)
      cont_params(key, pieces, 0) ++ ";\r\n " ++ key ++ "=\"" ++ fallback ++ "\""

# A file name parameter: quoted when it is short plain ASCII, else UTF-8
# RFC 2231 continuations followed by an ASCII fallback. Encoded-word-looking
# names use the same continuations with a neutral "attachment" fallback so
# tolerant readers cannot interpret the fallback as hidden text.
def name_param(key: String, +name: String) -> String:
  name_param.if(key, name, is_short_plain(name, 200n), has_encoded_word(name))

def text_charset.go(
  s: String, +need: U32, lo: U32, hi: U32, +ascii: Bool, ok: Bool
) -> String:
  match s ok:
    case _ False{}:
      ""
    case SNil{} True{}:
      Bool.pick(String, U32.is_zero(need),
        Bool.pick(String, ascii, "; charset=us-ascii", "; charset=utf-8"), "")
    case SCon{c, t} True{}:
      +n = C.u(c)
      +lead = U32.is_zero(need)
      +more = C.utf8_decode.need(n)
      +plain = U32.is_lt(n, 128)
      valid = Bool.pick(Bool, lead, U32.is_lt(more, 4), C.between(n, lo, hi))
      low = Bool.pick(U32, U32.is_eq(n, 224), 160,
        Bool.pick(U32, U32.is_eq(n, 240), 144, 128))
      high = Bool.pick(U32, U32.is_eq(n, 237), 159,
        Bool.pick(U32, U32.is_eq(n, 244), 143, 191))
      text_charset.go(t, Bool.pick(U32, lead, more, (need - 1 : U32)),
        Bool.pick(U32, lead, low, 128), Bool.pick(U32, lead, high, 191),
        ascii && plain, valid)

def att_ctype.if(ctype: String, data: String, text: Bool) -> String:
  match text:
    case True{}:
      ctype ++ text_charset.go(data, 0, 128, 191, True{}, True{})
    case False{}:
      ctype

def att_ctype(+ctype: String, data: String) -> String:
  att_ctype.if(ctype, data, String.starts_with(ctype, "text/"))

def att_head(b: String, ctype: String, +name: String, cte: String) -> String:
  "--" ++ b ++ "\r\n"
    ++ "Content-Type: " ++ ctype ++ ";\r\n " ++ name_param("name", name) ++ "\r\n"
    ++ "Content-Disposition: attachment;\r\n " ++ name_param("filename", name)
    ++ "\r\n"
    ++ "Content-Transfer-Encoding: " ++ cte ++ "\r\n\r\n"

# RFC 2046 allows only 7bit/8bit/binary for message/rfc822. A clean message
# without a boundary collision stays raw; otherwise it is an opaque base64 file.
# The CRLF after a raw message always belongs to the next boundary, so the
# message's own final CRLF survives decoding. `ctype` is already safe.
def att_body(
  raw: Bool, b: String, +ctype: String, name: String, +data: String
) -> String:
  match raw:
    case True{}:
      att_head(b, "message/rfc822", name, "7bit") ++ data ++ "\r\n"
    case False{}:
      rfc822 = String.eq(ctype, "message/rfc822")
      opaque = Bool.pick(String, rfc822, "application/octet-stream", ctype)
      att_head(b, att_ctype(opaque, data), name, "base64")
        ++ C.wrap76(C.b64_encode(data, False{}), 0)

# RFC 2046 forbids the boundary delimiter even as a prefix of a part line.
def att_part.raw(+data: String, +b: String, rfc822: Bool) -> Bool:
  match rfc822:
    case True{}:
      seven_bit(data, 0) && Bool.not(String.starts_with(data, "--" ++ b))
        && Bool.not(String.contains(data, "\r\n--" ++ b))
    case False{}:
      False{}

def att_part(+b: String, +a: Attach) -> String:
  Attach{name, ctype, data} = a
  +safe = safe_ctype(ctype)
  raw = att_part.raw(data, b, String.eq(safe, "message/rfc822"))
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

def body_section(+b: String, text: String, atts: List<&2, Attach>) -> String:
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
  in_reply_to = fold_ids(bounded_ids(msg_ids(irt), 985n))
  ids = bounded_ids(msg_ids(refs), 986n)
  field_line("From", encode_addr(from))
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

# A civil date as "D Mon YYYY".
def civil_text(date: U32 & (U32 & U32)) -> String:
  (y, (m, d)) = date
  U32.show(d) ++ " " ++ C.month_name(m) ++ " " ++ U32.show(y)

# A civil date as "YYYY-MM-DD".
def iso_text(date: U32 & (U32 & U32)) -> String:
  (y, (m, d)) = date
  U32.show(y) ++ "-" ++ pad2(m) ++ "-" ++ pad2(d)

# Seconds since the epoch to an RFC 5322 date in UTC.
def rfc5322_date(+secs: U32) -> String:
  +days = (secs / 86400 : U32)
  +rem = (secs % 86400 : U32)
  time = pad2((rem / 3600 : U32)) ++ ":" ++ pad2(((rem % 3600) / 60 : U32))
    ++ ":" ++ pad2((rem % 60 : U32))
  wday(days) ++ ", " ++ civil_text(C.civil(days)) ++ " " ++ time ++ " +0000"

# Seconds since the epoch to the UTC date, as YYYY-MM-DD.
def iso_date(secs: U32) -> String:
  iso_text(C.civil((secs / 86400 : U32)))
