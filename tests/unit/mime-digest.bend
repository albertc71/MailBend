# Multipart/digest defaults keep enclosed messages opaque and preserve their bytes.

import Base
import ../../src/codec.bend as C
import ../../src/imap.bend as I
import ../../src/mime.bend as M
import ../../src/jev.bend as Jev
import ../../src/secrets.bend as Secrets
import ../../src/sections.bend as P

def container(kind: String, +b: String, child: String) -> String:
  "Content-Type: multipart/" ++ kind ++ "; boundary=" ++ b ++ "\r\n\r\n--" ++ b ++
    "\r\n" ++ child ++ "\r\n--" ++ b ++ "--"

def inner() -> String:
  "Subject: inner\r\n\r\nhello"

def digest() -> String:
  container("digest", "d", "\r\n" ++ inner())

def attachments(xs: List<&2, M.Att>) -> String:
  match xs:
    case Nil{}:
      ""
    case M.Att{name, typ, size} <> t:
      name ++ "|" ++ typ ++ "|" ++ U32.show(size) ++ ";" ++ attachments(t)

def show_parts(p: M.Parts) -> String:
  M.Parts{text, html, atts} = p
  "text=[" ++ text ++ "] html=[" ++ html ++ "] attachments=" ++ attachments(atts)

def saved(a: Maybe<&2, M.Attach>, expected: String) -> String:
  match a:
    case None{}:
      "missing"
    case Some{M.Attach{name, typ, data}}:
      name ++ "|" ++ typ ++ "|exact=" ++ Bool.show(String.eq(data, expected))

# Compare complete reader output without trimming leading body line breaks.
def text_is.parts(p: M.Parts, expected: String) -> Bool:
  M.Parts{text, html, atts} = p
  String.eq(text, expected) && String.is_empty(html) && List.is_empty(&2, M.Att, atts)

def text_is(msg: String, expected: String) -> Bool:
  text_is.parts(M.parts(msg), expected)

def nested(+n: Nat, msg: String) -> String:
  match n:
    case 0n:
      msg
    case 1n+p:
      container("mixed", "b" ++ Nat.show(p), nested(p, msg))

def context_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_parts(M.parts(container("digest", "d", "Content-Type: text/plain\r\n\r\nouter"))))
    IO.print(show_parts(M.parts(container("digest", "d", "Content-Type:\r\n\r\nrecovery"))))
    IO.print(show_parts(M.parts(container("mixed", "m", digest() ++ "\r\n--m\r\n\r\nouter"))))
    IO.print(show_parts(M.parts(container("digest", "d",
      container("mixed", "m", "\r\nouter") ++ "\r\n--d\r\n\r\n" ++ inner()))))
    IO.print(show_parts(M.parts(container("digest", "d", "\r\n" ++ inner() ++
      "\r\n--d\r\nContent-Disposition: attachment; filename=next.eml\r\n\r\n" ++ inner()))))
    IO.print(saved(M.attachment_at(container("digest", "d", "\r\n" ++ inner() ++
      "\r\n--d\r\nContent-Disposition: attachment; filename=next.eml\r\n\r\n" ++ inner()), 1), inner()))
    IO.print(show_parts(M.parts(nested(6n, digest()))))
    IO.print(show_parts(M.parts(nested(7n, digest()))))

def empty_header_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print("root CRLF " ++ Bool.show(text_is("\r\nFirst: body\r\n\r\ntail", "First: body\n\ntail")))
    IO.print("root LF " ++ Bool.show(text_is("\nFirst: body\n\ntail", "First: body\n\ntail")))
    IO.print("extra CRLF " ++ Bool.show(text_is("\r\n\r\nhello", "\nhello")))
    IO.print("extra LF " ++ Bool.show(text_is("\n\nhello", "\nhello")))
    IO.print("no separator " ++ Bool.show(text_is("Subject: header only", "")))
    IO.print("empty root " ++ Bool.show(text_is("", "")))
    IO.print(saved(M.attachment_at(container("digest", "d", "\r\n\r\n" ++ inner()), 0), "\r\n" ++ inner()))
    IO.print(saved(M.attachment_at("Content-Type: multipart/digest; boundary=d\n\n--d\n\nSubject: inner\n\nhello\n--d--", 0), "Subject: inner\n\nhello"))
    IO.print(saved(M.attachment_at(container("digest", "d", "\r\n\r\n\0\u{FF}\nend"), 0), "\r\n\0\u{FF}\nend"))

def completeness(c: Jev.Completeness) -> String:
  match c:
    case Jev.Complete{}:
      "complete"
    case Jev.Partial{}:
      "partial"

def jev.text(t: Jev.Text) -> String:
  Jev.MessageText{text, whole} = t
  "Jev [" ++ text ++ "] " ++ completeness(whole)

def jev(msg: String) -> String:
  jev.text(Jev.text_of(I.Msg{1, [], "", 0, "", msg, I.VNil{}}, 1024))

def scan(msg: String) -> String:
  Secrets.scan_name(Secrets.secret_scan([], "See attached.", [M.Attach{"digest.eml", "message/rfc822", msg}]))

def digest_levels(+n: Nat, msg: String) -> String:
  match n:
    case 0n:
      msg
    case 1n+p:
      container("digest", "d" ++ Nat.show(p), "\r\n" ++ digest_levels(p, msg))

def section_bytes(r: Result<&2, &2, String, String>) -> Bool:
  match r:
    case Done{bytes}:
      String.eq(bytes, "Subject: inner\r\n\r\nhello")
    case Fail{why}:
      False{}

def section.kind(k: M.PartKind, p: P.Part) -> String:
  M.PartKind{ct, typ, name, file} = k
  typ ++ "|file=" ++ Bool.show(file) ++ "|exact=" ++
    Bool.show(section_bytes(P.decode(p, inner(), 1024)))

def section(r: Result<&2, &2, String, List<&2, P.Part>>) -> String:
  match r:
    case Done{+p <> Nil{}}:
      section.kind(P.kind(p), p)
    case _:
      "bad section"

def consumer_cases() -> IO(Unit):
  +token = "ghp_" ++ String.repeat("a1B2", 9n)
  +encoded_body = "Subject: inner\r\nContent-Transfer-Encoding: base64\r\n\r\n" ++ C.b64_encode(token, False{})
  encoded_header = "Subject: =?utf-8?b?" ++ C.b64_encode(token, False{}) ++ "?=\r\n\r\nhello"
  versions = container("alternative", "a", "Content-Type: text/plain\r\n\r\nouter\r\n--a\r\nContent-Type: text/html\r\n\r\n<b>outer</b>")
  do IO<Unit>:
    IO.print(jev(digest()))
    IO.print(jev(container("mixed", "m", "\r\nouter\r\n--m\r\n" ++ digest())))
    IO.print(jev(container("digest", "d", versions)))
    IO.print(jev(container("mixed", "m", "\r\nouter\r\n--m\r\nContent-Type: text/html\r\n\r\n<b>other</b>")))
    IO.print(jev(nested(6n, digest())))
    IO.print(jev(nested(7n, digest())))
    IO.print("encoded inner header " ++ scan(digest_levels(1n, encoded_header)))
    IO.print("encoded inner body " ++ scan(digest_levels(1n, encoded_body)))
    IO.print("forward at limit " ++ scan(digest_levels(2n, encoded_body)))
    IO.print("forward beyond limit " ++ scan(digest_levels(3n, inner())))
    IO.print("multipart at limit " ++ scan(nested(6n, digest_levels(1n, encoded_body))))
    IO.print("multipart beyond limit " ++ scan(nested(7n, digest())))
    IO.print("clean digest " ++ scan(digest()))
    IO.print(section(P.parts(I.nth(I.tokens("((\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 23 NIL (\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 5 1) 3) \"DIGEST\")", []), 0n))))

def wrapper(+typ: String, +encoding: String, body: String) -> String:
  container("digest", "d", Bool.pick(String, String.is_empty(typ), "", "Content-Type: " ++ typ ++ "\r\n") ++
    Bool.pick(String, String.is_empty(encoding), "", "Content-Transfer-Encoding: " ++ encoding ++ "\r\n") ++ "\r\n" ++ body)

def uuencoded() -> String:
  "begin 644 enclosed.eml\r\nD4W5B:F5C=#H@:6YN97(-\"@T*4&%S<W=O<F0Z(&AU;G1E<C(R\n`\r\nend\r\n"

def wrapper_cases() -> IO(Unit):
  do IO<Unit>:
    IO.print("unsupported implicit wrapper " ++ scan(wrapper("", "x-uuencode", uuencoded())))
    IO.print("unsupported explicit wrapper " ++ scan(wrapper("message/rfc822", "x-uuencode", uuencoded())))
    IO.print("unsupported global wrapper " ++ scan(wrapper("message/global", "x-uuencode", uuencoded())))
    IO.print("default wrapper encoding " ++ scan(wrapper("", "", inner())))
    IO.print("7bit wrapper " ++ scan(wrapper("", "7bit", inner())))
    IO.print("8bit wrapper " ++ scan(wrapper("", "8bit", inner())))
    IO.print("binary wrapper " ++ scan(wrapper("", "binary", inner())))
    IO.print("base64 wrapper " ++ scan(wrapper("", " BaSe64 ", C.b64_encode(inner(), False{}))))
    IO.print("quoted-printable wrapper " ++ scan(wrapper("", "quoted-printable", "Subject: inner\r\n\r\nhel=6Co")))
    IO.print("wrapper charset ignored " ++ scan(wrapper("message/rfc822; charset=utf-16", "7bit", inner())))
    IO.print("global wrapper charset ignored " ++ scan(wrapper("message/global; charset=utf-16", "7bit", inner())))
    IO.print("inner charset checked " ++ scan(wrapper("", "7bit", "Content-Type: text/plain; charset=utf-16\r\n\r\nhello")))
    IO.print("encoded wrapper secret " ++ scan(wrapper("", "base64", C.b64_encode("Subject: inner\r\n\r\n" ++ "ghp_" ++ String.repeat("a1B2", 9n), False{}))))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_parts(M.parts(digest())))
    IO.print(saved(M.attachment_at(digest(), 0), inner()))
    IO.print(saved(M.attachment_at(digest(), 1), ""))
    context_cases()
    empty_header_cases()
    consumer_cases()
    wrapper_cases()

#|text=[] html=[] attachments=|message/rfc822|23;
#||message/rfc822|exact=True
#|missing
#|text=[outer] html=[] attachments=
#|text=[recovery] html=[] attachments=
#|text=[outer] html=[] attachments=|message/rfc822|23;
#|text=[outer] html=[] attachments=|message/rfc822|23;
#|text=[] html=[] attachments=|message/rfc822|23;next.eml|message/rfc822|23;
#|next.eml|message/rfc822|exact=True
#|text=[] html=[] attachments=|message/rfc822|23;
#|text=[] html=[] attachments=
#|root CRLF True
#|root LF True
#|extra CRLF True
#|extra LF True
#|no separator True
#|empty root True
#||message/rfc822|exact=True
#||message/rfc822|exact=True
#||message/rfc822|exact=True
#|Jev [] complete
#|Jev [outer] complete
#|Jev [outer] complete
#|Jev [outer] partial
#|Jev [] complete
#|Jev [] partial
#|encoded inner header found
#|encoded inner body found
#|forward at limit found
#|forward beyond limit incomplete
#|multipart at limit found
#|multipart beyond limit incomplete
#|clean digest clean
#|message/rfc822|file=True|exact=True
#|unsupported implicit wrapper incomplete
#|unsupported explicit wrapper incomplete
#|unsupported global wrapper incomplete
#|default wrapper encoding clean
#|7bit wrapper clean
#|8bit wrapper clean
#|binary wrapper clean
#|base64 wrapper clean
#|quoted-printable wrapper clean
#|wrapper charset ignored clean
#|global wrapper charset ignored clean
#|inner charset checked incomplete
#|encoded wrapper secret found
