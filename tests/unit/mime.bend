# MIME parsing and composition, and header address lists.

import Base
import ../../src/mime.bend as M
import ../../src/codec.bend as C

def show_line_breaks(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ show_line_breaks(t)
    case SCon{'\n', t}:
      "\\n" ++ show_line_breaks(t)
    case SCon{c, t}:
      SCon{c, show_line_breaks(t)}

def multipart_message() -> String:
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
    case M.Att{n, t, s} <> r:
      n ++ "|" ++ t ++ "|" ++ U32.show(s) ++ ";" ++ show_atts(r)

def show_parts(p: M.Parts) -> String:
  match p:
    case M.Parts{t, h, a}:
      "text=" ++ String.trim(t) ++ " html=" ++ String.trim(M.html_text(h)) ++ " atts=" ++ show_atts(a)

def show_headers(+hs: List<&2, M.Hdr>) -> IO(Unit):
  do IO<Unit>:
    IO.print(M.decode_header(M.header(hs, "from")))
    IO.print(M.decode_header(M.header(hs, "subject")))
    IO.print(M.header(hs, "to"))
    IO.print(M.main_value(M.header(hs, "content-type")) ++ " " ++ M.param(M.header(hs, "content-type"), "boundary"))

def attachment_draft() -> M.Draft:
  M.Draft{"Tester <tester@example.com>", ["José Q <jose@example.com>", "b@example.com"], [], [], "Résumé attached", "Line one\nligne deux é\n", "Sun, 27 Sep 2026 03:19:30 +0000", "<1@example.com>", "", "", [M.Attach{"notes.txt", "text/plain", "hello"}]}

# Whether a message is 7-bit: printable ASCII, tabs and CRLF only.
def crlf_plain(s: String) -> Bool:
  C.is_plain(String.concat(String.split(String.concat(String.split(s, '\r')), '\n')))

def roundtrip(+m: String) -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(crlf_plain(m)))
    IO.print(M.decode_header(M.header(M.headers(M.head_of(M.split(m))), "to")))
    IO.print(M.decode_header(M.header(M.headers(M.head_of(M.split(m))), "subject")))
    IO.print(show_parts(M.parts(m)))

# Caller-supplied threading headers and content types cannot add header lines.
def header_injection_draft() -> M.Draft:
  M.Draft{"t@example.com", ["a@example.com"], [], [], "s", "b", "d", "<1@x>", "<x@y>\r\nBcc: evil@example.com", "", [M.Attach{"f.txt", "text/plain\r\nX-Evil: 1", "hi"}]}

def has_no_injected_headers(+m: String) -> Bool:
  Bool.not(String.contains(m, "\r\nBcc:") || String.contains(m, "\r\nX-Evil:"))

def long_name() -> String:
  String.repeat("é", 120n) ++ ".pdf"

# The longest line (between CRLFs) in a string.
def max_line(s: String, cur: U32, best: U32) -> U32:
  match s:
    case SNil{}:
      U32.max(cur, best)
    case SCon{'\n', t}:
      max_line(t, 0, U32.max(cur, best))
    case SCon{c, t}:
      max_line(t, (cur + 1 : U32), best)

# Header fields as "name=value;" pairs, for pinning parsed headers exactly.
def show_hdrs(hs: List<&2, M.Hdr>) -> String:
  match hs:
    case Nil{}:
      ""
    case M.Hdr{n, v} <> t:
      n ++ "=" ++ v ++ ";" ++ show_hdrs(t)

# A message's parts with nothing trimmed and line breaks made visible.
def show_parts_raw(p: M.Parts) -> String:
  match p:
    case M.Parts{t, h, a}:
      "text=" ++ show_line_breaks(t) ++ " html=" ++ show_line_breaks(h) ++ " atts=" ++ show_atts(a)

def print_parts(m: String) -> IO(Unit):
  IO.print(show_parts_raw(M.parts(m)))

def print_compose(d: M.Draft, b: String) -> IO(Unit):
  IO.print(show_line_breaks(M.compose(d, b)))

# A multipart message nested `n` levels deep around one text/plain part.
def nested(+n: Nat) -> String:
  match n:
    case 0n:
      "Content-Type: text/plain\r\n\r\ndeep"
    case 1n+p:
      +b = "b" ++ Nat.show(1n+p)
      "Content-Type: multipart/mixed; boundary=" ++ b ++ "\r\n\r\n--" ++ b ++ "\r\n" ++ nested(p) ++ "\r\n--" ++ b ++ "--"

def header_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_line_breaks(M.head_of(M.split("A: 1\r\n\r\nbody\r\n\r\nmore"))) ++ " | " ++ show_line_breaks(M.head_of(M.split("A: 1\n\nbody"))) ++ " | " ++ show_line_breaks(M.head_of(M.split("no break"))) ++ " | " ++ M.head_of(M.split("")))
    IO.print(show_hdrs(M.headers(" lead\r\nA: 1\r\nB:2\r\n continued\r\n\tmore\r\nbogus line\r\nC : x : y\r\nSUBJECT:  Hi  \r\na: second")))
    IO.print(M.header(M.headers("A: 1\r\nB: 2\r\nA: 3"), "a") ++ " [" ++ M.header(M.headers("A: 1"), "missing") ++ "] [" ++ M.header(M.headers("A: 1"), "A") ++ "]")
    IO.print(M.decode_header("=?utf-8?b?Q2Fmw6k=?=") ++ " | " ++ M.decode_header("Re: =?UTF-8?Q?caf=C3=A9?=") ++ " | " ++ M.decode_header("=?bad?=") ++ " | " ++ M.decode_header("=?UTF-8?X?a_b?="))
    IO.print(M.decode_header("a  b") ++ " | " ++ M.decode_header("caf\u{C3}\u{A9}") ++ " | " ++ M.decode_header("=?ISO-8859-1?Q?caf=E9?=") ++ " | " ++ M.decode_header("=?UTF-8?Q?a?= x =?UTF-8?Q?b?=") ++ " | [" ++ M.decode_header("") ++ "]")

def param_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print(M.main_value("TEXT/HTML ; x=1") ++ " [" ++ M.main_value("") ++ "] " ++ M.main_value("text/plain"))
    IO.print(M.param("text/plain; charset=utf-8", "charset") ++ " " ++ M.param("text/plain; CHARSET = \"ISO-8859-1\"", "charset") ++ " [" ++ M.param("text/plain", "charset") ++ "] [" ++ M.param("a; filename=x", "name") ++ "]")
    IO.print(M.param("a; filename=plain.txt; filename*=utf-8''r%C3%A9.txt", "filename") ++ " | " ++ M.param("a; filename*=utf-8'en'%41%zz%4", "filename") ++ " | " ++ M.param("a; filename*=noquotes", "filename") ++ " | " ++ M.param("a; filename*=\"\"; filename=fallback", "filename"))
    IO.print(M.param("a; filename*0=\"a \"; filename*2=\"c\"", "filename") ++ " | " ++ M.param("a; filename*0=\"a b\"; filename*1*=%C3%A9", "filename") ++ " | " ++ M.param("a; name=\"=?UTF-8?Q?caf=C3=A9?=\"", "name") ++ " | " ++ M.param("a; x=\"q\\\\b\"", "x") ++ " [" ++ M.param("a; x=\"\"", "x") ++ "] " ++ M.param("a; x=\"", "x"))

def parts_cases() -> IO(Unit):
  do IO<Unit>:
    print_parts("Content-Type: text/html; charset=utf-8\r\n\r\n<p>Hi &lt;3</p>\r\n")
    print_parts("Content-Transfer-Encoding:  BASE64 \r\n\r\naGk=")
    print_parts("Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: Quoted-Printable\r\n\r\ncaf=E9 =\r\nsoft")
    print_parts("Content-Type: text/plain; name=a.txt\r\n\r\nabc")
    print_parts("Content-Type: text/plain\r\nContent-Disposition: ATTACHMENT\r\n\r\nabc")
    print_parts("Content-Type: image/png\r\nContent-Disposition: inline; filename=\"i.png\"\r\nContent-Transfer-Encoding: base64\r\n\r\neHl6\r\n")
    print_parts("Content-Type: image/png\r\n\r\nxyz")
    print_parts("Subject: x\n\nline1\r\nline2\rend")
    print_parts("Content-Type: multipart/mixed; boundary=B\r\n\r\npre\r\n--B\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--B\r\nContent-Type: text/plain\r\n\r\nsecond\r\n--B \r\nContent-Type: text/html\r\n\r\n<b>h</b>\r\n--B--\r\n--B\r\nContent-Type: text/plain\r\n\r\nepilogue")
    print_parts("Content-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--B\r\nContent-Type: text/html\r\n\r\n<b>cut")
    print_parts("Content-Type: multipart/mixed\r\n\r\n--B\r\nabc")
    print_parts("Content-Type: multipart/mixed; boundary=B\r\n\r\nno parts at all")
    print_parts(nested(7n))
    print_parts(nested(8n))

def html_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print("[" ++ M.html_text("a<br>b") ++ "] [" ++ M.html_text("<p>x</p>  <p>y</p>") ++ "] [" ++ M.html_text("unclosed <tag text") ++ "] [" ++ M.html_text("stray > here") ++ "]")
    IO.print("[" ++ M.html_text("1 &gt; 0 &amp;&amp; &quot;q&quot; &#39;s&#39;&nbsp;&foo; &amp;lt;") ++ "] [" ++ M.html_text("\ttab\t\t sp  ") ++ "] [" ++ M.html_text("") ++ "] [" ++ M.html_text("&lt;b&gt;") ++ "]")

def compose_draft() -> M.Draft:
  M.Draft{"Zoë Ñ <z@example.com>", [], ["c1@example.com", "\"Doe, J\" <j@x.com>", "<bare@x.com>"], ["hidden@example.com"], "plain subject", "a\rb\nc\r\nd=e é", "D", "<m@x>", "  <p@x>\r\n ", "<r1@x>  <r2@x>\t<r3@x>", [M.Attach{"résumé.pdf", "Application/PDF", "%PDF\u{FF}"}, M.Attach{"bad.bin", "x", ""}, M.Attach{"m.eml", "message/rfc822", "Subject: \u{E9}\r\n\r\nhi"}]}

def compose_cases() -> IO(Unit):
  do IO<Unit>:
    print_compose(compose_draft(), "BB")
    print_compose(M.Draft{"a@b.c", ["x@y.z"], [], [], "", "", "D", "<i@x>", "", "", []}, "unused")
    IO.print(M.encode_header("") ++ "|" ++ M.encode_header("Café") ++ "|" ++ show_line_breaks(M.encode_header(String.repeat("é", 30n))) ++ "|" ++ Nat.show(String.length(M.encode_header(String.repeat("a", 900n)))) ++ " " ++ Nat.show(String.length(M.encode_header(String.repeat("a", 901n)))))
    IO.print(M.safe_ctype("text/") ++ " " ++ M.safe_ctype("/x") ++ " " ++ M.safe_ctype("a/b/c") ++ " " ++ M.safe_ctype("") ++ " " ++ M.safe_ctype("image/svg+xml") ++ " " ++ M.safe_ctype("Message/RFC822"))
    IO.print(Bool.show(M.seven_bit(String.repeat("a", 998n), 0)) ++ " " ++ Bool.show(M.seven_bit(String.repeat("a", 999n), 0)) ++ " " ++ Bool.show(M.seven_bit("a\u{0}", 0)) ++ " " ++ Bool.show(M.seven_bit("a\nb", 0)) ++ " " ++ Bool.show(M.seven_bit("a\rb", 0)) ++ " " ++ Bool.show(M.seven_bit("\u{7F}", 0)) ++ " " ++ Bool.show(M.seven_bit("", 0)))
    IO.print(M.name_param("name", "a\"b\\c") ++ " | " ++ Nat.show(String.length(M.name_param("f", String.repeat("a", 200n)))) ++ " | " ++ show_line_breaks(M.name_param("f", String.repeat("a", 201n))))
    IO.print("[" ++ M.fold_ids([]) ++ "] [" ++ show_line_breaks(M.fold_ids(M.msg_ids("<a@x> <> <b@y>"))) ++ "] [" ++ show_line_breaks(M.fold_ids(M.msg_ids("<a@x> " ++ String.repeat("x", 901n)))) ++ "]")
    IO.print(show_line_breaks(M.att_part("B", M.Attach{"a.txt", "text/plain", "hi"})) ++ " | " ++ show_line_breaks(M.att_part("B", M.Attach{"m.eml", "message/rfc822", "a\nb"})))

def date_cases() -> IO(Unit):
  IO.print(M.rfc5322_date(1709164800) ++ " / " ++ M.rfc5322_date(946684799) ++ " / " ++ M.rfc5322_date(4294967295) ++ " / " ++ M.rfc5322_date(86399) ++ " / " ++ M.rfc5322_date(1715000000))

# Line breaks made visible, so folded headers fit on one expected line.
def visible(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ visible(t)
    case SCon{'\n', t}:
      "\\n" ++ visible(t)
    case SCon{c, t}:
      SCon{c, visible(t)}

def specs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      "[" ++ M.addr_spec(x) ++ "]" ++ specs(t)

def oks(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      Bool.show(M.addr_ok(x)) ++ " " ++ oks(t)

# A message with attachments: base64 and quoted-printable ones in a nested
# multipart (the second with an RFC 2231 name), then a 7bit one without a
# name after the text.
def attachments_message() -> String:
  String.concat([
    "Content-Type: multipart/mixed; boundary=\"A\"\r\n",
    "\r\n",
    "--A\r\n",
    "Content-Type: text/plain\r\n\r\nbody text\r\n",
    "--A\r\n",
    "Content-Type: multipart/mixed; boundary=B\r\n\r\n",
    "--B\r\n",
    "Content-Type: application/octet-stream; name=\"b64.bin\"\r\n",
    "Content-Transfer-Encoding: base64\r\n\r\nAP+ACg==\r\n",
    "--B\r\n",
    "Content-Type: text/plain\r\n",
    "Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.txt\r\n",
    "Content-Transfer-Encoding: quoted-printable\r\n\r\ncaf=E9 =\r\nsoft\r\n",
    "--B--\r\n",
    "--A\r\n",
    "Content-Type: image/png\r\nContent-Transfer-Encoding: 7bit\r\n\r\nraw bytes\r\n",
    "--A--\r\n"])

# A binary part whose bytes hold a bare LF, a CRLF and a bare CR.
def binary_message() -> String:
  "Content-Type: multipart/mixed; boundary=\"Z\"\r\n\r\n--Z\r\n" ++
    "Content-Type: application/octet-stream; name=\"raw.bin\"\r\n" ++
    "Content-Transfer-Encoding: binary\r\n\r\nA\nB\r\nC\rD\r\n--Z--\r\n"

def byte_values.go(s: String) -> List<&2, String>:
  match s:
    case SNil{}:
      []
    case SCon{c, t}:
      U32.show(Char.to_u32(c)) <> byte_values.go(t)

# A byte string as its byte values.
def byte_values(s: String) -> String:
  String.join(byte_values.go(s), ",")

def show_attachment(m: Maybe<&2, M.Attach>) -> String:
  match m:
    case None{}:
      "none"
    case Some{M.Attach{name, ctype, data}}:
      name ++ "|" ++ ctype ++ "|" ++ byte_values(data)

def attachment_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_parts(M.parts(attachments_message())))
    IO.print(show_attachment(M.attachment_at(attachments_message(), 0)))
    IO.print(show_attachment(M.attachment_at(attachments_message(), 1)))
    IO.print(show_attachment(M.attachment_at(attachments_message(), 2)))
    IO.print(show_attachment(M.attachment_at(attachments_message(), 3)))
    IO.print(show_attachment(M.attachment_at("Subject: x\r\n\r\nno parts", 0)))
    IO.print(show_attachment(M.attachment_at(multipart_message(), 0)))
    IO.print(show_attachment(M.attachment_at(binary_message(), 0)))

def local_name_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print(M.local_name("../../evil.sh") ++ " | " ++ M.local_name("/etc/passwd") ++ " | " ++ M.local_name("C:\\Users\\x\\report.pdf") ++ " | [" ++ M.local_name("dir/") ++ "]")
    IO.print(M.local_name("\u{202E}gnp.exe") ++ " | " ++ M.local_name("...hidden") ++ " | " ++ M.local_name("a\u{0}b\tc\u{7F}d\u{9F}e\u{AD}f\u{FEFF}g\u{E0041}h") ++ " | " ++ M.local_name(". .x"))
    IO.print("[" ++ M.local_name("..") ++ "] [" ++ M.local_name(".") ++ "] [" ++ M.local_name("") ++ "] [" ++ M.local_name("\u{202E}") ++ "]")
    IO.print(Nat.show(String.length(M.local_name(String.repeat("a", 300n)))) ++ " " ++ Nat.show(String.length(M.local_name(String.repeat("\u{E9}", 200n)))) ++ " " ++ Nat.show(String.length(M.local_name("a" ++ String.repeat("\u{1F600}", 64n)))) ++ " " ++ M.local_name("caf\u{E9}.txt"))

def conformance_draft(subject: String, irt: String, refs: String, atts: List<&2, M.Attach>) -> M.Draft:
  M.Draft{"a@x", ["b@y"], [], [], subject, "body", "D", "<m@x>", irt, refs, atts}

def composed_header(subject: String) -> String:
  M.head_of(M.split(M.compose(conformance_draft(subject, "", "", []), "B")))

def subject_roundtrip(+subject: String) -> Bool:
  String.eq(M.decode_header(M.header(M.headers(composed_header(subject)), "subject")), subject)

def unfold(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      unfold(t)
    case SCon{c, t}:
      SCon{c, unfold(t)}

def composed_thread(irt: String, refs: String, name: String) -> String:
  String.trim(M.header(M.headers(M.head_of(M.split(M.compose(conformance_draft("s", irt, refs, []), "B")))), name))

def long_refs() -> String:
  "<root@x> " ++ String.repeat("<middle@x> ", 120n) ++ "<last1@x> <last2@x>"

def conformance_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print("encoded subject line bound " ++ Bool.show(U32.is_le(max_line(composed_header(String.repeat("é", 80n)), 0, 0), 77)))
    IO.print("encoded display line bound " ++ Bool.show(U32.is_le(max_line("From: " ++ M.encode_addr(String.repeat("é", 39n) ++ " <long.address@example.invalid>"), 0, 0), 77)))
    IO.print("literal encoded words " ++ Bool.show(subject_roundtrip("=?x?=")) ++ " " ++ Bool.show(subject_roundtrip("Re: =?UTF-8?B?SGFja2Vk?=")))
    IO.print("long ASCII subject line bound " ++ Bool.show(U32.is_le(max_line(composed_header(String.repeat("one two ", 20n) ++ "end"), 0, 0), 79)))
    IO.print("ASCII subject whitespace preserved " ++ Bool.show(String.eq(unfold(M.encode_header(String.repeat("one  two ", 20n) ++ "end")), String.repeat("one  two ", 20n) ++ "end")))
    IO.print("first subject token bounds " ++ Bool.show(U32.is_le(max_line(composed_header(String.repeat("a", 69n)), 0, 0), 79)) ++ " " ++ Bool.show(U32.is_le(max_line(composed_header(String.repeat("a", 70n)), 0, 0), 79)) ++ " " ++ Bool.show(U32.is_le(max_line(composed_header(String.repeat("a", 77n)), 0, 0), 79)))
    IO.print("literal display word " ++ Bool.show(String.contains(M.encode_addr("=?UTF-8?B?SGFja2Vk?= <a@x>"), "=?UTF-8?B?PT9VVEYtOD9CP1NHRmphMlZrPz0=?=")))
    IO.print("UTF-8 attachment charset " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"notes.txt", "text/plain", C.utf8_encode("café")}), "text/plain; charset=utf-8")))
    IO.print("ASCII attachment charset " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"notes.csv", "text/csv", "one,two\r\n"}), "text/csv; charset=us-ascii")))
    IO.print("invalid UTF-8 attachment unchanged " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"notes.txt", "text/plain", "caf\u{E9}"}), "text/plain;\r\n name=")))
    IO.print("binary attachment unchanged " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"data.bin", "application/octet-stream", "ASCII"}), "application/octet-stream;\r\n name=")))
    IO.print("threading tokens " ++ M.header(M.headers(M.head_of(M.split(M.compose(conformance_draft("s", "<a@x> (by relay)", "(note) <root@x> junk <a@x>", []), "B")))), "in-reply-to"))
    IO.print("references tokens " ++ M.header(M.headers(M.head_of(M.split(M.compose(conformance_draft("s", "", "(note) <root@x> junk <a@x>", []), "B")))), "references"))
    IO.print("references bound " ++ Bool.show(Nat.is_le(String.length(M.header(M.headers(M.head_of(M.split(M.compose(conformance_draft("s", "", "<root@x> " ++ String.repeat("<middle@x> ", 120n) ++ "<last1@x> <last2@x>", []), "B")))), "references")), 986n)))
    IO.print("references keep endpoints " ++ Bool.show(String.starts_with(composed_thread("", long_refs(), "references"), "<root@x> ")) ++ " " ++ Bool.show(String.ends_with(composed_thread("", long_refs(), "references"), "<last1@x> <last2@x>")))
    IO.print("threading malformed dropped [" ++ composed_thread("(fake <comment@x>) <a@x> <bad> <two@@x> <space @x> <\u{E9}@x> <open", "", "in-reply-to") ++ "]")
    IO.print("boundary collision encoded " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"original.eml", "message/rfc822", "Subject: old\r\n\r\n--B\r\nbody"}), "Content-Type: application/octet-stream")))
    IO.print("whole QP padded soft break " ++ M.readable_text(M.parts("Content-Transfer-Encoding: quoted-printable\r\n\r\nfoo= \r\nbar")))
    IO.print("whole QP final soft break " ++ M.readable_text(M.parts("Content-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nlast=\r\n--B--\r\n")))

def charset_is(data: String, charset: String) -> Bool:
  +part = M.att_part("B", M.Attach{"text.txt", "text/plain", data})
  String.eq(M.param(M.header(M.headers(M.head_of(M.split(part))), "content-type"), "charset"), charset)

def attachment_text(+part: String) -> String:
  +hs = M.headers(M.head_of(M.split(part)))
  M.leaf.text(M.header(hs, "content-type"), M.leaf_bytes(hs, M.body_of(M.split(part))))

def raw_attachment(data: String) -> Bool:
  String.contains(M.att_part("B", M.Attach{"m.eml", "message/rfc822", data}), "Content-Transfer-Encoding: 7bit")

def long_id(n: Nat, c: String) -> String:
  "<" ++ String.repeat(c, n) ++ "@x>"

def conformance_edges() -> IO(Unit):
  do IO<Unit>:
    IO.print("single long subject token roundtrip " ++ Bool.show(subject_roundtrip(String.repeat("a", 79n))) ++ " " ++ Bool.show(subject_roundtrip(String.repeat("a", 900n))))
    IO.print("first subject token roundtrip " ++ Bool.show(subject_roundtrip(String.repeat("a", 69n))) ++ " " ++ Bool.show(subject_roundtrip(String.repeat("a", 70n))) ++ " " ++ Bool.show(subject_roundtrip(String.repeat("a", 77n))))
    IO.print("text charset validity " ++ Bool.show(charset_is("\u{0}\t\r\n", "us-ascii")) ++ " " ++ Bool.show(charset_is(C.utf8_encode("é€😀�"), "utf-8")) ++ " " ++ Bool.show(charset_is("\u{C0}\u{AF}", "")) ++ " " ++ Bool.show(charset_is("\u{ED}\u{A0}\u{80}", "")) ++ " " ++ Bool.show(charset_is("\u{F4}\u{90}\u{80}\u{80}", "")) ++ " " ++ Bool.show(charset_is("\u{C3}", "")) ++ " " ++ Bool.show(charset_is("\u{80}", "")))
    IO.print("text attachment roundtrip " ++ attachment_text(M.att_part("B", M.Attach{"café.txt", "text/plain", C.utf8_encode("café")})))
    IO.print("boundary prefix checks " ++ Bool.show(raw_attachment("--B\r\n")) ++ " " ++ Bool.show(raw_attachment("Subject: s\r\n\r\n--B--\r\n")) ++ " " ++ Bool.show(raw_attachment("Subject: s\r\n\r\n--Bextra\r\n")) ++ " " ++ Bool.show(raw_attachment("Subject: s\r\n\r\ntext --B\r\n")))
    IO.print("reference exact limits " ++ Bool.show(Nat.is_eq(String.length(composed_thread("", long_id(982n, "a"), "references")), 986n)) ++ " " ++ Bool.show(String.is_empty(composed_thread("", long_id(983n, "a"), "references"))) ++ " " ++ Bool.show(Nat.is_eq(String.length(composed_thread("", long_id(496n, "a") ++ " " ++ long_id(481n, "b"), "references")), 986n)))
    IO.print("oversized mandatory references omitted " ++ Bool.show(String.is_empty(composed_thread("<reply@x>", long_id(336n, "a") ++ " " ++ long_id(336n, "b") ++ " " ++ long_id(336n, "c"), "references"))) ++ " " ++ composed_thread("<reply@x>", long_id(336n, "a") ++ " " ++ long_id(336n, "b") ++ " " ++ long_id(336n, "c"), "in-reply-to"))
    IO.print("thread token grammar " ++ composed_thread("<bad<inner@x>> <a..b@x> <a@.x> <ok@[127.0.0.1]> <ok@[IPv6:abcd::1]> (nested (fake <n@x>)) \"quote <q@x>\" <end@x>", "", "in-reply-to"))
    IO.print("tab and long whitespace preserved " ++ Bool.show(String.eq(unfold(M.encode_header(String.repeat("a\tb ", 40n))), String.repeat("a\tb ", 40n))) ++ " " ++ Bool.show(String.eq(unfold(M.encode_header("start" ++ String.repeat(" ", 200n) ++ "end")), "start" ++ String.repeat(" ", 200n) ++ "end")))
    IO.print("attachment parameter line bound " ++ Bool.show(U32.is_le(max_line(M.att_part("B", M.Attach{String.repeat("n", 60n), "text/plain", "a"}), 0, 0), 79)))
    IO.print("bare address line bound " ++ Bool.show(U32.is_le(max_line(M.field_line("From", M.encode_addr(String.repeat("a", 72n) ++ "@x")), 0, 0), 79)))

def main() -> IO(Unit):
  do IO<Unit>:
    show_headers(M.headers(M.head_of(M.split(multipart_message()))))
    IO.print(show_parts(M.parts(multipart_message())))
    IO.print(show_parts(M.parts("Subject: plain\r\n\r\nJust text\r\n")))
    roundtrip(M.compose(attachment_draft(), "b0undary"))
    IO.print(M.rfc5322_date(0) ++ " / " ++ M.rfc5322_date(951782400) ++ " / " ++ M.rfc5322_date(1790480370) ++ " / " ++ M.rfc5322_date(4102444799))
    IO.print(Bool.show(has_no_injected_headers(M.compose(header_injection_draft(), "b"))) ++ " " ++ M.safe_ctype("Text/Plain") ++ " " ++ M.safe_ctype("a/b; x=\"y\"") ++ " " ++ Bool.show(M.seven_bit("ok\r\nline", 0)) ++ " " ++ Bool.show(M.seven_bit("caf\u{E9}", 0)))
    IO.print(show_line_breaks(M.name_param("filename", "résumé.pdf")) ++ " | " ++ M.name_param("filename", "plain.txt"))
    IO.print(Nat.show(String.length(M.encode_header(String.repeat("a", 950n)))) ++ " " ++ Bool.show(String.contains(M.encode_header(String.repeat("a", 950n)), "\r\n ")) ++ " " ++ show_line_breaks(M.fold_ids(["<a@x>", "<b@y>"])))
    IO.print(Bool.show(String.eq(M.param("attachment; " ++ String.concat(String.split(M.name_param("filename", long_name()), '\n')), "filename"), long_name())) ++ " " ++ Bool.show(U32.is_lt(max_line(M.name_param("filename", long_name()), 0, 0), 80)))
    IO.print(M.param("attachment; filename=\"Q1; final \\\"v2\\\".pdf\"; size=3", "filename") ++ " | " ++ M.main_value("text/plain ; charset=\"a;b\"") ++ " | " ++ M.addr_spec("john@example.com (Doe, John)"))
    IO.print(M.addr_spec("\"a <evil@x.com>\" <real@y.com>") ++ " " ++ M.addr_spec("plain@z.com"))
    IO.print(M.encode_addr("\"Sales < Europe\" <sales@example.com>") ++ " | " ++ M.encode_addr("Ann <a@x.com>") ++ " | " ++ Bool.show(String.ends_with(M.att_part("B", M.Attach{"m.eml", "message/rfc822", "Subject: x\r\n\r\nhi\r\n"}), "hi\r\n\r\n")))
    IO.print(Bool.show(M.addr_ok("A <a@b.c>")) ++ " " ++ Bool.show(M.addr_ok("a@b.c\r\nRCPT TO:<x@y>")) ++ " " ++ Bool.show(M.addr_ok("no-at")) ++ " " ++ Bool.show(M.addr_ok("a@b@c")))
    IO.print(M.param("attachment; filename*0=\"Q1 \"; filename*1=\"final.pdf\"", "filename") ++ " | " ++ M.param("attachment; filename*0*=utf-8''r%C3%A9; filename*1=\" sum.pdf\"", "filename") ++ " | " ++ M.decode_header("=?UTF-8?Q?caf=C3=A9?=\t=?UTF-8?Q?_cr=C3=A8me?= ok"))
    header_cases()
    param_cases()
    parts_cases()
    html_cases()
    compose_cases()
    date_cases()
    IO.print("[" ++ String.join(M.addr_list("undisclosed-recipients:;"), "|") ++ "]")
    IO.print(String.join(M.addr_list("Team: A <a@x.com>, b@y.com; c@z.com"), "|"))
    IO.print(String.join(M.addr_list("\"Doe, J\" <j@x.com>, k@y.com (K, Jr)"), "|"))
    IO.print(String.join(M.addr_list("<@route.example:u@x.com>, \"a: b\" <v@y.com>"), "|"))
    IO.print("[" ++ String.join(M.addr_list(""), "|") ++ "] [" ++ String.join(M.addr_list(" , ,"), "|") ++ "] [" ++ String.join(M.addr_list("a@x (c, d), \"q\\\" ,\" <b@y>"), "|") ++ "]")
    IO.print(specs(["Name <a@b>", " a@b (c) ", "\"x\" <a@b> trailing", "<a@b", "a (b (c) d) e@f", "\"(x)\" y@z", "a) b@c", "", "x <a> <b@c>"]))
    IO.print(oks(["", "@a", "a@", "a b@c", "<a@b>", "a@b (c)", "Name <a@b>\u{7F}", "A <a@b>, c@d", "a@b\t", "a@b@c", "a@b.c", "ü@b.c"]))
    IO.print(Bool.show(M.all_addrs_ok([])) ++ " " ++ Bool.show(M.all_addrs_ok(["a@b", "c@d"])) ++ " " ++ Bool.show(M.all_addrs_ok(["a@b", "x"])))
    IO.print(Bool.show(M.no_ctl("abc")) ++ " " ++ Bool.show(M.no_ctl("")) ++ " " ++ Bool.show(M.no_ctl("a\tb")) ++ " " ++ Bool.show(M.no_ctl("a\u{7F}")) ++ " " ++ Bool.show(M.no_ctl("é")) ++ " " ++ Bool.show(M.no_ctl("a\u{0}")))
    IO.print(M.encode_addr("a@b") ++ " | " ++ M.encode_addr("<a@b>") ++ " | " ++ visible(M.encode_addr("José <j@x.com>")) ++ " | " ++ M.encode_addr("\"Q \\\"x\\\"\" <q@x>") ++ " | " ++ M.encode_addr("Back\\slash <b@x>") ++ " | " ++ M.encode_addr("Name <a@b> (c)"))
    IO.print(visible(M.encode_addr(String.repeat("n", 201n) ++ " <a@b>")) ++ " | " ++ Nat.show(String.length(M.encode_addr(String.repeat("n", 200n) ++ " <a@b>"))))
    IO.print(M.iso_date(0) ++ " " ++ M.iso_date(951782400) ++ " " ++ M.iso_date(1790480370) ++ " " ++ M.iso_date(4102444799))
    attachment_cases()
    local_name_cases()
    conformance_cases()
    conformance_edges()

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
#|1640 True <a@x>\r\n <b@y>
#|True True
#|Q1; final "v2".pdf | text/plain | john@example.com
#|real@y.com plain@z.com
#|"Sales < Europe" <sales@example.com> | "Ann" <a@x.com> | True
#|True False False False
#|Q1 final.pdf | ré sum.pdf | café crème ok
#|A: 1 | A: 1 | no break | 
#|a=1;b=2 continued more;c=x : y;subject=Hi;a=second;
#|1 [] []
#|Café | Re: café | =?bad?= | a b
#|a  b | café | café | a x b | []
#|text/html [] text/plain
#|utf-8 ISO-8859-1 [] []
#|ré.txt | A%4 | noquotes | 
#|a  | a bé | café | q\b [] "
#|text= html=<p>Hi &lt;3</p>\n atts=
#|text=hi html= atts=
#|text=café soft html= atts=
#|text= html= atts=a.txt|text/plain|3;
#|text= html= atts=|text/plain|3;
#|text= html= atts=i.png|image/png|3;
#|text= html= atts=|image/png|3;
#|text=line1\nline2\rend html= atts=
#|text=first html=<b>h</b> atts=
#|text=first html=<b>cut atts=
#|text= html= atts=|multipart/mixed|8;
#|text= html= atts=
#|text=deep html= atts=
#|text= html= atts=
#|[a b] [ x y ] [unclosed ] [stray > here]
#|[1 > 0 && "q" 's' &foo; &lt;] [ tab sp ] [] [<b>]
#|From: =?UTF-8?B?Wm/DqyDDkQ==?=\r\n <z@example.com>\r\nCc: c1@example.com,\r\n "Doe, J" <j@x.com>,\r\n bare@x.com\r\nBcc: hidden@example.com\r\nSubject: plain subject\r\nDate: D\r\nMessage-ID: <m@x>\r\nIn-Reply-To: <p@x>\r\nReferences: <r1@x>\r\n <r2@x>\r\n <r3@x>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="BB"\r\n\r\nThis is a multi-part message in MIME format.\r\n--BB\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\na\r\nb\r\nc\r\nd=3De =C3=A9\r\n--BB\r\nContent-Type: application/pdf;\r\n name="r_sum_.pdf";\r\n name*0*=utf-8''r%C3%A9sum%C3%A9.pdf\r\nContent-Disposition: attachment;\r\n filename="r_sum_.pdf";\r\n filename*0*=utf-8''r%C3%A9sum%C3%A9.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERv8=\r\n--BB\r\nContent-Type: application/octet-stream;\r\n name="bad.bin"\r\nContent-Disposition: attachment;\r\n filename="bad.bin"\r\nContent-Transfer-Encoding: base64\r\n\r\n--BB\r\nContent-Type: application/octet-stream;\r\n name="m.eml"\r\nContent-Disposition: attachment;\r\n filename="m.eml"\r\nContent-Transfer-Encoding: base64\r\n\r\nU3ViamVjdDog6Q0KDQpoaQ==\r\n--BB--\r\n
#|From: a@b.c\r\nTo: x@y.z\r\nSubject: \r\nDate: D\r\nMessage-ID: <i@x>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n
#||=?UTF-8?B?Q2Fmw6k=?=|=?UTF-8?B?w6nDqcOpw6nDqcOpw6nDqcOpw6nDqcOpw6nDqcOpw6nDqcOpw6k=?=\r\n =?UTF-8?B?w6nDqcOpw6nDqcOpw6nDqcOpw6nDqQ==?=|900 1561
#|application/octet-stream application/octet-stream application/octet-stream application/octet-stream image/svg+xml message/rfc822
#|True False False False False False True
#|name="a\"b\\c" | 204 | f="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";\r\n f*0*=utf-8''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*1*=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*2*=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*3*=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*4*=a
#|[] [<a@x>\r\n <b@y>] [<a@x>]
#|--B\r\nContent-Type: text/plain; charset=us-ascii;\r\n name="a.txt"\r\nContent-Disposition: attachment;\r\n filename="a.txt"\r\nContent-Transfer-Encoding: base64\r\n\r\naGk=\r\n | --B\r\nContent-Type: application/octet-stream;\r\n name="m.eml"\r\nContent-Disposition: attachment;\r\n filename="m.eml"\r\nContent-Transfer-Encoding: base64\r\n\r\nYQpi\r\n
#|Thu, 29 Feb 2024 00:00:00 +0000 / Fri, 31 Dec 1999 23:59:59 +0000 / Sun, 7 Feb 2106 06:28:15 +0000 / Thu, 1 Jan 1970 23:59:59 +0000 / Mon, 6 May 2024 12:53:20 +0000
#|[]
#|A <a@x.com>|b@y.com|c@z.com
#|"Doe, J" <j@x.com>|k@y.com (K, Jr)
#|<@route.example:u@x.com>|"a: b" <v@y.com>
#|[] [] [a@x (c, d)|"q\" ," <b@y>]
#|[a@b][a@b][a@b][a@b][a  e@f]["(x)" y@z][a) b@c][][b@c]
#|False False False False True True False True False False True False 
#|True True False
#|True True False False True False
#|a@b | a@b | =?UTF-8?B?Sm9zw6k=?=\r\n <j@x.com> | "Q \"x\"" <q@x> | "Back\\slash" <b@x> | "Name" <a@b>
#|=?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5u?=\r\n <a@b> | 210
#|1970-01-01 2000-02-29 2026-09-27 2099-12-31
#|text=body text html= atts=b64.bin|application/octet-stream|4;résumé.txt|text/plain|9;|image/png|9;
#|b64.bin|application/octet-stream|0,255,128,10
#|résumé.txt|text/plain|99,97,102,233,32,115,111,102,116
#||image/png|114,97,119,32,98,121,116,101,115
#|none
#|none
#|résumé.pdf|application/pdf|37,80,68,70,45,49,46,52,10
#|raw.bin|application/octet-stream|65,10,66,13,10,67,13,68
#|evil.sh | passwd | report.pdf | []
#|gnp.exe | hidden | abcdefgh |  .x
#|[] [] [] []
#|255 127 64 café.txt
#|encoded subject line bound True
#|encoded display line bound True
#|literal encoded words True True
#|long ASCII subject line bound True
#|ASCII subject whitespace preserved True
#|first subject token bounds True True True
#|literal display word True
#|UTF-8 attachment charset True
#|ASCII attachment charset True
#|invalid UTF-8 attachment unchanged True
#|binary attachment unchanged True
#|threading tokens <a@x>
#|references tokens <root@x> <a@x>
#|references bound True
#|references keep endpoints True True
#|threading malformed dropped [<a@x>]
#|boundary collision encoded True
#|whole QP padded soft break foobar
#|whole QP final soft break last
#|single long subject token roundtrip True True
#|first subject token roundtrip True True True
#|text charset validity True True True True True True True
#|text attachment roundtrip café
#|boundary prefix checks False False False True
#|reference exact limits True True True
#|oversized mandatory references omitted True <reply@x>
#|thread token grammar <ok@[127.0.0.1]> <ok@[IPv6:abcd::1]> <end@x>
#|tab and long whitespace preserved True True
#|attachment parameter line bound True
#|bare address line bound True
