import Base
import ../../src/pacing.bend as P

def entry_count(xs: List<&1, P.Entry>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case P.PacingEntry{cost, completed} <> tail:
      1n+entry_count(tail)

def refusal_text(reason: P.Reason, ledger: P.Ledger) -> String:
  match reason ledger:
    case P.PacingWait{seconds} P.PacingReady{budget, last, entries}:
      "wait=" ++ Nat.show(seconds) ++ " entries=" ++ Nat.show(entry_count(entries))
    case _ _:
      "unexpected refusal"

def observed(a: P.Admission) -> String:
  match a:
    case P.PacingRefused{reason, ledger}:
      refusal_text(reason, ledger)
    case P.PacingAdmitted{flight}:
      "unexpected admission"

def main() -> IO(Unit):
  IO.print(observed(P.admit(P.PacingReady{6, Some{2000n},
    [P.PacingEntry{2, 2000n}, P.PacingEntry{4, 1000n}]}, 5, 601001n)))

#|wait=1 entries=2
