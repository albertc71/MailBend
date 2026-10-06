# The local secret scan. With Jev on, an outgoing message is first scanned
# here, without TypeSafe, for three kinds of secret: a private key block, a
# token with a well-known prefix, and a password line. It reads the content
# before transfer encoding: the header fields, the body, each attachment's
# name and bytes, and a forwarded message's header section and parts. Any
# text it cannot read makes the scan Incomplete, which blocks the send just
# as a secret does: a status shown after delivery would not stop a secret.
# The scan catches an accidental leak; it is no boundary against a secret
# hidden on purpose (in a compressed file, say).

import Base
import ./mime.bend as M

# The scan's result
# =================

# What the scan found: a secret in the part named; a part it could not
# read, and why; or nothing in any part it had to read.
type Scan is Data:
  Found{part: String}
  Incomplete{reason: String}
  Clean{}

def scan_name(s: Scan) -> String:
  match s:
    case Found{part}:
      "found"
    case Incomplete{reason}:
      "incomplete"
    case Clean{}:
      "clean"

# Limits
# ------

# The most text the scan reads, in characters: 1 MB. The bytes of parts
# that are not text are read in what is left of it.
def scan_limit() -> Nat:
  1048576n

# The most parts the scan opens or reads; a message with more is
# Incomplete.
def scan_fuel() -> Nat:
  10000n

# The most levels of forwarded messages the scan opens, the outermost
# included.
def forward_limit() -> Nat:
  3n

# The rules
# =========

# The scan reads a text once, a character at a time, and never looks
# ahead (copying the rest of a long text at each character would cost too
# much): it keeps only how much of each private-key armour it has just
# read, and the start of the current word and of the current line.

# Private keys
# ------------

# A private key in PEM or PGP armour, as the "PRIVATE KEY-----" of
# "-----BEGIN RSA PRIVATE KEY-----", or "PRIVATE KEY BLOCK-----".
def pem_armour() -> String:
  "PRIVATE KEY-----"

def pgp_armour() -> String:
  "PRIVATE KEY BLOCK-----"

def armour.if(hit: Bool, c: Char, rest: String, +pattern: String) -> String:
  match hit:
    case True{}:
      rest
    case False{}:
      Bool.pick(String, Char.is_eq(c, 'P'), String.drop(pattern, 1n), pattern)

# What is still to come of the armour `pattern` once `c` is read, `want`
# being what was; "" once all of it has been read. "P" starts each pattern
# and appears nowhere else in it, so a mismatch restarts it at `c`.
def armour(+c: Char, want: String, pattern: String) -> String:
  match want:
    case SNil{}:
      ""
    case SCon{w, rest}:
      armour.if(Char.is_eq(c, w), c, rest, pattern)

# Tokens
# ------

# A character a token is made of: a letter, a digit, "_" or "-".
def token_char(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '_') || Char.is_eq(c, '-')

# The prefixes of well-known access keys and API tokens: AWS, Google,
# GitHub, GitLab, Slack, Stripe, Anthropic, OpenAI and npm.
def token_prefixes() -> List<&2, String>:
  ["AKIA", "ASIA", "AIza", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-",
    "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "sk_live_", "rk_live_", "sk-ant-", "sk-proj-",
    "npm_"]

# How many characters of a word the token rule reads: a token is a word of
# at least 20 token characters (a prefix and enough more to make 20) that
# starts with one of the prefixes.
def token_length() -> Nat:
  20n

def word_start(tok: Bool, room: Bool, c: Char, word: String) -> String:
  match tok room:
    case False{} _:
      ""
    case True{} True{}:
      SCon{c, word}
    case True{} False{}:
      word

def word_count(tok: Bool, room: Bool, n: Nat) -> Nat:
  match tok room:
    case False{} _:
      0n
    case True{} True{}:
      Nat.add(n, 1n)
    case True{} False{}:
      n

def has_token_prefix(+s: String, ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> t:
      String.starts_with(s, p) || has_token_prefix(s, t)

# Whether the start of a word just read in full (`word`, reversed) makes
# it a token; `full` says it has just reached token_length.
def token_hit(full: Bool, word: String) -> Bool:
  match full:
    case True{}:
      has_token_prefix(String.reverse(word), token_prefixes())
    case False{}:
      False{}

# Passwords
# ---------

def password_keys() -> List<&2, String>:
  ["password", "passwd", "passcode", "pwd"]

# The length of the longest of password_keys: how much of a line's start
# is compared with them.
def password_key_length() -> Nat:
  8n

# `c` and the rest of its word, `space` saying whether `c` is a space.
def first_word.go(t: String, c: Char, space: Bool) -> String:
  match t space:
    case _ True{}:
      ""
    case SNil{} False{}:
      SCon{c, ""}
    case SCon{+d, u} False{}:
      SCon{c, first_word.go(u, d, Char.is_space(d))}

def first_word(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      first_word.go(t, c, Char.is_space(c))

# A password: a word of at least 6 characters with a digit in it, which
# keeps out words such as "required" or "(none)".
def password_word(+w: String) -> Bool:
  Nat.is_ge(String.length(w), 6n) &&
    List.any(~&2, ~Char, ~(c => Char.is_digit(c)), String.to_list(w))

# What follows a password key: ":" or "=", then the password.
def password_value(s: String) -> Bool:
  match s:
    case SCon{':', v}:
      password_word(first_word(String.trim_start(v)))
    case SCon{'=', v}:
      password_word(first_word(String.trim_start(v)))
    case _:
      False{}

def password_line.if(at: Bool, l: String, k: String) -> Bool:
  match at:
    case True{}:
      password_value(String.trim_start(String.drop(l, String.length(k))))
    case False{}:
      False{}

def password_line.go(+l: String, +head: String, ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case +k <> t:
      password_line.if(String.starts_with(head, k), l, k) || password_line.go(l, head, t)

# A line without the reply quoting before its text: any run of ">",
# spaces and tabs, as in "> > Password: ...".
def unquoted(s: String) -> String:
  match s:
    case SCon{'>', t}:
      unquoted(t)
    case SCon{' ', t}:
      unquoted(t)
    case SCon{'\t', t}:
      unquoted(t)
    case SCon{c, t}:
      SCon{c, t}
    case SNil{}:
      ""

# A line that gives a password: one of password_keys (in any case) at its
# start, after any reply quoting, then ":" or "=", then a password, as in
# "Password: hunter22".
def password_line(line: String) -> Bool:
  +l = unquoted(String.trim_start(line))
  password_line.go(l, String.to_lower(String.take(l, password_key_length())), password_keys())

# How many characters of a line the password rule reads.
def line_length() -> Nat:
  96n

def line_start(nl: Bool, room: Bool, c: Char, line: String) -> String:
  match nl room:
    case True{} _:
      ""
    case False{} True{}:
      SCon{c, line}
    case False{} False{}:
      line

def line_count(nl: Bool, room: Bool, n: Nat) -> Nat:
  match nl room:
    case True{} _:
      0n
    case False{} True{}:
      Nat.add(n, 1n)
    case False{} False{}:
      n

# Whether the start of a line (`line`, reversed) gives a password; `ends`
# says it is read in full: the line ended, or reached line_length.
def password_hit(ends: Bool, line: String) -> Bool:
  match ends:
    case True{}:
      password_line(String.reverse(line))
    case False{}:
      False{}

# Reading a text
# --------------

# What the scan keeps while it reads a text: what is still to come of each
# armour, the start of the current word and of the current line (each
# reversed, with its length), whether a secret was found, and whether a
# text read strictly held a NUL character.
type Watch is Data:
  Watch{
    pem: String,
    pgp: String,
    word: String,
    word_n: Nat,
    line: String,
    line_n: Nat,
    found: Bool,
    nul: Bool
  }

def first_watch() -> Watch:
  Watch{pem_armour(), pgp_armour(), "", 0n, "", 0n, False{}, False{}}

# The watch once `c` is read. A line is judged when it ends, or once its
# start is read in full; a word, once its start is.
def reading.step(
  +c: Char,
  strict: Bool,
  pem: String,
  pgp: String,
  word: String,
  +word_n: Nat,
  +line: String,
  +line_n: Nat
) -> Watch:
  +tok = token_char(c)
  +nl = Char.is_eq(c, '\n')
  +room = Nat.is_lt(word_n, token_length())
  +line_room = Nat.is_lt(line_n, line_length())
  +p = armour(c, pem, pem_armour())
  +g = armour(c, pgp, pgp_armour())
  +w = word_start(tok, room, c, word)
  +l = line_start(nl, line_room, c, line)
  found = String.is_empty(p) || String.is_empty(g) ||
    token_hit(tok && Nat.is_eq(Nat.add(word_n, 1n), token_length()), w) ||
    password_hit(nl && line_room, line) ||
    password_hit(Bool.not(nl) && Nat.is_eq(Nat.add(line_n, 1n), line_length()), l)
  Watch{p, g, w, word_count(tok, room, word_n), l, line_count(nl, line_room, line_n), found,
    strict && Char.is_eq(c, '\0')}

# What reading a text within the scan's budget found: a secret; a NUL
# character, in a text read strictly (UTF-16 and UTF-32 text hold them,
# whatever its charset is called), with the budget left; nothing, with the
# budget left; or nothing in what it read, the text going on past the
# budget.
type Reading is Data:
  Spotted{}
  Nul{left: Nat}
  Read{left: Nat}
  Over{}

def reading.if(hit: Bool, left: Nat) -> Reading:
  match hit:
    case True{}:
      Spotted{}
    case False{}:
      Read{left}

# At the end of the text, its last line is judged unless it already was.
def reading.fin(line: String, line_n: Nat, left: Nat) -> Reading:
  reading.if(password_hit(Nat.is_lt(line_n, line_length()), line), left)

# One walk over the characters, within `left` of them; a find, or a NUL
# in a strict reading, ends it.
def reading.go(s: String, left: Nat, +strict: Bool, l: Watch) -> Reading:
  match s left l:
    case _ _ Watch{pem, pgp, word, word_n, line, line_n, True{}, nul}:
      Spotted{}
    case _ _ Watch{pem, pgp, word, word_n, line, line_n, False{}, True{}}:
      Nul{left}
    case SNil{} _ Watch{pem, pgp, word, word_n, line, line_n, False{}, False{}}:
      reading.fin(line, line_n, left)
    case SCon{c, t} 0n _:
      Over{}
    case SCon{+c, t} 1n+n Watch{pem, pgp, word, word_n, line, line_n, False{}, False{}}:
      reading.go(t, n, strict, reading.step(c, strict, pem, pgp, word, word_n, line, line_n))

# Reads `text` for a secret by the three rules, within `left` characters;
# `strict` says a NUL character makes it unreadable.
def reading(text: String, left: Nat, strict: Bool) -> Reading:
  reading.go(text, left, strict, first_watch())

# What the scan reads
# ===================

# Whether a text part's bytes can be read for ASCII rules: its transfer
# encoding is one MailBend undoes, or none, and its charset keeps ASCII as
# ASCII (UTF-16, UTF-32, UTF-7 and UCS do not).
def scannable_encoding(cte: String, charset: String) -> Bool:
  +cs = String.to_lower(charset)
  undone = List.contains(~String, ~String.eq,
    ["", "7bit", "8bit", "binary", "base64", "quoted-printable"], String.to_lower(String.trim(cte)))
  wide = String.starts_with(cs, "utf-16") || String.starts_with(cs, "utf-32") ||
    String.starts_with(cs, "utf-7") || String.starts_with(cs, "ucs-")
  undone && Bool.not(wide)

# A part still to scan: text, read strictly; a forwarded message to open,
# inside which `forwards` more may still be opened; a part that cannot be
# read, and why; or the bytes of any other part, read last.
type Piece is Data:
  Plain{part: String, text: String}
  Message{part: String, raw: String, forwards: Nat}
  Unreadable{reason: String}
  Bytes{part: String, data: String}

# Where a scan stands: a secret found in the part named; or the pieces
# still to scan, the bytes to read last (newest first), how many
# characters it may still read, and why it is incomplete so far ("" while
# it is not).
type Scanning is Data:
  Hit{part: String}
  Next{todo: List<&2, Piece>, later: List<&2, Piece>, left: Nat, missed: String}

# What a single part holds to scan, `label` naming it: a forwarded message
# is opened while `forwards` allows it; a text part is read once decoded,
# unless its encoding cannot be; any other part's bytes are read last.
# Only the arm taken decodes the part.
def part_pieces.put(
  forward: Bool,
  text: Bool,
  readable: Bool,
  forwards: Nat,
  hs: List<&2, M.Hdr>,
  body: String,
  label: String
) -> List<&2, Piece>:
  match forward text readable forwards:
    case True{} _ _ 0n:
      [Unreadable{label ++ " nests forwarded messages more than " ++ Nat.show(forward_limit()) ++
        " levels deep"}]
    case True{} _ _ 1n+f:
      [Message{label, M.leaf_bytes(hs, body), f}]
    case False{} True{} True{} _:
      [Plain{label, M.leaf_bytes(hs, body)}]
    case False{} True{} False{} _:
      [Unreadable{"the text part " ++ label ++ " cannot be decoded"}]
    case False{} False{} _ _:
      [Bytes{label, M.leaf_bytes(hs, body)}]

# A single part, by its kind `k`; it is named after its type within
# `part`.
def part_pieces.kind(
  k: M.PartKind,
  +hs: List<&2, M.Hdr>,
  body: String,
  forwards: Nat,
  part: String
) -> List<&2, Piece>:
  M.PartKind{ct, +typ, name, file} = k
  part_pieces.put(String.eq(typ, "message/rfc822") || String.eq(typ, "message/global"),
    String.starts_with(typ, "text/"),
    scannable_encoding(M.header(hs, "content-transfer-encoding"), M.param(ct, "charset")),
    forwards, hs, body, part ++ " > " ++ typ)

def part_pieces(forwards: Nat, part: String, l: M.Leaf) -> List<&2, Piece>:
  M.Leaf{+hs, body} = l
  part_pieces.kind(M.part_kind(hs), hs, body, forwards, part)

def leaves_pieces(ls: List<&2, M.Leaf>, +forwards: Nat, +part: String) -> List<&2, Piece>:
  match ls:
    case Nil{}:
      []
    case l <> t:
      List.append(&2, Piece, part_pieces(forwards, part, l), leaves_pieces(t, forwards, part))

def cut_pieces(cut: Bool, part: String) -> List<&2, Piece>:
  match cut:
    case True{}:
      [Unreadable{part ++ " nests its parts more than " ++ Nat.show(M.multipart_limit()) ++
        " levels deep"}]
    case False{}:
      []

# Each header field's value with its RFC 2047 encoded words decoded, one
# per line.
def decoded_values(fs: List<&2, M.Hdr>) -> String:
  match fs:
    case Nil{}:
      ""
    case M.Hdr{name, value} <> t:
      M.decode_header(value) ++ "\n" ++ decoded_values(t)

def message_pieces.put(
  +part: String,
  +head: String,
  forwards: Nat,
  leaves: List<&2, M.Leaf> & Bool
) -> List<&2, Piece>:
  (ls, cut) = leaves
  Plain{"the header of " ++ part, head} <>
    Plain{"the decoded header of " ++ part, decoded_values(M.headers(head))} <>
      List.append(&2, Piece, leaves_pieces(ls, forwards, part), cut_pieces(cut, part))

# A forwarded message: its header section, read as text (so a message with
# no blank line is read whole) and with its values decoded, then its single
# parts. Parts nested past M.multipart_limit are missed.
def message_pieces(part: String, +raw: String, forwards: Nat) -> List<&2, Piece>:
  message_pieces.put(part, M.head_of(M.split(raw)), forwards, M.message_leaves.cut(raw))

# `missed`, or `reason` when nothing was missed yet.
def secret_scan.missed(+missed: String, reason: String) -> String:
  Bool.pick(String, String.is_empty(missed), reason, missed)

# What reading a text gives: a NUL makes it unreadable, and the text past
# the 1 MB is missed.
def secret_scan.read(
  r: Reading,
  part: String,
  rest: List<&2, Piece>,
  later: List<&2, Piece>,
  missed: String
) -> Scanning:
  match r:
    case Spotted{}:
      Hit{part}
    case Nul{left}:
      Next{rest, later, left, secret_scan.missed(missed, part ++ " cannot be decoded: it " ++
        "holds a NUL character, as UTF-16 and UTF-32 text do")}
    case Read{left}:
      Next{rest, later, left, missed}
    case Over{}:
      Next{rest, later, 0n, secret_scan.missed(missed, "it holds more than 1 MB of text")}

def secret_scan.step(
  p: Piece,
  rest: List<&2, Piece>,
  later: List<&2, Piece>,
  left: Nat,
  missed: String
) -> Scanning:
  match p:
    case Plain{part, text}:
      secret_scan.read(reading(text, left, True{}), part, rest, later, missed)
    case Message{part, raw, forwards}:
      Next{List.append(&2, Piece, message_pieces(part, raw, forwards), rest), later, left, missed}
    case Unreadable{reason}:
      Next{rest, later, left, secret_scan.missed(missed, reason)}
    case Bytes{part, data}:
      Next{rest, Bytes{part, data} <> later, left, missed}

def secret_scan.fin(missed: String) -> Scan:
  match missed:
    case SNil{}:
      Clean{}
    case SCon{h, t}:
      Incomplete{SCon{h, t}}

# The bytes of the parts that are not text, read last in what is left of
# the budget, `r` being what reading the previous ones (in `part`) gave. A
# find is Found, but bytes past the budget are not missed: most such parts
# (PDF, images, archives) are compressed, so their text cannot be read
# anyway. Only Bytes pieces are kept for last.
def secret_scan.last(ps: List<&2, Piece>, r: Reading, part: String, missed: String) -> Scan:
  match ps r:
    case _ Spotted{}:
      Found{part}
    case Bytes{p, data} <> t Read{left}:
      secret_scan.last(t, reading(data, left, False{}), p, missed)
    case _ <> t Read{left}:
      secret_scan.last(t, Read{left}, part, missed)
    case _ _:
      secret_scan.fin(missed)

# The fuel bounds the parts the scan takes; a find ends it.
def secret_scan.go(fuel: Nat, s: Scanning) -> Scan:
  match fuel s:
    case _ Hit{part}:
      Found{part}
    case _ Next{Nil{}, later, left, missed}:
      secret_scan.last(List.reverse(&2, Piece, later), Read{left}, "", missed)
    case 0n Next{p <> t, later, left, missed}:
      Incomplete{"it has too many parts"}
    case 1n+f Next{p <> t, later, left, missed}:
      secret_scan.go(f, secret_scan.step(p, t, later, left, missed))

def field_pieces(fs: List<&2, M.Hdr>) -> List<&2, Piece>:
  match fs:
    case Nil{}:
      []
    case M.Hdr{name, value} <> t:
      Plain{"the " ++ name ++ " field", value} <> field_pieces(t)

# Each attachment's name, then what it holds, named by its position from
# `n`: a name may itself be the secret, which the result must not repeat.
# A file read from disk has no transfer encoding, and a forwarded message
# may nest forward_limit levels in all.
def attachment_pieces(atts: List<&2, M.Attach>, +n: Nat) -> List<&2, Piece>:
  match atts:
    case Nil{}:
      []
    case M.Attach{name, ctype, data} <> t:
      +label = "attachment " ++ Nat.show(n)
      Plain{"the name of " ++ label, name} <> List.append(&2, Piece,
        part_pieces(forward_limit(), label, M.Leaf{[M.Hdr{"content-type", ctype}], data}),
        attachment_pieces(t, 1n+n))

# The secret scan of an outgoing message: its header fields (`fields`),
# its body (before transfer encoding) and its attachments.
def secret_scan(fields: List<&2, M.Hdr>, text: String, atts: List<&2, M.Attach>) -> Scan:
  pieces = List.concat(&2, Piece,
    [field_pieces(fields), [Plain{"the body", text}], attachment_pieces(atts, 1n)])
  secret_scan.go(scan_fuel(), Next{pieces, [], scan_limit(), ""})
