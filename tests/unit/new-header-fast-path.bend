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

def uids_from(raw: String, uids: List<&2, U32>) -> String:
  uid_list(T.new_messages(I.frame(raw), uids))

def missing_uids(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      U32.show(x) ++ "," ++ missing_uids(t)

def coverage.show(result: T.NewCoverage) -> String:
  T.NewCoverage{ms, missing} = result
  uid_list(ms) ++ " missing=" ++ missing_uids(missing)

def coverage(raw: String, uids: List<&2, U32>) -> String:
  coverage.show(T.new_messages.coverage(I.frame(raw), uids))

def main() -> IO(Unit):
  do IO<Unit>:
    # Complete normal path, including an unsolicited and duplicate response.
    IO.print(uids_from(header(4) ++ header(9) ++ header(9) ++ header(99), [4, 9]))
    # Mixed normal/empty path must retain the fallback for missing UIDs.
    IO.print(uids_from(header(4) ++ empty_header(9), [4, 9]))
    # Missing data remains missing; no cursor-safe message is fabricated.
    IO.print(uids_from(header(4), [4, 9]))
    IO.print(coverage(header(4) ++ header(9), [4, 9]))
    IO.print(coverage(header(4) ++ empty_header(9), [4, 9]))
    IO.print(coverage(header(4), [4, 9]))
    IO.print(coverage("", []))
    IO.print(coverage(header(4), [4, 4]))
    IO.print(coverage(empty_header(4), [4, 4, 9]))
    # The fallback may fill one UID while another remains missing.
    IO.print(coverage(header(4) ++ empty_header(9), [4, 9, 12]))
    return Unit{}

#|4,9,
#|4,9,
#|4,
#|4,9, missing=
#|4,9, missing=
#|4, missing=9,
#| missing=
#|4, missing=
#|4, missing=9,
#|4,9, missing=12,
