import Base
import ./json.bend as J

type SourceEnd is Data:
  Complete{}
  Prefix{}

type Span is Data:
  Span{start: Nat, end: Nat, line: Nat}
  ZoomSpan{start: Nat, end: Nat, line: Nat}

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

def digit(+c: Char) -> Bool:
  U32.is_ge(Char.to_u32(c), 48) && U32.is_le(Char.to_u32(c), 57)

def label_alnum(+c: Char) -> Bool:
  lowercase(c) || digit(c)

def ascii_alnum(+c: Char) -> Bool:
  label_alnum(c) || (U32.is_ge(Char.to_u32(c), 65) && U32.is_le(Char.to_u32(c), 90))

def hex_digit(+c: Char) -> Bool:
  digit(c) || (U32.is_ge(Char.to_u32(c), 65) && U32.is_le(Char.to_u32(c), 70)) ||
    (U32.is_ge(Char.to_u32(c), 97) && U32.is_le(Char.to_u32(c), 102))

def zoom_query(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{'%', SCon{a, SCon{b, tail}}}:
      hex_digit(a) && hex_digit(b) && zoom_query(tail)
    case SCon{'%', _}:
      False{}
    case SCon{+c, rest}:
      (ascii_alnum(c) || String.contains("-._~=&+", SCon{c, ""})) && zoom_query(rest)

def zoom_id(s: String, +digits: Nat, valid: Bool) -> Bool:
  match s valid:
    case _ False{}:
      False{}
    case SNil{} True{}:
      Nat.is_le(9n, digits) && Nat.is_le(digits, 11n)
    case SCon{'?', SCon{c, rest}} True{}:
      Nat.is_le(9n, digits) && Nat.is_le(digits, 11n) && zoom_query(SCon{c, rest})
    case SCon{c, rest} True{}:
      zoom_id(rest, 1n+digits, digit(c) && Nat.is_lt(digits, 11n))

def zoom_label(s: String, +width: Nat, last_alnum: Bool, valid: Bool) -> Bool:
  match s valid:
    case _ False{}:
      False{}
    case SNil{} True{}:
      False{}
    case SCon{'.', +rest} True{}:
      last_alnum && String.starts_with(rest, "zoom.us/j/") &&
        zoom_id(String.drop(rest, 10n), 0n, True{})
    case SCon{+c, rest} True{}:
      zoom_label(rest, 1n+width, label_alnum(c),
        Nat.is_lt(width, 63n) && (label_alnum(c) || Char.is_eq(c, '-')))

def zoom_host.label(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+c, rest}:
      zoom_label(rest, 1n, label_alnum(c), label_alnum(c))

def zoom_host.select(s: String, apex: Bool) -> Bool:
  match apex:
    case True{}:
      zoom_id(String.drop(s, 10n), 0n, True{})
    case False{}:
      zoom_host.label(s)

def zoom_host(+s: String) -> Bool:
  zoom_host.select(s, String.starts_with(s, "zoom.us/j/"))

def zoom_url(+s: String) -> Bool:
  String.starts_with(s, "https://") && zoom_host(String.drop(s, 8n))

def zoom_token.go(s: String, fuel: Nat, room: Nat, ending: SourceEnd,
  finished: Bool, +rev: String) -> Maybe<&2, String>:
  match s fuel room finished:
    case _ _ _ True{}:
      Some{String.reverse(rev)}
    case _ 0n _ False{}:
      None{}
    case SNil{} 1n+rest _ False{}:
      Bool.pick(Maybe<&2, String>, complete(ending), Some{String.reverse(rev)}, None{})
    case SCon{c, tail} 1n+rest 0n False{}:
      Bool.pick(Maybe<&2, String>, right_boundary(SCon{c, ""}, Prefix{}),
        Some{String.reverse(rev)}, None{})
    case SCon{+c, tail} 1n+rest 1n+more False{}:
      +boundary = right_boundary(SCon{c, ""}, Prefix{})
      zoom_token.go(tail, rest, more, ending, boundary,
        Bool.pick(String, boundary, rev, SCon{c, rev}))

def zoom_token(s: String, fuel: Nat, room: Nat, ending: SourceEnd) -> Maybe<&2, String>:
  zoom_token.go(s, fuel, room, ending, False{}, "")

def zoom_admit(+width: Nat, +bound: Nat, accepted: Bool) -> Nat:
  Bool.pick(Nat, accepted && Nat.is_lt(0n, width) && Nat.is_le(width, 512n) &&
    Nat.is_le(width, bound), width, 0n)

def zoom_candidate_within.collected(result: Maybe<&2, String>, bound: Nat) -> Nat:
  match result:
    case None{}:
      0n
    case Some{+token}:
      zoom_admit(String.length(token), bound, zoom_url(token))

def zoom_candidate_within.prefix(source: String, +fuel: Nat, ending: SourceEnd,
  has_prefix: Bool) -> Nat:
  match has_prefix:
    case False{}:
      0n
    case True{}:
      +bounded = String.take(source, Nat.min(fuel, 513n))
      zoom_candidate_within.collected(zoom_token(bounded, fuel, 512n, ending), String.length(bounded))

def zoom_candidate_within(+source: String, +fuel: Nat, ending: SourceEnd) -> Nat:
  zoom_candidate_within.prefix(source, fuel, ending,
    String.starts_with(String.take(source, Nat.min(fuel, 8n)), "https://"))

def zoom_at_boundary(source: String, fuel: Nat, ending: SourceEnd, left: Bool) -> Nat:
  match left:
    case False{}:
      0n
    case True{}:
      zoom_candidate_within(source, fuel, ending)

type Extraction is Data:
  Extraction{spans: List<&2, Span>, limited: Bool}

def put(found: Bool, span: Span, rest: List<&2, Span>) -> List<&2, Span>:
  match found:
    case True{}:
      span <> rest
    case False{}:
      rest

def scan(fuel: Nat, s: String, remaining: Nat, +ending: SourceEnd, +left: Bool,
  +offset: Nat, +line: Nat, spans: List<&2, Span>) -> Extraction:
  match fuel s remaining:
    case 0n _ _:
      Extraction{List.reverse(&2, Span, spans), True{}}
    case 1n+rest _ 0n:
      Extraction{List.reverse(&2, Span, spans), True{}}
    case 1n+rest SNil{} 1n+more:
      Extraction{List.reverse(&2, Span, spans), Bool.not(complete(ending))}
    case 1n+ +rest SCon{+c, +t} 1n+ +more:
      +meet = left && candidate_within(SCon{c, t}, 1n+rest, ending)
      +zoom = zoom_at_boundary(SCon{c, t}, 1n+rest, ending, left)
      +found = meet || Nat.is_lt(0n, zoom)
      span = Bool.pick(Span, meet, Span{offset, Nat.add(offset, 36n), line},
        ZoomSpan{offset, Nat.add(offset, zoom), line})
      scan(rest, t, Bool.pick(Nat, found, more, 1n+more), ending, left_boundary(c),
        1n+offset, Bool.pick(Nat, U32.is_eq(Char.to_u32(c), 10), 1n+line, line),
        put(found, span, spans))

def extract(source: String, ending: SourceEnd) -> Extraction:
  scan(65536n, source, 16n, ending, True{}, 0n, 1n, [])

def render_bounds(+source: String, +start: Nat, +end: Nat, line: Nat) -> J.Json:
  J.obj([J.kv("kind", J.str("meeting_link")),
    J.kv("value", J.str(String.take(String.drop(source, start), Nat.sub(end, start)))),
    J.kv("source", J.str("text")), J.kv("start", J.JNum{Nat.show(start)}),
    J.kv("end", J.JNum{Nat.show(end)}), J.kv("line", J.JNum{Nat.show(line)}),
    J.kv("untrusted", J.bool(True{}))])

def render(source: String, span: Span) -> J.Json:
  match span:
    case Span{start, end, line}:
      render_bounds(source, start, end, line)
    case ZoomSpan{start, end, line}:
      render_bounds(source, start, end, line)

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

