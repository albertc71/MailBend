# Bounded SEARCH interpreter regression.

import Base
import ../awaiting-search-helpers.bend as H
import ../../src/awaiting.bend as A
import ../../src/imap.bend as I

def main() -> IO(Unit):
  IO.print(H.count(A.search([I.RLine{H.line(10001n, 10001, ""), []}])))

#|incomplete
