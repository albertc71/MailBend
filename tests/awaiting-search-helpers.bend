# Large bounded SEARCH evidence survives the interpreter path.

import Base
import ../src/awaiting.bend as A
import ../src/imap.bend as I
import ../src/tools.bend as T

def words(n: Nat, +u: U32, acc: List<&2, String>) -> List<&2, String>:
  match n:
    case 0n:
      acc
    case 1n+rest:
      words(rest, (u - 1 : U32), U32.show(u) <> acc)

def line(n: Nat, high: U32, +suffix: String) -> String:
  "* SEARCH " ++ String.join(words(n, high,
    Bool.pick(List<&2, String>, String.is_empty(suffix), [], [suffix])), " ")

def count(r: Maybe<&2, List<&2, U32>>) -> String:
  match r:
    case None{}:
      "incomplete"
    case Some{us}:
      Nat.show(List.length(&2, U32, us))

def session(r: Result<&2, &2, String, List<&2, T.Found>>) -> String:
  match r:
    case Fail{m}:
      "incomplete"
    case Done{+fs}:
      wants = T.await_wants(fs, 50n)
      Nat.show(T.await_count(fs)) ++ ":" ++ Nat.show(T.await_wanted_count(wants))
