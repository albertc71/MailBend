# Natural UTF-8 weight of the production reverse-accumulator JSON escape.

import Base
import ./budget-observers.bend as Budget
import ./budget-proofs.bend as BudgetProof
import ./budget-arithmetic.bend as Arithmetic
import ./scalar-atom-proofs.bend as Atom
import ./budget-addition.bend as Addition
import ../../src/response.bend as Response
import ../../src/codec.bend as C
import ../../src/json.bend as J

def add_zero(a: Nat) -> {Nat.add(a, 0n) == a : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.add(p, 0n), p, add_zero(p))

def add_comm(a: Nat, +b: Nat) -> {Nat.add(a, b) == Nat.add(b, a) : Nat}:
  match a:
    case 0n:
      Equal.sym(Nat, Nat.add(b, 0n), b, add_zero(b))
    case 1n+p:
      Equal.trans(Nat, 1n+Nat.add(p, b), 1n+Nat.add(b, p), Nat.add(b, 1n+p),
        Equal.cong(Nat, Nat, x => 1n+x, Nat.add(p, b), Nat.add(b, p), add_comm(p, b)),
        Equal.sym(Nat, Nat.add(b, 1n+p), 1n+Nat.add(b, p),
          Arithmetic.add_right_succ(b, p)))

# Move the next scalar in front of the tail while preserving the accumulator.
def add_swap(+a: Nat, +b: Nat, -c: Nat)
  -> {Nat.add(a, Nat.add(b, c)) == Nat.add(b, Nat.add(a, c)) : Nat}:
  Equal.trans(Nat, Nat.add(a, Nat.add(b, c)), Nat.add(Nat.add(a, b), c),
    Nat.add(b, Nat.add(a, c)), BudgetProof.add_assoc(a, b, c),
    Equal.trans(Nat, Nat.add(Nat.add(a, b), c), Nat.add(Nat.add(b, a), c),
      Nat.add(b, Nat.add(a, c)),
      Equal.cong(Nat, Nat, x => Nat.add(x, c), Nat.add(a, b), Nat.add(b, a),
        add_comm(a, b)),
      Equal.sym(Nat, Nat.add(b, Nat.add(a, c)), Nat.add(Nat.add(b, a), c),
        BudgetProof.add_assoc(b, a, c))))

def reverse_weight(s: String, acc: String)
  -> {Atom.utf8_weight(String.reverse.go(s, acc)) ==
      Nat.add(Atom.utf8_weight(s), Atom.utf8_weight(acc)) : Nat}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Equal.trans(Nat, Atom.utf8_weight(String.reverse.go(t, SCon{c, acc})),
        Nat.add(Atom.utf8_weight(t),
          Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(acc))),
        Nat.add(Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(t)),
          Atom.utf8_weight(acc)), reverse_weight(t, SCon{c, acc}),
        Equal.trans(Nat,
          Nat.add(Atom.utf8_weight(t),
            Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(acc))),
          Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))),
            Nat.add(Atom.utf8_weight(t), Atom.utf8_weight(acc))),
          Nat.add(Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(t)),
            Atom.utf8_weight(acc)),
          add_swap(Atom.utf8_weight(t), U32.to_nat(C.utf8_width(Char.to_u32(c))),
            Atom.utf8_weight(acc)),
          BudgetProof.add_assoc(U32.to_nat(C.utf8_width(Char.to_u32(c))),
            Atom.utf8_weight(t), Atom.utf8_weight(acc))))

def onto_weight(s: String, acc: String)
  -> {Atom.utf8_weight(J.esc.onto(s, acc)) ==
      Nat.add(Atom.utf8_weight(s), Atom.utf8_weight(acc)) : Nat}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Equal.trans(Nat, Atom.utf8_weight(J.esc.onto(t, SCon{c, acc})),
        Nat.add(Atom.utf8_weight(t),
          Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(acc))),
        Nat.add(Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(t)),
          Atom.utf8_weight(acc)), onto_weight(t, SCon{c, acc}),
        Equal.trans(Nat,
          Nat.add(Atom.utf8_weight(t),
            Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(acc))),
          Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))),
            Nat.add(Atom.utf8_weight(t), Atom.utf8_weight(acc))),
          Nat.add(Nat.add(U32.to_nat(C.utf8_width(Char.to_u32(c))), Atom.utf8_weight(t)),
            Atom.utf8_weight(acc)),
          add_swap(Atom.utf8_weight(t), U32.to_nat(C.utf8_width(Char.to_u32(c))),
            Atom.utf8_weight(acc)),
          BudgetProof.add_assoc(U32.to_nat(C.utf8_width(Char.to_u32(c))),
            Atom.utf8_weight(t), Atom.utf8_weight(acc))))

def escape_go_weight(s: String, +acc: String)
  -> {Atom.utf8_weight(J.esc.go(s, acc)) ==
      Nat.add(Budget.escaped_bytes(s), Atom.utf8_weight(acc)) : Nat}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Equal.trans(Nat, Atom.utf8_weight(J.esc.go(t, J.esc.onto(J.esc_char(c), acc))),
        Nat.add(Budget.escaped_bytes(t), Atom.utf8_weight(J.esc.onto(J.esc_char(c), acc))),
        Nat.add(Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Budget.escaped_bytes(t)),
          Atom.utf8_weight(acc)), escape_go_weight(t, J.esc.onto(J.esc_char(c), acc)),
        Equal.trans(Nat,
          Nat.add(Budget.escaped_bytes(t), Atom.utf8_weight(J.esc.onto(J.esc_char(c), acc))),
          Nat.add(Budget.escaped_bytes(t),
            Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Atom.utf8_weight(acc))),
          Nat.add(Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Budget.escaped_bytes(t)),
            Atom.utf8_weight(acc)),
          Equal.cong(Nat, Nat, x => Nat.add(Budget.escaped_bytes(t), x),
            Atom.utf8_weight(J.esc.onto(J.esc_char(c), acc)),
            Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Atom.utf8_weight(acc)),
            Equal.trans(Nat, Atom.utf8_weight(J.esc.onto(J.esc_char(c), acc)),
              Nat.add(Atom.utf8_weight(J.esc_char(c)), Atom.utf8_weight(acc)),
              Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Atom.utf8_weight(acc)),
              onto_weight(J.esc_char(c), acc),
              Equal.cong(Nat, Nat, x => Nat.add(x, Atom.utf8_weight(acc)),
                Atom.utf8_weight(J.esc_char(c)), U32.to_nat(C.utf8_len(J.esc_char(c))),
                Atom.atom_exact(c)))),
          Equal.trans(Nat,
            Nat.add(Budget.escaped_bytes(t),
              Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Atom.utf8_weight(acc))),
            Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))),
              Nat.add(Budget.escaped_bytes(t), Atom.utf8_weight(acc))),
            Nat.add(Nat.add(U32.to_nat(C.utf8_len(J.esc_char(c))), Budget.escaped_bytes(t)),
              Atom.utf8_weight(acc)),
            add_swap(Budget.escaped_bytes(t), U32.to_nat(C.utf8_len(J.esc_char(c))),
              Atom.utf8_weight(acc)),
            BudgetProof.add_assoc(U32.to_nat(C.utf8_len(J.esc_char(c))),
              Budget.escaped_bytes(t), Atom.utf8_weight(acc)))))

def escape_weight(+s: String)
  -> {Atom.utf8_weight(J.esc(s)) == Budget.escaped_bytes(s) : Nat}:
  Equal.trans(Nat, Atom.utf8_weight(J.esc(s)), Atom.utf8_weight(J.esc.go(s, "")),
    Budget.escaped_bytes(s),
    Equal.trans(Nat, Atom.utf8_weight(String.reverse(J.esc.go(s, ""))),
      Nat.add(Atom.utf8_weight(J.esc.go(s, "")), 0n), Atom.utf8_weight(J.esc.go(s, "")),
      reverse_weight(J.esc.go(s, ""), ""), add_zero(Atom.utf8_weight(J.esc.go(s, "")))),
    Equal.trans(Nat, Atom.utf8_weight(J.esc.go(s, "")), Nat.add(Budget.escaped_bytes(s), 0n),
      Budget.escaped_bytes(s), escape_go_weight(s, ""), add_zero(Budget.escaped_bytes(s))))

# The witness bounds the actual accumulated width. It is not an assumption
# that the machine count is exact; add_within derives that from the bound.
def step_fits(-cap: U32, +a: Nat, +b: Nat, +tail: Nat, +extra: Nat,
  fits: {U32.to_nat(cap) == Nat.add(Nat.add(a, Nat.add(b, tail)), extra) : Nat})
  -> {U32.to_nat(cap) == Nat.add(Nat.add(a, b), Nat.add(tail, extra)) : Nat}:
  Equal.trans(Nat, U32.to_nat(cap), Nat.add(Nat.add(a, Nat.add(b, tail)), extra),
    Nat.add(Nat.add(a, b), Nat.add(tail, extra)), fits,
    Equal.trans(Nat, Nat.add(Nat.add(a, Nat.add(b, tail)), extra),
      Nat.add(Nat.add(Nat.add(a, b), tail), extra),
      Nat.add(Nat.add(a, b), Nat.add(tail, extra)),
      Equal.cong(Nat, Nat, x => Nat.add(x, extra), Nat.add(a, Nat.add(b, tail)),
        Nat.add(Nat.add(a, b), tail), BudgetProof.add_assoc(a, b, tail)),
      Equal.sym(Nat, Nat.add(Nat.add(a, b), Nat.add(tail, extra)),
        Nat.add(Nat.add(Nat.add(a, b), tail), extra),
        BudgetProof.add_assoc(Nat.add(a, b), tail, extra))))

def utf8_go_exact(s: String, +acc: U32, +cap: U32, +extra: Nat,
  +fits: {U32.to_nat(cap) == Nat.add(Nat.add(U32.to_nat(acc), Atom.utf8_weight(s)),
    extra) : Nat})
  -> {U32.to_nat(C.utf8_len.go(s, acc)) ==
      Nat.add(U32.to_nat(acc), Atom.utf8_weight(s)) : Nat}:
  match s:
    case SNil{}:
      Equal.sym(Nat, Nat.add(U32.to_nat(acc), 0n), U32.to_nat(acc),
        add_zero(U32.to_nat(acc)))
    case SCon{+c, +t}:
      +width = C.utf8_width(Char.to_u32(c))
      +next = U32.add(acc, width)
      +exact = Addition.add_within(acc, width, cap, Nat.add(Atom.utf8_weight(t), extra),
        step_fits(cap, U32.to_nat(acc), U32.to_nat(width), Atom.utf8_weight(t), extra, fits))
      +next_fits = Equal.trans(Nat, U32.to_nat(cap),
        Nat.add(Nat.add(U32.to_nat(acc), Nat.add(U32.to_nat(width), Atom.utf8_weight(t))),
          extra), Nat.add(Nat.add(U32.to_nat(next), Atom.utf8_weight(t)), extra), fits,
        Equal.cong(Nat, Nat, x => Nat.add(x, extra),
          Nat.add(U32.to_nat(acc), Nat.add(U32.to_nat(width), Atom.utf8_weight(t))),
          Nat.add(U32.to_nat(next), Atom.utf8_weight(t)),
          Equal.trans(Nat,
            Nat.add(U32.to_nat(acc), Nat.add(U32.to_nat(width), Atom.utf8_weight(t))),
            Nat.add(Nat.add(U32.to_nat(acc), U32.to_nat(width)), Atom.utf8_weight(t)),
            Nat.add(U32.to_nat(next), Atom.utf8_weight(t)),
            BudgetProof.add_assoc(U32.to_nat(acc), U32.to_nat(width), Atom.utf8_weight(t)),
            Equal.cong(Nat, Nat, x => Nat.add(x, Atom.utf8_weight(t)),
              Nat.add(U32.to_nat(acc), U32.to_nat(width)), U32.to_nat(next),
              Equal.sym(Nat, U32.to_nat(next), Nat.add(U32.to_nat(acc), U32.to_nat(width)),
                exact)))))
      Equal.trans(Nat, U32.to_nat(C.utf8_len.go(t, next)),
        Nat.add(U32.to_nat(next), Atom.utf8_weight(t)),
        Nat.add(U32.to_nat(acc), Nat.add(U32.to_nat(width), Atom.utf8_weight(t))),
        utf8_go_exact(t, next, cap, extra, next_fits),
        Equal.trans(Nat, Nat.add(U32.to_nat(next), Atom.utf8_weight(t)),
          Nat.add(Nat.add(U32.to_nat(acc), U32.to_nat(width)), Atom.utf8_weight(t)),
          Nat.add(U32.to_nat(acc), Nat.add(U32.to_nat(width), Atom.utf8_weight(t))),
          Equal.cong(Nat, Nat, x => Nat.add(x, Atom.utf8_weight(t)), U32.to_nat(next),
            Nat.add(U32.to_nat(acc), U32.to_nat(width)), exact),
          Equal.sym(Nat,
            Nat.add(U32.to_nat(acc), Nat.add(U32.to_nat(width), Atom.utf8_weight(t))),
            Nat.add(Nat.add(U32.to_nat(acc), U32.to_nat(width)), Atom.utf8_weight(t)),
            BudgetProof.add_assoc(U32.to_nat(acc), U32.to_nat(width), Atom.utf8_weight(t)))))

def serialized_exact(+s: String, +cap: U32, +extra: Nat,
  fits: {U32.to_nat(cap) == Nat.add(Budget.escaped_bytes(s), extra) : Nat})
  -> {U32.to_nat(C.utf8_len(J.esc(s))) == Budget.escaped_bytes(s) : Nat}:
  Equal.trans(Nat, U32.to_nat(C.utf8_len(J.esc(s))), Atom.utf8_weight(J.esc(s)),
    Budget.escaped_bytes(s),
    utf8_go_exact(J.esc(s), 0, cap, extra,
      Equal.trans(Nat, U32.to_nat(cap), Nat.add(Budget.escaped_bytes(s), extra),
        Nat.add(Atom.utf8_weight(J.esc(s)), extra), fits,
        Equal.cong(Nat, Nat, x => Nat.add(x, extra), Budget.escaped_bytes(s),
          Atom.utf8_weight(J.esc(s)),
          Equal.sym(Nat, Atom.utf8_weight(J.esc(s)), Budget.escaped_bytes(s),
            escape_weight(s))))), escape_weight(s))

def prefix_serialized_conserves(+s: String, +left: U32)
  -> {U32.to_nat(left) ==
      Nat.add(U32.to_nat(C.utf8_len(J.esc(Budget.prefix_text(Response.prefix(s, left))))),
        U32.to_nat(Budget.prefix_left(Response.prefix(s, left)))) : Nat}:
  +p = Response.prefix(s, left)
  Equal.trans(Nat, U32.to_nat(left),
    Nat.add(Budget.escaped_bytes(Budget.prefix_text(p)), U32.to_nat(Budget.prefix_left(p))),
    Nat.add(U32.to_nat(C.utf8_len(J.esc(Budget.prefix_text(p)))),
      U32.to_nat(Budget.prefix_left(p))), BudgetProof.prefix_conserves(s, left),
    Equal.cong(Nat, Nat, x => Nat.add(x, U32.to_nat(Budget.prefix_left(p))),
      Budget.escaped_bytes(Budget.prefix_text(p)), U32.to_nat(C.utf8_len(J.esc(Budget.prefix_text(p)))),
      Equal.sym(Nat, U32.to_nat(C.utf8_len(J.esc(Budget.prefix_text(p)))),
        Budget.escaped_bytes(Budget.prefix_text(p)),
        serialized_exact(Budget.prefix_text(p), left, U32.to_nat(Budget.prefix_left(p)),
          BudgetProof.prefix_conserves(s, left)))))

def prefix_fits_allowance(+s: String, +left: U32)
  -> Budget.Within<U32.to_nat(C.utf8_len(J.esc(Budget.prefix_text(Response.prefix(s, left))))),
      left>:
  Budget.Within{U32.to_nat(Budget.prefix_left(Response.prefix(s, left))),
    prefix_serialized_conserves(s, left)}

# This also bounds the unbounded mathematical wire weight, so the claim
# cannot be satisfied merely by wrapping the machine byte counter.
def prefix_wire_weight_conserves(+s: String, +left: U32)
  -> {U32.to_nat(left) ==
      Nat.add(Atom.utf8_weight(J.esc(Budget.prefix_text(Response.prefix(s, left)))),
        U32.to_nat(Budget.prefix_left(Response.prefix(s, left)))) : Nat}:
  +p = Response.prefix(s, left)
  Equal.trans(Nat, U32.to_nat(left),
    Nat.add(Budget.escaped_bytes(Budget.prefix_text(p)), U32.to_nat(Budget.prefix_left(p))),
    Nat.add(Atom.utf8_weight(J.esc(Budget.prefix_text(p))), U32.to_nat(Budget.prefix_left(p))),
    BudgetProof.prefix_conserves(s, left),
    Equal.cong(Nat, Nat, x => Nat.add(x, U32.to_nat(Budget.prefix_left(p))),
      Budget.escaped_bytes(Budget.prefix_text(p)), Atom.utf8_weight(J.esc(Budget.prefix_text(p))),
      Equal.sym(Nat, Atom.utf8_weight(J.esc(Budget.prefix_text(p))),
        Budget.escaped_bytes(Budget.prefix_text(p)), escape_weight(Budget.prefix_text(p)))))

# The natural full-wire-size premise excludes mathematical strings too big
# for the U32 allowance without trusting a wrapped utf8_len measurement.
def prefix_whole_when_wire_room(+s: String, +left: U32, +extra: Nat,
  enough: {U32.to_nat(left) == Nat.add(Atom.utf8_weight(J.esc(s)), extra) : Nat})
  -> ({Budget.prefix_text(Response.prefix(s, left)) == s : String} &
      {U32.to_nat(Budget.prefix_left(Response.prefix(s, left))) == extra : Nat}):
  BudgetProof.prefix_whole(s, left, extra,
    Equal.trans(Nat, U32.to_nat(left), Nat.add(Atom.utf8_weight(J.esc(s)), extra),
      Nat.add(Budget.escaped_bytes(s), extra), enough,
      Equal.cong(Nat, Nat, x => Nat.add(x, extra), Atom.utf8_weight(J.esc(s)),
        Budget.escaped_bytes(s), escape_weight(s))))
