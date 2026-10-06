# Unit tests for src/secrets.bend: the local secret scan's rules, what it
# reads of an outgoing message, and its limits. Fake secrets only.

import Base
import ../../src/codec.bend as C
import ../../src/mime.bend as M
import ../../src/secrets.bend as Secrets

def show_scan(s: Secrets.Scan) -> String:
  match s:
    case Secrets.Found{part}:
      "found in " ++ part
    case Secrets.Incomplete{reason}:
      "incomplete: " ++ reason
    case Secrets.Clean{}:
      "clean"

def found_flag(s: Secrets.Scan) -> String:
  match s:
    case Secrets.Found{part}:
      "T"
    case Secrets.Incomplete{reason}:
      "I"
    case Secrets.Clean{}:
      "F"

# Whether the scan finds a secret in each body text.
def secret_flags(ts: List<&2, String>) -> String:
  match ts:
    case Nil{}:
      ""
    case t <> rest:
      found_flag(Secrets.secret_scan([], t, [])) ++ secret_flags(rest)

def flags(xs: List<&2, Bool>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      Bool.pick(String, x, "T", "F") ++ flags(t)

def github_token() -> String:
  "ghp_" ++ String.repeat("a1B2", 9n)

def pem() -> String:
  "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAfakefakefake\n-----END RSA PRIVATE KEY-----\n"

# Texts that hold a secret by one of the three rules.
def secrets() -> List<&2, String>:
  [
    "-----BEGIN RSA PRIVATE KEY-----\nMIIE",
    "x\n-----BEGIN OPENSSH PRIVATE KEY-----",
    "-----BEGIN PGP PRIVATE KEY BLOCK-----",
    "the key AKIAIOSFODNN7EXAMPLE works",
    "token: " ++ github_token(),
    "(xoxb-123456789012-abcdefABCDEF)",
    "sk-ant-api03-abcdefghijklmnop",
    "Password: hunter22",
    "  PWD = s3cret!x",
    "intro\npasscode:   7391-ab more",
    "> Password: hunter22",
    "On Monday you wrote:\n> > >Password: hunter22\n> thanks",
    ">\tpwd=abc123x"
  ]

# Texts that only look like one.
def lookalikes() -> List<&2, String>:
  [
    "-----BEGIN PUBLIC KEY-----",
    "the AKIA prefix marks an AWS access key",
    "XAKIAIOSFODNN7EXAMPLE",
    "my_" ++ github_token(),
    "ghp_short",
    "sk-ant-",
    "Password: required",
    "Your password: (see the vault)",
    "Passwords must have 8 characters: 2 digits",
    "Password reset code: 123456",
    "password:",
    "> Password: required",
    "x > Password: hunter22",
    ""
  ]

# `s` as UTF-16LE, each character followed by a NUL.
def wide(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      SCon{c, SCon{'\0', wide(t)}}

def text_entity(headers: String, body: String) -> String:
  headers ++ "\r\n" ++ body

# A forwarded message whose single text part holds `body`, encoded by
# `cte`, in the charset `cs`.
def forwarded_in(cs: String, cte: String, body: String) -> String:
  text_entity("Subject: fwd\r\nContent-Type: text/plain; charset=" ++ cs ++ "\r\n" ++
    "Content-Transfer-Encoding: " ++ cte ++ "\r\n", body)

def forwarded(cte: String, body: String) -> String:
  forwarded_in("utf-8", cte, body)

# A forwarded message holding `inner` forwarded inside it, `n` times over,
# each level with a boundary of its own.
def nested(n: Nat, inner: String) -> String:
  match n:
    case Zero{}:
      inner
    case Succ{+k}:
      +b = "b" ++ Nat.show(k)
      text_entity("Subject: fwd\r\nContent-Type: multipart/mixed; boundary=\"" ++ b ++ "\"\r\n",
        "--" ++ b ++ "\r\nContent-Type: text/plain\r\n\r\nsee below\r\n--" ++ b ++
          "\r\nContent-Type: message/rfc822\r\n\r\n" ++ nested(k, inner) ++ "\r\n--" ++ b ++
          "--\r\n")

# `inner` inside `n` levels of multipart/mixed, each with a boundary of its
# own, in one message.
def multiparts(n: Nat, inner: String) -> String:
  match n:
    case Zero{}:
      inner
    case Succ{+k}:
      +b = "m" ++ Nat.show(k)
      text_entity("Content-Type: multipart/mixed; boundary=\"" ++ b ++ "\"\r\n",
        "--" ++ b ++ "\r\n" ++ multiparts(k, inner) ++ "\r\n--" ++ b ++ "--\r\n")

# A forwarded message with a text part and a part of type `ctype` holding
# `data` in base64.
def with_part(ctype: String, data: String) -> String:
  text_entity("Subject: keys\r\nContent-Type: multipart/mixed; boundary=\"k\"\r\n",
    "--k\r\nContent-Type: text/plain\r\n\r\nthe key you asked for\r\n--k\r\n" ++
      "Content-Type: " ++ ctype ++ "\r\nContent-Transfer-Encoding: base64\r\n\r\n" ++
      C.b64_encode(data, False{}) ++ "\r\n--k--\r\n")

def eml(data: String) -> M.Attach:
  M.Attach{"forwarded-message.eml", "message/rfc822", data}

# `n` words of 5 characters each, built without deep recursion.
def words(n: Nat, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+k:
      words(k, "word " ++ acc)

def scan_atts(atts: List<&2, M.Attach>) -> String:
  show_scan(Secrets.secret_scan([M.Hdr{"subject", "Hello"}], "See the attachment.", atts))

def check_rules() -> IO(Unit):
  do IO<Unit>:
    IO.print(secret_flags(secrets()) ++ " " ++ secret_flags(lookalikes()))
    IO.print(flags([Secrets.scannable_encoding("", ""),
      Secrets.scannable_encoding("Base64", "UTF-8"),
      Secrets.scannable_encoding(" quoted-printable ", "iso-8859-1"),
      Secrets.scannable_encoding("x-uuencode", ""),
      Secrets.scannable_encoding("7bit", "UTF-16LE"),
      Secrets.scannable_encoding("", "utf-7")]))

def check_fields() -> IO(Unit):
  +secret : String = "Password: hunter22"
  do IO<Unit>:
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}], "See you at noon.", [])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", secret}], "Hi", [])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}], "Hi\n" ++ secret, [])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"},
      M.Hdr{"to", "\"" ++ github_token() ++ "\" <a@x.com>"}], "Hi", [])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"},
      M.Hdr{"in-reply-to", "<" ++ github_token() ++ "@x.com>"}], "Hi", [])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}],
      "Hi\0", [])))

def check_attachments() -> IO(Unit):
  +secret : String = "Password: hunter22"
  do IO<Unit>:
    IO.print(scan_atts([M.Attach{"notes.txt", "text/plain", "x\n" ++ secret}]))
    IO.print(scan_atts([M.Attach{"AKIAIOSFODNN7EXAMPLE.txt", "text/plain", "x"}]))
    IO.print(scan_atts([M.Attach{"bill.pdf", "application/pdf", "%PDF-1.7 no secret here"}]))
    IO.print(scan_atts([M.Attach{"config.json", "application/json",
      "{\"token\": \"" ++ github_token() ++ "\"}"}]))
    IO.print(scan_atts([M.Attach{"id_rsa", "application/octet-stream", pem()}]))
    IO.print(scan_atts([M.Attach{"creds.env", "application/octet-stream", "DB_" ++ secret}]))
    IO.print(scan_atts([M.Attach{"creds.env", "application/octet-stream", secret}]))
    IO.print(scan_atts([M.Attach{"photo.png", "image/png",
      "\u{89}PNG\0no secret"}]))
    IO.print(scan_atts([M.Attach{"wide.txt", "text/plain", wide(secret)}]))
    IO.print(scan_atts([M.Attach{"wide.txt", "text/plain",
      SCon{Char.from_u32(255), SCon{Char.from_u32(254), wide(secret)}}}]))
    IO.print(scan_atts([M.Attach{"wide.txt", "text/plain; charset=utf-16", "x"}]))
    IO.print(scan_atts([M.Attach{"wide.txt", "text/plain; charset=utf-16", "x"},
      M.Attach{"notes.txt", "text/plain", secret}]))
    IO.print(scan_atts([M.Attach{"notes.txt", "text/plain", secret},
      M.Attach{"wide.txt", "text/plain; charset=utf-16", "x"}]))
    IO.print(scan_atts([M.Attach{"id_rsa", "application/octet-stream", pem()},
      M.Attach{"notes.txt", "text/plain", secret}]))
    IO.print(scan_atts([M.Attach{"wide.txt", "text/plain; charset=utf-16", "x"},
      M.Attach{"id_rsa", "application/octet-stream", pem()}]))

def check_forwards() -> IO(Unit):
  +secret : String = "Password: hunter22"
  +plain = forwarded("7bit", "nothing to see\r\n")
  do IO<Unit>:
    IO.print(scan_atts([eml(plain)]))
    IO.print(scan_atts([eml(forwarded("base64", C.b64_encode(secret, False{})))]))
    IO.print(scan_atts([eml(forwarded("quoted-printable", "Pass=\r\nword: hunter=322"))]))
    IO.print(scan_atts([eml(nested(2n, forwarded("7bit", secret)))]))
    IO.print(scan_atts([eml(nested(3n, forwarded("7bit", secret)))]))
    IO.print(scan_atts([eml(nested(3n, plain))]))
    IO.print(scan_atts([eml(forwarded("x-uuencode", "begin 644 x"))]))
    IO.print(scan_atts([eml(forwarded_in("unicode", "base64", C.b64_encode(wide(secret),
      False{})))]))
    IO.print(scan_atts([eml(forwarded_in("iso-10646-ucs-2", "base64",
      C.b64_encode(wide(secret), False{})))]))
    IO.print(scan_atts([eml(forwarded_in("csUnicode", "base64", C.b64_encode(wide(secret),
      False{})))]))
    IO.print(scan_atts([eml(forwarded_in("unicodefeff", "base64", C.b64_encode(wide(secret),
      False{})))]))
    IO.print(scan_atts([eml(with_part("application/octet-stream; name=\"id_rsa\"", pem()))]))
    IO.print(scan_atts([eml(with_part("message/global", "Subject: inner\r\n\r\n" ++ secret))]))
    IO.print(scan_atts([eml("Subject: Deploy\r\nX-Deploy-Token: " ++ github_token() ++
      "\r\n\r\nsee the header\r\n")]))
    IO.print(scan_atts([M.Attach{"key.eml", "message/rfc822", pem()}]))
    IO.print(scan_atts([eml(multiparts(7n, forwarded("7bit", secret)))]))
    IO.print(scan_atts([eml(multiparts(8n, forwarded("7bit", secret)))]))

def check_limits() -> IO(Unit):
  +secret : String = "Password: hunter22"
  do IO<Unit>:
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}], words(209700n, ""),
      [M.Attach{"notes.txt", "text/plain", secret}])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}], words(209710n, ""),
      [M.Attach{"notes.txt", "text/plain", secret}])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}], words(209700n, ""),
      [M.Attach{"creds.env", "application/octet-stream", secret}])))
    IO.print(show_scan(Secrets.secret_scan([M.Hdr{"subject", "Lunch"}], words(209710n, ""),
      [M.Attach{"creds.env", "application/octet-stream", secret}])))

def main() -> IO(Unit):
  do IO<Unit>:
    check_rules()
    check_fields()
    check_attachments()
    check_forwards()
    check_limits()

#|TTTTTTTTTTTTT FFFFFFFFFFFFFF
#|TTTFFF
#|clean
#|found in the subject field
#|found in the body
#|found in the to field
#|found in the in-reply-to field
#|incomplete: the body cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|found in attachment 1 > text/plain
#|found in the name of attachment 1
#|clean
#|found in attachment 1 > application/json
#|found in attachment 1 > application/octet-stream
#|clean
#|found in attachment 1 > application/octet-stream
#|clean
#|incomplete: attachment 1 > text/plain cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|incomplete: attachment 1 > text/plain cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|incomplete: the text part attachment 1 > text/plain cannot be decoded
#|found in attachment 2 > text/plain
#|found in attachment 1 > text/plain
#|found in attachment 2 > text/plain
#|found in attachment 2 > application/octet-stream
#|clean
#|found in attachment 1 > message/rfc822 > text/plain
#|found in attachment 1 > message/rfc822 > text/plain
#|found in attachment 1 > message/rfc822 > message/rfc822 > message/rfc822 > text/plain
#|incomplete: attachment 1 > message/rfc822 > message/rfc822 > message/rfc822 > message/rfc822 nests forwarded messages more than 3 levels deep
#|incomplete: attachment 1 > message/rfc822 > message/rfc822 > message/rfc822 > message/rfc822 nests forwarded messages more than 3 levels deep
#|incomplete: the text part attachment 1 > message/rfc822 > text/plain cannot be decoded
#|incomplete: attachment 1 > message/rfc822 > text/plain cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|incomplete: attachment 1 > message/rfc822 > text/plain cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|incomplete: attachment 1 > message/rfc822 > text/plain cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|incomplete: attachment 1 > message/rfc822 > text/plain cannot be decoded: it holds a NUL character, as UTF-16 and UTF-32 text do
#|found in attachment 1 > message/rfc822 > application/octet-stream
#|found in attachment 1 > message/rfc822 > message/global > text/plain
#|found in the header of attachment 1 > message/rfc822
#|found in the header of attachment 1 > message/rfc822
#|found in attachment 1 > message/rfc822 > text/plain
#|incomplete: attachment 1 > message/rfc822 nests its parts more than 8 levels deep
#|found in attachment 1 > text/plain
#|incomplete: it holds more than 1 MB of text
#|found in attachment 1 > application/octet-stream
#|clean
