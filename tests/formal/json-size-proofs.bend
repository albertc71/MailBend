# Correspondence of the actual JSON serializer and its modular U32 counter.

import Base
import ./json-size-reference.bend as Reference
import ./json-size-builder-proofs.bend as Show
import ./json-size-arithmetic.bend as Arithmetic
import ./json-size-escape-atoms.bend as EscapeAtoms
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/response.bend as Response

def right_zero(+a: U32) -> {U32.add(a, 0) == a : U32}:
  Equal.trans(U32, U32.add(a, 0), U32.add(0, a), a,
    U32.add_comm(a, 0), Arithmetic.add_zero(a))

def utf8_shift(s: String, +a: U32, +b: U32)
  -> {C.utf8_len.go(s, U32.add(a, b)) == U32.add(a, C.utf8_len.go(s, b)) : U32}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      +w = C.utf8_width(Char.to_u32(c))
      Equal.trans(U32, C.utf8_len.go(t, U32.add(U32.add(a, b), w)),
        C.utf8_len.go(t, U32.add(a, U32.add(b, w))),
        U32.add(a, C.utf8_len.go(t, U32.add(b, w))),
        Equal.cong(U32, U32, x => C.utf8_len.go(t, x),
          U32.add(U32.add(a, b), w), U32.add(a, U32.add(b, w)),
          Arithmetic.add_assoc(a, b, w)), utf8_shift(t, a, U32.add(b, w)))

def utf8_acc(+s: String, +acc: U32)
  -> {C.utf8_len.go(s, acc) == U32.add(acc, C.utf8_len(s)) : U32}:
  Equal.trans(U32, C.utf8_len.go(s, acc), C.utf8_len.go(s, U32.add(acc, 0)),
    U32.add(acc, C.utf8_len(s)),
    Equal.cong(U32, U32, x => C.utf8_len.go(s, x), acc, U32.add(acc, 0),
      Equal.sym(U32, U32.add(acc, 0), acc, right_zero(acc))), utf8_shift(s, acc, 0))

def utf8_append_acc(a: String, +b: String, +acc: U32)
  -> {C.utf8_len.go(a ++ b, acc) == C.utf8_len.go(b, C.utf8_len.go(a, acc)) : U32}:
  match a:
    case SNil{}:
      {==}
    case SCon{c, t}:
      utf8_append_acc(t, b, U32.add(acc, C.utf8_width(Char.to_u32(c))))

def utf8_append(+a: String, +b: String)
  -> {C.utf8_len(a ++ b) == U32.add(C.utf8_len(a), C.utf8_len(b)) : U32}:
  Equal.trans(U32, C.utf8_len(a ++ b), C.utf8_len.go(b, C.utf8_len(a)),
    U32.add(C.utf8_len(a), C.utf8_len(b)), utf8_append_acc(a, b, 0),
    utf8_acc(b, C.utf8_len(a)))

def utf8_three(+a: String, +b: String, +c: String)
  -> {C.utf8_len(a ++ b ++ c) ==
      U32.add(U32.add(C.utf8_len(a), C.utf8_len(b)), C.utf8_len(c)) : U32}:
  Equal.trans(U32, C.utf8_len(a ++ b ++ c),
    U32.add(C.utf8_len(a), C.utf8_len(b ++ c)),
    U32.add(U32.add(C.utf8_len(a), C.utf8_len(b)), C.utf8_len(c)),
    utf8_append(a, b ++ c),
    Equal.trans(U32, U32.add(C.utf8_len(a), C.utf8_len(b ++ c)),
      U32.add(C.utf8_len(a), U32.add(C.utf8_len(b), C.utf8_len(c))),
      U32.add(U32.add(C.utf8_len(a), C.utf8_len(b)), C.utf8_len(c)),
      Equal.cong(U32, U32, x => U32.add(C.utf8_len(a), x), C.utf8_len(b ++ c),
        U32.add(C.utf8_len(b), C.utf8_len(c)), utf8_append(b, c)),
      Equal.sym(U32, U32.add(U32.add(C.utf8_len(a), C.utf8_len(b)), C.utf8_len(c)),
        U32.add(C.utf8_len(a), U32.add(C.utf8_len(b), C.utf8_len(c))),
        Arithmetic.add_assoc(C.utf8_len(a), C.utf8_len(b), C.utf8_len(c)))))

def swap_last(+a: U32, +b: U32, +c: U32)
  -> {U32.add(U32.add(a, b), c) == U32.add(U32.add(a, c), b) : U32}:
  Equal.trans(U32, U32.add(U32.add(a, b), c), U32.add(a, U32.add(b, c)),
    U32.add(U32.add(a, c), b), Arithmetic.add_assoc(a, b, c),
    Equal.trans(U32, U32.add(a, U32.add(b, c)), U32.add(a, U32.add(c, b)),
      U32.add(U32.add(a, c), b),
      Equal.cong(U32, U32, x => U32.add(a, x), U32.add(b, c), U32.add(c, b),
        U32.add_comm(b, c)),
      Equal.sym(U32, U32.add(U32.add(a, c), b), U32.add(a, U32.add(c, b)),
        Arithmetic.add_assoc(a, c, b))))

# Each delimiter is checked against the real UTF-8 counter, not assumed to
# be ASCII by a replacement serializer.
def frame(+left: String, +s: String, +right: String,
  first: {C.utf8_len(left) == 1 : U32}, last: {C.utf8_len(right) == 1 : U32})
  -> {C.utf8_len(left ++ s ++ right) == U32.add(2, C.utf8_len(s)) : U32}:
  Equal.trans(U32, C.utf8_len(left ++ s ++ right),
    U32.add(U32.add(C.utf8_len(left), C.utf8_len(s)), C.utf8_len(right)),
    U32.add(2, C.utf8_len(s)), utf8_three(left, s, right),
    Equal.trans(U32,
      U32.add(U32.add(C.utf8_len(left), C.utf8_len(s)), C.utf8_len(right)),
      U32.add(U32.add(1, C.utf8_len(s)), 1), U32.add(2, C.utf8_len(s)),
      Equal.trans(U32,
        U32.add(U32.add(C.utf8_len(left), C.utf8_len(s)), C.utf8_len(right)),
        U32.add(U32.add(1, C.utf8_len(s)), C.utf8_len(right)),
        U32.add(U32.add(1, C.utf8_len(s)), 1),
        Equal.cong(U32, U32, x => U32.add(U32.add(x, C.utf8_len(s)), C.utf8_len(right)),
          C.utf8_len(left), 1, first),
        Equal.cong(U32, U32, x => U32.add(U32.add(1, C.utf8_len(s)), x),
          C.utf8_len(right), 1, last)), swap_last(1, C.utf8_len(s), 1)))

def quote(+s: String)
  -> {C.utf8_len(Reference.quote(s)) == U32.add(2, C.utf8_len(J.esc(s))) : U32}:
  frame("\"", J.esc(s), "\"", {==}, {==})

def utf8_step_commute(+s: String, +acc: U32, +width: U32)
  -> {C.utf8_len.go(s, U32.add(acc, width)) ==
      U32.add(C.utf8_len.go(s, acc), width) : U32}:
  Equal.trans(U32, C.utf8_len.go(s, U32.add(acc, width)),
    C.utf8_len.go(s, U32.add(width, acc)), U32.add(C.utf8_len.go(s, acc), width),
    Equal.cong(U32, U32, n => C.utf8_len.go(s, n),
      U32.add(acc, width), U32.add(width, acc), U32.add_comm(acc, width)),
    Equal.trans(U32, C.utf8_len.go(s, U32.add(width, acc)),
      U32.add(width, C.utf8_len.go(s, acc)), U32.add(C.utf8_len.go(s, acc), width),
      utf8_shift(s, width, acc), U32.add_comm(width, C.utf8_len.go(s, acc))))

def utf8_onto_acc(s: String, +out: String, +acc: U32)
  -> {C.utf8_len.go(J.esc.onto(s, out), acc) ==
      C.utf8_len.go(out, C.utf8_len.go(s, acc)) : U32}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      +w = C.utf8_width(Char.to_u32(c))
      Equal.trans(U32, C.utf8_len.go(J.esc.onto(t, SCon{c, out}), acc),
        C.utf8_len.go(out, U32.add(C.utf8_len.go(t, acc), w)),
        C.utf8_len.go(out, C.utf8_len.go(t, U32.add(acc, w))),
        utf8_onto_acc(t, SCon{c, out}, acc),
        Equal.cong(U32, U32, n => C.utf8_len.go(out, n),
          U32.add(C.utf8_len.go(t, acc), w), C.utf8_len.go(t, U32.add(acc, w)),
          Equal.sym(U32, C.utf8_len.go(t, U32.add(acc, w)),
            U32.add(C.utf8_len.go(t, acc), w), utf8_step_commute(t, acc, w))))

def utf8_reverse(+s: String)
  -> {C.utf8_len(String.reverse(s)) == C.utf8_len(s) : U32}:
  Equal.trans(U32, C.utf8_len(String.reverse(s)), C.utf8_len(J.esc.onto(s, "")),
    C.utf8_len(s),
    Equal.cong(String, U32, t => C.utf8_len(t), String.reverse(s), J.esc.onto(s, ""),
      Show.reverse_onto(s, "")), utf8_onto_acc(s, "", 0))

def escape_go_count(s: String, +out: String)
  -> {C.utf8_len(J.esc.go(s, out)) == J.esc_bytes.go(s, C.utf8_len(out)) : U32}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Equal.trans(U32, C.utf8_len(J.esc.go(t, J.esc.onto(J.esc_char(c), out))),
        J.esc_bytes.go(t, C.utf8_len(J.esc.onto(J.esc_char(c), out))),
        J.esc_bytes.go(t, U32.add(C.utf8_len(out), J.esc_bytes.char(c))),
        escape_go_count(t, J.esc.onto(J.esc_char(c), out)),
        Equal.cong(U32, U32, n => J.esc_bytes.go(t, n),
          C.utf8_len(J.esc.onto(J.esc_char(c), out)),
          U32.add(C.utf8_len(out), J.esc_bytes.char(c)),
          Equal.trans(U32, C.utf8_len(J.esc.onto(J.esc_char(c), out)),
            C.utf8_len.go(out, C.utf8_len(J.esc_char(c))),
            U32.add(C.utf8_len(out), J.esc_bytes.char(c)),
            utf8_onto_acc(J.esc_char(c), out, 0),
            Equal.trans(U32, C.utf8_len.go(out, C.utf8_len(J.esc_char(c))),
              U32.add(C.utf8_len(J.esc_char(c)), C.utf8_len(out)),
              U32.add(C.utf8_len(out), J.esc_bytes.char(c)),
              utf8_acc(out, C.utf8_len(J.esc_char(c))),
              Equal.trans(U32, U32.add(C.utf8_len(J.esc_char(c)), C.utf8_len(out)),
                U32.add(C.utf8_len(out), C.utf8_len(J.esc_char(c))),
                U32.add(C.utf8_len(out), J.esc_bytes.char(c)),
                U32.add_comm(C.utf8_len(J.esc_char(c)), C.utf8_len(out)),
                Equal.cong(U32, U32, n => U32.add(C.utf8_len(out), n),
                  C.utf8_len(J.esc_char(c)), J.esc_bytes.char(c),
                  EscapeAtoms.atom_exact(c)))))))

def escape_count(+s: String)
  -> {C.utf8_len(J.esc(s)) == J.esc_bytes(s) : U32}:
  Equal.trans(U32, C.utf8_len(J.esc(s)), C.utf8_len(J.esc.go(s, "")), J.esc_bytes(s),
    utf8_reverse(J.esc.go(s, "")), escape_go_count(s, ""))

def separator(t: J.Json)
  -> {C.utf8_len(Reference.sep(t)) == Response.bytes.separator(t) : U32}:
  match t:
    case J.JEnd{}:
      {==}
    case J.JNull{}:
      {==}
    case J.JBool{b}:
      {==}
    case J.JNum{s}:
      {==}
    case J.JStr{s}:
      {==}
    case J.JArr{items}:
      {==}
    case J.JObj{items}:
      {==}
    case J.JCons{head, tail}:
      {==}
    case J.JKv{key, val}:
      {==}

def count_three(+a: String, +b: String, +c: String, +x: U32, +y: U32, +z: U32,
  ea: {C.utf8_len(a) == x : U32}, eb: {C.utf8_len(b) == y : U32},
  ec: {C.utf8_len(c) == z : U32})
  -> {C.utf8_len(a ++ b ++ c) == U32.add(U32.add(x, y), z) : U32}:
  %ec : {C.utf8_len(a ++ b ++ c) == U32.add(U32.add(x, y), _) : U32}
  %eb : {C.utf8_len(a ++ b ++ c) == U32.add(U32.add(x, _), C.utf8_len(c)) : U32}
  %ea : {C.utf8_len(a ++ b ++ c) == U32.add(U32.add(_, C.utf8_len(b)), C.utf8_len(c)) : U32}
  utf8_three(a, b, c)

# Json itself contains chains and object members; the induction therefore
# includes those cases without assuming that every tree is a valid JSON AST.
def reference_bytes(j: J.Json) -> {C.utf8_len(Reference.show(j)) == Response.bytes(j) : U32}:
  match j:
    case J.JNull{}:
      {==}
    case J.JBool{b}:
      match b:
        case False{}:
          {==}
        case True{}:
          {==}
    case J.JNum{raw}:
      {==}
    case J.JStr{+s}:
      Equal.trans(U32, C.utf8_len(Reference.quote(s)),
        U32.add(2, C.utf8_len(J.esc(s))), U32.add(2, J.esc_bytes(s)), quote(s),
        Equal.cong(U32, U32, n => U32.add(2, n), C.utf8_len(J.esc(s)),
          J.esc_bytes(s), escape_count(s)))
    case J.JArr{+items}:
      Equal.trans(U32, C.utf8_len("[" ++ Reference.show(items) ++ "]"),
        U32.add(2, C.utf8_len(Reference.show(items))), U32.add(2, Response.bytes(items)),
        frame("[", Reference.show(items), "]", {==}, {==}),
        Equal.cong(U32, U32, n => U32.add(2, n), C.utf8_len(Reference.show(items)),
          Response.bytes(items), reference_bytes(items)))
    case J.JObj{+items}:
      Equal.trans(U32, C.utf8_len("{" ++ Reference.show(items) ++ "}"),
        U32.add(2, C.utf8_len(Reference.show(items))), U32.add(2, Response.bytes(items)),
        frame("{", Reference.show(items), "}", {==}, {==}),
        Equal.cong(U32, U32, n => U32.add(2, n), C.utf8_len(Reference.show(items)),
          Response.bytes(items), reference_bytes(items)))
    case J.JCons{+h, +t}:
      count_three(Reference.show(h), Reference.sep(t), Reference.show(t), Response.bytes(h),
        Response.bytes.separator(t), Response.bytes(t), reference_bytes(h), separator(t), reference_bytes(t))
    case J.JEnd{}:
      {==}
    case J.JKv{+k, +v}:
      %escape_count(k) : {C.utf8_len(Reference.show(J.JKv{k, v})) ==
        U32.add(U32.add(3, _), Response.bytes(v)) : U32}
      Equal.trans(U32, C.utf8_len(Reference.quote(k) ++ ":" ++ Reference.show(v)),
        U32.add(U32.add(U32.add(2, C.utf8_len(J.esc(k))), 1), Response.bytes(v)),
        U32.add(U32.add(3, C.utf8_len(J.esc(k))), Response.bytes(v)),
        count_three(Reference.quote(k), ":", Reference.show(v), U32.add(2, C.utf8_len(J.esc(k))),
          1, Response.bytes(v), quote(k), {==}, reference_bytes(v)),
        Equal.cong(U32, U32, n => U32.add(n, Response.bytes(v)),
          U32.add(U32.add(2, C.utf8_len(J.esc(k))), 1), U32.add(3, C.utf8_len(J.esc(k))),
          swap_last(2, C.utf8_len(J.esc(k)), 1)))


def show_bytes(+j: J.Json) -> {C.utf8_len(J.show(j)) == Response.bytes(j) : U32}:
  Equal.trans(U32, C.utf8_len(J.show(j)), C.utf8_len(Reference.show(j)), Response.bytes(j),
    Equal.cong(String, U32, s => C.utf8_len(s), J.show(j), Reference.show(j),
      Show.show_equal(j)), reference_bytes(j))
