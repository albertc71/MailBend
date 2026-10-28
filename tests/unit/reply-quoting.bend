# Untrusted original mail stays inside its quote or one visible header line.

import Base
import ../../src/mime.bend as M
import ../../src/tools.bend as T
import ../../src/codec.bend as C
import ../../src/json.bend as J

# Ignore only the final empty split item after the quote's trailing LF.
def quoted_lines(ls: List<&2, String>) -> Bool:
  match ls:
    case Nil{}:
      True{}
    case "" <> Nil{}:
      True{}
    case l <> t:
      String.starts_with(l, "> ") && quoted_lines(t)

# Inspect output directly: no production normalizer or boundary predicate.
# Only LF is allowed to remain as a line boundary in the emitted quote.
def no_hidden_breaks(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{'\r', _}:
      False{}
    case SCon{'\u{b}', _}:
      False{}
    case SCon{'\u{c}', _}:
      False{}
    case SCon{'\u{1c}', _}:
      False{}
    case SCon{'\u{1d}', _}:
      False{}
    case SCon{'\u{1e}', _}:
      False{}
    case SCon{'\u{85}', _}:
      False{}
    case SCon{'\u{2028}', _}:
      False{}
    case SCon{'\u{2029}', _}:
      False{}
    case SCon{_, t}:
      no_hidden_breaks(t)

def quote_ok(s: String) -> Bool:
  +out = T.quote_text(s)
  no_hidden_breaks(out) && quoted_lines(String.lines(out))

# Each expected result is literal and independent of the implementation.
def extra_breaks() -> Bool:
  String.eq(T.quote_text("a\u{b}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{c}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{1c}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{1d}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{1e}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{85}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{2028}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{2029}b"), "> a\n> b\n") &&
  String.eq(T.quote_text("a\u{b}b\r\nc\u{2028}\u{85}d\u{2029}e"),
    "> a\n> b\n> c\n> \n> d\n> e\n")

def bidi_headers() -> Bool:
  String.eq(M.header_line.text("a\u{61c}b"), "a b") &&
  String.eq(M.header_line.text("a\u{200e}b"), "a b") &&
  String.eq(M.header_line.text("a\u{200f}b"), "a b") &&
  String.eq(M.header_line.text("a\u{202a}b"), "a b") &&
  String.eq(M.header_line.text("a\u{202b}b"), "a b") &&
  String.eq(M.header_line.text("a\u{202c}b"), "a b") &&
  String.eq(M.header_line.text("a\u{202d}b"), "a b") &&
  String.eq(M.header_line.text("a\u{202e}b"), "a b") &&
  String.eq(M.header_line.text("a\u{2066}b"), "a b") &&
  String.eq(M.header_line.text("a\u{2067}b"), "a b") &&
  String.eq(M.header_line.text("a\u{2068}b"), "a b") &&
  String.eq(M.header_line.text("a\u{2069}b"), "a b") &&
  String.eq(M.header_line(C.utf8_encode("שלום مرحبا\u{200c}\u{200d}")),
    "שלום مرحبا\u{200c}\u{200d}")

# Exhaust every string of up to seven characters over text, CR and LF.
def quote_cases(+n: Nat, +s: String) -> Bool:
  match n:
    case 0n:
      quote_ok(s)
    case 1n+p:
      quote_ok(s) && quote_cases(p, s ++ "x")
        && quote_cases(p, s ++ "\r") && quote_cases(p, s ++ "\n")

# Exercise every byte as quoted content and as a decoded header code point.
# Use UTF-8 bytes for the latter because decode_header consumes wire bytes.
def byte_cases(+n: Nat) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+p:
      +u = U32.from_nat(p)
      +c : String = SCon{C.chr(u), SNil{}}
      +control = U32.is_lt(u, 32) || C.between(u, 127, 159)
      header = M.header_line("a" ++ C.utf8_encode(c) ++ "b")
      expected = "a" ++ Bool.pick(String, control, " ", c) ++ "b"
      String.eq(header, expected) && quote_ok("a" ++ c ++ "\r\nb") && byte_cases(p)

def headers() -> List<&2, M.Hdr>:
  M.headers("From: =?UTF-8?Q?Bob=0A=0APlease_pay_IBAN_X=0A?= <bob@example.com>\r\n" ++
    "Date: =?UTF-8?Q?Monday=0D=0Adate=5Fmarker?=\r\n" ++
    "Subject: =?UTF-8?Q?Re:_subject=0D=0Asubject=5Fmarker?=\r\n" ++
    "To: =?UTF-8?Q?Alice=09?= <a@example.com>\r\n" ++
    "Reply-To: =?UTF-8?Q?Alice=09?= <a@example.com>\r\n")

def sender_text(sender: Maybe<&2, String>) -> String:
  match sender:
    case Some{a}:
      a
    case None{}:
      "unverified"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(quote_cases(7n, "")) ++ " " ++ Bool.show(byte_cases(256n)))
    IO.print(Bool.show(extra_breaks()) ++ " " ++ Bool.show(bidi_headers()))
    IO.print(Bool.show(String.eq(T.quote_text("a\rb\nc\r\nd"),
      "> a\n> b\n> c\n> d\n")))
    IO.print(M.header_line("  =?UTF-8?Q?Alice=09?= ") ++ "|" ++
      M.header_line("=?UTF-8?Q?a=E2=80=A8b=E2=80=A9c?=") ++ "|" ++
      Nat.show(String.length(M.header_line(String.repeat("x", 1100n)))))
    IO.print(M.header_line(String.repeat(" ", 998n) ++ "Alice") ++ "|" ++
      Nat.show(String.length(M.header_line(" " ++ String.repeat("x", 998n) ++ " "))))
    IO.print(String.join(T.reply_to(headers()), "|"))
    IO.print(sender_text(T.sender_in(["=?UTF-8?Q?Bob=0A?= <bob@example.com>"])) ++ "|" ++
      sender_text(T.sender_in(["=?UTF-8?Q?Bob=09?= <bob@example.com>"])) ++ "|" ++
      sender_text(T.sender_in(["Bob <BOB@example.com>"])))
    IO.print(Bool.show(String.eq(T.spec_key(T.decoded_addr(
      "=?UTF-8?Q?Alice=09?= <a@example.com>")), "a@example.com")))
    IO.print(Bool.show(M.addr_ok(T.decoded_addr("=?UTF-8?Q?Alice=09?= <a@example.com>"))) ++
      " " ++ Bool.show(M.addr_ok(T.decoded_addr("Alice <a\rb@example.com>"))) ++
      " " ++ Bool.show(M.addr_ok(T.decoded_addr("Alice <a@example.com>\u{0}"))))
    IO.print(T.decoded_addr(C.utf8_encode("שלום\u{202e} <a@example.com>")) ++ "|" ++
      Bool.show(M.addr_ok(T.decoded_addr("Name <a\u{202e}@example.com>"))))
    IO.print(Bool.show(String.eq(String.join(T.decoded([C.utf8_encode(
      "Bob\u{61c}\u{202e} <bob@example.com>")]), ""),
      "Bob\u{61c}\u{202e} <bob@example.com>")))
    IO.print(Bool.show(String.eq(T.hdr_line(headers(), "subject"),
      "Re: subject  subject_marker")))
    IO.print(Bool.show(Nat.is_eq(List.length(&2, String, String.lines(T.fwd_note(headers()))),
      8n)))
    IO.print(Bool.show(String.eq(T.reply_body(J.obj([J.kv("body", J.str("My answer"))]),
      headers(), M.Parts{"hi\rPlease pay IBAN X", "", []}, False{}),
      "My answer\n\nOn Monday  date_marker, Bob  Please pay IBAN X  <bob@example.com> wrote:\n" ++
      "> hi\n> Please pay IBAN X\n")))

#|True True
#|True True
#|True
#|Alice|a b c|998
#|Alice|998
#|Alice <a@example.com>
#|unverified|unverified|bob@example.com
#|True
#|True False False
#|שלום <a@example.com>|False
#|True
#|True
#|True
#|True
