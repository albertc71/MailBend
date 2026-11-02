# Exact natural-number accounting for guarded machine-word subtraction.

import Base

def false_type(b: Bool) -> Type:
  match b:
    case False{}:
      Unit
    case True{}:
      Empty

def false_is_not_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : false_type(_)
  Unit{}

def add_right_succ(a: Nat, -b: Nat)
  -> {Nat.add(a, 1n+b) == 1n+Nat.add(a, b) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.add(p, 1n+b), 1n+Nat.add(p, b),
        add_right_succ(p, b))

def double_add(a: Nat, -b: Nat)
  -> {Nat.double(Nat.add(a, b)) == Nat.add(Nat.double(a), Nat.double(b)) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 2n+x, Nat.double(Nat.add(p, b)),
        Nat.add(Nat.double(p), Nat.double(b)), double_add(p, b))

def double_sum(-a: Nat, b: Nat, -r: Nat, e: {a == Nat.add(b, r) : Nat})
  -> {Nat.double(a) == Nat.add(Nat.double(b), Nat.double(r)) : Nat}:
  Equal.trans(Nat, Nat.double(a), Nat.double(Nat.add(b, r)),
    Nat.add(Nat.double(b), Nat.double(r)),
    Equal.cong(Nat, Nat, Nat.double, a, Nat.add(b, r), e), double_add(b, r))

def double_borrow(-a: Nat, +b: Nat, -r: Nat,
  e: {a == Nat.add(b, 1n+r) : Nat})
  -> {Nat.double(a) == 2n+Nat.add(Nat.double(b), Nat.double(r)) : Nat}:
  Equal.trans(Nat, Nat.double(a), Nat.add(Nat.double(b), 2n+Nat.double(r)),
    2n+Nat.add(Nat.double(b), Nat.double(r)), double_sum(a, b, 1n+r, e),
    Equal.trans(Nat, Nat.add(Nat.double(b), 2n+Nat.double(r)),
      1n+Nat.add(Nat.double(b), 1n+Nat.double(r)),
      2n+Nat.add(Nat.double(b), Nat.double(r)),
      add_right_succ(Nat.double(b), 1n+Nat.double(r)),
      Equal.cong(Nat, Nat, x => 1n+x,
        Nat.add(Nat.double(b), 1n+Nat.double(r)),
        1n+Nat.add(Nat.double(b), Nat.double(r)),
        add_right_succ(Nat.double(b), Nat.double(r)))))

def even_borrow(-a: Nat, b: Nat, -r: Nat,
  e: {a == Nat.add(b, 1n+r) : Nat})
  -> {Nat.double(a) == Nat.add(Nat.double(b), 2n+Nat.double(r)) : Nat}:
  double_sum(a, b, 1n+r, e)

def even_borrow_left(-a: Nat, +b: Nat, -r: Nat,
  e: {a == Nat.add(b, 1n+r) : Nat})
  -> {Nat.double(a) == 1n+Nat.add(Nat.double(b), 1n+Nat.double(r)) : Nat}:
  Equal.trans(Nat, Nat.double(a), 2n+Nat.add(Nat.double(b), Nat.double(r)),
    1n+Nat.add(Nat.double(b), 1n+Nat.double(r)), double_borrow(a, b, r, e),
    Equal.cong(Nat, Nat, x => 1n+x,
      1n+Nat.add(Nat.double(b), Nat.double(r)),
      Nat.add(Nat.double(b), 1n+Nat.double(r)),
      Equal.sym(Nat, Nat.add(Nat.double(b), 1n+Nat.double(r)),
        1n+Nat.add(Nat.double(b), Nat.double(r)),
        add_right_succ(Nat.double(b), Nat.double(r)))))

def odd_sum(-a: Nat, +b: Nat, -r: Nat, e: {a == Nat.add(b, r) : Nat})
  -> {1n+Nat.double(a) == Nat.add(Nat.double(b), 1n+Nat.double(r)) : Nat}:
  Equal.trans(Nat, 1n+Nat.double(a), 1n+Nat.add(Nat.double(b), Nat.double(r)),
    Nat.add(Nat.double(b), 1n+Nat.double(r)),
    Equal.cong(Nat, Nat, x => 1n+x, Nat.double(a),
      Nat.add(Nat.double(b), Nat.double(r)), double_sum(a, b, r, e)),
    Equal.sym(Nat, Nat.add(Nat.double(b), 1n+Nat.double(r)),
      1n+Nat.add(Nat.double(b), Nat.double(r)),
      add_right_succ(Nat.double(b), Nat.double(r))))

def allowed(carry: Bool, order: Cmp) -> Bool:
  match carry:
    case True{}:
      Cmp.is_ge(order)
    case False{}:
      Cmp.is_gt(order)

def borrow(carry: Bool) -> Nat:
  match carry:
    case True{}:
      0n
    case False{}:
      1n

def guard.same(order: Cmp, bit: Bool, carry: Bool,
  ok: {allowed(carry, Word.cmp.fin(bit, bit, order)) == True{} : Bool})
  -> {allowed(carry, order) == True{} : Bool}:
  match order bit:
    case LT{} _:
      ok
    case EQ{} False{}:
      ok
    case EQ{} True{}:
      ok
    case GT{} _:
      ok

def guard.less(order: Cmp, carry: Bool,
  ok: {allowed(carry, Word.cmp.fin(False{}, True{}, order)) == True{} : Bool})
  -> {allowed(False{}, order) == True{} : Bool}:
  match order carry:
    case LT{} False{}:
      ok
    case LT{} True{}:
      ok
    case EQ{} False{}:
      ok
    case EQ{} True{}:
      ok
    case GT{} _:
      {==}

def guard.greater(order: Cmp, carry: Bool,
  ok: {allowed(carry, Word.cmp.fin(True{}, False{}, order)) == True{} : Bool})
  -> {allowed(True{}, order) == True{} : Bool}:
  match order carry:
    case LT{} False{}:
      ok
    case LT{} True{}:
      ok
    case EQ{} _:
      {==}
    case GT{} _:
      {==}

law word_debit:
  for +n: Nat
  for a: Word(n)
  for b: Word(n)
  for carry: Bool
  for ok: {allowed(carry, Word.cmp(n, a, b)) == True{} : Bool}
  {Word.to_nat(n, a) == Nat.add(Word.to_nat(n, b),
    Nat.add(borrow(carry), Word.to_nat(n, Word.adc(n, a, b, True{}, carry)))) : Nat}

def word_debit(n, a, b, carry, ok):
  match n:
    case 0n:
      match a b carry:
        case WNil{} WNil{} True{}:
          {==}
        case WNil{} WNil{} False{}:
          Empty.absurd({0n == 1n : Nat}, false_is_not_true(ok))
    case 1n+p:
      match a b carry:
        case WCon{False{}, +at} WCon{False{}, +bt} False{}:
          even_borrow(Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, True{}, False{})),
            word_debit(p, at, bt, False{},
              guard.same(Word.cmp(p, at, bt), False{}, False{}, ok)))
        case WCon{False{}, +at} WCon{False{}, +bt} True{}:
          double_sum(Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, True{}, True{})),
            word_debit(p, at, bt, True{},
              guard.same(Word.cmp(p, at, bt), False{}, True{}, ok)))
        case WCon{False{}, +at} WCon{True{}, +bt} False{}:
          even_borrow_left(Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, True{}, False{})),
            word_debit(p, at, bt, False{},
              guard.less(Word.cmp(p, at, bt), False{}, ok)))
        case WCon{False{}, +at} WCon{True{}, +bt} True{}:
          even_borrow_left(Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, True{}, False{})),
            word_debit(p, at, bt, False{},
              guard.less(Word.cmp(p, at, bt), True{}, ok)))
        case WCon{True{}, +at} WCon{False{}, +bt} False{}:
          odd_sum(Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, True{}, True{})),
            word_debit(p, at, bt, True{},
              guard.greater(Word.cmp(p, at, bt), False{}, ok)))
        case WCon{True{}, +at} WCon{False{}, +bt} True{}:
          odd_sum(Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, True{}, True{})),
            word_debit(p, at, bt, True{},
              guard.greater(Word.cmp(p, at, bt), True{}, ok)))
        case WCon{True{}, +at} WCon{True{}, +bt} False{}:
          Equal.cong(Nat, Nat, x => 1n+x, Nat.double(Word.to_nat(p, at)),
            Nat.add(Nat.double(Word.to_nat(p, bt)),
              2n+Nat.double(Word.to_nat(p, Word.adc(p, at, bt, True{}, False{})))),
            even_borrow(Word.to_nat(p, at), Word.to_nat(p, bt),
              Word.to_nat(p, Word.adc(p, at, bt, True{}, False{})),
              word_debit(p, at, bt, False{},
                guard.same(Word.cmp(p, at, bt), True{}, False{}, ok))))
        case WCon{True{}, +at} WCon{True{}, +bt} True{}:
          Equal.cong(Nat, Nat, x => 1n+x, Nat.double(Word.to_nat(p, at)),
            Nat.add(Nat.double(Word.to_nat(p, bt)),
              Nat.double(Word.to_nat(p, Word.adc(p, at, bt, True{}, True{})))),
            double_sum(Word.to_nat(p, at), Word.to_nat(p, bt),
              Word.to_nat(p, Word.adc(p, at, bt, True{}, True{})),
              word_debit(p, at, bt, True{},
                guard.same(Word.cmp(p, at, bt), True{}, True{}, ok))))

def safe_sub_ge(a: U32, b: U32, ok: {U32.is_ge(a, b) == True{} : Bool})
  -> {U32.to_nat(a) == Nat.add(U32.to_nat(b), U32.to_nat(U32.sub(a, b))) : Nat}:
  match a b:
    case U32{x} U32{y}:
      word_debit(32n, x, y, True{}, ok)

def cmp_flip(c: Cmp) -> Cmp:
  match c:
    case LT{}:
      GT{}
    case EQ{}:
      EQ{}
    case GT{}:
      LT{}

def cmp_flip.fin(t: Cmp, a: Bool, b: Bool)
  -> {Word.cmp.fin(a, b, cmp_flip(t)) == cmp_flip(Word.cmp.fin(b, a, t)) : Cmp}:
  match t a b:
    case LT{} _ _:
      {==}
    case GT{} _ _:
      {==}
    case EQ{} False{} False{}:
      {==}
    case EQ{} False{} True{}:
      {==}
    case EQ{} True{} False{}:
      {==}
    case EQ{} True{} True{}:
      {==}

def word_cmp_flip(+n: Nat, a: Word(n), b: Word(n))
  -> {Word.cmp(n, a, b) == cmp_flip(Word.cmp(n, b, a)) : Cmp}:
  match n:
    case 0n:
      match a b:
        case WNil{} WNil{}:
          {==}
    case 1n+p:
      match a b:
        case WCon{+ah, +at} WCon{+bh, +bt}:
          Equal.trans(Cmp, Word.cmp.fin(ah, bh, Word.cmp(p, at, bt)),
            Word.cmp.fin(ah, bh, cmp_flip(Word.cmp(p, bt, at))),
            cmp_flip(Word.cmp.fin(bh, ah, Word.cmp(p, bt, at))),
            Equal.cong(Cmp, Cmp, t => Word.cmp.fin(ah, bh, t),
              Word.cmp(p, at, bt), cmp_flip(Word.cmp(p, bt, at)),
              word_cmp_flip(p, at, bt)), cmp_flip.fin(Word.cmp(p, bt, at), ah, bh))

def not_gt_ge(order: Cmp, ok: {Cmp.is_gt(order) == False{} : Bool})
  -> {Cmp.is_ge(cmp_flip(order)) == True{} : Bool}:
  match order:
    case LT{}:
      {==}
    case EQ{}:
      {==}
    case GT{}:
      Empty.absurd({False{} == True{} : Bool},
        false_is_not_true(Equal.sym(Bool, True{}, False{}, ok)))

def safe_sub_not_gt(a: U32, b: U32, ok: {U32.is_gt(b, a) == False{} : Bool})
  -> {U32.to_nat(a) == Nat.add(U32.to_nat(b), U32.to_nat(U32.sub(a, b))) : Nat}:
  match a b:
    case U32{+x} U32{+y}:
      safe_sub_ge(U32{x}, U32{y},
        Equal.trans(Bool, Cmp.is_ge(Word.cmp(32n, x, y)),
          Cmp.is_ge(cmp_flip(Word.cmp(32n, y, x))), True{},
          Equal.cong(Cmp, Bool, Cmp.is_ge, Word.cmp(32n, x, y),
            cmp_flip(Word.cmp(32n, y, x)), word_cmp_flip(32n, x, y)),
          not_gt_ge(Word.cmp(32n, y, x), ok)))

def zero_cmp.step(order: Cmp, bit: Bool,
  ok: {Cmp.is_lt(order) == False{} : Bool})
  -> {Cmp.is_lt(Word.cmp.fin(bit, False{}, order)) == False{} : Bool}:
  match order bit:
    case LT{} _:
      ok
    case EQ{} False{}:
      {==}
    case EQ{} True{}:
      {==}
    case GT{} _:
      {==}

def word_zero_cmp(+n: Nat, a: Word(n))
  -> {Cmp.is_lt(Word.cmp(n, a, Word.zero(n))) == False{} : Bool}:
  match n:
    case 0n:
      match a:
        case WNil{}:
          {==}
    case 1n+p:
      match a:
        case WCon{bit, +tail}:
          zero_cmp.step(Word.cmp(p, tail, Word.zero(p)), bit, word_zero_cmp(p, tail))

def positive_ge_one.if(order: Cmp, bit: Bool,
  nonnegative: {Cmp.is_lt(order) == False{} : Bool},
  positive: {Cmp.is_eq(Word.cmp.fin(bit, False{}, order)) == False{} : Bool})
  -> {Cmp.is_ge(Word.cmp.fin(bit, True{}, order)) == True{} : Bool}:
  match order bit:
    case LT{} _:
      Empty.absurd({False{} == True{} : Bool},
        false_is_not_true(Equal.sym(Bool, True{}, False{}, nonnegative)))
    case EQ{} False{}:
      Empty.absurd({False{} == True{} : Bool},
        false_is_not_true(Equal.sym(Bool, True{}, False{}, positive)))
    case EQ{} True{}:
      {==}
    case GT{} _:
      {==}

def positive_ge_one(a: U32, ok: {U32.is_zero(a) == False{} : Bool})
  -> {U32.is_ge(a, 1) == True{} : Bool}:
  match a:
    case U32{WCon{bit, +tail}}:
      positive_ge_one.if(Word.cmp(31n, tail, Word.zero(31n)), bit,
        word_zero_cmp(31n, tail), ok)

def safe_sub_one(+a: U32, ok: {U32.is_zero(a) == False{} : Bool})
  -> {U32.to_nat(a) == 1n+U32.to_nat(U32.sub(a, 1)) : Nat}:
  safe_sub_ge(a, 1, positive_ge_one(a, ok))

law strict_debit:
  for a: U32
  for b: U32
  for ok: {U32.is_gt(a, b) == True{} : Bool}
  exs rest: Nat
  {U32.to_nat(a) == Nat.add(U32.to_nat(b), 1n+rest) : Nat}

def strict_debit(a, b, ok):
  match a b:
    case U32{+x} U32{+y}:
      (Word.to_nat(32n, Word.adc(32n, x, y, True{}, False{})),
        word_debit(32n, x, y, False{}, ok))

def not_ge_gt(order: Cmp, ok: {Cmp.is_ge(order) == False{} : Bool})
  -> {Cmp.is_gt(cmp_flip(order)) == True{} : Bool}:
  match order:
    case LT{}:
      {==}
    case EQ{}:
      Empty.absurd({False{} == True{} : Bool},
        false_is_not_true(Equal.sym(Bool, True{}, False{}, ok)))
    case GT{}:
      Empty.absurd({False{} == True{} : Bool},
        false_is_not_true(Equal.sym(Bool, True{}, False{}, ok)))

law strict_debit_not_ge:
  for a: U32
  for b: U32
  for ok: {U32.is_ge(a, b) == False{} : Bool}
  exs rest: Nat
  {U32.to_nat(b) == Nat.add(U32.to_nat(a), 1n+rest) : Nat}

def strict_debit_not_ge(a, b, ok):
  match a b:
    case U32{+x} U32{+y}:
      strict_debit(U32{y}, U32{x},
        Equal.trans(Bool, Cmp.is_gt(Word.cmp(32n, y, x)),
          Cmp.is_gt(cmp_flip(Word.cmp(32n, x, y))), True{},
          Equal.cong(Cmp, Bool, Cmp.is_gt, Word.cmp(32n, y, x),
            cmp_flip(Word.cmp(32n, x, y)), word_cmp_flip(32n, y, x)),
          not_ge_gt(Word.cmp(32n, x, y), ok)))
