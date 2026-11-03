import Base
import ../../src/tools.bend as T
import ../../src/imap.bend as I

def header(uid: U32) -> String:
  "* 1 FETCH (UID " ++ U32.show(uid) ++ " BODY[HEADER.FIELDS (SUBJECT)] {12}\r\nSubject: X\r\n)\r\n"

def empty_header(uid: U32) -> String:
  "* 1 FETCH (UID " ++ U32.show(uid) ++ " BODY[HEADER.FIELDS (" ++ I.header_fields() ++ ")] \"\")\r\n"

def uid_list(ms: List<&2, I.Msg>) -> String:
  match ms:
    case Nil{}:
      ""
    case m <> t:
      U32.show(T.msg_uid(m)) ++ "," ++ uid_list(t)

def count(raw: String, uids: List<&2, U32>) -> String:
  uid_list(T.new_messages(I.frame(raw), uids))

def main() -> IO(Unit):
  do IO<Unit>:
    # Complete normal path, including an unsolicited and duplicate response.
    IO.print(count(header(4) ++ header(9) ++ header(9) ++ header(99), [4, 9]))
    # Mixed normal/empty path must retain the fallback for missing UIDs.
    IO.print(count(header(4) ++ empty_header(9), [4, 9]))
    # Missing data remains missing; no cursor-safe message is fabricated.
    IO.print(count(header(4), [4, 9]))
    return Unit{}

#|4,9,
#|4,9,
#|4,
