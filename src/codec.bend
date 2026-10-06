import Base

# Byte-level codecs. A "byte string" is a String whose characters are all
# in 0..255, one per byte: that is how mailbend-tls hands over server data,
# and how composed messages are built before they go to the wire.

def u(+c: Char) -> U32:
  Char.to_u32(c)

def chr(+n: U32) -> Char:
  Char.from_u32(n)

def between(+x: U32, +lo: U32, +hi: U32) -> Bool:
  U32.is_ge(x, lo) && U32.is_le(x, hi)

# The replacement character U+FFFD, for input that cannot be decoded.
def repl() -> Char:
  chr(65533)

# UTF-8 encoding
# --------------

# Number of UTF-8 bytes code point n takes.
def utf8_width(+n: U32) -> U32:
  Bool.pick(U32, U32.is_lt(n, 128), 1,
    Bool.pick(U32, U32.is_lt(n, 2048), 2,
      Bool.pick(U32, U32.is_lt(n, 65536), 3, 4)))

# A continuation byte carrying the low six bits of x.
def utf8_encode.cont(x: U32) -> Char:
  chr((128 + (x .&. 63) : U32))

# Code point n as its `width` UTF-8 bytes, in front of `rest`.
def utf8_encode.put(width: U32, +n: U32, rest: String) -> String:
  match width:
    case 1:
      SCon{chr(n), rest}
    case 2:
      SCon{chr((192 + (n >> 6n) : U32)), SCon{utf8_encode.cont(n), rest}}
    case 3:
      SCon{chr((224 + (n >> 12n) : U32)),
        SCon{utf8_encode.cont((n >> 6n : U32)),
          SCon{utf8_encode.cont(n), rest}}}
    case _:
      SCon{chr((240 + (n >> 18n) : U32)),
        SCon{utf8_encode.cont((n >> 12n : U32)),
          SCon{utf8_encode.cont((n >> 6n : U32)),
            SCon{utf8_encode.cont(n), rest}}}}

# Text to UTF-8 bytes.
def utf8_encode(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      +n = u(c)
      utf8_encode.put(utf8_width(n), n, utf8_encode(t))

# Number of UTF-8 bytes the text takes on the wire.
def utf8_len(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{c, t}:
      (utf8_width(u(c)) + utf8_len(t) : U32)

# UTF-8 decoding
# --------------

# Decoder state: the code point so far, how many continuation bytes are
# still expected, the least value the open sequence must reach, and the
# text so far, reversed.
type Utf8State is Data:
  Utf8State{cp: U32, need: U32, min: U32, out: String}

# How many continuation bytes follow lead byte b; 4 marks a byte that
# cannot start a sequence.
def utf8_decode.need(+b: U32) -> U32:
  Bool.pick(U32, U32.is_lt(b, 128), 0,
    Bool.pick(U32, between(b, 194, 223), 1,
      Bool.pick(U32, between(b, 224, 239), 2,
        Bool.pick(U32, between(b, 240, 244), 3, 4))))

# Opens the sequence lead byte b starts, given how many bytes it needs.
# The least value is U+0080 for 2 bytes, U+0800 for 3, U+10000 for 4:
# anything below is overlong.
def utf8_decode.lead.put(need: U32, b: U32, out: String) -> Utf8State:
  match need:
    case 0:
      Utf8State{0, 0, 0, SCon{chr(b), out}}
    case 1:
      Utf8State{(b .&. 31 : U32), 1, 128, out}
    case 2:
      Utf8State{(b .&. 15 : U32), 2, 2048, out}
    case 3:
      Utf8State{(b .&. 7 : U32), 3, 65536, out}
    case _:
      Utf8State{0, 0, 0, SCon{repl(), out}}

def utf8_decode.lead(+b: U32, out: String) -> Utf8State:
  utf8_decode.lead.put(utf8_decode.need(b), b, out)

# A match, not a Bool.pick: an argument is built before the call, and the
# runtime refuses a Char that is a surrogate or out of range.
def utf8_decode.char.put(bad: Bool, cp: U32) -> Char:
  match bad:
    case True{}:
      repl()
    case False{}:
      chr(cp)

# The char a finished sequence decodes to: U+FFFD when it is overlong (below
# `min`), a surrogate or out of range.
def utf8_decode.char(+cp: U32, min: U32) -> Char:
  bad = between(cp, 55296, 57343) || U32.is_gt(cp, 1114111)
    || U32.is_lt(cp, min)
  utf8_decode.char.put(bad, cp)

# Adds a continuation byte's bits; `last` ends the sequence.
def utf8_decode.more(
  last: Bool, cp: U32, need: U32, min: U32, out: String
) -> Utf8State:
  match last:
    case True{}:
      Utf8State{0, 0, 0, SCon{utf8_decode.char(cp, min), out}}
    case False{}:
      Utf8State{cp, (need - 1 : U32), min, out}

# Byte b inside an open sequence: a continuation byte when `ok`; otherwise
# the sequence is cut short, becomes U+FFFD, and b starts afresh.
def utf8_decode.cont(
  ok: Bool, b: U32, cp: U32, +need: U32, min: U32, out: String
) -> Utf8State:
  match ok:
    case True{}:
      utf8_decode.more(U32.is_eq(need, 1),
        ((cp << 6n) .|. (b .&. 63) : U32), need, min, out)
    case False{}:
      utf8_decode.lead(b, SCon{repl(), out})

# Byte b, with no sequence open when `idle`.
def utf8_decode.next(
  idle: Bool, +b: U32, cp: U32, need: U32, min: U32, out: String
) -> Utf8State:
  match idle:
    case True{}:
      utf8_decode.lead(b, out)
    case False{}:
      utf8_decode.cont(between(b, 128, 191), b, cp, need, min, out)

def utf8_decode.step(st: Utf8State, b: U32) -> Utf8State:
  Utf8State{cp, +need, min, out} = st
  utf8_decode.next(U32.is_zero(need), b, cp, need, min, out)

def utf8_decode.go(s: String, st: Utf8State) -> Utf8State:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      utf8_decode.go(t, utf8_decode.step(st, u(c)))

# The decoded text; a sequence still open at the end becomes U+FFFD.
def utf8_decode.end(st: Utf8State) -> String:
  Utf8State{_, need, _, +out} = st
  String.reverse(Bool.pick(String, U32.is_zero(need), out, SCon{repl(), out}))

# UTF-8 bytes to text. Invalid sequences decode to U+FFFD.
def utf8_decode(bytes: String) -> String:
  utf8_decode.end(utf8_decode.go(bytes, Utf8State{0, 0, 0, ""}))

# Other charsets
# --------------

# The code point of a Windows-1252 byte. Windows-1252 differs from
# Latin-1 only in 0x80..0x9F.
def cp1252_decode.code(b: U32) -> U32:
  match b:
    case 128:
      8364
    case 130:
      8218
    case 131:
      402
    case 132:
      8222
    case 133:
      8230
    case 134:
      8224
    case 135:
      8225
    case 136:
      710
    case 137:
      8240
    case 138:
      352
    case 139:
      8249
    case 140:
      338
    case 142:
      381
    case 145:
      8216
    case 146:
      8217
    case 147:
      8220
    case 148:
      8221
    case 149:
      8226
    case 150:
      8211
    case 151:
      8212
    case 152:
      732
    case 153:
      8482
    case 154:
      353
    case 155:
      8250
    case 156:
      339
    case 158:
      382
    case 159:
      376
    case _:
      b

def cp1252_decode(bytes: String) -> String:
  match bytes:
    case SNil{}:
      ""
    case SCon{c, t}:
      SCon{chr(cp1252_decode.code(u(c))), cp1252_decode(t)}

def charset_decode.cp1252(yes: Bool, bytes: String) -> String:
  match yes:
    case True{}:
      cp1252_decode(bytes)
    case False{}:
      utf8_decode(bytes)

# `name` is the charset name in lower case. Latin-1 and ASCII bytes are
# their own code points.
def charset_decode.latin1(yes: Bool, +name: String, bytes: String) -> String:
  match yes:
    case True{}:
      bytes
    case False{}:
      charset_decode.cp1252(
        String.eq(name, "windows-1252") || String.eq(name, "cp1252"), bytes)

# Bytes in a named charset to text. Unknown charsets decode as UTF-8, which
# keeps ASCII intact and marks anything else with U+FFFD.
def charset_decode(cs: String, bytes: String) -> String:
  +name = String.to_lower(cs)
  latin1 = String.eq(name, "iso-8859-1") || String.eq(name, "latin1")
    || String.eq(name, "us-ascii") || String.eq(name, "ascii")
  charset_decode.latin1(latin1, name, bytes)

# Base64
# ------

# The digit for six bits n. `imap` selects the IMAP mailbox alphabet, which
# has ',' for '/'.
def b64_encode.digit(+n: U32, imap: Bool) -> Char:
  chr(Bool.pick(U32, U32.is_lt(n, 26), (n + 65 : U32),
    Bool.pick(U32, U32.is_lt(n, 52), (n + 71 : U32),
      Bool.pick(U32, U32.is_lt(n, 62), (n - 4 : U32),
        Bool.pick(U32, U32.is_eq(n, 62), 43, Bool.pick(U32, imap, 44, 47))))))

# Bytes a, b and c as four digits, in front of `rest`.
def b64_encode.group(
  a: U32, b: U32, c: U32, +imap: Bool, rest: String
) -> String:
  +n = ((a << 16n) .|. (b << 8n) .|. c : U32)
  SCon{b64_encode.digit((n >> 18n : U32), imap),
    SCon{b64_encode.digit(((n >> 12n) .&. 63 : U32), imap),
      SCon{b64_encode.digit(((n >> 6n) .&. 63 : U32), imap),
        SCon{b64_encode.digit((n .&. 63 : U32), imap), rest}}}}

# The first `keep` digits of a short final group, padded with '=' to four
# unless `imap`.
def b64_encode.pad(s: String, +keep: U32, imap: Bool) -> String:
  String.take(s, U32.to_nat(keep))
    ++ Bool.pick(String, imap, "",
      String.repeat("=", U32.to_nat((4 - keep : U32))))

# Base64 of a byte string. `imap` selects the IMAP mailbox alphabet
# (',' for '/') without padding.
def b64_encode(bytes: String, +imap: Bool) -> String:
  match bytes:
    case SNil{}:
      ""
    case SCon{a, SNil{}}:
      b64_encode.pad(b64_encode.group(u(a), 0, 0, imap, ""), 2, imap)
    case SCon{a, SCon{b, SNil{}}}:
      b64_encode.pad(b64_encode.group(u(a), u(b), 0, imap, ""), 3, imap)
    case SCon{a, SCon{b, SCon{c, rest}}}:
      b64_encode.group(u(a), u(b), u(c), imap, b64_encode(rest, imap))

# Decoder state: the bits not yet output, how many there are, and the bytes
# so far, reversed.
type B64State is Data:
  B64State{acc: U32, bits: U32, out: String}

# The six bits digit c stands for, in either alphabet; 64 marks a char
# that is not a digit.
def b64_decode.value(c: Char) -> U32:
  +n = u(c)
  Bool.pick(U32, between(n, 65, 90), (n - 65 : U32),
    Bool.pick(U32, between(n, 97, 122), (n - 71 : U32),
      Bool.pick(U32, between(n, 48, 57), (n + 4 : U32),
        Bool.pick(U32, U32.is_eq(n, 43), 62,
          Bool.pick(U32, U32.is_eq(n, 47) || U32.is_eq(n, 44), 63, 64)))))

# Outputs the byte above the low `left` bits of acc, and keeps those bits.
def b64_decode.byte(+acc: U32, +left: U32, out: String) -> B64State:
  +shift = U32.to_nat(left)
  B64State{(acc .&. ((1 << shift) - 1) : U32), left,
    SCon{chr(((acc >> shift) .&. 255 : U32)), out}}

# Outputs a byte once eight bits have gathered.
def b64_decode.emit(
  full: Bool, acc: U32, bits: U32, out: String
) -> B64State:
  match full:
    case True{}:
      b64_decode.byte(acc, (bits - 8 : U32), out)
    case False{}:
      B64State{acc, bits, out}

def b64_decode.push(v: U32, st: B64State) -> B64State:
  B64State{acc, bits, out} = st
  +more = (bits + 6 : U32)
  b64_decode.emit(U32.is_ge(more, 8), ((acc << 6n) .|. v : U32), more, out)

# Takes in the six bits v, or skips a char that is not a digit.
def b64_decode.step(digit: Bool, v: U32, st: B64State) -> B64State:
  match digit:
    case True{}:
      b64_decode.push(v, st)
    case False{}:
      st

def b64_decode.go(s: String, st: B64State) -> B64State:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      +v = b64_decode.value(c)
      b64_decode.go(t, b64_decode.step(U32.is_lt(v, 64), v, st))

def b64_decode.end(st: B64State) -> String:
  B64State{_, _, out} = st
  String.reverse(out)

# Base64 (either alphabet) to bytes; whitespace, padding and junk are skipped.
def b64_decode(s: String) -> String:
  b64_decode.end(b64_decode.go(s, B64State{0, 0, ""}))

# Breaks a line of ASCII into CRLF-terminated lines of at most 76 chars,
# starting at column `col`.
def wrap76(s: String, +col: U32) -> String:
  match s:
    case SNil{}:
      Bool.pick(String, U32.is_zero(col), "", "\r\n")
    case SCon{c, t}:
      +full = U32.is_eq(col, 76)
      Bool.pick(String, full, "\r\n", "")
        ++ SCon{c, wrap76(t, Bool.pick(U32, full, 1, (col + 1 : U32)))}

# Quoted-printable
# ----------------

# The value of hex digit c, either case; 16 marks a char that is not one.
def hex_val(+c: Char) -> U32:
  +n = u(c)
  Bool.pick(U32, between(n, 48, 57), (n - 48 : U32),
    Bool.pick(U32, between(n, 65, 70), (n - 55 : U32),
      Bool.pick(U32, between(n, 97, 102), (n - 87 : U32), 16)))

# The upper-case hex digit for n in 0..15.
def hex_up(+n: U32) -> Char:
  chr(Bool.pick(U32, U32.is_lt(n, 10), (n + 48 : U32), (n + 55 : U32)))

# The byte an "=XX" escape stands for, in front of `rest`; when the digits
# are not hex (`ok` is false), the escape text `orig` is kept as it is.
def qp_decode.pair(
  ok: Bool, h: U32, l: U32, rest: String, orig: String
) -> String:
  match ok:
    case True{}:
      SCon{chr((h * 16 + l : U32)), rest}
    case False{}:
      orig ++ rest

# Quoted-printable to bytes. With `q` (RFC 2047 "Q" encoding) '_' is a space.
def qp_decode(s: String, +q: Bool) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'=', SCon{'\r', SCon{'\n', t}}}:
      qp_decode(t, q)
    case SCon{'=', SCon{'\n', t}}:
      qp_decode(t, q)
    case SCon{'=', SCon{+a, SCon{+b, t}}}:
      +high = hex_val(a)
      +low = hex_val(b)
      qp_decode.pair(U32.is_lt(high, 16) && U32.is_lt(low, 16), high, low,
        qp_decode(t, q), SCon{'=', SCon{a, SCon{b, SNil{}}}})
    case SCon{'_', t}:
      SCon{Bool.pick(Char, q, ' ', '_'), qp_decode(t, q)}
    case SCon{c, t}:
      SCon{c, qp_decode(t, q)}

# The "=XX" escape of byte n.
def qp_encode.escape(+n: U32) -> String:
  SCon{'=',
    SCon{hex_up((n >> 4n : U32)), SCon{hex_up((n .&. 15 : U32)), SNil{}}}}

# Whether byte n must be escaped in quoted-printable body text.
def qp_encode.needs(+n: U32) -> Bool:
  U32.is_gt(n, 126) || U32.is_eq(n, 61) || (U32.is_lt(n, 32) && U32.is_ne(n, 9))

def qp_encode.token.put(escape: Bool, c: Char) -> String:
  match escape:
    case True{}:
      qp_encode.escape(u(c))
    case False{}:
      SCon{c, SNil{}}

# One output token for a byte: the byte itself or its "=XX" escape.
def qp_encode.token(+c: Char) -> String:
  qp_encode.token.put(qp_encode.needs(u(c)), c)

# The soft break to put before `w` more chars at column `col`, if any.
def qp_encode.soft_break(col: U32, w: U32) -> String:
  Bool.pick(String, U32.is_gt((col + w : U32), 75), "=\r\n", "")

# The column after putting `w` chars at column `col`.
def qp_encode.col(+col: U32, +w: U32) -> U32:
  Bool.pick(U32, U32.is_gt((col + w : U32), 75), w, (col + w : U32))

# Bytes to quoted-printable, keeping CRLF line breaks, escaping a space or
# tab before a break, and inserting soft breaks so no line passes 76 chars.
def qp_encode(bytes: String, +col: U32) -> String:
  match bytes:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      "\r\n" ++ qp_encode(t, 0)
    case SCon{' ', SCon{'\r', SCon{'\n', t}}}:
      qp_encode.soft_break(col, 3) ++ "=20\r\n" ++ qp_encode(t, 0)
    case SCon{'\t', SCon{'\r', SCon{'\n', t}}}:
      qp_encode.soft_break(col, 3) ++ "=09\r\n" ++ qp_encode(t, 0)
    case SCon{' ', SNil{}}:
      qp_encode.soft_break(col, 3) ++ "=20"
    case SCon{'\t', SNil{}}:
      qp_encode.soft_break(col, 3) ++ "=09"
    case SCon{c, t}:
      +token = qp_encode.token(c)
      +width = U32.from_nat(String.length(token))
      qp_encode.soft_break(col, width) ++ token
        ++ qp_encode(t, qp_encode.col(col, width))

# Plain text
# ----------

# Whether byte n is printable ASCII or a tab.
def is_plain.char(+n: U32) -> Bool:
  between(n, 32, 126) || U32.is_eq(n, 9)

# Whether s is plain, given that every char before it is (`ok`). The scan
# stops at the first char that is not.
def is_plain.go(s: String, ok: Bool) -> Bool:
  match s ok:
    case _ False{}:
      False{}
    case SNil{} True{}:
      True{}
    case SCon{c, t} True{}:
      is_plain.go(t, is_plain.char(u(c)))

# Whether every char is printable ASCII or a tab (no CR, LF or 8-bit).
def is_plain(s: String) -> Bool:
  is_plain.go(s, True{})
