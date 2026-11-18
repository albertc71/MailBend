# Large SEARCH answers: the interpreter keeps at most 10000 valid UIDs, and a
# complete one passes the awaiting session and bounded selection.

import Base
import ../awaiting-search-helpers.bend as H
import ../../src/awaiting.bend as A
import ../../src/imap.bend as I
import ../../src/tools.bend as T

def searched(n: Nat, high: U32, suffix: String) -> String:
  H.count(A.search([I.RLine{H.line(n, high, suffix), []}]))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(searched(5000n, 5000, ""))
    IO.print(searched(5000n, 5000, "invalid"))
    IO.print(searched(10000n, 10000, ""))
    IO.print(searched(10001n, 10001, ""))
    IO.print(H.session(T.await_session(Done{[
        I.RLine{"* OK [UIDVALIDITY 7] valid", []}, I.RLine{"a1 OK examined", []},
        I.RLine{H.line(5000n, 5000, ""), []}, I.RLine{"a2 OK searched", []}]},
        [I.CExamine{"Sent"}, I.CSearch{[I.KAll{}]}], [])))

#|5000
#|incomplete
#|10000
#|incomplete
#|101:50
