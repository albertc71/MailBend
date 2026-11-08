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
