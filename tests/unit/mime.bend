# MIME parsing and composition.
import Base
import ../../src/mime.bend as M
import ../../src/codec.bend as C

def vis(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ vis(t)
    case SCon{'\n', t}:
      "\\n" ++ vis(t)
    case SCon{c, t}:
      SCon{c, vis(t)}

def msg() -> String:
  String.concat([
    "From: =?UTF-8?B?Sm9zw6k=?= <jose@example.com>\r\n",
    "Subject: =?utf-8?q?Caf=C3=A9?= =?utf-8?q?_menu?= today\r\n",
    "To: a@example.com,\r\n b@example.com\r\n",
    "Content-Type: multipart/mixed; boundary=\"XX\"\r\n",
    "\r\n",
    "preamble\r\n",
    "--XX\r\n",
    "Content-Type: multipart/alternative; boundary=YY\r\n",
    "\r\n",
    "--YY\r\n",
    "Content-Type: text/plain; charset=utf-8\r\n",
    "Content-Transfer-Encoding: quoted-printable\r\n",
    "\r\n",
    "Bonjour =C3=A0 tous\r\n",
    "--YY\r\n",
    "Content-Type: text/html\r\n",
    "\r\n",
    "<p>Bonjour &amp; <b>tous</b></p>\r\n",
    "--YY--\r\n",
    "--XX\r\n",
    "Content-Type: application/pdf\r\n",
    "Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf\r\n",
    "Content-Transfer-Encoding: base64\r\n",
    "\r\n",
    "JVBERi0xLjQK\r\n",
    "--XX--\r\n"])

def show_atts(xs: List<&2, M.Att>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{M.Att{n, t, s}, r}:
      n ++ "|" ++ t ++ "|" ++ U32.show(s) ++ ";" ++ show_atts(r)

def show_parts(p: M.Parts) -> String:
  match p:
    case M.Parts{t, h, a}:
      "text=" ++ String.trim(t) ++ " html=" ++ String.trim(M.html_text(h)) ++ " atts=" ++ show_atts(a)

def check(+hs: List<&2, M.Hdr>) -> IO(Unit):
  do IO<Unit>:
    IO.print(M.decode_header(M.header(hs, "from")))
    IO.print(M.decode_header(M.header(hs, "subject")))
    IO.print(M.header(hs, "to"))
    IO.print(M.main_value(M.header(hs, "content-type")) ++ " " ++ M.param(M.header(hs, "content-type"), "boundary"))

def draft() -> M.Draft:
  M.Draft{"Tester <tester@example.com>", ["José Q <jose@example.com>", "b@example.com"], [], [], "Résumé attached", "Line one\nligne deux é\n", "Sun, 27 Sep 2026 03:19:30 +0000", "<1@example.com>", "", "", [M.Attach{"notes.txt", "text/plain", "hello"}]}

# Whether a message is 7-bit: printable ASCII, tabs and CRLF only.
def crlf_plain(+s: String) -> Bool:
  C.is_plain(String.concat(String.split(String.concat(String.split(s, '\r')), '\n')))

def roundtrip(+m: String) -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(crlf_plain(m)))
    IO.print(M.decode_header(M.header(M.headers(M.head_of(M.split(m))), "to")))
    IO.print(M.decode_header(M.header(M.headers(M.head_of(M.split(m))), "subject")))
    IO.print(show_parts(M.parts(m)))

# Caller-supplied threading headers and content types cannot add header lines.
def evil() -> M.Draft:
  M.Draft{"t@example.com", ["a@example.com"], [], [], "s", "b", "d", "<1@x>", "<x@y>\r\nBcc: evil@example.com", "", [M.Attach{"f.txt", "text/plain\r\nX-Evil: 1", "hi"}]}

def no_evil(+m: String) -> Bool:
  Bool.not(String.contains(m, "\r\nBcc:") || String.contains(m, "\r\nX-Evil:"))

def long_name() -> String:
  String.repeat("é", 120n) ++ ".pdf"

# The longest line (between CRLFs) in a string.
def max_line(+s: String, +cur: U32, +best: U32) -> U32:
  match s:
    case SNil{}:
      U32.max(cur, best)
    case SCon{'\n', t}:
      max_line(t, 0, U32.max(cur, best))
    case SCon{c, t}:
      max_line(t, (cur + 1 : U32), best)

def main() -> IO(Unit):
  do IO<Unit>:
    check(M.headers(M.head_of(M.split(msg()))))
    IO.print(show_parts(M.parts(msg())))
    IO.print(show_parts(M.parts("Subject: plain\r\n\r\nJust text\r\n")))
    roundtrip(M.compose(draft(), "b0undary"))
    IO.print(M.rfc5322_date(0) ++ " / " ++ M.rfc5322_date(951782400) ++ " / " ++ M.rfc5322_date(1790480370) ++ " / " ++ M.rfc5322_date(4102444799))
    IO.print(Bool.show(no_evil(M.compose(evil(), "b"))) ++ " " ++ M.safe_ctype("Text/Plain") ++ " " ++ M.safe_ctype("a/b; x=\"y\"") ++ " " ++ Bool.show(M.seven_bit("ok\r\nline", 0)) ++ " " ++ Bool.show(M.seven_bit("caf\u{E9}", 0)))
    IO.print(vis(M.name_param("filename", "résumé.pdf")) ++ " | " ++ M.name_param("filename", "plain.txt"))
    IO.print(Nat.show(String.length(M.encode_header(String.repeat("a", 950n)))) ++ " " ++ Bool.show(String.contains(M.encode_header(String.repeat("a", 950n)), "\r\n ")) ++ " " ++ vis(M.fold_ids(["<a@x>", "<b@y>"])))
    IO.print(Bool.show(String.eq(M.param("attachment; " ++ String.concat(String.split(M.name_param("filename", long_name()), '\n')), "filename"), long_name())) ++ " " ++ Bool.show(U32.is_lt(max_line(M.name_param("filename", long_name()), 0, 0), 80)))
    IO.print(M.param("attachment; filename=\"Q1; final \\\"v2\\\".pdf\"; size=3", "filename") ++ " | " ++ M.main_value("text/plain ; charset=\"a;b\"") ++ " | " ++ M.addr_spec("john@example.com (Doe, John)"))
    IO.print(M.addr_spec("\"a <evil@x.com>\" <real@y.com>") ++ " " ++ M.addr_spec("plain@z.com"))
    IO.print(Bool.show(M.addr_ok("A <a@b.c>")) ++ " " ++ Bool.show(M.addr_ok("a@b.c\r\nRCPT TO:<x@y>")) ++ " " ++ Bool.show(M.addr_ok("no-at")) ++ " " ++ Bool.show(M.addr_ok("a@b@c")))
    IO.print(M.param("attachment; filename*0=\"Q1 \"; filename*1=\"final.pdf\"", "filename") ++ " | " ++ M.param("attachment; filename*0*=utf-8''r%C3%A9; filename*1=\" sum.pdf\"", "filename") ++ " | " ++ M.decode_header("=?UTF-8?Q?caf=C3=A9?=\t=?UTF-8?Q?_cr=C3=A8me?= ok"))

#|José <jose@example.com>
#|Café menu today
#|a@example.com, b@example.com
#|multipart/mixed XX
#|text=Bonjour à tous html=Bonjour & tous atts=résumé.pdf|application/pdf|9;
#|text=Just text html= atts=
#|True
#|José Q <jose@example.com>, b@example.com
#|Résumé attached
#|text=Line one
#|ligne deux é html= atts=notes.txt|text/plain|5;
#|Thu, 1 Jan 1970 00:00:00 +0000 / Tue, 29 Feb 2000 00:00:00 +0000 / Sun, 27 Sep 2026 03:39:30 +0000 / Thu, 31 Dec 2099 23:59:59 +0000
#|True text/plain application/octet-stream True False
#|filename="r_sum_.pdf";\r\n filename*0*=utf-8''r%C3%A9sum%C3%A9.pdf | filename="plain.txt"
#|1595 True <a@x>\r\n <b@y>
#|True True
#|Q1; final "v2".pdf | text/plain | john@example.com
#|real@y.com plain@z.com
#|True False False False
#|Q1 final.pdf | ré sum.pdf | café crème ok
