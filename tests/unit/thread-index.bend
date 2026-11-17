# Thread ordering retains exact broken-header behavior.

import Base
import ../../src/thread.bend as T
import ../thread-support/fixtures.bend as F

def missing(n: Nat) -> List<&2, String>:
  match n:
    case 0n:
      []
    case 1n+k:
      "missing" <> missing(k)

def cutoff(n: Nat) -> String:
  F.parents(T.thread_order([
    F.node(1, 1, "a", [], []), F.node(2, 2, "b", [], "a" <> missing(n))]))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("cycle does not retry References")
    IO.print(F.parents(T.thread_order([
      F.node(1, 1, "a", ["b"], []), F.node(2, 2, "b", ["c"], []),
      F.node(3, 3, "root", [], []), F.node(4, 4, "c", ["a"], ["root"])])))
    IO.print("only the first In-Reply-To is tried")
    IO.print(F.parents(T.thread_order([
      F.node(1, 1, "a", [], []), F.node(2, 2, "b", ["missing", "a"], [])])))
    IO.print("missing IDs are not shared")
    IO.print(F.parents(T.thread_order([
      F.node(1, 1, "", ["a"], []), F.node(2, 2, "", ["a"], []), F.node(3, 3, "a", [], [])])))
    IO.print("shared IDs keep no parent, but remain candidates")
    IO.print(F.parents(T.thread_order([
      F.node(1, 1, "x", ["y"], []), F.node(2, 2, "x", ["y"], []),
      F.node(3, 3, "y", ["x"], []), F.node(4, 4, "x", ["y"], [])])))
    IO.print("baseline projections")
    IO.print(Bool.show(F.equivalent([])))
    IO.print(Bool.show(F.equivalent([
      F.node(1, 1, "prefix", ["prefix-long"], []),
      F.node(1, 1, "prefix-long", ["prefix"], [])])))
    IO.print(Bool.show(F.equivalent([
      F.node(3, 3, "é", ["É"], []), F.node(2, 2, "É", ["e"], []),
      F.node(1, 1, "e", ["é"], [])])))
    IO.print("References lengths 49, 50, 51")
    IO.print(cutoff(48n))
    IO.print(cutoff(49n))
    IO.print(cutoff(50n))
    IO.print("prefix NUL and Unicode spelling")
    IO.print(Bool.show(F.equivalent([
      F.node(1, 1, "a", ["a" ++ SCon{Chr{0}, ""}], []),
      F.node(2, 2, "a" ++ SCon{Chr{0}, ""}, ["a"], [])])))
    IO.print(Bool.show(F.equivalent([
      F.node(1, 1, "é", ["é"], []), F.node(2, 2, "é", ["é"], [])])))

#|cycle does not retry References
#|1<-b;2<-c;3<-;4<-;
#|only the first In-Reply-To is tried
#|1<-;2<-;
#|missing IDs are not shared
#|1<-a;2<-a;3<-;
#|shared IDs keep no parent, but remain candidates
#|1<-;2<-;3<-x;4<-;
#|baseline projections
#|True
#|True
#|True
#|References lengths 49, 50, 51
#|1<-;2<-a;
#|1<-;2<-a;
#|1<-;2<-;
#|prefix NUL and Unicode spelling
#|True
#|True
