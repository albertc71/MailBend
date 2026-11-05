# A selected-section microbenchmark. Payloads are synthetic bytes, not image files.

import Base
import ../../src/tools.bend as T
import ../../src/imap.bend as I
import ../../src/sections.bend as P
import ../../src/codec.bend as C

def payload(n: Nat, s: String) -> String:
  match n:
    case 0n:
      s
    case 1n+k:
      payload(k, SCon{'A', s})

def metadata(n: Nat, +leaf: String) -> String:
  match n:
    case 0n:
      ""
    case 1n+k:
      leaf ++ metadata(k, leaf)

def structure.if(complex: Bool, leaf: String) -> String:
  match complex:
    case False{}:
      leaf
    case True{}:
      "(" ++ metadata(127n, leaf) ++ " \"MIXED\")"

def structure(complex: Bool, size: U32) -> String:
  structure.if(complex,
    "(\"IMAGE\" \"PNG\" NIL NIL NIL \"7BIT\" " ++ U32.show(size) ++ ")")

def response(uid: U32, +size: U32, raw: String, complex: Bool) -> I.RLine:
  I.RLine{"* 1 FETCH (UID " ++ U32.show(uid) ++ " BODYSTRUCTURE " ++
    structure(complex, size) ++ " BODY[1]<0> " ++ SCon{I.lit_mark(), ")"}, [raw]}

def lines(+size: U32, +raw: String, +complex: Bool) -> List<&2, I.RLine>:
  [I.RLine{"* OK [UIDVALIDITY 42] current", []}, response(1, size, raw, complex),
    response(2, size, raw, complex), response(3, size, raw, complex),
    response(4, size, raw, complex)]

def result(r: Result<&2, &2, String, String>) -> U32:
  match r:
    case Fail{why}:
      0
    case Done{raw}:
      C.byte_len(raw)

def one(run: T.Run(), uid: U32, +size: U32) -> U32:
  result(T.part_bytes(run, uid, 42, P.Part{[1], "image/png", "", "7bit", size},
    (size + 1 : U32)))

def repeat(n: Nat, +run: T.Run(), +size: U32, acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+k:
      count = (one(run, 1, size) + one(run, 2, size) + one(run, 3, size) +
        one(run, 4, size) : U32)
      repeat(k, run, size, (acc + count : U32))

def run(+args: List<&2, String>) -> IO(Unit):
  +size = Maybe.default(&2, U32, Maybe.bind(&2, String, U32,
    List.get(&2, String, args, 1n), U32.read), 1)
  n = Maybe.default(&2, U32, Maybe.bind(&2, String, U32,
    List.get(&2, String, args, 2n), U32.read), 100)
  complex = String.eq(Maybe.default(&2, String, List.get(&2, String, args, 3n), "small"), "complex")
  IO.print(U32.show(repeat(U32.to_nat(n), Done{lines(size, payload(U32.to_nat(size), ""), complex)},
    size, 0)))

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
