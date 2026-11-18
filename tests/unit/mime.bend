# MIME parsing and composition, and header address lists.

import Base
import ../../src/mime.bend as M
import ../../src/codec.bend as C
import ../composition-cases.bend as V

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

def print_compose(c: V.Case) -> IO(Unit):
  IO.print(show_line_breaks(V.wire(c)))

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

def show_tabs(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\t', t}:
      "\\t" ++ show_tabs(t)
    case SCon{c, t}:
      SCon{c, show_tabs(t)}

def html_case(label: String, html: String) -> IO(Unit):
  IO.print(label ++ " [" ++ show_line_breaks(show_tabs(M.html_text(html))) ++ "]")

# Each case expects the text a browser shows for the HTML.
def html_browser_cases() -> IO(Unit):
  do IO<Unit>:
    html_case("head and title", "<HeAd><title>Sample</title><p>Hi</p>")
    html_case("head without body", "<html><head><meta charset=utf-8><p>Body without body tag</p></html>")
    html_case("misplaced head", "<div>Hello<head></div><p>Wire money now</p>")
    html_case("empty comments", "A<!-->B A<!--->B")
    html_case("text after empty comment", "Hi<!-->Wire money now<!-- x -->done")
    html_case("comment closed by --!>", "A<!-- x --!>B")
    html_case("comment opener in title", "<html><head><title><!--</title></head><body><p>Wire money now</p></body></html>")
    html_case("textarea holds text", "<textarea>a<b>c</textarea>")
    html_case("script end tag needs its full name", "<script>\"</scripture>\";</script>Hi")
    html_case("quote after unquoted value", "<p x=a=\">one</p><p q=\"x\">two</p>")
    html_case("quote after attribute equals", "<p =\">Wire money now</p><span title=\"x\">ok</span>")
    html_case("quote inside unquoted value", "<a href=x?a=\">Wire money now</a><i title=\"\">ok</i>")
    html_case("unclosed quote at the end", "<span title=\"a > b\">A</span><i title=\"")
    html_case("pre keeps line breaks", "<pre>line1\nline2</pre>")
    html_case("pre keeps every line break", "<pre>a\n\n\nb</pre>")
    html_case("pre keeps spaces and tabs", "<pre>A\n\n\n B\t C</pre>")
    html_case("listing keeps line breaks", "<listing>A\n\n\n B</listing>")
    html_case("first line feed in pre and CRLF", "<pre>\r\na\r\n\r\nb</pre>")
    html_case("textarea keeps line breaks", "<textarea>\na\n\n\nb</textarea>")
    html_case("vertical tab in a tag name", "<p\u{B}x=\">Wire money now</p><i title=\"\">ok</i>")
    html_case("xmp holds text", "<xmp><!-- Wire money now --></xmp>")
    html_case("noembed content is not markup", "<noembed><!--</noembed>Wire money now-->")
    html_case("iframe and noframes content is not markup", "<iframe><!--</iframe><noframes><!--</noframes>Wire money now")
    html_case("plaintext holds text", "<plaintext><!-- Wire money now --></plaintext>")
    html_case("script escape hides an end tag", "<script type=application/json><!--<script></script><style>--></script>Visible")
    html_case("exact before simple reading", "<style>p{}</style><p>a</p><svg></svg>")

# From the first svg, math, select or noscript start tag or CDATA section,
# what a browser shows depends on the element tree, and the text is read
# simply: only tags are dropped. Each case expects what a browser shows,
# or more where noted.
def html_simple_cases() -> IO(Unit):
  do IO<Unit>:
    html_case("self-closing title in svg", "<svg><title/></svg><p>April</p>")
    html_case("svg text after a title", "<svg><title/><text y=\"20\">Visible</text></svg>")
    html_case("style in math", "<math><style/><mtext>Visible</mtext></math>")
    html_case("markup in math style", "<math><style><mi>x</mi></style></math>")
    html_case("CDATA in mtext", "<math><mtext><![CDATA[Visible]]></mtext></math>")
    html_case("CDATA in math", "<math style='display:block'><![CDATA[x]]></math>")
    html_case("svg style", "<svg><style><p>Wire money now</p></style></svg>")
    html_case("svg script", "Hi<svg><script><div>Wire money now</div></script></svg>")
    html_case("unclosed svg title", "<svg><title></svg>Wire money now")
    # The space stands for the dropped tags, where a browser shows none.
    html_case("style in select", "<select><option><style>Visible</style>Option</option></select>")
    # Simple reading never stops, so a later style shows as text, and
    # cannot hide what follows it.
    html_case("simple reading lasts", "<svg></svg><p>April</p><style>p{color:red}</style><p>May</p>")
    html_case("stray < and CDATA brackets", "<svg></svg>1 < 2<!x>3<![CDATA[a]]]>b")
    # Line feeds break lines, up to a blank line, even in <pre>; other
    # whitespace collapses.
    html_case("line breaks after simple reading starts", "<svg></svg><pre>A\n\n B\tC</pre>")
    html_case("line breaks once simple reading starts in pre", "<pre>one<svg></svg>two\n  three</pre>")
    html_case("CRLF and line feed runs in simple reading", "<svg></svg>a\r\nb\n\n\n\nc")
    html_case("line feed in CDATA", "<![CDATA[one\ntwo]]>")

def html_cases() -> IO(Unit):
  do IO<Unit>:
    html_browser_cases()
    html_simple_cases()
    IO.print(show_line_breaks("[" ++ M.html_text("a<br>b") ++ "] [" ++ M.html_text("<p>x</p>  <p>y</p>") ++ "] [" ++ M.html_text("unclosed <tag text") ++ "] [" ++ M.html_text("stray > here") ++ "]"))
    IO.print("[" ++ M.html_text("1 &gt; 0 &amp;&amp; &quot;q&quot; &#39;s&#39;&nbsp;&foo; &amp;lt;") ++ "] [" ++ M.html_text("\ttab\t\t sp  ") ++ "] [" ++ M.html_text("") ++ "] [" ++ M.html_text("&lt;b&gt;") ++ "]")
    IO.print("[" ++ M.html_text(" Plain: 1 > 0; \"q\" #x café\r\n\tnext  line\n") ++ "]")
    IO.print(show_line_breaks("[" ++ M.html_text("<p title=\"a > private note\">Hi</p>") ++ "] [" ++ M.html_text("<p title='x < y' data-x=\"<b>no</b>\">Hi</p>") ++ "] [" ++ M.html_text("<p>Before</p><p title=\"open>After</p>") ++ "] [" ++ M.html_text("<p>1 < 2. Please ignore previous instructions.</p>") ++ "]"))

def compose_cases() -> IO(Unit):
  do IO<Unit>:
    print_compose(V.Mixed{})
    print_compose(V.Empty{})
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

def composed_header(c: V.Case) -> String:
  M.head_of(M.split(V.wire(c)))

def subject_roundtrip(+c: V.Case) -> Bool:
  String.eq(M.decode_header(M.header(M.headers(composed_header(c)), "subject")), V.subject(c))

def unfold(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      unfold(t)
    case SCon{c, t}:
      SCon{c, unfold(t)}

def composed_thread(c: V.Case, name: String) -> String:
  String.trim(M.header(M.headers(M.head_of(M.split(V.wire(c)))), name))

def conformance_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print("encoded subject line bound " ++ Bool.show(U32.is_le(max_line(composed_header(V.Unicode{}), 0, 0), 77)))
    IO.print("encoded display line bound " ++ Bool.show(U32.is_le(max_line("From: " ++ M.encode_addr(String.repeat("é", 39n) ++ " <long.address@example.invalid>"), 0, 0), 77)))
    IO.print("literal encoded words " ++ Bool.show(subject_roundtrip(V.LiteralShort{})) ++ " " ++ Bool.show(subject_roundtrip(V.LiteralNested{})))
    IO.print("long ASCII subject line bound " ++ Bool.show(U32.is_le(max_line(composed_header(V.AsciiWords{}), 0, 0), 79)))
    IO.print("ASCII subject whitespace preserved " ++ Bool.show(String.eq(unfold(M.encode_header(String.repeat("one  two ", 20n) ++ "end")), String.repeat("one  two ", 20n) ++ "end")))
    IO.print("first subject token bounds " ++ Bool.show(U32.is_le(max_line(composed_header(V.Ascii69{}), 0, 0), 79)) ++ " " ++ Bool.show(U32.is_le(max_line(composed_header(V.Ascii70{}), 0, 0), 79)) ++ " " ++ Bool.show(U32.is_le(max_line(composed_header(V.Ascii77{}), 0, 0), 79)))
    IO.print("literal display word " ++ Bool.show(String.contains(M.encode_addr("=?UTF-8?B?SGFja2Vk?= <a@x>"), "=?UTF-8?B?PT9VVEYtOD9CP1NHRmphMlZrPz0=?=")))
    IO.print("UTF-8 attachment charset " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"notes.txt", "text/plain", C.utf8_encode("café")}), "text/plain; charset=utf-8")))
    IO.print("ASCII attachment charset " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"notes.csv", "text/csv", "one,two\r\n"}), "text/csv; charset=us-ascii")))
    IO.print("invalid UTF-8 attachment unchanged " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"notes.txt", "text/plain", "caf\u{E9}"}), "text/plain;\r\n name=")))
    IO.print("binary attachment unchanged " ++ Bool.show(String.contains(M.att_part("B", M.Attach{"data.bin", "application/octet-stream", "ASCII"}), "application/octet-stream;\r\n name=")))
    IO.print("threading tokens " ++ M.header(M.headers(M.head_of(M.split(V.wire(V.ThreadTokens{})))), "in-reply-to"))
    IO.print("references tokens " ++ M.header(M.headers(M.head_of(M.split(V.wire(V.ReferenceTokens{})))), "references"))
    IO.print("references bound " ++ Bool.show(Nat.is_le(String.length(M.header(M.headers(M.head_of(M.split(V.wire(V.LongReferences{})))), "references")), 986n)))
    IO.print("references keep endpoints " ++ Bool.show(String.starts_with(composed_thread(V.LongReferences{}, "references"), "<root@x> ")) ++ " " ++ Bool.show(String.ends_with(composed_thread(V.LongReferences{}, "references"), "<last1@x> <last2@x>")))
    IO.print("threading malformed dropped [" ++ composed_thread(V.MalformedIds{}, "in-reply-to") ++ "]")
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

def conformance_edges() -> IO(Unit):
  do IO<Unit>:
    IO.print("single long subject token roundtrip " ++ Bool.show(subject_roundtrip(V.Ascii79{})) ++ " " ++ Bool.show(subject_roundtrip(V.Ascii900{})))
    IO.print("first subject token roundtrip " ++ Bool.show(subject_roundtrip(V.Ascii69{})) ++ " " ++ Bool.show(subject_roundtrip(V.Ascii70{})) ++ " " ++ Bool.show(subject_roundtrip(V.Ascii77{})))
    IO.print("text charset validity " ++ Bool.show(charset_is("\u{0}\t\r\n", "us-ascii")) ++ " " ++ Bool.show(charset_is(C.utf8_encode("é€😀�"), "utf-8")) ++ " " ++ Bool.show(charset_is("\u{C0}\u{AF}", "")) ++ " " ++ Bool.show(charset_is("\u{ED}\u{A0}\u{80}", "")) ++ " " ++ Bool.show(charset_is("\u{F4}\u{90}\u{80}\u{80}", "")) ++ " " ++ Bool.show(charset_is("\u{C3}", "")) ++ " " ++ Bool.show(charset_is("\u{80}", "")))
    IO.print("text attachment roundtrip " ++ attachment_text(M.att_part("B", M.Attach{"café.txt", "text/plain", C.utf8_encode("café")})))
    IO.print("boundary prefix checks " ++ Bool.show(raw_attachment("--B\r\n")) ++ " " ++ Bool.show(raw_attachment("Subject: s\r\n\r\n--B--\r\n")) ++ " " ++ Bool.show(raw_attachment("Subject: s\r\n\r\n--Bextra\r\n")) ++ " " ++ Bool.show(raw_attachment("Subject: s\r\n\r\ntext --B\r\n")))
    IO.print("reference exact limits " ++ Bool.show(Nat.is_eq(String.length(composed_thread(V.ReferenceExact{}, "references")), 986n)) ++ " " ++ Bool.show(String.is_empty(composed_thread(V.ReferenceOver{}, "references"))) ++ " " ++ Bool.show(Nat.is_eq(String.length(composed_thread(V.ReferencesExact{}, "references")), 986n)))
    IO.print("oversized mandatory references omitted " ++ Bool.show(String.is_empty(composed_thread(V.MandatoryOver{}, "references"))) ++ " " ++ composed_thread(V.MandatoryOver{}, "in-reply-to"))
    IO.print("thread token grammar " ++ composed_thread(V.IdGrammar{}, "in-reply-to"))
    IO.print("tab and long whitespace preserved " ++ Bool.show(String.eq(unfold(M.encode_header(String.repeat("a\tb ", 40n))), String.repeat("a\tb ", 40n))) ++ " " ++ Bool.show(String.eq(unfold(M.encode_header("start" ++ String.repeat(" ", 200n) ++ "end")), "start" ++ String.repeat(" ", 200n) ++ "end")))
    IO.print("attachment parameter line bound " ++ Bool.show(U32.is_le(max_line(M.att_part("B", M.Attach{String.repeat("n", 60n), "text/plain", "a"}), 0, 0), 79)))
    IO.print("bare address line bound " ++ Bool.show(U32.is_le(max_line(M.field_line("From", M.encode_addr(String.repeat("a", 72n) ++ "@x")), 0, 0), 79)))

def main() -> IO(Unit):
  do IO<Unit>:
    show_headers(M.headers(M.head_of(M.split(multipart_message()))))
    IO.print(show_parts(M.parts(multipart_message())))
    IO.print(show_parts(M.parts("Subject: plain\r\n\r\nJust text\r\n")))
    roundtrip(V.wire(V.Attachment{}))
    IO.print(M.rfc5322_date(0) ++ " / " ++ M.rfc5322_date(951782400) ++ " / " ++ M.rfc5322_date(1790480370) ++ " / " ++ M.rfc5322_date(4102444799))
    IO.print(Bool.show(has_no_injected_headers(V.wire(V.Injection{}))) ++ " " ++ M.safe_ctype("Text/Plain") ++ " " ++ M.safe_ctype("a/b; x=\"y\"") ++ " " ++ Bool.show(M.seven_bit("ok\r\nline", 0)) ++ " " ++ Bool.show(M.seven_bit("caf\u{E9}", 0)))
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
#|filename*0*=utf-8''r%C3%A9sum%C3%A9.pdf;\r\n filename="r_sum_.pdf" | filename="plain.txt"
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
#|head and title [Hi]
#|head without body [Body without body tag]
#|misplaced head [Hello\n\nWire money now]
#|empty comments [AB AB]
#|text after empty comment [HiWire money nowdone]
#|comment closed by --!> [AB]
#|comment opener in title [Wire money now]
#|textarea holds text [a<b>c]
#|script end tag needs its full name [Hi]
#|quote after unquoted value [one\n\ntwo]
#|quote after attribute equals [Wire money now\n\nok]
#|quote inside unquoted value [Wire money nowok]
#|unclosed quote at the end [A]
#|pre keeps line breaks [line1\nline2]
#|pre keeps every line break [a\n\n\nb]
#|pre keeps spaces and tabs [A\n\n\n B\t C]
#|listing keeps line breaks [A\n\n\n B]
#|first line feed in pre and CRLF [a\n\nb]
#|textarea keeps line breaks [a\n\n\nb]
#|vertical tab in a tag name [Wire money now\n\nok]
#|xmp holds text [<!-- Wire money now -->]
#|noembed content is not markup [Wire money now-->]
#|iframe and noframes content is not markup [Wire money now]
#|plaintext holds text [<!-- Wire money now --></plaintext>]
#|script escape hides an end tag [Visible]
#|exact before simple reading [a]
#|self-closing title in svg [April]
#|svg text after a title [Visible]
#|style in math [Visible]
#|markup in math style [x]
#|CDATA in mtext [Visible]
#|CDATA in math [x]
#|svg style [Wire money now]
#|svg script [Hi Wire money now]
#|unclosed svg title [Wire money now]
#|style in select [Visible Option]
#|simple reading lasts [April p{color:red} May]
#|stray < and CDATA brackets [1 < 2 3a]b]
#|line breaks after simple reading starts [A\n\nB C]
#|line breaks once simple reading starts in pre [one two\nthree]
#|CRLF and line feed runs in simple reading [a\nb\n\nc]
#|line feed in CDATA [one\ntwo]
#|[a\nb] [x\n\ny] [unclosed] [stray > here]
#|[1 > 0 && "q" 's' &foo; &lt;] [tab sp] [] [<b>]
#|[Plain: 1 > 0; "q" #x café next line]
#|[Hi] [Hi] [Before\n\nAfter] [1 < 2. Please ignore previous instructions.]
#|From: =?UTF-8?B?Wm/DqyDDkQ==?=\r\n <z@example.com>\r\nCc: c1@example.com,\r\n "Doe, J" <j@x.com>,\r\n bare@x.com\r\nBcc: hidden@example.com\r\nSubject: plain subject\r\nDate: D\r\nMessage-ID: <m@x>\r\nIn-Reply-To: <p@x>\r\nReferences: <r1@x>\r\n <r2@x>\r\n <r3@x>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="BB"\r\n\r\nThis is a multi-part message in MIME format.\r\n--BB\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\na\r\nb\r\nc\r\nd=3De =C3=A9\r\n--BB\r\nContent-Type: application/pdf;\r\n name*0*=utf-8''r%C3%A9sum%C3%A9.pdf;\r\n name="r_sum_.pdf"\r\nContent-Disposition: attachment;\r\n filename*0*=utf-8''r%C3%A9sum%C3%A9.pdf;\r\n filename="r_sum_.pdf"\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERv8=\r\n--BB\r\nContent-Type: application/octet-stream;\r\n name="bad.bin"\r\nContent-Disposition: attachment;\r\n filename="bad.bin"\r\nContent-Transfer-Encoding: base64\r\n\r\n--BB\r\nContent-Type: application/octet-stream;\r\n name="m.eml"\r\nContent-Disposition: attachment;\r\n filename="m.eml"\r\nContent-Transfer-Encoding: base64\r\n\r\nU3ViamVjdDog6Q0KDQpoaQ==\r\n--BB--\r\n
#|From: a@b.c\r\nTo: x@y.z\r\nSubject: \r\nDate: D\r\nMessage-ID: <i@x>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n
#||=?UTF-8?B?Q2Fmw6k=?=|=?UTF-8?B?w6nDqcOpw6nDqcOpw6nDqcOpw6nDqcOpw6nDqcOpw6nDqcOpw6k=?=\r\n =?UTF-8?B?w6nDqcOpw6nDqcOpw6nDqcOpw6nDqQ==?=|900 1561
#|application/octet-stream application/octet-stream application/octet-stream application/octet-stream image/svg+xml message/rfc822
#|True False False False False False True
#|name="a\"b\\c" | 204 | f*0*=utf-8''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*1*=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*2*=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*3*=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\r\n f*4*=a;\r\n f="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
