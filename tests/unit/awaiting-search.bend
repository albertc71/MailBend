# Complete large SEARCH passes the awaiting session and bounded selection.

import Base
import ../awaiting-search-helpers.bend as H
import ../../src/imap.bend as I
import ../../src/tools.bend as T

def main() -> IO(Unit):
  IO.print(H.session(T.await_session(Done{[
      I.RLine{"* OK [UIDVALIDITY 7] valid", []}, I.RLine{"a1 OK examined", []},
      I.RLine{H.line(5000n, 5000, ""), []}, I.RLine{"a2 OK searched", []}]},
      [I.CExamine{"Sent"}, I.CSearch{[I.KAll{}]}], [])))

#|101:50
