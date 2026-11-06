import Base
import ./json.bend as J

type SourceEnd is Data:
  Complete{}
  Prefix{}

type Span is Data:
  Span{start: Nat, end: Nat, line: Nat}

def lowercase(+c: Char) -> Bool:
  U32.is_ge(Char.to_u32(c), 97) && U32.is_le(Char.to_u32(c), 122)

def complete(ending: SourceEnd) -> Bool:
  match ending:
    case Complete{}:
      True{}
    case Prefix{}:
      False{}

def whitespace(c: Char) -> Bool:
  match c:
    case ' ':
      True{}
    case '\t':
      True{}
    case '\r':
      True{}
    case '\n':
      True{}
    case _:
      False{}

def left_boundary(+c: Char) -> Bool:
  whitespace(c) || String.contains("([{<\"'", SCon{c, ""})

def right_boundary(s: String, ending: SourceEnd) -> Bool:
  match s:
    case SNil{}:
      complete(ending)
    case SCon{+c, rest}:
      whitespace(c) || String.contains(")]}>\"'", SCon{c, ""})

def code(s: String, ending: SourceEnd) -> Bool:
  match s:
    case SCon{a, SCon{b, SCon{c, SCon{sep1, SCon{d, SCon{e, SCon{f, SCon{g,
      SCon{sep2, SCon{h, SCon{i, SCon{j, rest}}}}}}}}}}}}:
      Char.is_eq(sep1, '-') && Char.is_eq(sep2, '-') && lowercase(a) && lowercase(b) &&
        lowercase(c) && lowercase(d) && lowercase(e) &&
        lowercase(f) && lowercase(g) && lowercase(h) && lowercase(i) && lowercase(j) &&
        right_boundary(rest, ending)
    case _:
      False{}

def candidate(+s: String, ending: SourceEnd) -> Bool:
  String.starts_with(s, "https://meet.google.com/") && code(String.drop(s, 24n), ending)

def candidate_within(source: String, +fuel: Nat, ending: SourceEnd) -> Bool:
  effective = Bool.pick(SourceEnd, Nat.is_le(fuel, 36n), Prefix{}, ending)
  candidate(String.take(source, Nat.min(fuel, 37n)), effective)

type Extraction is Data:
  Extraction{spans: List<&2, Span>, limited: Bool}

def put(found: Bool, span: Span, rest: List<&2, Span>) -> List<&2, Span>:
  match found:
    case True{}:
      span <> rest
    case False{}:
      rest

def scan(fuel: Nat, s: String, remaining: Nat, +ending: SourceEnd, left: Bool,
  +offset: Nat, +line: Nat, spans: List<&2, Span>) -> Extraction:
  match fuel s remaining:
    case 0n _ _:
      Extraction{List.reverse(&2, Span, spans), True{}}
    case 1n+rest _ 0n:
      Extraction{List.reverse(&2, Span, spans), True{}}
    case 1n+rest SNil{} 1n+more:
      Extraction{List.reverse(&2, Span, spans), Bool.not(complete(ending))}
    case 1n+ +rest SCon{+c, +t} 1n+ +more:
      +found = left && candidate_within(SCon{c, t}, 1n+rest, ending)
      scan(rest, t, Bool.pick(Nat, found, more, 1n+more), ending, left_boundary(c),
        1n+offset, Bool.pick(Nat, U32.is_eq(Char.to_u32(c), 10), 1n+line, line),
        put(found, Span{offset, Nat.add(offset, 36n), line}, spans))

def extract(source: String, ending: SourceEnd) -> Extraction:
  scan(65536n, source, 16n, ending, True{}, 0n, 1n, [])

def render(+source: String, span: Span) -> J.Json:
  Span{+start, +end, line} = span
  J.obj([J.kv("kind", J.str("meeting_link")),
    J.kv("value", J.str(String.take(String.drop(source, start), Nat.sub(end, start)))),
    J.kv("source", J.str("text")), J.kv("start", J.JNum{Nat.show(start)}),
    J.kv("end", J.JNum{Nat.show(end)}), J.kv("line", J.JNum{Nat.show(line)}),
    J.kv("untrusted", J.bool(True{}))])

def render_all(spans: List<&2, Span>, +source: String) -> List<&2, J.Json>:
  match spans:
    case Nil{}:
      []
    case span <> rest:
      render(source, span) <> render_all(rest, source)

def fields_of(result: Extraction, +source: String) -> List<&2, J.Json>:
  Extraction{spans, limited} = result
  [J.kv("facts", J.arr(render_all(spans, source))),
    J.kv("facts_scan", J.obj([J.kv("scope", J.str("returned_text")),
      J.kv("limited", J.bool(limited))]))]

def fields(+source: String, ending: SourceEnd) -> List<&2, J.Json>:
  fields_of(extract(source, ending), source)
