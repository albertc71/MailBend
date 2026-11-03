#!/usr/bin/env python3
"""Generate the finite carry cases for modular Word addition associativity.

There are 16 incoming-carry pairs: six have equal sums. Each valid pair
splits the three low operand bits, giving 48 inductive arms; the other ten
pairs contradict the equality premise. Word length stays universally
quantified. Python is not trusted: Bend's kernel checks every emitted arm.
Run without arguments to print the module, or --check for a read-only drift
check. No production serializer or arithmetic function is generated.
"""
import argparse
from itertools import product
from pathlib import Path


def bit(value: int) -> str:
    return 'True{}' if value else 'False{}'


def adc(a: str, b: str, carry: int) -> str:
    return f'Word.adc(p, {a}, {b}, False{{}}, {bit(carry)})'


def render() -> str:
    s='''# Modular addition used by the serializer byte-count proof.
# Generated finite carry cases; the kernel checks each case and Word induction.

import Base
import ./budget-arithmetic.bend as Arithmetic

def same_carries(+i: Bool, +j: Bool, +k: Bool, +l: Bool) -> Bool:
  Bool.not(Bool.xor(Bool.xor(i, j), Bool.xor(k, l))) && Bool.not(Bool.xor(i && j, k && l))

law adc_assoc:
  for n: Nat
  for i: Bool
  for j: Bool
  for k: Bool
  for l: Bool
  for a: Word(n)
  for b: Word(n)
  for c: Word(n)
  for same: {same_carries(i, j, k, l) == True{} : Bool}
  {Word.adc(n, Word.adc(n, a, b, False{}, i), c, False{}, j) ==
   Word.adc(n, a, Word.adc(n, b, c, False{}, k), False{}, l) : Word(n)}

def adc_assoc(n, i, j, k, l, a, b, c, same):
  match n:
    case 0n:
      match a b c:
        case WNil{} WNil{} WNil{}:
          {==}
    case 1n+p:
      match i j k l:
'''
    for i, j, k, l in product(range(2), repeat=4):
        s += f'        case {bit(i)} {bit(j)} {bit(k)} {bit(l)}:\n'
        if i + j != k + l:
            s += (
                f'          Empty.absurd({{Word.adc(1n+p, Word.adc(1n+p, a, b, False{{}}, {bit(i)}), '
                f'c, False{{}}, {bit(j)}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{{}}, '
                f'{bit(k)}), False{{}}, {bit(l)}) : Word(1n+p)}}, Arithmetic.false_is_not_true(same))\n'
            )
            continue
        s += '          match a b c:\n'
        for ah, bh, ch in product(range(2), repeat=3):
            q = ah + bh + i
            r = q % 2 + ch + j
            u = bh + ch + k
            v = ah + u % 2 + l
            assert r % 2 == v % 2 and q // 2 + r // 2 == u // 2 + v // 2
            lhs = adc(adc('at', 'bt', q // 2), 'ct', r // 2)
            rhs = adc('at', adc('bt', 'ct', u // 2), v // 2)
            s += f'''            case WCon{{{bit(ah)}, +at}} WCon{{{bit(bh)}, +bt}} WCon{{{bit(ch)}, +ct}}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{{{bit(r % 2)}, w}},
                {lhs},
                {rhs},
                adc_assoc(p, {bit(q // 2)}, {bit(r // 2)}, {bit(u // 2)}, {bit(v // 2)}, at, bt, ct, {{==}}))
'''
    s+='''
def add_assoc(a: U32, b: U32, c: U32)
  -> {U32.add(U32.add(a, b), c) == U32.add(a, U32.add(b, c)) : U32}:
  match a b c:
    case U32{+x} U32{+y} U32{+z}:
      Equal.cong(Word(32n), U32, w => U32{w},
        Word.add(32n, Word.add(32n, x, y), z),
        Word.add(32n, x, Word.add(32n, y, z)),
        adc_assoc(32n, False{}, False{}, False{}, False{}, x, y, z, {==}))

def word_zero(n: Nat, a: Word(n))
  -> {Word.add(n, Word.zero(n), a) == a : Word(n)}:
  match n:
    case 0n:
      match a:
        case WNil{}:
          {==}
    case 1n+p:
      match a:
        case WCon{False{}, +t}:
          Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
            Word.add(p, Word.zero(p), t), t, word_zero(p, t))
        case WCon{True{}, +t}:
          Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
            Word.add(p, Word.zero(p), t), t, word_zero(p, t))

def add_zero(a: U32) -> {U32.add(0, a) == a : U32}:
  match a:
    case U32{+w}:
      Equal.cong(Word(32n), U32, x => U32{x}, Word.add(32n, Word.zero(32n), w),
        w, word_zero(32n, w))
'''
    return s


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generated = render()
    if args.check:
        path = Path(__file__).with_name('json-size-arithmetic.bend')
        if path.read_text() != generated:
            raise SystemExit('JSON size arithmetic differs from generator')
        print('JSON size arithmetic matches generator')
    else:
        print(generated, end='')


if __name__ == '__main__':
    main()
