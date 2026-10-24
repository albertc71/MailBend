# Search continuation parsing and its exclusive descending UID boundary.
# Tokens are bounded, versioned text; the exact folder and rendered criteria
# are retained, avoiding collisions from a small hash or ambiguous separators.

import Base
import ./json.bend as J

type Cursor is Data:
  Start{}
  Continue{uidv: U32, before: U32}

def ResultCursor() -> Data:
  Result<&2, &2, String, Cursor>

# Stop inspecting once the bound is exceeded, before splitting any token.
def fits(s: String, fuel: Nat) -> Bool:
  match s fuel:
    case SNil{} _:
      True{}
    case SCon{h, t} 0n:
      False{}
    case SCon{h, t} 1n+n:
      fits(t, n)

def binding(folder: String, criteria: String) -> String:
  J.show(J.strs([folder, criteria]))

def token(binding: String, uidv: U32, before: U32) -> String:
  "s1:" ++ U32.show(uidv) ++ ":" ++ U32.show(before) ++ ":" ++ binding

def invalid() -> ResultCursor():
  Fail{"invalid search cursor: use next_cursor unchanged with the original folder and query"}

def parsed.if(valid: Bool, uidv: U32, before: U32) -> ResultCursor():
  match valid:
    case True{}:
      Done{Continue{uidv, before}}
    case False{}:
      invalid()

def parsed(
  v: Maybe<&2, U32>, b: Maybe<&2, U32>, raw: String, binding: String
) -> ResultCursor():
  match v b:
    case Some{+uidv} Some{+before}:
      parsed.if(Bool.not(U32.is_zero(uidv)) && U32.is_gt(before, 1) &&
        String.eq(raw, token(binding, uidv, before)), uidv, before)
    case _ _:
      invalid()

def parts(xs: List<&2, String>, raw: String, binding: String) -> ResultCursor():
  match xs:
    case version <> v <> b <> rest:
      parsed(U32.read(v), U32.read(b), raw, binding)
    case _:
      invalid()

def read.if(bounded: Bool, +raw: String, binding: String) -> ResultCursor():
  match bounded:
    case True{}:
      parts(String.split(raw, ':'), raw, binding)
    case False{}:
      invalid()

def read(m: Maybe<&2, J.Json>, binding: String) -> ResultCursor():
  match m:
    case None{}:
      Done{Start{}}
    case Some{J.JStr{+raw}}:
      read.if(fits(raw, 4096n), raw, binding)
    case _:
      invalid()

# No arithmetic on UIDs: maximum UID and the bottom boundary cannot wrap.
def below(xs: List<&2, U32>, +before: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case +u <> t:
      List.filter.put(U32, u, below(t, before), U32.is_gt(u, 0) && U32.is_lt(u, before))

def eligible(c: Cursor, xs: List<&2, U32>) -> List<&2, U32>:
  match c:
    case Start{}:
      xs
    case Continue{uidv, before}:
      below(xs, before)

def same(c: Cursor, now: Maybe<&2, U32>) -> Bool:
  match c now:
    case Start{} Some{v}:
      Bool.not(U32.is_zero(v))
    case Continue{known, before} Some{v}:
      U32.is_eq(known, v)
    case _ _:
      False{}

def next(more: Bool, binding: String, uidv: U32, uids: List<&2, U32>) -> J.Json:
  match more:
    case False{}:
      J.JNull{}
    case True{}:
      J.str(token(binding, uidv, Maybe.default(&2, U32, List.last(&2, U32, uids), 0)))
