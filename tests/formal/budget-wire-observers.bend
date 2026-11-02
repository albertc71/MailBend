# Natural wire-byte observation used by the law contract.

import Base
import ../../src/codec.bend as C

# Unbounded mathematical wire length, distinct from the U32 accumulator.
def utf8_weight(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{c, t}:
      Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), utf8_weight(t))
