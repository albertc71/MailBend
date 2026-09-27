import Base

# Byte-level codecs. A "byte string" is a String whose characters are all
# in 0..255, one per byte: that is how mailbend-tls hands over server data,
# and how composed messages are built before they go to the wire.

# Decoder state: the code point so far and how many continuation bytes are
# still expected. Invalid sequences decode to U+FFFD.
type U8St is Data:
  U8St{cp: U32, need: U32, min: U32, out: String}

type B64St is Data:
  B64St{acc: U32, bits: U32, out: String}

def u(+c: Char) -> U32:
  Char.to_u32(c)

def chr(+n: U32) -> Char:
  Char.from_u32(n)

def between(+x: U32, +lo: U32, +hi: U32) -> Bool:
  U32.is_ge(x, lo) && U32.is_le(x, hi)

# ---- UTF-8 -------------------------------------------------------------------

def utf8_char(+n: U32, +rest: String) -> String:
  Bool.pick(String, U32.is_lt(n, 128), SCon{chr(n), rest},
    Bool.pick(String, U32.is_lt(n, 2048),
      SCon{chr((192 + (n >> 6n) : U32)), SCon{chr((128 + (n .&. 63) : U32)), rest}},
      Bool.pick(String, U32.is_lt(n, 65536),
        SCon{chr((224 + (n >> 12n) : U32)), SCon{chr((128 + ((n >> 6n) .&. 63) : U32)), SCon{chr((128 + (n .&. 63) : U32)), rest}}},
        SCon{chr((240 + (n >> 18n) : U32)), SCon{chr((128 + ((n >> 12n) .&. 63) : U32)), SCon{chr((128 + ((n >> 6n) .&. 63) : U32)), SCon{chr((128 + (n .&. 63) : U32)), rest}}}})))

# Text to UTF-8 bytes.
def utf8_encode(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      utf8_char(u(c), utf8_encode(t))

def utf8_width(+n: U32) -> U32:
  Bool.pick(U32, U32.is_lt(n, 128), 1, Bool.pick(U32, U32.is_lt(n, 2048), 2, Bool.pick(U32, U32.is_lt(n, 65536), 3, 4)))

# Number of UTF-8 bytes the text takes on the wire.
def utf8_len(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{c, t}:
      (utf8_width(u(c)) + utf8_len(t) : U32)

def repl() -> Char:
  chr(65533)

def u8_lead(+b: U32, +out: String) -> U8St:
  Bool.pick(U8St, U32.is_lt(b, 128), U8St{0, 0, 0, SCon{chr(b), out}},
    Bool.pick(U8St, between(b, 194, 223), U8St{(b .&. 31 : U32), 1, 128, out},
      Bool.pick(U8St, between(b, 224, 239), U8St{(b .&. 15 : U32), 2, 2048, out},
        Bool.pick(U8St, between(b, 240, 244), U8St{(b .&. 7 : U32), 3, 65536, out},
          U8St{0, 0, 0, SCon{repl(), out}}))))

# Overlong, surrogate and out-of-range results become U+FFFD. A sequence is
# overlong when its value is below the least one of its width needs: U+0080
# for 2 bytes, U+0800 for 3, U+10000 for 4.
def u8_put(+bad: Bool, +cp: U32, out: String) -> String:
  match bad:
    case True{}:
      SCon{repl(), out}
    case False{}:
      SCon{chr(cp), out}

def u8_emit(+cp: U32, +min: U32, out: String) -> String:
  u8_put(between(cp, 55296, 57343) || U32.is_gt(cp, 1114111) || U32.is_lt(cp, min), cp, out)

def u8_more(+last: Bool, +cp: U32, +need: U32, +min: U32, out: String) -> U8St:
  match last:
    case True{}:
      U8St{0, 0, 0, u8_emit(cp, min, out)}
    case False{}:
      U8St{cp, (need - 1 : U32), min, out}

def u8_cont(+ok: Bool, +b: U32, +cp: U32, +need: U32, +min: U32, out: String) -> U8St:
  match ok:
    case True{}:
      u8_more(U32.is_eq(need, 1), ((cp << 6n) .|. (b .&. 63) : U32), need, min, out)
    case False{}:
      u8_lead(b, SCon{repl(), out})

def u8_next(+idle: Bool, +b: U32, +cp: U32, +need: U32, +min: U32, out: String) -> U8St:
  match idle:
    case True{}:
      u8_lead(b, out)
    case False{}:
      u8_cont(between(b, 128, 191), b, cp, need, min, out)

def u8_step(st: U8St, +b: U32) -> U8St:
  match st:
    case U8St{+cp, +need, +min, out}:
      u8_next(U32.is_zero(need), b, cp, need, min, out)

def u8_go(s: String, st: U8St) -> U8St:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      u8_go(t, u8_step(st, u(c)))

def u8_end(st: U8St) -> String:
  match st:
    case U8St{cp, +need, min, +out}:
      String.reverse(Bool.pick(String, U32.is_zero(need), out, SCon{repl(), out}))

# UTF-8 bytes to text.
def utf8_decode(bytes: String) -> String:
  u8_end(u8_go(bytes, U8St{0, 0, 0, ""}))

# Windows-1252 differs from Latin-1 only in 0x80..0x9F.
def cp1252_hi(+b: U32) -> U32:
  match b:
    case 128: 8364
    case 130: 8218
    case 131: 402
    case 132: 8222
    case 133: 8230
    case 134: 8224
    case 135: 8225
    case 136: 710
    case 137: 8240
    case 138: 352
    case 139: 8249
    case 140: 338
    case 142: 381
    case 145: 8216
    case 146: 8217
    case 147: 8220
    case 148: 8221
    case 149: 8226
    case 150: 8211
    case 151: 8212
    case 152: 732
    case 153: 8482
    case 154: 353
    case 155: 8250
    case 156: 339
    case 158: 382
    case 159: 376
    case _: b

def cp1252_decode(bytes: String) -> String:
  match bytes:
    case SNil{}:
      ""
    case SCon{c, t}:
      SCon{chr(cp1252_hi(u(c))), cp1252_decode(t)}

def cs_1252(+yes: Bool, bytes: String) -> String:
  match yes:
    case True{}:
      cp1252_decode(bytes)
    case False{}:
      utf8_decode(bytes)

def cs_latin1(+yes: Bool, +l: String, bytes: String) -> String:
  match yes:
    case True{}:
      bytes
    case False{}:
      cs_1252(String.eq(l, "windows-1252") || String.eq(l, "cp1252"), bytes)

# Bytes in a named charset to text. Unknown charsets decode as UTF-8, which
# keeps ASCII intact and marks anything else with U+FFFD.
def charset_decode(cs: String, bytes: String) -> String:
  +l = String.to_lower(cs)
  cs_latin1(String.eq(l, "iso-8859-1") || String.eq(l, "latin1") || String.eq(l, "us-ascii") || String.eq(l, "ascii"), l, bytes)

# ---- base64 -------------------------------------------------------------------

def b64_digit(+n: U32, +imap: Bool) -> Char:
  chr(Bool.pick(U32, U32.is_lt(n, 26), (n + 65 : U32),
    Bool.pick(U32, U32.is_lt(n, 52), (n + 71 : U32),
      Bool.pick(U32, U32.is_lt(n, 62), (n - 4 : U32),
        Bool.pick(U32, U32.is_eq(n, 62), 43, Bool.pick(U32, imap, 44, 47))))))

def b64_3(+a: U32, +b: U32, +c: U32, +imap: Bool, rest: String) -> String:
  +n = ((a << 16n) .|. (b << 8n) .|. c : U32)
  SCon{b64_digit((n >> 18n : U32), imap), SCon{b64_digit(((n >> 12n) .&. 63 : U32), imap), SCon{b64_digit(((n >> 6n) .&. 63 : U32), imap), SCon{b64_digit((n .&. 63 : U32), imap), rest}}}}

def b64_pad(+s: String, +keep: U32, +imap: Bool) -> String:
  match imap:
    case True{}:
      String.take(s, U32.to_nat(keep))
    case False{}:
      String.take(s, U32.to_nat(keep)) ++ String.repeat("=", U32.to_nat((4 - keep : U32)))

# Base64 of a byte string. `imap` selects the IMAP mailbox alphabet
# (',' for '/') without padding.
def b64_encode(bytes: String, +imap: Bool) -> String:
  match bytes:
    case SNil{}:
      ""
    case SCon{a, SNil{}}:
      b64_pad(b64_3(u(a), 0, 0, imap, ""), 2, imap)
    case SCon{a, SCon{b, SNil{}}}:
      b64_pad(b64_3(u(a), u(b), 0, imap, ""), 3, imap)
    case SCon{a, SCon{b, SCon{c, rest}}}:
      b64_3(u(a), u(b), u(c), imap, b64_encode(rest, imap))

def b64_val(+c: Char) -> U32:
  +n = u(c)
  Bool.pick(U32, between(n, 65, 90), (n - 65 : U32),
    Bool.pick(U32, between(n, 97, 122), (n - 71 : U32),
      Bool.pick(U32, between(n, 48, 57), (n + 4 : U32),
        Bool.pick(U32, U32.is_eq(n, 43), 62,
          Bool.pick(U32, U32.is_eq(n, 47) || U32.is_eq(n, 44), 63, 64)))))

def b64_emit(+acc: U32, +bits: U32, +out: String) -> B64St:
  Bool.pick(B64St, U32.is_ge(bits, 8),
    B64St{(acc .&. ((1 << U32.to_nat((bits - 8 : U32))) - 1) : U32), (bits - 8 : U32), SCon{chr(((acc >> U32.to_nat((bits - 8 : U32))) .&. 255 : U32)), out}},
    B64St{acc, bits, out})

def b64_push(+v: U32, st: B64St) -> B64St:
  match st:
    case B64St{acc, bits, out}:
      b64_emit(((acc << 6n) .|. v : U32), (bits + 6 : U32), out)

def b64_step(+v: U32, +st: B64St) -> B64St:
  Bool.pick(B64St, U32.is_lt(v, 64), b64_push(v, st), st)

def b64_go(s: String, st: B64St) -> B64St:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      b64_go(t, b64_step(b64_val(c), st))

def b64_out(st: B64St) -> String:
  match st:
    case B64St{acc, bits, out}:
      String.reverse(out)

# Base64 (either alphabet) to bytes; whitespace, padding and junk are skipped.
def b64_decode(s: String) -> String:
  b64_out(b64_go(s, B64St{0, 0, ""}))

# Breaks a line of ASCII into CRLF-terminated lines of at most 76 chars.
def wrap76(s: String, +col: U32) -> String:
  match s:
    case SNil{}:
      Bool.pick(String, U32.is_zero(col), "", "\r\n")
    case SCon{c, t}:
      Bool.pick(String, U32.is_eq(col, 76), "\r\n", "") ++ SCon{c, wrap76(t, Bool.pick(U32, U32.is_eq(col, 76), 1, (col + 1 : U32)))}

# ---- quoted-printable ------------------------------------------------------------

def hex_val(+c: Char) -> U32:
  +n = u(c)
  Bool.pick(U32, between(n, 48, 57), (n - 48 : U32),
    Bool.pick(U32, between(n, 65, 70), (n - 55 : U32),
      Bool.pick(U32, between(n, 97, 102), (n - 87 : U32), 16)))

def hex_up(+n: U32) -> Char:
  chr(Bool.pick(U32, U32.is_lt(n, 10), (n + 48 : U32), (n + 55 : U32)))

def qp_pair(+ok: Bool, +h: U32, +l: U32, rest: String, orig: String) -> String:
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
      qp_pair(U32.is_lt(hex_val(a), 16) && U32.is_lt(hex_val(b), 16), hex_val(a), hex_val(b), qp_decode(t, q), SCon{'=', SCon{a, SCon{b, SNil{}}}})
    case SCon{'_', t}:
      SCon{Bool.pick(Char, q, ' ', '_'), qp_decode(t, q)}
    case SCon{c, t}:
      SCon{c, qp_decode(t, q)}

def qp_escape(+n: U32) -> String:
  SCon{'=', SCon{hex_up((n >> 4n : U32)), SCon{hex_up((n .&. 15 : U32)), SNil{}}}}

# Whether a byte must be escaped in quoted-printable body text.
def qp_needs(+n: U32) -> Bool:
  U32.is_gt(n, 126) || U32.is_eq(n, 61) || (U32.is_lt(n, 32) && Bool.not(U32.is_eq(n, 9)))

# One output token for a byte: the byte itself or its =XX escape.
def qp_token(+c: Char) -> String:
  Bool.pick(String, qp_needs(u(c)), qp_escape(u(c)), SCon{c, SNil{}})

# The soft break to put before `w` more chars at column `col`, if any.
def qp_brk(+col: U32, +w: U32) -> String:
  Bool.pick(String, U32.is_gt((col + w : U32), 75), "=\r\n", "")

# The column after putting `w` chars at column `col`.
def qp_col(+col: U32, +w: U32) -> U32:
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
      qp_brk(col, 3) ++ "=20\r\n" ++ qp_encode(t, 0)
    case SCon{'\t', SCon{'\r', SCon{'\n', t}}}:
      qp_brk(col, 3) ++ "=09\r\n" ++ qp_encode(t, 0)
    case SCon{' ', SNil{}}:
      qp_brk(col, 3) ++ "=20"
    case SCon{'\t', SNil{}}:
      qp_brk(col, 3) ++ "=09"
    case SCon{+c, t}:
      +tok = qp_token(c)
      +w = U32.from_nat(String.length(tok))
      qp_brk(col, w) ++ tok ++ qp_encode(t, qp_col(col, w))

def plain_char(+n: U32) -> Bool:
  between(n, 32, 126) || U32.is_eq(n, 9)

# Whether every char is printable ASCII or a tab (no CR, LF or 8-bit).
def is_plain(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      plain_char(u(c)) && is_plain(t)
