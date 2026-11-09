# Literal nested-view contracts. Expected output is not produced by the parser.

import Base
import ../../src/nested.bend as N
import ../../src/json.bend as J
import ../../src/sections.bend as P

def show(r: Result<&2, &2, String, J.Json>) -> String:
  match r:
    case Done{j}:
      J.show(j)
    case Fail{why}:
      "error"

def wide(n: Nat) -> String:
  "Content-Type: multipart/mixed; boundary=b\r\n\r\n" ++ String.repeat("--b\r\n\r\n\r\n", n) ++ "--b--"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show(N.view("Subject: inner\r\n\r\nhello")))
    IO.print(show(N.view("Content-Transfer-Encoding: base64\r\n\r\naGVsbG8=")))
    IO.print(show(N.view("Content-Transfer-Encoding: base64\r\n\r\naGVsbG8!")))
    IO.print(show(N.view("Content-Transfer-Encoding: quoted-printable\r\n\r\nA=20B")))
    IO.print(show(N.view("Content-Transfer-Encoding: quoted-printable\r\n\r\nA=GG")))
    IO.print(show(N.view("Content-Transfer-Encoding: quoted-printable\r\n\r\nA=0")))
    IO.print(show(N.view("Content-Transfer-Encoding: quoted-printable\r\n\r\nA=")))
    IO.print(show(N.view("Content-Transfer-Encoding: x-private\r\n\r\nhello")))
    IO.print(Bool.show(P.qp_ok("A=")))
    IO.print(show(N.view("Subject: =?utf-8?Q?A=0D=0AB=09C=7F?=\r\n\r\nhello")))
    IO.print(show(N.view("Content-Type: multipart/mixed\r\n\r\nhello")))
    IO.print(show(N.view("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\nhello")))
    # Synthetic EOF/LF/epilogue controls, with independent literal JSON below.
    IO.print(show(N.view("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\nhello\r\n--b--")))
    IO.print(show(N.view("Content-Type: multipart/mixed; boundary=b\n\n--b\n\nhello\n--b--\n")))
    IO.print(show(N.view("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\nhello\r\n--b--\r\n--b\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!!")))
    # The multipart root and 127 empty children fill the 128-entity allowance.
    IO.print(show(N.view(wide(127n))))
    IO.print(show(N.view(wide(128n))))
    # Nested filenames go through the one-line header sanitizer.
    IO.print(show(N.view("Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Disposition: attachment; filename*=utf-8''a%0D%0AFrom%3A%20x%E2%80%AE\r\n\r\nhi\r\n--b\r\nContent-Type: application/octet-stream; name=\"=?utf-8?Q?a=0D=0Ab?=\"\r\n\r\nhi\r\n--b--")))

#|{"headers":{"from":"","to":"","subject":"inner","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]}
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]}
#|error
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"A B","attachments":[],"parse_complete":true,"omissions":[]}
#|error
#|error
#|error
#|error
#|True
#|{"headers":{"from":"","to":"","subject":"A  B C","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]}
#|error
#|error
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]}
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]}
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"hello","attachments":[],"parse_complete":true,"omissions":[]}
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"","attachments":[],"parse_complete":true,"omissions":[]}
#|error
#|{"headers":{"from":"","to":"","subject":"","date":"","message_id":""},"text":"","attachments":[{"filename":"a  From: x","content_type":"text/plain","size":2},{"filename":"a  b","content_type":"application/octet-stream","size":2}],"parse_complete":true,"omissions":[]}
