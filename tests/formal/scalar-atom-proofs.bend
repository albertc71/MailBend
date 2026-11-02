# Exact UTF-8 accounting for one production JSON escape atom.

import Base
import ./budget-wire-observers.bend as Wire
import ../../src/codec.bend as C
import ../../src/json.bend as J

# Compatibility name for the shared law-contract observation.
def utf8_weight(s: String) -> Nat:
  Wire.utf8_weight(s)

def width(a: Bool, b: Bool, c: Bool) -> U32:
  Bool.pick(U32, a, 1, Bool.pick(U32, b, 2, Bool.pick(U32, c, 3, 4)))

# All four production width cases are small enough to add to zero exactly.
def single_width(+a: Bool, +b: Bool, +c: Bool)
  -> {Nat.add(U32.to_nat(width(a, b, c)), 0n) ==
    U32.to_nat(U32.add(0, width(a, b, c))) : Nat}:
  match a b c:
    case True{} _ _:
      {==}
    case False{} True{} _:
      {==}
    case False{} False{} True{}:
      {==}
    case False{} False{} False{}:
      {==}

# A control escape has four literal ASCII characters and two hex digits.
# Even without assuming that the hex digits are ASCII, two UTF-8 widths
# lie in 1..4, so this actual accumulator addition cannot wrap U32.
def control_widths(+a: Bool, +b: Bool, +c: Bool, +d: Bool, +e: Bool, +f: Bool)
  -> {4n+Nat.add(U32.to_nat(width(a, b, c)),
      Nat.add(U32.to_nat(width(d, e, f)), 0n)) ==
    U32.to_nat(U32.add(U32.add(4, width(a, b, c)), width(d, e, f))) : Nat}:
  match a b c d e f:
    case True{} _ _ True{} _ _:
      {==}
    case True{} _ _ False{} True{} _:
      {==}
    case True{} _ _ False{} False{} True{}:
      {==}
    case True{} _ _ False{} False{} False{}:
      {==}
    case False{} True{} _ True{} _ _:
      {==}
    case False{} True{} _ False{} True{} _:
      {==}
    case False{} True{} _ False{} False{} True{}:
      {==}
    case False{} True{} _ False{} False{} False{}:
      {==}
    case False{} False{} True{} True{} _ _:
      {==}
    case False{} False{} True{} False{} True{} _:
      {==}
    case False{} False{} True{} False{} False{} True{}:
      {==}
    case False{} False{} True{} False{} False{} False{}:
      {==}
    case False{} False{} False{} True{} _ _:
      {==}
    case False{} False{} False{} False{} True{} _:
      {==}
    case False{} False{} False{} False{} False{} True{}:
      {==}
    case False{} False{} False{} False{} False{} False{}:
      {==}

def single(c: Char)
  -> {utf8_weight(SCon{c, SNil{}}) ==
    U32.to_nat(C.utf8_len(SCon{c, SNil{}})) : Nat}:
  +n = Char.to_u32(c)
  single_width(U32.is_lt(n, 128), U32.is_lt(n, 2048), U32.is_lt(n, 65536))

def control(a: Char, b: Char)
  -> {utf8_weight("\\u00" ++ SCon{a, SCon{b, SNil{}}}) ==
    U32.to_nat(C.utf8_len("\\u00" ++ SCon{a, SCon{b, SNil{}}})) : Nat}:
  +x = Char.to_u32(a)
  +y = Char.to_u32(b)
  control_widths(U32.is_lt(x, 128), U32.is_lt(x, 2048), U32.is_lt(x, 65536),
    U32.is_lt(y, 128), U32.is_lt(y, 2048), U32.is_lt(y, 65536))

def atom_exact.if(ctrl: Bool, +u: U32, c: Char)
  -> {utf8_weight(J.esc_char.if(ctrl, u, c)) ==
    U32.to_nat(C.utf8_len(J.esc_char.if(ctrl, u, c))) : Nat}:
  match ctrl:
    case True{}:
      control(C.hex_low((u >> 4n : U32)), C.hex_low((u .&. 15 : U32)))
    case False{}:
      single(c)

# Explicit positive bit cases avoid the compiler's negative literal-pattern
# refinement: each fallback path differs from all five special characters.
def atom_exact(+c: Char)
  -> {utf8_weight(J.esc_char(c)) == U32.to_nat(C.utf8_len(J.esc_char(c))) : Nat}:
  match c:
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{False{}, tail}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, tail}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, tail}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, tail}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, tail}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, WCon{True{}, tail}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, tail}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, tail}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, tail}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, tail}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{False{}, WCon{True{}, WCon{True{}, tail}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, tail}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{False{}, WCon{True{}, tail}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, WCon{True{}, tail}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{False{}, tail}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      {==}
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, WNil{}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{False{}, WCon{True{}, tail}}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{False{}, WCon{True{}, tail}}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{False{}, WCon{True{}, WCon{True{}, WCon{True{}, tail}}}}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
    case Chr{U32{WCon{True{}, WCon{True{}, tail}}}}:
      +u = Char.to_u32(c)
      atom_exact.if(U32.is_lt(u, 32), u, c)
