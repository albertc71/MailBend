# Proofs about the real admission fold and scalar escape accounting.

import Base
import ./budget-observers.bend as Budget
import ./budget-arithmetic.bend as Arithmetic
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/image.bend as Image
import ../../src/response.bend as Response

def add_assoc(a: Nat, -b: Nat, -c: Nat)
  -> {Nat.add(a, Nat.add(b, c)) == Nat.add(Nat.add(a, b), c) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, n => 1n+n, Nat.add(p, Nat.add(b, c)),
        Nat.add(Nat.add(p, b), c), add_assoc(p, b, c))

def chain(-initial: Nat, head: Nat, -middle: Nat, -tail: Nat, -last: Nat,
  first: {initial == Nat.add(head, middle) : Nat},
  rest: {middle == Nat.add(tail, last) : Nat})
  -> {initial == Nat.add(Nat.add(head, tail), last) : Nat}:
  %Equal.sym(Nat, initial, Nat.add(head, middle), first) :
    {_ == Nat.add(Nat.add(head, tail), last) : Nat}
  %Equal.sym(Nat, middle, Nat.add(tail, last), rest) :
    {Nat.add(head, _) == Nat.add(Nat.add(head, tail), last) : Nat}
  add_assoc(head, tail, last)

def add_bound(a: Nat, b: Nat) -> {Nat.is_le(a, Nat.add(a, b)) == True{} : Bool}:
  match a b:
    case 0n 0n:
      {==}
    case 0n 1n+p:
      {==}
    case 1n+p _:
      add_bound(p, b)

def conserved_bound(-initial: Nat, +used: Nat, +left: Nat,
  e: {initial == Nat.add(used, left) : Nat})
  -> {Nat.is_le(used, initial) == True{} : Bool}:
  %Equal.sym(Nat, initial, Nat.add(used, left), e) :
    {Nat.is_le(used, _) == True{} : Bool}
  add_bound(used, left)

def step_count(a: Image.Admitted) -> Nat:
  match a:
    case Image.Take{still, room}:
      1n
    case Image.Leave{section, name, reason, room}:
      0n

def still_bytes(s: Image.Still) -> U32:
  Image.Still{section, name, format, px, data, removed} = s
  C.byte_len(data)

def step_bytes(a: Image.Admitted) -> Nat:
  match a:
    case Image.Take{Image.Still{section, name, format, px, data, removed}, room}:
      U32.to_nat(C.byte_len(data))
    case Image.Leave{section, name, reason, room}:
      0n

def step_conserved(+before: Image.Room, +a: Image.Admitted) -> Type:
  {U32.to_nat(Budget.count(before)) == Nat.add(step_count(a),
    U32.to_nat(Budget.count(Budget.room(a)))) : Nat} &
  {U32.to_nat(Budget.bytes(before)) == Nat.add(step_bytes(a),
    U32.to_nat(Budget.bytes(Budget.room(a)))) : Nat}

def all_conserved(+before: Image.Room, +a: Budget.Admission) -> Type:
  {U32.to_nat(Budget.count(before)) == Nat.add(List.length(&2, Image.Still,
    Budget.stills(a)), U32.to_nat(Budget.count(Budget.remaining(a)))) : Nat} &
  {U32.to_nat(Budget.bytes(before)) == Nat.add(Budget.measured_bytes(Budget.stills(a)),
    U32.to_nat(Budget.bytes(Budget.remaining(a)))) : Nat}

def admit_conserves.budget(over: Bool, still: Image.Still, count: U32, bytes: U32,
  nonzero: {U32.is_zero(count) == False{} : Bool},
  fits: {U32.is_gt(still_bytes(still), bytes) == over : Bool})
  -> step_conserved(Image.Room{count, bytes}, Image.admit.budget(over, still, count, bytes)):
  match over still:
    case True{} Image.Still{section, name, format, px, data, removed}:
      ({==}, {==})
    case False{} Image.Still{section, name, format, px, data, removed}:
      (Arithmetic.safe_sub_one(count, nonzero),
       Arithmetic.safe_sub_not_gt(bytes, C.byte_len(data), fits))

def admit_conserves.count(none: Bool, still: Image.Still, count: U32, +bytes: U32,
  empty: {U32.is_zero(count) == none : Bool})
  -> step_conserved(Image.Room{count, bytes}, Image.admit.count(none, still, count, bytes)):
  match none still:
    case True{} Image.Still{section, name, format, px, data, removed}:
      ({==}, {==})
    case False{} Image.Still{section, name, format, px, +data, removed}:
      admit_conserves.budget(U32.is_gt(C.byte_len(data), bytes),
        Image.Still{section, name, format, px, data, removed}, count, bytes, empty, {==})

def admit_conserves(before: Image.Room, v: Image.Verdict)
  -> step_conserved(before, Image.admit(before, v)):
  match before v:
    case _ Image.VDrop{section, name, reason}:
      ({==}, {==})
    case Image.Room{+count, bytes} Image.Keep{still}:
      admit_conserves.count(U32.is_zero(count), still, count, bytes, {==})

def admit_all_conserves.put(-before: Image.Room, a: Image.Admitted, later: Budget.Admission,
  step: step_conserved(before, a), rest: all_conserved(Budget.room(a), later))
  -> all_conserved(before, Budget.admit_all.put(a, later)):
  match a later:
    case Image.Leave{section, name, reason, room} Budget.Admission{stills, final}:
      (sc, sb) = step
      (rc, rb) = rest
      (Equal.trans(Nat, U32.to_nat(Budget.count(before)), U32.to_nat(Budget.count(room)),
         Nat.add(List.length(&2, Image.Still, Budget.stills(later)),
           U32.to_nat(Budget.count(Budget.remaining(later)))), sc, rc),
       Equal.trans(Nat, U32.to_nat(Budget.bytes(before)), U32.to_nat(Budget.bytes(room)),
         Nat.add(Budget.measured_bytes(Budget.stills(later)),
           U32.to_nat(Budget.bytes(Budget.remaining(later)))), sb, rb))
    case Image.Take{Image.Still{section, name, format, px, data, removed}, +room}
      Budget.Admission{+stills, +final}:
      (sc, sb) = step
      (rc, rb) = rest
      (chain(U32.to_nat(Budget.count(before)), 1n, U32.to_nat(Budget.count(room)),
         List.length(&2, Image.Still, stills), U32.to_nat(Budget.count(final)), sc, rc),
       chain(U32.to_nat(Budget.bytes(before)), U32.to_nat(C.byte_len(data)),
         U32.to_nat(Budget.bytes(room)), Budget.measured_bytes(stills),
         U32.to_nat(Budget.bytes(final)), sb, rb))

def admit_all_conserves(vs: List<&2, Image.Verdict>, +before: Image.Room)
  -> all_conserved(before, Budget.admit_all(vs, before)):
  match vs:
    case Nil{}:
      ({==}, {==})
    case +v <> +rest:
      +a = Image.admit(before, v)
      admit_all_conserves.put(before, a, Budget.admit_all(rest, Budget.room(a)),
        admit_conserves(before, v), admit_all_conserves(rest, Budget.room(a)))

def measured_exact(ss: List<&2, Image.Still>, exact: Budget.lengths_exact(ss))
  -> {Budget.measured_bytes(ss) == Budget.exact_bytes(ss) : Nat}:
  match ss:
    case Nil{}:
      {==}
    case Image.Still{section, name, format, px, data, removed} <> t:
      (head, rest) = exact
      %head : {Nat.add(U32.to_nat(C.byte_len(data)), Budget.measured_bytes(t)) ==
        Nat.add(_, Budget.exact_bytes(t)) : Nat}
      %measured_exact(t, rest) :
        {Nat.add(U32.to_nat(C.byte_len(data)), Budget.measured_bytes(t)) ==
          Nat.add(U32.to_nat(C.byte_len(data)), _) : Nat}
      {==}

def prefix_conserved(left: U32, +p: Response.Prefix) -> Type:
  {U32.to_nat(left) == Nat.add(Budget.escaped_bytes(Budget.prefix_text(p)),
    U32.to_nat(Budget.prefix_left(p))) : Nat}

def prefix_conserves.put(enough: Bool, p: Response.Prefix, c: Char, +left: U32,
  safe: {U32.is_ge(left, C.utf8_len(J.esc_char(c))) == enough : Bool},
  rest: prefix_conserved(Bool.pick(U32, enough, (left - C.utf8_len(J.esc_char(c)) : U32),
    0), p)) -> prefix_conserved(left, Response.prefix.put(p, enough, c, left)):
  match enough p:
    case False{} Response.Prefix{part, remain}:
      {==}
    case True{} Response.Prefix{part, remain}:
      +n = C.utf8_len(J.esc_char(c))
      chain(U32.to_nat(left), U32.to_nat(n), U32.to_nat((left - n : U32)),
        Budget.escaped_bytes(part), U32.to_nat(remain), Arithmetic.safe_sub_ge(left, n, safe),
        rest)

def prefix_conserves.go(s: String, +left: U32, run: Bool)
  -> prefix_conserved(left, Response.prefix.go(s, left, run)):
  match s run:
    case _ False{}:
      {==}
    case SNil{} True{}:
      {==}
    case SCon{+c, +t} True{}:
      +n = C.utf8_len(J.esc_char(c))
      +enough = U32.is_ge(left, n)
      +next = Bool.pick(U32, enough, (left - n : U32), 0)
      prefix_conserves.put(enough, Response.prefix.go(t, next, enough), c, left, {==},
        prefix_conserves.go(t, next, enough))

def prefix_conserves(s: String, left: U32) -> prefix_conserved(left, Response.prefix(s, left)):
  prefix_conserves.go(s, left, True{})

def zero_type(n: Nat) -> Type:
  match n:
    case 0n:
      Empty
    case 1n+p:
      Unit

def succ_not_zero(-n: Nat, e: {1n+n == 0n : Nat}) -> Empty:
  %e : zero_type(_)
  Unit{}

def pred(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      p

def no_cycle(a: Nat, b: Nat, -rest: Nat, -extra: Nat,
  enough: {a == Nat.add(b, extra) : Nat},
  over: {b == Nat.add(a, 1n+rest) : Nat}) -> Empty:
  match a b:
    case 0n 0n:
      succ_not_zero(rest, Equal.sym(Nat, 0n, 1n+rest, over))
    case 0n 1n+q:
      succ_not_zero(Nat.add(q, extra), Equal.sym(Nat, 0n, 1n+Nat.add(q, extra), enough))
    case 1n+p 0n:
      succ_not_zero(Nat.add(p, 1n+rest),
        Equal.sym(Nat, 0n, 1n+Nat.add(p, 1n+rest), over))
    case 1n+p 1n+q:
      no_cycle(p, q, rest, extra,
        Equal.cong(Nat, Nat, pred, 1n+p, 1n+Nat.add(q, extra), enough),
        Equal.cong(Nat, Nat, pred, 1n+q, 1n+Nat.add(p, 1n+rest), over))

def add_cancel_left(a: Nat, -b: Nat, -c: Nat,
  e: {Nat.add(a, b) == Nat.add(a, c) : Nat}) -> {b == c : Nat}:
  match a:
    case 0n:
      e
    case 1n+p:
      add_cancel_left(p, b, c,
        Equal.cong(Nat, Nat, pred, 1n+Nat.add(p, b), 1n+Nat.add(p, c), e))

def head_room(-left: Nat, +head: Nat, -tail: Nat, -extra: Nat,
  e: {left == Nat.add(Nat.add(head, tail), extra) : Nat})
  -> {left == Nat.add(head, Nat.add(tail, extra)) : Nat}:
  Equal.trans(Nat, left, Nat.add(Nat.add(head, tail), extra),
    Nat.add(head, Nat.add(tail, extra)), e,
    Equal.sym(Nat, Nat.add(head, Nat.add(tail, extra)),
      Nat.add(Nat.add(head, tail), extra), add_assoc(head, tail, extra)))

def tail_room(-left: Nat, +head: Nat, -tail: Nat, -extra: Nat, -remaining: Nat,
  debit: {left == Nat.add(head, remaining) : Nat},
  enough: {left == Nat.add(Nat.add(head, tail), extra) : Nat})
  -> {remaining == Nat.add(tail, extra) : Nat}:
  add_cancel_left(head, remaining, Nat.add(tail, extra),
    Equal.trans(Nat, Nat.add(head, remaining), left, Nat.add(head, Nat.add(tail, extra)),
      Equal.sym(Nat, left, Nat.add(head, remaining), debit),
      head_room(left, head, tail, extra, enough)))

def whole(s: String, +p: Response.Prefix, extra: Nat) -> Type:
  {Budget.prefix_text(p) == s : String} & {U32.to_nat(Budget.prefix_left(p)) == extra : Nat}

law prefix_whole:
  for s: String
  for +left: U32
  for +extra: Nat
  for enough: {U32.to_nat(left) == Nat.add(Budget.escaped_bytes(s), extra) : Nat}
  whole(s, Response.prefix(s, left), extra)

def prefix_whole.put(p: Response.Prefix, -c: Char, -left: U32, -tail: String,
  -extra: Nat, e: whole(tail, p, extra))
  -> whole(SCon{c, tail}, Response.prefix.put(p, True{}, c, left), extra):
  match p:
    case Response.Prefix{text, remain}:
      (same, rest) = e
      (Equal.cong(String, String, s => SCon{c, s}, text, tail, same), rest)

def prefix_whole.over(c: Char, tail: String, +left: U32, extra: Nat,
  enough: {U32.to_nat(left) == Nat.add(Budget.escaped_bytes(SCon{c, tail}), extra) : Nat},
  debit: &rest: Nat -> {U32.to_nat(C.utf8_len(J.esc_char(c))) ==
    Nat.add(U32.to_nat(left), 1n+rest) : Nat})
  -> whole(SCon{c, tail}, Response.Prefix{"", left}, extra):
  (rest, over) = debit
  +n = C.utf8_len(J.esc_char(c))
  Empty.absurd(whole(SCon{c, tail}, Response.Prefix{"", left}, extra),
    no_cycle(U32.to_nat(left), U32.to_nat(n), rest,
      Nat.add(Budget.escaped_bytes(tail), extra),
      head_room(U32.to_nat(left), U32.to_nat(n), Budget.escaped_bytes(tail), extra, enough),
      over))

def prefix_stopped(s: String, -left: U32)
  -> {Response.prefix.go(s, left, False{}) == Response.Prefix{"", left} : Response.Prefix}:
  match s:
    case SNil{}:
      {==}
    case SCon{c, tail}:
      {==}

def prefix_whole.if(ok: Bool, +c: Char, +tail: String, +left: U32, +extra: Nat,
  guard: {U32.is_ge(left, C.utf8_len(J.esc_char(c))) == ok : Bool},
  enough: {U32.to_nat(left) == Nat.add(Budget.escaped_bytes(SCon{c, tail}), extra) : Nat},
  recur: @remaining: U32 ->
    {U32.to_nat(remaining) == Nat.add(Budget.escaped_bytes(tail), extra) : Nat} ->
    whole(tail, Response.prefix(tail, remaining), extra))
  -> whole(SCon{c, tail}, Response.prefix.put(Response.prefix.go(tail,
    Bool.pick(U32, ok, (left - C.utf8_len(J.esc_char(c)) : U32), 0), ok), ok, c, left), extra):
  match ok:
    case False{}:
      %Equal.sym(Response.Prefix, Response.prefix.go(tail, 0, False{}),
        Response.Prefix{"", 0}, prefix_stopped(tail, 0)) :
        whole(SCon{c, tail}, Response.prefix.put(_, False{}, c, left), extra)
      prefix_whole.over(c, tail, left, extra, enough,
        Arithmetic.strict_debit_not_ge(left, C.utf8_len(J.esc_char(c)), guard))
    case True{}:
      +n = C.utf8_len(J.esc_char(c))
      +remaining = (left - n : U32)
      prefix_whole.put(Response.prefix(tail, remaining), c, left, tail, extra,
        recur(remaining,
          tail_room(U32.to_nat(left), U32.to_nat(n), Budget.escaped_bytes(tail), extra,
            U32.to_nat(remaining), Arithmetic.safe_sub_ge(left, n, guard), enough)))

def prefix_whole(s, left, extra, enough):
  match s:
    case SNil{}:
      ({==}, enough)
    case SCon{+c, +tail}:
      prefix_whole.if(U32.is_ge(left, C.utf8_len(J.esc_char(c))), c, tail, left, extra,
        {==}, enough, remaining => fits => prefix_whole(tail, remaining, extra, fits))
