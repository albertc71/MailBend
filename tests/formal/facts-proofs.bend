import Base
import ../../src/facts.bend as Facts
import ../../src/json.bend as J
import ./facts-observers.bend as Observe
import ./budget-arithmetic.bend as Arithmetic

def zero_le(n: Nat) -> {Nat.is_le(0n, n) == True{} : Bool}:
  match n:
    case 0n:
      {==}
    case 1n+rest:
      {==}

def and_right(a: Bool, -b: Bool, e: {Bool.and(a, b) == True{} : Bool})
  -> {b == True{} : Bool}:
  match a:
    case True{}:
      e
    case False{}:
      Empty.absurd({b == True{} : Bool}, Arithmetic.false_is_not_true(e))

def code_width(s: String, ending: Facts.SourceEnd, ok: {Facts.code(s, ending) == True{} : Bool})
  -> {Nat.is_le(12n, String.length(s)) == True{} : Bool}:
  match s:
    case SNil{}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SNil{}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SNil{}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SNil{}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SNil{}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SNil{}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SNil{}}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SCon{c6, SNil{}}}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SCon{c6, SCon{c7, SNil{}}}}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SCon{c6, SCon{c7, SCon{c8, SNil{}}}}}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SCon{c6, SCon{c7, SCon{c8, SCon{c9, SNil{}}}}}}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SCon{c6, SCon{c7, SCon{c8, SCon{c9, SCon{c10, SNil{}}}}}}}}}}}}:
      Empty.absurd({Nat.is_le(12n, String.length(s)) == True{} : Bool},
        Arithmetic.false_is_not_true(ok))
    case SCon{c0, SCon{c1, SCon{c2, SCon{c3, SCon{c4, SCon{c5, SCon{c6, SCon{c7, SCon{c8, SCon{c9, SCon{c10, SCon{c11, rest}}}}}}}}}}}}:
      zero_le(String.length(rest))

def drop_width(s: String, n: Nat, +k: Nat,
  fit: {Nat.is_le(1n+k, String.length(String.drop(s, n))) == True{} : Bool})
  -> {Nat.is_le(Nat.add(n, 1n+k), String.length(s)) == True{} : Bool}:
  match s n:
    case SNil{} _:
      Empty.absurd({Nat.is_le(Nat.add(n, 1n+k), 0n) == True{} : Bool},
        Arithmetic.false_is_not_true(fit))
    case SCon{h, t} 0n:
      fit
    case SCon{h, t} 1n+p:
      drop_width(t, p, k, fit)

def take_width(s: String, n: Nat, k: Nat,
  fit: {Nat.is_le(k, String.length(String.take(s, n))) == True{} : Bool})
  -> {Nat.is_le(k, String.length(s)) == True{} : Bool}:
  match s n k:
    case _ _ 0n:
      zero_le(String.length(s))
    case SNil{} _ 1n+q:
      Empty.absurd({Nat.is_le(1n+q, 0n) == True{} : Bool},
        Arithmetic.false_is_not_true(fit))
    case SCon{h, t} 0n 1n+q:
      Empty.absurd({Nat.is_le(1n+q, 1n+String.length(t)) == True{} : Bool},
        Arithmetic.false_is_not_true(fit))
    case SCon{h, t} 1n+p 1n+q:
      take_width(t, p, q, fit)

def candidate_width(+s: String, +ending: Facts.SourceEnd,
  ok: {Facts.candidate(s, ending) == True{} : Bool})
  -> {Nat.is_le(36n, String.length(s)) == True{} : Bool}:
  drop_width(s, 24n, 11n, code_width(String.drop(s, 24n), ending,
    and_right(String.starts_with(s, "https://meet.google.com/"),
      Facts.code(String.drop(s, 24n), ending), ok)))

def candidate_within_width(+s: String, +fuel: Nat, +ending: Facts.SourceEnd,
  ok: {Facts.candidate_within(s, fuel, ending) == True{} : Bool})
  -> {Nat.is_le(36n, String.length(s)) == True{} : Bool}:
  take_width(s, Nat.min(fuel, 37n), 36n,
    candidate_width(String.take(s, Nat.min(fuel, 37n)),
      Bool.pick(Facts.SourceEnd, Nat.is_le(fuel, 36n), Facts.Prefix{}, ending), ok))

def add_mono(a: Nat, -b: Nat, -c: Nat, e: {Nat.is_le(b, c) == True{} : Bool})
  -> {Nat.is_le(Nat.add(a, b), Nat.add(a, c)) == True{} : Bool}:
  match a:
    case 0n:
      e
    case 1n+p:
      add_mono(p, b, c, e)

def width_positive(n: Nat) -> {Nat.is_lt(n, Nat.add(n, 36n)) == True{} : Bool}:
  match n:
    case 0n:
      {==}
    case 1n+p:
      width_positive(p)

def reversed_within(items: List<&2, Facts.Span>, acc: List<&2, Facts.Span>, +cap: Nat,
  safe: Observe.spans_within(cap, items), saved: Observe.spans_within(cap, acc))
  -> Observe.spans_within(cap, List.reverse.go(&2, Facts.Span, items, acc)):
  match items:
    case Nil{}:
      saved
    case head <> tail:
      (one, rest) = safe
      reversed_within(tail, head <> acc, cap, rest, (one, saved))

def accumulated(found: Bool, +left: Bool, +s: String, +fuel: Nat, +ending: Facts.SourceEnd,
  +offset: Nat, line: Nat, items: List<&2, Facts.Span>,
  ok: {Bool.and(left, Facts.candidate_within(s, fuel, ending)) == found : Bool},
  safe: Observe.spans_within(Nat.add(offset, String.length(s)), items))
  -> Observe.spans_within(Nat.add(offset, String.length(s)),
    Facts.put(found, Facts.Span{offset, Nat.add(offset, 36n), line}, items)):
  match found:
    case True{}:
      (({==}, (width_positive(offset), add_mono(offset, 36n, String.length(s),
        candidate_within_width(s, fuel, ending,
          and_right(left, Facts.candidate_within(s, fuel, ending), ok))))), safe)
    case False{}:
      safe

def transport(-from: Nat, -to: Nat, -items: List<&2, Facts.Span>,
  equality: {from == to : Nat}, proof: Observe.spans_within(from, items))
  -> Observe.spans_within(to, items):
  %equality : Observe.spans_within(_, items)
  proof

def scan_bounds(fuel: Nat, s: String, remaining: Nat, +ending: Facts.SourceEnd,
  +left: Bool, +offset: Nat, +line: Nat, +items: List<&2, Facts.Span>,
  safe: Observe.spans_within(Nat.add(offset, String.length(s)), items))
  -> Observe.spans_within(Nat.add(offset, String.length(s)),
    Observe.spans(Facts.scan(fuel, s, remaining, ending, left, offset, line, items))):
  match fuel s remaining:
    case 0n _ _:
      reversed_within(items, [], Nat.add(offset, String.length(s)), safe, Unit{})
    case 1n+rest _ 0n:
      reversed_within(items, [], Nat.add(offset, String.length(s)), safe, Unit{})
    case 1n+rest SNil{} 1n+more:
      reversed_within(items, [], Nat.add(offset, 0n), safe, Unit{})
    case 1n+ +rest SCon{+c, +t} 1n+ +more:
      +found = left && Facts.candidate_within(SCon{c, t}, 1n+rest, ending)
      +next = Facts.put(found, Facts.Span{offset, Nat.add(offset, 36n), line}, items)
      +before = Nat.add(offset, 1n+String.length(t))
      +after = Nat.add(1n+offset, String.length(t))
      +equal = Arithmetic.add_right_succ(offset, String.length(t))
      moved = transport(before, after, next, equal,
        accumulated(found, left, SCon{c, t}, 1n+rest, ending, offset, line, items, {==}, safe))
      transport(after, before,
        Observe.spans(Facts.scan(rest, t, Bool.pick(Nat, found, more, 1n+more), ending,
          Facts.left_boundary(c), 1n+offset,
          Bool.pick(Nat, U32.is_eq(Char.to_u32(c), 10), 1n+line, line), next)),
        Equal.sym(Nat, before, after, equal),
        scan_bounds(rest, t, Bool.pick(Nat, found, more, 1n+more), ending,
          Facts.left_boundary(c), 1n+offset,
          Bool.pick(Nat, U32.is_eq(Char.to_u32(c), 10), 1n+line, line), next, moved))

def extraction_bounds(+source: String, ending: Facts.SourceEnd)
  -> Observe.spans_within(String.length(source), Observe.spans(Facts.extract(source, ending))):
  scan_bounds(65536n, source, 16n, ending, True{}, 0n, 1n, [], Unit{})

def rendered_all(spans: List<&2, Facts.Span>, +source: String)
  -> Observe.emitted(source, spans, J.chain(Facts.render_all(spans, source))):
  match spans:
    case Nil{}:
      Unit{}
    case Facts.Span{start, end, line} <> rest:
      ({==}, ({==}, ({==}, ({==}, ({==}, rendered_all(rest, source))))))

def rendered_result(result: Facts.Extraction, +source: String)
  -> Observe.rendered(source, Observe.spans(result),
    J.get(J.obj(Facts.fields_of(result, source)), "facts")):
  match result:
    case Facts.Extraction{spans, limited}:
      rendered_all(spans, source)

def extracted_rendered(+source: String, ending: Facts.SourceEnd)
  -> Observe.rendered(source, Observe.spans(Facts.extract(source, ending)),
    J.get(J.obj(Facts.fields(source, ending)), "facts")):
  rendered_result(Facts.extract(source, ending), source)
