# Bounded synthetic thread equivalence and compiled ordering probe.

import Base
import ../../src/imap.bend as I
import ../../src/thread.bend as T
import ../thread-support/fixtures.bend as F
import ../thread-support/reference.bend as R

def id(+n: U32) -> String:
  Bool.pick(String, U32.is_eq(n, 0), "", Bool.pick(String, U32.is_eq(n, 1), "a", "b"))

def reply(+n: U32) -> List<&2, String>:
  Bool.pick(List<&2, String>, U32.is_eq(n, 0), [],
    [Bool.pick(String, U32.is_eq(n, 3), "missing", id(n))])

def tie(n: T.Node, +tied: Bool) -> T.Node:
  T.Node{folder, generation, I.Msg{uid, flags, date, size, headers, body, tree},
    time, own, replies, refs} = n
  T.Node{folder, generation,
    I.Msg{Bool.pick(U32, tied, 0, uid), flags, date, size, headers, body, tree},
    Bool.pick(U32, tied, 0, time), own, replies, refs}

def nodes(length: Nat, +code: U32, +slot: U32, +tied: Bool) -> List<&2, T.Node>:
  match length:
    case 0n:
      []
    case 1n+n:
      +digit = U32.mod(code, 12)
      tie(F.node(slot, slot, id(U32.div(digit, 4)), reply(U32.mod(digit, 4)), []), tied)
        <> nodes(n, U32.div(code, 12), U32.inc(slot), tied)

def cases(left: Nat, +length: Nat, +tied: Bool, +code: U32, failed: U32) -> U32:
  match left:
    case 0n:
      failed
    case 1n+n:
      ok = F.equivalent(nodes(length, code, 1, tied))
      cases(n, length, tied, U32.inc(code), (failed + Bool.pick(U32, ok, 0, 1) : U32))

def exhaustive(tied: Bool) -> U32:
  +same = tied
  (cases(1n, 0n, same, 0, 0) + cases(12n, 1n, same, 0, 0) +
    cases(144n, 2n, same, 0, 0) + cases(1728n, 3n, same, 0, 0) : U32)

def check() -> IO(Unit):
  IO.print("equivalence cases=3770 failures=" ++
    U32.show((exhaustive(False{}) + exhaustive(True{}) : U32)))

def key(+i: U32, prefix: String) -> String:
  "<" ++ prefix ++ U32.show(i) ++ "@example.invalid>"

def chain(+left: Nat, +i: U32, +prefix: String, +cycle: Bool) -> List<&2, T.Node>:
  match left:
    case 0n:
      []
    case 1n+n:
      p = Bool.pick(List<&2, String>, U32.is_eq(i, 1),
        Bool.pick(List<&2, String>, cycle, [key(U32.from_nat(left), prefix)], []),
        [key(U32.sub(i, 1), prefix)])
      F.node(i, i, key(i, prefix), p, []) <> chain(n, U32.inc(i), prefix, cycle)

def ordered(ns: List<&2, T.Node>, baseline: Bool) -> List<&2, T.Placed>:
  match baseline:
    case True{}:
      R.thread_order(ns)
    case False{}:
      T.thread_order(ns)

def measure(size: U32, +shape: String, baseline: Bool) -> IO(Unit):
  prefix = Bool.pick(String, String.eq(shape, "prefix"), String.repeat("p", 256n), "")
  IO.print(F.lines(ordered(chain(U32.to_nat(size), 1, prefix, String.eq(shape, "cycle")), baseline)))

def run.mode(mode: String, +args: List<&2, String>) -> IO(Unit):
  match mode:
    case "check":
      check()
    case other:
      size = Maybe.default(&2, U32, Maybe.bind(&2, String, U32,
        List.get(&2, String, args, 2n), U32.read), 10)
      shape = Maybe.default(&2, String, List.get(&2, String, args, 3n), "chain")
      measure(size, shape, String.eq(other, "baseline"))

def run(+args: List<&2, String>) -> IO(Unit):
  run.mode(Maybe.default(&2, String, List.get(&2, String, args, 1n), "check"), args)

def share(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case h <> t:
      h <> share(t)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<&1, String> <- IO.args()
    run(share(args))
