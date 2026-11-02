# Natural-number conservation for the actual machine-word addition.

import Base
import ./budget-arithmetic.bend as Arithmetic

def bit(b: Bool) -> Nat:
  match b:
    case False{}:
      0n
    case True{}:
      1n

def carry(n: Nat, a: Word(n), b: Word(n), incoming: Bool) -> Bool:
  match n:
    case 0n:
      incoming
    case 1n+p:
      match a b:
        case WCon{ah, at} WCon{bh, bt}:
          carry(p, at, bt, Pair.snd(Bool, Bool, Bool.full_add(ah, bh, incoming)))

def overflow(a: U32, b: U32) -> Bool:
  match a b:
    case U32{x} U32{y}:
      carry(32n, x, y, False{})

# Normalize the eight possible low-bit addition cases. The tail equality
# is supplied by induction on Word.adc, not assumed about U32.add.
def lift_bits(ah: Bool, bh: Bool, incoming: Bool, +a: Nat, +b: Nat)
  -> {Nat.add(bit(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming))),
        Nat.double(Nat.add(bit(Pair.snd(Bool, Bool, Bool.full_add(ah, bh, incoming))),
          Nat.add(a, b)))) ==
      Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
        Nat.add(bit(bh), Nat.double(b)))) : Nat}:
  match ah bh incoming:
    case False{} False{} False{}:
      Arithmetic.double_add(a, b)
    case False{} False{} True{}:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.double(Nat.add(a, b)),
        Nat.add(Nat.double(a), Nat.double(b)), Arithmetic.double_add(a, b))
    case False{} True{} False{}:
      Arithmetic.odd_sum(Nat.add(a, b), a, b, {==})
    case False{} True{} True{}:
      Equal.cong(Nat, Nat, x => 1n+x, 1n+Nat.double(Nat.add(a, b)),
        Nat.add(Nat.double(a), 1n+Nat.double(b)),
        Arithmetic.odd_sum(Nat.add(a, b), a, b, {==}))
    case True{} False{} False{}:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.double(Nat.add(a, b)),
        Nat.add(Nat.double(a), Nat.double(b)), Arithmetic.double_add(a, b))
    case True{} False{} True{}:
      Equal.cong(Nat, Nat, x => 2n+x, Nat.double(Nat.add(a, b)),
        Nat.add(Nat.double(a), Nat.double(b)), Arithmetic.double_add(a, b))
    case True{} True{} False{}:
      Equal.cong(Nat, Nat, x => 1n+x, 1n+Nat.double(Nat.add(a, b)),
        Nat.add(Nat.double(a), 1n+Nat.double(b)),
        Arithmetic.odd_sum(Nat.add(a, b), a, b, {==}))
    case True{} True{} True{}:
      Equal.cong(Nat, Nat, x => 2n+x, 1n+Nat.double(Nat.add(a, b)),
        Nat.add(Nat.double(a), 1n+Nat.double(b)),
        Arithmetic.odd_sum(Nat.add(a, b), a, b, {==}))

def lift(+ah: Bool, +bh: Bool, +incoming: Bool, +a: Nat, +b: Nat, -r: Nat,
  tail: {r == Nat.add(bit(Pair.snd(Bool, Bool, Bool.full_add(ah, bh, incoming))),
    Nat.add(a, b)) : Nat})
  -> {Nat.add(bit(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming))),
        Nat.double(r)) ==
      Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
        Nat.add(bit(bh), Nat.double(b)))) : Nat}:
  %Equal.sym(Nat, r,
    Nat.add(bit(Pair.snd(Bool, Bool, Bool.full_add(ah, bh, incoming))), Nat.add(a, b)),
    tail) :
    {Nat.add(bit(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming))), Nat.double(_)) ==
      Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
        Nat.add(bit(bh), Nat.double(b)))) : Nat}
  lift_bits(ah, bh, incoming, a, b)

law adc_exact:
  for +n: Nat
  for +a: Word(n)
  for +b: Word(n)
  for +incoming: Bool
  for clear: {carry(n, a, b, incoming) == False{} : Bool}
  {Word.to_nat(n, Word.adc(n, a, b, False{}, incoming)) ==
    Nat.add(bit(incoming), Nat.add(Word.to_nat(n, a), Word.to_nat(n, b))) : Nat}

def adc_exact(n, a, b, incoming, clear):
  match n:
    case 0n:
      match a b incoming:
        case WNil{} WNil{} False{}:
          {==}
        case WNil{} WNil{} True{}:
          Empty.absurd({0n == 1n : Nat}, Arithmetic.false_is_not_true(
            Equal.sym(Bool, True{}, False{}, clear)))
    case 1n+p:
      match a b incoming:
        case WCon{False{}, +at} WCon{False{}, +bt} False{}:
          lift(False{}, False{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, False{})),
            adc_exact(p, at, bt, False{}, clear))
        case WCon{False{}, +at} WCon{False{}, +bt} True{}:
          lift(False{}, False{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, False{})),
            adc_exact(p, at, bt, False{}, clear))
        case WCon{False{}, +at} WCon{True{}, +bt} False{}:
          lift(False{}, True{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, False{})),
            adc_exact(p, at, bt, False{}, clear))
        case WCon{False{}, +at} WCon{True{}, +bt} True{}:
          lift(False{}, True{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, True{})),
            adc_exact(p, at, bt, True{}, clear))
        case WCon{True{}, +at} WCon{False{}, +bt} False{}:
          lift(True{}, False{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, False{})),
            adc_exact(p, at, bt, False{}, clear))
        case WCon{True{}, +at} WCon{False{}, +bt} True{}:
          lift(True{}, False{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, True{})),
            adc_exact(p, at, bt, True{}, clear))
        case WCon{True{}, +at} WCon{True{}, +bt} False{}:
          lift(True{}, True{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, True{})),
            adc_exact(p, at, bt, True{}, clear))
        case WCon{True{}, +at} WCon{True{}, +bt} True{}:
          lift(True{}, True{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            Word.to_nat(p, Word.adc(p, at, bt, False{}, True{})),
            adc_exact(p, at, bt, True{}, clear))

def safe_add(a: U32, b: U32, clear: {overflow(a, b) == False{} : Bool})
  -> {U32.to_nat(U32.add(a, b)) == Nat.add(U32.to_nat(a), U32.to_nat(b)) : Nat}:
  match a b:
    case U32{x} U32{y}:
      adc_exact(32n, x, y, False{}, clear)

def power(n: Nat) -> Nat:
  match n:
    case 0n:
      1n
    case 1n+p:
      Nat.double(power(p))

def doubled(s: Bool, +a: Nat, +b: Nat)
  -> {Nat.add(bit(s), Nat.double(Nat.add(a, b))) ==
      Nat.add(Nat.double(a), Nat.add(bit(s), Nat.double(b))) : Nat}:
  match s:
    case False{}:
      Arithmetic.double_add(a, b)
    case True{}:
      Arithmetic.odd_sum(Nat.add(a, b), a, b, {==})

def overflow_lift(+ah: Bool, +bh: Bool, +incoming: Bool, +a: Nat, +b: Nat,
  +p: Nat, +extra: Nat,
  tail: {Nat.add(bit(Pair.snd(Bool, Bool, Bool.full_add(ah, bh, incoming))),
    Nat.add(a, b)) == Nat.add(power(p), extra) : Nat})
  -> {Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
        Nat.add(bit(bh), Nat.double(b)))) ==
      Nat.add(power(1n+p), Nat.add(bit(Pair.fst(Bool, Bool,
        Bool.full_add(ah, bh, incoming))), Nat.double(extra))) : Nat}:
  Equal.trans(Nat,
    Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
      Nat.add(bit(bh), Nat.double(b)))),
    Nat.add(bit(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming))),
      Nat.double(Nat.add(power(p), extra))),
    Nat.add(power(1n+p), Nat.add(bit(Pair.fst(Bool, Bool,
      Bool.full_add(ah, bh, incoming))), Nat.double(extra))),
    Equal.sym(Nat,
      Nat.add(bit(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming))),
        Nat.double(Nat.add(power(p), extra))),
      Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
        Nat.add(bit(bh), Nat.double(b)))),
      lift(ah, bh, incoming, a, b, Nat.add(power(p), extra),
        Equal.sym(Nat, Nat.add(bit(Pair.snd(Bool, Bool,
          Bool.full_add(ah, bh, incoming))), Nat.add(a, b)),
          Nat.add(power(p), extra), tail))),
    doubled(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming)), power(p), extra))

def overflow_finish(+ah: Bool, +bh: Bool, +incoming: Bool, +a: Nat, +b: Nat, +p: Nat,
  bound: Exists(Nat, extra =>
    {Nat.add(bit(Pair.snd(Bool, Bool, Bool.full_add(ah, bh, incoming))), Nat.add(a, b)) ==
      Nat.add(power(p), extra) : Nat}))
  -> Exists(Nat, extra =>
    {Nat.add(bit(incoming), Nat.add(Nat.add(bit(ah), Nat.double(a)),
      Nat.add(bit(bh), Nat.double(b)))) == Nat.add(power(1n+p), extra) : Nat}):
  (+extra, proof) = bound
  (Nat.add(bit(Pair.fst(Bool, Bool, Bool.full_add(ah, bh, incoming))), Nat.double(extra)),
    overflow_lift(ah, bh, incoming, a, b, p, extra, proof))

law overflow_bound:
  for +n: Nat
  for +a: Word(n)
  for +b: Word(n)
  for +incoming: Bool
  for set: {carry(n, a, b, incoming) == True{} : Bool}
  exs extra: Nat
  {Nat.add(bit(incoming), Nat.add(Word.to_nat(n, a), Word.to_nat(n, b))) ==
    Nat.add(power(n), extra) : Nat}

def overflow_bound(n, a, b, incoming, set):
  match n:
    case 0n:
      match a b incoming:
        case WNil{} WNil{} False{}:
          Empty.absurd(Exists(Nat, extra => {0n == Nat.add(1n, extra) : Nat}),
            Arithmetic.false_is_not_true(set))
        case WNil{} WNil{} True{}:
          (0n, {==})
    case 1n+p:
      match a b incoming:
        case WCon{False{}, +at} WCon{False{}, +bt} False{}:
          overflow_finish(False{}, False{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, False{}, set))
        case WCon{False{}, +at} WCon{False{}, +bt} True{}:
          overflow_finish(False{}, False{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, False{}, set))
        case WCon{False{}, +at} WCon{True{}, +bt} False{}:
          overflow_finish(False{}, True{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, False{}, set))
        case WCon{False{}, +at} WCon{True{}, +bt} True{}:
          overflow_finish(False{}, True{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, True{}, set))
        case WCon{True{}, +at} WCon{False{}, +bt} False{}:
          overflow_finish(True{}, False{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, False{}, set))
        case WCon{True{}, +at} WCon{False{}, +bt} True{}:
          overflow_finish(True{}, False{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, True{}, set))
        case WCon{True{}, +at} WCon{True{}, +bt} False{}:
          overflow_finish(True{}, True{}, False{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, True{}, set))
        case WCon{True{}, +at} WCon{True{}, +bt} True{}:
          overflow_finish(True{}, True{}, True{}, Word.to_nat(p, at), Word.to_nat(p, bt),
            p, overflow_bound(p, at, bt, True{}, set))

def upper_double(-r: Nat, +a: Nat, +extra: Nat,
  upper: {r == 1n+Nat.add(a, extra) : Nat})
  -> {Nat.double(r) == 2n+Nat.add(Nat.double(a), Nat.double(extra)) : Nat}:
  Equal.trans(Nat, Nat.double(r), 2n+Nat.double(Nat.add(a, extra)),
    2n+Nat.add(Nat.double(a), Nat.double(extra)),
    Equal.cong(Nat, Nat, Nat.double, r, 1n+Nat.add(a, extra), upper),
    Equal.cong(Nat, Nat, x => 2n+x, Nat.double(Nat.add(a, extra)),
      Nat.add(Nat.double(a), Nat.double(extra)), Arithmetic.double_add(a, extra)))

def upper_finish(h: Bool, +p: Nat, +a: Nat,
  bound: Exists(Nat, extra => {power(p) == 1n+Nat.add(a, extra) : Nat}))
  -> Exists(Nat, extra =>
    {power(1n+p) == 1n+Nat.add(Nat.add(bit(h), Nat.double(a)), extra) : Nat}):
  match h:
    case False{}:
      (+extra, upper) = bound
      (1n+Nat.double(extra),
        Equal.trans(Nat, power(1n+p),
          2n+Nat.add(Nat.double(a), Nat.double(extra)),
          1n+Nat.add(Nat.double(a), 1n+Nat.double(extra)),
          upper_double(power(p), a, extra, upper),
          Equal.cong(Nat, Nat, x => 1n+x,
            1n+Nat.add(Nat.double(a), Nat.double(extra)),
            Nat.add(Nat.double(a), 1n+Nat.double(extra)),
            Equal.sym(Nat,
              Nat.add(Nat.double(a), 1n+Nat.double(extra)),
              1n+Nat.add(Nat.double(a), Nat.double(extra)),
              Arithmetic.add_right_succ(Nat.double(a),
                Nat.double(extra))))))
    case True{}:
      (+extra, upper) = bound
      (Nat.double(extra), upper_double(power(p), a, extra, upper))

law word_upper:
  for +n: Nat
  for +w: Word(n)
  exs extra: Nat
  {power(n) == 1n+Nat.add(Word.to_nat(n, w), extra) : Nat}

def word_upper(n, w):
  match n:
    case 0n:
      match w:
        case WNil{}:
          (0n, {==})
    case 1n+p:
      match w:
        case WCon{False{}, +tail}:
          upper_finish(False{}, p, Word.to_nat(p, tail), word_upper(p, tail))
        case WCon{True{}, +tail}:
          upper_finish(True{}, p, Word.to_nat(p, tail), word_upper(p, tail))

def assoc(a: Nat, -b: Nat, -c: Nat)
  -> {Nat.add(Nat.add(a, b), c) == Nat.add(a, Nat.add(b, c)) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.add(Nat.add(p, b), c),
        Nat.add(p, Nat.add(b, c)), assoc(p, b, c))

def zero_type(n: Nat) -> Type:
  match n:
    case 0n:
      Unit
    case 1n+p:
      Empty

def pred(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      p

def no_self_succ(a: Nat, extra: Nat, bad: {a == 1n+Nat.add(a, extra) : Nat}) -> Empty:
  match a:
    case 0n:
      %bad : zero_type(_)
      Unit{}
    case 1n+p:
      no_self_succ(p, extra,
        Equal.cong(Nat, Nat, pred, 1n+p, 1n+Nat.add(1n+p, extra), bad))

def bounded_not_over(+cap: Nat, +sum: Nat, +limit: Nat,
  +room: Nat, +upper_extra: Nat, +over_extra: Nat,
  fits: {cap == Nat.add(sum, room) : Nat},
  upper: {limit == 1n+Nat.add(cap, upper_extra) : Nat},
  over: {sum == Nat.add(limit, over_extra) : Nat}) -> Empty:
  no_self_succ(cap, Nat.add(upper_extra, Nat.add(over_extra, room)),
    Equal.trans(Nat, cap, Nat.add(sum, room),
      1n+Nat.add(cap, Nat.add(upper_extra, Nat.add(over_extra, room))), fits,
      Equal.trans(Nat, Nat.add(sum, room), Nat.add(Nat.add(limit, over_extra), room),
        1n+Nat.add(cap, Nat.add(upper_extra, Nat.add(over_extra, room))),
        Equal.cong(Nat, Nat, x => Nat.add(x, room), sum, Nat.add(limit, over_extra), over),
        Equal.trans(Nat, Nat.add(Nat.add(limit, over_extra), room),
          Nat.add(limit, Nat.add(over_extra, room)),
          1n+Nat.add(cap, Nat.add(upper_extra, Nat.add(over_extra, room))),
          assoc(limit, over_extra, room),
          Equal.trans(Nat, Nat.add(limit, Nat.add(over_extra, room)),
            1n+Nat.add(Nat.add(cap, upper_extra), Nat.add(over_extra, room)),
            1n+Nat.add(cap, Nat.add(upper_extra, Nat.add(over_extra, room))),
            Equal.cong(Nat, Nat, x => Nat.add(x, Nat.add(over_extra, room)),
              limit, 1n+Nat.add(cap, upper_extra), upper),
            Equal.cong(Nat, Nat, x => 1n+x,
              Nat.add(Nat.add(cap, upper_extra), Nat.add(over_extra, room)),
              Nat.add(cap, Nat.add(upper_extra, Nat.add(over_extra, room))),
              assoc(cap, upper_extra, Nat.add(over_extra, room))))))))

def clear_contradiction(+n: Nat, +a: Nat, +b: Nat, +cap: Nat, +room: Nat,
  overflowed: Exists(Nat, extra => {Nat.add(a, b) == Nat.add(power(n), extra) : Nat}),
  bounded: Exists(Nat, extra => {power(n) == 1n+Nat.add(cap, extra) : Nat}),
  fits: {cap == Nat.add(Nat.add(a, b), room) : Nat}) -> Empty:
  (over_extra, over) = overflowed
  (upper_extra, upper) = bounded
  bounded_not_over(cap, Nat.add(a, b), power(n),
    room, upper_extra, over_extra, fits, upper, over)

def word_clear.if(+n: Nat, out: Bool, +a: Word(n), +b: Word(n), +cap: Word(n), room: Nat,
  observed: {carry(n, a, b, False{}) == out : Bool},
  fits: {Word.to_nat(n, cap) ==
    Nat.add(Nat.add(Word.to_nat(n, a), Word.to_nat(n, b)), room) : Nat})
  -> {out == False{} : Bool}:
  match out:
    case False{}:
      {==}
    case True{}:
      Empty.absurd({True{} == False{} : Bool},
        clear_contradiction(n, Word.to_nat(n, a), Word.to_nat(n, b), Word.to_nat(n, cap),
          room, overflow_bound(n, a, b, False{}, observed), word_upper(n, cap), fits))

def word_clear(+n: Nat, +a: Word(n), +b: Word(n), cap: Word(n), room: Nat,
  fits: {Word.to_nat(n, cap) ==
    Nat.add(Nat.add(Word.to_nat(n, a), Word.to_nat(n, b)), room) : Nat})
  -> {carry(n, a, b, False{}) == False{} : Bool}:
  word_clear.if(n, carry(n, a, b, False{}), a, b, cap, room, {==}, fits)

def word_add_within(+n: Nat, +a: Word(n), +b: Word(n), cap: Word(n), room: Nat,
  fits: {Word.to_nat(n, cap) ==
    Nat.add(Nat.add(Word.to_nat(n, a), Word.to_nat(n, b)), room) : Nat})
  -> {Word.to_nat(n, Word.add(n, a, b)) ==
    Nat.add(Word.to_nat(n, a), Word.to_nat(n, b)) : Nat}:
  adc_exact(n, a, b, False{}, word_clear(n, a, b, cap, room, fits))

def clear_within(a: U32, b: U32, cap: U32, room: Nat,
  fits: {U32.to_nat(cap) == Nat.add(Nat.add(U32.to_nat(a), U32.to_nat(b)), room) : Nat})
  -> {overflow(a, b) == False{} : Bool}:
  match a b cap:
    case U32{x} U32{y} U32{z}:
      word_clear(32n, x, y, z, room, fits)

def add_within(a: U32, b: U32, cap: U32, room: Nat,
  fits: {U32.to_nat(cap) == Nat.add(Nat.add(U32.to_nat(a), U32.to_nat(b)), room) : Nat})
  -> {U32.to_nat(U32.add(a, b)) == Nat.add(U32.to_nat(a), U32.to_nat(b)) : Nat}:
  match a b cap:
    case U32{x} U32{y} U32{z}:
      word_add_within(32n, x, y, z, room, fits)
