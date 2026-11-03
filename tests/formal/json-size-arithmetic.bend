# Modular addition used by the serializer byte-count proof.
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
        case False{} False{} False{} False{}:
          match a b c:
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
        case False{} False{} False{} True{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, False{}), c, False{}, False{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, False{}), False{}, True{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case False{} False{} True{} False{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, False{}), c, False{}, False{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, True{}), False{}, False{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case False{} False{} True{} True{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, False{}), c, False{}, False{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, True{}), False{}, True{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case False{} True{} False{} False{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, False{}), c, False{}, True{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, False{}), False{}, False{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case False{} True{} False{} True{}:
          match a b c:
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
        case False{} True{} True{} False{}:
          match a b c:
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
        case False{} True{} True{} True{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, False{}), c, False{}, True{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, True{}), False{}, True{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case True{} False{} False{} False{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, True{}), c, False{}, False{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, False{}), False{}, False{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case True{} False{} False{} True{}:
          match a b c:
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
        case True{} False{} True{} False{}:
          match a b c:
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, False{}),
                adc_assoc(p, False{}, False{}, False{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
        case True{} False{} True{} True{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, True{}), c, False{}, False{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, True{}), False{}, True{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case True{} True{} False{} False{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, True{}), c, False{}, True{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, False{}), False{}, False{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case True{} True{} False{} True{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, True{}), c, False{}, True{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, False{}), False{}, True{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case True{} True{} True{} False{}:
          Empty.absurd({Word.adc(1n+p, Word.adc(1n+p, a, b, False{}, True{}), c, False{}, True{}) == Word.adc(1n+p, a, Word.adc(1n+p, b, c, False{}, True{}), False{}, False{}) : Word(1n+p)}, Arithmetic.false_is_not_true(same))
        case True{} True{} True{} True{}:
          match a b c:
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, False{}, True{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, False{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, False{}, True{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, False{}),
                adc_assoc(p, True{}, False{}, True{}, False{}, at, bt, ct, {==}))
            case WCon{False{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, False{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, False{}), False{}, True{}),
                adc_assoc(p, True{}, False{}, False{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{False{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{False{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{False{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))
            case WCon{True{}, +at} WCon{True{}, +bt} WCon{True{}, +ct}:
              Equal.cong(Word(p), Word(1n+p), w => WCon{True{}, w},
                Word.adc(p, Word.adc(p, at, bt, False{}, True{}), ct, False{}, True{}),
                Word.adc(p, at, Word.adc(p, bt, ct, False{}, True{}), False{}, True{}),
                adc_assoc(p, True{}, True{}, True{}, True{}, at, bt, ct, {==}))

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
