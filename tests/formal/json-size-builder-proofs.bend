# Exact compatibility of the accumulator serializer for every Json constructor.

import Base
import ../../src/json.bend as J
import ./json-size-reference.bend as Reference

def append_empty(s: String) -> {s ++ "" == s : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Equal.cong(String, String, x => SCon{c, x}, t ++ "", t, append_empty(t))

def reverse_onto(s: String, acc: String)
  -> {String.reverse.go(s, acc) == J.esc.onto(s, acc) : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{c, t}:
      reverse_onto(t, SCon{c, acc})

def onto_shift(s: String, a: String, b: String)
  -> {J.esc.onto(s, a ++ b) == J.esc.onto(s, a) ++ b : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{c, t}:
      onto_shift(t, SCon{c, a}, b)

def onto_append(a: String, b: String, acc: String)
  -> {J.esc.onto(a ++ b, acc) == J.esc.onto(b, J.esc.onto(a, acc)) : String}:
  match a:
    case SNil{}:
      {==}
    case SCon{c, t}:
      onto_append(t, b, SCon{c, acc})

def onto_twice(s: String, a: String, b: String)
  -> {J.esc.onto(J.esc.onto(s, a), b) == J.esc.onto(a, s ++ b) : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{c, t}:
      onto_twice(t, SCon{c, a}, b)

def escape_shift(s: String, +a: String, +b: String)
  -> {J.esc.go(s, a ++ b) == J.esc.go(s, a) ++ b : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Equal.trans(String,
        J.esc.go(t, J.esc.onto(J.esc_char(c), a ++ b)),
        J.esc.go(t, J.esc.onto(J.esc_char(c), a) ++ b),
        J.esc.go(t, J.esc.onto(J.esc_char(c), a)) ++ b,
        Equal.cong(String, String, x => J.esc.go(t, x),
          J.esc.onto(J.esc_char(c), a ++ b), J.esc.onto(J.esc_char(c), a) ++ b,
          onto_shift(J.esc_char(c), a, b)),
        escape_shift(t, J.esc.onto(J.esc_char(c), a), b))

def escape_onto(+s: String, +acc: String)
  -> {J.esc.go(s, acc) == J.esc.onto(J.esc(s), acc) : String}:
  Equal.trans(String, J.esc.go(s, acc), J.esc.go(s, "") ++ acc,
    J.esc.onto(J.esc(s), acc), escape_shift(s, "", acc),
    Equal.sym(String, J.esc.onto(J.esc(s), acc), J.esc.go(s, "") ++ acc,
      Equal.trans(String, J.esc.onto(J.esc(s), acc),
        J.esc.onto(J.esc.onto(J.esc.go(s, ""), ""), acc), J.esc.go(s, "") ++ acc,
        Equal.cong(String, String, x => J.esc.onto(x, acc),
          J.esc(s), J.esc.onto(J.esc.go(s, ""), ""), reverse_onto(J.esc.go(s, ""), "")),
        onto_twice(J.esc.go(s, ""), "", acc))))

def quote_onto(+s: String, +acc: String)
  -> {J.show.quote(s, acc) == J.esc.onto(Reference.quote(s), acc) : String}:
  Equal.trans(String, J.show.quote(s, acc),
    SCon{'"', J.esc.onto(J.esc(s), SCon{'"', acc})},
    J.esc.onto(Reference.quote(s), acc),
    Equal.cong(String, String, x => SCon{'"', x},
      J.esc.go(s, SCon{'"', acc}), J.esc.onto(J.esc(s), SCon{'"', acc}),
      escape_onto(s, SCon{'"', acc})),
    Equal.sym(String, J.esc.onto(Reference.quote(s), acc),
      SCon{'"', J.esc.onto(J.esc(s), SCon{'"', acc})},
      onto_append(J.esc(s), "\"", SCon{'"', acc})))

# Splitting three pieces follows the source's right-associative ++ operator.
def onto_three(+a: String, +b: String, +c: String, +acc: String)
  -> {J.esc.onto(a ++ b ++ c, acc) ==
      J.esc.onto(c, J.esc.onto(b, J.esc.onto(a, acc))) : String}:
  Equal.trans(String, J.esc.onto(a ++ b ++ c, acc),
    J.esc.onto(b ++ c, J.esc.onto(a, acc)),
    J.esc.onto(c, J.esc.onto(b, J.esc.onto(a, acc))),
    onto_append(a, b ++ c, acc), onto_append(b, c, J.esc.onto(a, acc)))

def separator_equal(t: J.Json) -> {J.sep(t) == Reference.sep(t) : String}:
  match t:
    case J.JNull{}:
      {==}
    case J.JBool{b}:
      {==}
    case J.JNum{raw}:
      {==}
    case J.JStr{s}:
      {==}
    case J.JArr{items}:
      {==}
    case J.JObj{items}:
      {==}
    case J.JCons{h, t}:
      {==}
    case J.JEnd{}:
      {==}
    case J.JKv{k, v}:
      {==}

def show_onto(j: J.Json, +acc: String)
  -> {J.show.go(j, acc) == J.esc.onto(Reference.show(j), acc) : String}:
  match j:
    case J.JNull{}:
      {==}
    case J.JBool{b}:
      {==}
    case J.JNum{raw}:
      {==}
    case J.JStr{s}:
      quote_onto(s, acc)
    case J.JArr{+items}:
      Equal.trans(String, SCon{']', J.show.go(items, SCon{'[', acc})},
        SCon{']', J.esc.onto(Reference.show(items), SCon{'[', acc})},
        J.esc.onto("[" ++ Reference.show(items) ++ "]", acc),
        Equal.cong(String, String, x => SCon{']', x},
          J.show.go(items, SCon{'[', acc}), J.esc.onto(Reference.show(items), SCon{'[', acc}),
          show_onto(items, SCon{'[', acc})),
        Equal.sym(String, J.esc.onto("[" ++ Reference.show(items) ++ "]", acc),
          SCon{']', J.esc.onto(Reference.show(items), SCon{'[', acc})},
          onto_append(Reference.show(items), "]", SCon{'[', acc})))
    case J.JObj{+items}:
      Equal.trans(String, SCon{'}', J.show.go(items, SCon{'{', acc})},
        SCon{'}', J.esc.onto(Reference.show(items), SCon{'{', acc})},
        J.esc.onto("{" ++ Reference.show(items) ++ "}", acc),
        Equal.cong(String, String, x => SCon{'}', x},
          J.show.go(items, SCon{'{', acc}), J.esc.onto(Reference.show(items), SCon{'{', acc}),
          show_onto(items, SCon{'{', acc})),
        Equal.sym(String, J.esc.onto("{" ++ Reference.show(items) ++ "}", acc),
          SCon{'}', J.esc.onto(Reference.show(items), SCon{'{', acc})},
          onto_append(Reference.show(items), "}", SCon{'{', acc})))
    case J.JCons{+h, +t}:
      %separator_equal(t) : {J.show.go(J.JCons{h, t}, acc) ==
        J.esc.onto(Reference.show(h) ++ _ ++ Reference.show(t), acc) : String}
      Equal.trans(String, J.show.go(t, J.esc.onto(J.sep(t), J.show.go(h, acc))),
        J.esc.onto(Reference.show(t), J.esc.onto(J.sep(t), J.show.go(h, acc))),
        J.esc.onto(Reference.show(h) ++ J.sep(t) ++ Reference.show(t), acc),
        show_onto(t, J.esc.onto(J.sep(t), J.show.go(h, acc))),
        Equal.trans(String,
          J.esc.onto(Reference.show(t), J.esc.onto(J.sep(t), J.show.go(h, acc))),
          J.esc.onto(Reference.show(t), J.esc.onto(J.sep(t), J.esc.onto(Reference.show(h), acc))),
          J.esc.onto(Reference.show(h) ++ J.sep(t) ++ Reference.show(t), acc),
          Equal.cong(String, String, x => J.esc.onto(Reference.show(t), J.esc.onto(J.sep(t), x)),
            J.show.go(h, acc), J.esc.onto(Reference.show(h), acc), show_onto(h, acc)),
          Equal.sym(String, J.esc.onto(Reference.show(h) ++ J.sep(t) ++ Reference.show(t), acc),
            J.esc.onto(Reference.show(t), J.esc.onto(J.sep(t), J.esc.onto(Reference.show(h), acc))),
            onto_three(Reference.show(h), J.sep(t), Reference.show(t), acc))))
    case J.JEnd{}:
      {==}
    case J.JKv{+k, +v}:
      Equal.trans(String, J.show.go(v, SCon{':', J.show.quote(k, acc)}),
        J.esc.onto(Reference.show(v), SCon{':', J.show.quote(k, acc)}),
        J.esc.onto(Reference.quote(k) ++ ":" ++ Reference.show(v), acc),
        show_onto(v, SCon{':', J.show.quote(k, acc)}),
        Equal.trans(String, J.esc.onto(Reference.show(v), SCon{':', J.show.quote(k, acc)}),
          J.esc.onto(Reference.show(v), SCon{':', J.esc.onto(Reference.quote(k), acc)}),
          J.esc.onto(Reference.quote(k) ++ ":" ++ Reference.show(v), acc),
          Equal.cong(String, String, x => J.esc.onto(Reference.show(v), SCon{':', x}),
            J.show.quote(k, acc), J.esc.onto(Reference.quote(k), acc), quote_onto(k, acc)),
          Equal.sym(String, J.esc.onto(Reference.quote(k) ++ ":" ++ Reference.show(v), acc),
            J.esc.onto(Reference.show(v), SCon{':', J.esc.onto(Reference.quote(k), acc)}),
            onto_three(Reference.quote(k), ":", Reference.show(v), acc))))

def show_equal(+j: J.Json) -> {J.show(j) == Reference.show(j) : String}:
  Equal.trans(String, J.show(j), J.esc.onto(J.show.go(j, ""), ""), Reference.show(j),
    reverse_onto(J.show.go(j, ""), ""),
    Equal.trans(String, J.esc.onto(J.show.go(j, ""), ""),
      J.esc.onto(J.esc.onto(Reference.show(j), ""), ""), Reference.show(j),
      Equal.cong(String, String, x => J.esc.onto(x, ""),
        J.show.go(j, ""), J.esc.onto(Reference.show(j), ""), show_onto(j, "")),
      Equal.trans(String, J.esc.onto(J.esc.onto(Reference.show(j), ""), ""),
        Reference.show(j) ++ "", Reference.show(j),
        onto_twice(Reference.show(j), "", ""), append_empty(Reference.show(j)))))
