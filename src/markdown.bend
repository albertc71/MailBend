# Structured source bodies and bounded escaped HTML data for Markdown composition.

import Base
import ./codec.bend as Codec

type SourceBody is Data:
  TextBody{plain: String}
  MarkdownBody{caller: String, suffix: String}

def plain(body: SourceBody) -> String:
  match body:
    case TextBody{text}:
      text
    case MarkdownBody{caller, suffix}:
      caller ++ suffix

type Error is Data:
  OutputLimit{}
  InputLimit{}
  ControlInput{}
  InvalidScalar{}
  InlineLineRequired{}
  StructureLimit{}
  ParserInvariant{}

type Fragment is Data:
  Fragment{html: String, remaining: Nat}

type Output is Data:
  Output{remaining: Nat, reversed: List<&2, String>}

def html_limit() -> Nat:
  4194304n

def escape_scalar(c: Char) -> String:
  match c:
    case '&':
      "&amp;"
    case '<':
      "&lt;"
    case '>':
      "&gt;"
    case '"':
      "&quot;"
    case '\'':
      "&#39;"
    case _:
      SCon{c, ""}

def output_push.if(fits: Bool, chunk: String, remaining: Nat, width: Nat,
  reversed: List<&2, String>) -> Result<&2, &2, Error, Output>:
  match fits:
    case False{}:
      Fail{OutputLimit{}}
    case True{}:
      Done{Output{Nat.sub(remaining, width), chunk <> reversed}}

def output_push(+chunk: String, output: Output) -> Result<&2, &2, Error, Output>:
  Output{+remaining, reversed} = output
  +width = String.length(Codec.utf8_encode(chunk))
  output_push.if(Nat.is_le(width, remaining), chunk, remaining, width, reversed)

def escape_data.go(source: String, output: Result<&2, &2, Error, Output>)
  -> Result<&2, &2, Error, Fragment>:
  match source output:
    case _ Fail{error}:
      Fail{error}
    case SNil{} Done{Output{remaining, reversed}}:
      Done{Fragment{String.join(List.reverse(&2, String, reversed), ""), remaining}}
    case SCon{c, rest} Done{buffer}:
      escape_data.go(rest, output_push(escape_scalar(c), buffer))

def escape_data(source: String, room: Nat) -> Result<&2, &2, Error, Fragment>:
  escape_data.go(source, Done{Output{Nat.min(room, html_limit()), []}})

def render_suffix.wrap(result: Result<&2, &2, Error, Fragment>)
  -> Result<&2, &2, Error, Fragment>:
  match result:
    case Fail{error}:
      Fail{error}
    case Done{Fragment{html, remaining}}:
      Done{Fragment{"<blockquote><pre>" ++ html ++ "</pre></blockquote>", remaining}}

def render_suffix.begin(fits: Bool, suffix: String, room: Nat)
  -> Result<&2, &2, Error, Fragment>:
  match fits:
    case False{}:
      Fail{OutputLimit{}}
    case True{}:
      render_suffix.wrap(escape_data(suffix, Nat.sub(room, 36n)))

def render_suffix(suffix: String, room: Nat) -> Result<&2, &2, Error, Fragment>:
  match suffix:
    case SNil{}:
      Done{Fragment{"", Nat.min(room, html_limit())}}
    case SCon{c, rest}:
      +available = Nat.min(room, html_limit())
      render_suffix.begin(Nat.is_ge(available, 36n), SCon{c, rest}, available)

type Anchor is Data:
  Anchor{source_start: Nat, source_end: Nat, html_start: Nat, html_end: Nat}

type Inline is Data:
  Inline{
    html: String, remaining: Nat, events_left: Nat,
    anchors: List<&2, Anchor>
  }

type Span is Data:
  Span{start: Nat, end: Nat}

type Token is Data:
  Literal{data: String}
  Code{data: String}
  Emphasis{data: String}
  Strong{data: String}
  Link{label: String, destination: String, source: Span}

type Step is Data:
  Step{token: Token, rest: String, position: Nat}

type Emission is Data:
  Emission{html: String, remaining: Nat, anchor: Maybe<&2, Anchor>}

type InlineState is Data:
  InlineState{
    rest: String, position: Nat, remaining: Nat, events_left: Nat,
    html_length: Nat, chunks: List<&2, String>, anchors: List<&2, Anchor>
  }

def caller_limit() -> Nat:
  262144n

def structure_limit() -> Nat:
  65536n

def ascii_alnum(+c: Char) -> Bool:
  Char.is_alpha(c) || Char.is_digit(c)

def emphasis_space(c: Char) -> Bool:
  +n = Char.to_u32(c)
  (U32.is_ge(n, 9) && U32.is_le(n, 13)) || U32.is_eq(n, 32) ||
    U32.is_eq(n, 133) || U32.is_eq(n, 160) ||
    U32.is_eq(n, 5760) || (U32.is_ge(n, 8192) && U32.is_le(n, 8202)) ||
    U32.is_eq(n, 8232) || U32.is_eq(n, 8233) || U32.is_eq(n, 8239) ||
    U32.is_eq(n, 8287) || U32.is_eq(n, 12288)

def url_ascii(source: String, room: Nat, okay: Bool) -> Bool:
  match source room okay:
    case _ _ False{}:
      False{}
    case SNil{} _ True{}:
      True{}
    case SCon{c, rest} 0n True{}:
      False{}
    case SCon{c, rest} 1n+left True{}:
      +n = Char.to_u32(c)
      url_ascii(rest, left, U32.is_ge(n, 33) && U32.is_le(n, 126))

def host_scan(source: String, +label: Nat, +total: Nat, last_alnum: Bool,
  numeric: Bool, dotted: Bool, okay: Bool) -> Bool:
  match source okay:
    case _ False{}:
      False{}
    case SNil{} True{}:
      Nat.is_ge(label, 1n) && last_alnum && Bool.not(dotted && numeric)
    case SCon{'.', rest} True{}:
      host_scan(rest, 0n, 1n+total, False{}, numeric, True{},
        Nat.is_ge(label, 1n) && last_alnum && Nat.is_lt(total, 253n))
    case SCon{+c, rest} True{}:
      +alnum = ascii_alnum(c)
      host_scan(rest, 1n+label, 1n+total, alnum, numeric && Char.is_digit(c), dotted,
        Nat.is_lt(label, 63n) && Nat.is_lt(total, 253n) &&
        (alnum || (Char.is_eq(c, '-') && Nat.is_ge(label, 1n))))

def host_valid(source: String) -> Bool:
  host_scan(source, 0n, 0n, False{}, True{}, False{}, True{})

def port_value(valid: Bool, c: Char, value: Nat) -> Nat:
  match valid:
    case False{}:
      0n
    case True{}:
      Nat.add(Nat.mul(value, 10n), U32.to_nat(U32.sub(Char.to_u32(c), 48)))

def port_scan(source: String, +digits: Nat, +value: Nat, okay: Bool) -> Bool:
  match source okay:
    case _ False{}:
      False{}
    case SNil{} True{}:
      Nat.is_ge(digits, 1n) && Nat.is_ge(value, 1n) && Nat.is_le(value, 65535n)
    case SCon{+c, rest} True{}:
      +valid = Char.is_digit(c) && Nat.is_lt(digits, 5n)
      port_scan(rest, 1n+digits, port_value(valid, c, value), valid)

def authority_scan(source: String, reversed: String) -> Bool:
  match source:
    case SNil{}:
      host_valid(String.reverse(reversed))
    case SCon{':', rest}:
      host_valid(String.reverse(reversed)) && port_scan(rest, 0n, 0n, True{})
    case SCon{c, rest}:
      authority_scan(rest, SCon{c, reversed})

def tail_valid(source: String, okay: Bool) -> Bool:
  match source okay:
    case _ False{}:
      False{}
    case SNil{} True{}:
      True{}
    case SCon{+c, rest} True{}:
      tail_valid(rest, ascii_alnum(c) || String.contains("-._~:/?&=+#,@!$", SCon{c, ""}))

def http_scan(source: String, authority: String) -> Bool:
  match source:
    case SNil{}:
      authority_scan(String.reverse(authority), "")
    case SCon{'/', rest}:
      authority_scan(String.reverse(authority), "") && tail_valid(rest, True{})
    case SCon{'?', rest}:
      authority_scan(String.reverse(authority), "") && tail_valid(rest, True{})
    case SCon{'#', rest}:
      authority_scan(String.reverse(authority), "") && tail_valid(rest, True{})
    case SCon{c, rest}:
      http_scan(rest, SCon{c, authority})

def mailto_scan(source: String, +length: Nat, after_dot: Bool, okay: Bool) -> Bool:
  match source okay:
    case _ False{}:
      False{}
    case SNil{} True{}:
      False{}
    case SCon{'@', domain} True{}:
      Nat.is_ge(length, 1n) && Bool.not(after_dot) && host_valid(domain)
    case SCon{'.', rest} True{}:
      mailto_scan(rest, 1n+length, True{},
        Nat.is_lt(length, 64n) && Nat.is_ge(length, 1n) && Bool.not(after_dot))
    case SCon{+c, rest} True{}:
      mailto_scan(rest, 1n+length, False{},
        Nat.is_lt(length, 64n) &&
        (ascii_alnum(c) || String.contains("_+-", SCon{c, ""})))

def destination_scheme(source: String) -> Bool:
  match source:
    case SCon{'h', SCon{'t', SCon{'t', SCon{'p', SCon{':', SCon{'/', SCon{'/', rest}}}}}}}:
      http_scan(rest, "")
    case SCon{'h', SCon{'t', SCon{'t', SCon{'p',
      SCon{'s', SCon{':', SCon{'/', SCon{'/', rest}}}}}}}}:
      http_scan(rest, "")
    case SCon{'m', SCon{'a', SCon{'i', SCon{'l',
      SCon{'t', SCon{'o', SCon{':', rest}}}}}}}:
      mailto_scan(rest, 0n, False{}, True{})
    case _:
      False{}

def valid_destination.if(ascii: Bool, source: String) -> Bool:
  match ascii:
    case False{}:
      False{}
    case True{}:
      destination_scheme(source)

def valid_destination(+source: String) -> Bool:
  valid_destination.if(url_ascii(source, 2048n, True{}), source)

def literal_remainder(source: String, position: Nat, reversed: String) -> Step:
  match source:
    case SNil{}:
      Step{Literal{String.reverse(reversed)}, "", position}
    case SCon{c, rest}:
      literal_remainder(rest, 1n+position, SCon{c, reversed})

type Run is Data:
  Run{rest: String, position: Nat, length: Nat, reversed: String}

def head_is(source: String, delimiter: Char) -> Bool:
  match source:
    case SNil{}:
      False{}
    case SCon{c, rest}:
      Char.is_eq(c, delimiter)

def delimiter_run(source: String, position: Nat, +delimiter: Char,
  length: Nat, reversed: String, same: Bool) -> Run:
  match source same:
    case _ False{}:
      Run{source, position, length, reversed}
    case SNil{} True{}:
      Run{"", position, length, reversed}
    case SCon{c, +rest} True{}:
      delimiter_run(rest, 1n+position, delimiter, 1n+length,
        SCon{c, reversed}, head_is(rest, delimiter))

def emphasis_char(c: Char) -> Bool:
  Bool.not(String.contains("*`[]\\", SCon{c, ""}))

def delimited_token(delimiter: Char, width: Nat, body: String) -> Token:
  match delimiter width:
    case '`' _:
      Code{body}
    case _ 1n:
      Emphasis{body}
    case _ _:
      Strong{body}

def delimiter_finish(accepted: Bool, delimiter: Char, width: Nat,
  body_reversed: String, closing: Run) -> Step:
  match accepted:
    case False{}:
      Run{rest, position, length, reversed} = closing
      Step{Literal{String.reverse(reversed)}, rest, position}
    case True{}:
      Run{rest, position, length, reversed} = closing
      Step{delimited_token(delimiter, width, String.reverse(body_reversed)), rest, position}

def delimiter_close(delimiter: Char, +width: Nat, body_reversed: String,
  valid: Bool, nonempty: Bool, edge_ok: Bool, closing: Run) -> Step:
  Run{rest, position, +length, reversed} = closing
  delimiter_finish(Nat.is_eq(width, length) && valid && nonempty && edge_ok,
    delimiter, width, body_reversed, Run{rest, position, length, reversed})

def delimiter_body(source: String, position: Nat, +delimiter: Char, width: Nat,
  reversed: String, body_reversed: String, valid: Bool, nonempty: Bool, edge_ok: Bool,
  closing: Bool) -> Step:
  match source closing:
    case SNil{} _:
      Step{Literal{String.reverse(reversed)}, "", position}
    case _ True{}:
      delimiter_close(delimiter, width, body_reversed, valid, nonempty, edge_ok,
        delimiter_run(source, position, delimiter, 0n, reversed, True{}))
    case SCon{+c, +rest} False{}:
      +code = Char.is_eq(delimiter, '`')
      +not_space = Bool.not(emphasis_space(c))
      delimiter_body(rest, 1n+position, delimiter, width,
        SCon{c, reversed}, SCon{c, body_reversed},
        valid && (code || emphasis_char(c)) && (nonempty || code || not_space),
        True{}, code || not_space, head_is(rest, delimiter))

def delimiter_open(eligible: Bool, +delimiter: Char, run: Run) -> Step:
  match eligible run:
    case False{} Run{rest, position, length, reversed}:
      Step{Literal{String.reverse(reversed)}, rest, position}
    case True{} Run{SNil{}, position, length, reversed}:
      Step{Literal{String.reverse(reversed)}, "", position}
    case True{} Run{SCon{+c, rest}, position, length, reversed}:
      delimiter_body(SCon{c, rest}, position, delimiter, length, reversed, "",
        True{}, False{}, False{}, Char.is_eq(c, delimiter))

def delimiter_start(+delimiter: Char, run: Run) -> Step:
  Run{rest, position, +length, reversed} = run
  delimiter_open(Nat.is_eq(length, 1n) ||
    (Char.is_eq(delimiter, '*') && Nat.is_eq(length, 2n)),
    delimiter, Run{rest, position, length, reversed})

def bracket_finish(accepted: Bool, label_reversed: String, destination: String,
  start: Nat, +end: Nat, reversed: String, rest: String) -> Step:
  match accepted:
    case False{}:
      Step{Literal{String.reverse(reversed)}, rest, 1n+end}
    case True{}:
      Step{Link{String.reverse(label_reversed), destination,
        Span{start, end}}, rest, 1n+end}

def bracket_candidate.if(eligible: Bool, label_reversed: String,
  destination_reversed: String, start: Nat, end: Nat, reversed: String, rest: String) -> Step:
  match eligible:
    case False{}:
      Step{Literal{String.reverse(reversed)}, rest, 1n+end}
    case True{}:
      +destination = String.reverse(destination_reversed)
      bracket_finish(valid_destination(destination), label_reversed, destination,
        start, end, reversed, rest)

def bracket_candidate(image: Bool, valid_label: Bool, label_reversed: String,
  destination_reversed: String, start: Nat, end: Nat, reversed: String, rest: String)
  -> Step:
  bracket_candidate.if(Bool.not(image) && valid_label,
    label_reversed, destination_reversed, start, end, reversed, rest)

def bracket_destination(source: String, +position: Nat, image: Bool, valid_label: Bool,
  label_reversed: String, start: Nat, destination_reversed: String, reversed: String) -> Step:
  match source:
    case SNil{}:
      Step{Literal{String.reverse(reversed)}, "", position}
    case SCon{')', rest}:
      bracket_candidate(image, valid_label, label_reversed, destination_reversed,
        start, position, SCon{')', reversed}, rest)
    case SCon{+c, rest}:
      bracket_destination(rest, 1n+position, image, valid_label, label_reversed, start,
        SCon{c, destination_reversed}, SCon{c, reversed})

def bracket_after_label(source: String, +position: Nat, image: Bool, valid_label: Bool,
  label_reversed: String, reversed: String) -> Step:
  match source:
    case SCon{'(', rest}:
      bracket_destination(rest, 1n+position, image, valid_label, label_reversed,
        1n+position, "", SCon{'(', reversed})
    case _:
      literal_remainder(source, position, reversed)

def bracket_label(source: String, position: Nat, image: Bool, valid: Bool,
  nonempty: Bool, label_reversed: String, reversed: String) -> Step:
  match source:
    case SNil{}:
      Step{Literal{String.reverse(reversed)}, "", position}
    case SCon{']', rest}:
      bracket_after_label(rest, 1n+position, image, valid && nonempty,
        label_reversed, SCon{']', reversed})
    case SCon{+c, rest}:
      bracket_label(rest, 1n+position, image,
        valid && Bool.not(Char.is_eq(c, '[') || Char.is_eq(c, '\\')), True{},
        SCon{c, label_reversed}, SCon{c, reversed})

def token_at(source: String, position: Nat) -> Step:
  match source:
    case SNil{}:
      Step{Literal{""}, "", position}
    case SCon{'\\', SCon{c, rest}}:
      Step{Literal{SCon{'\\', SCon{c, ""}}}, rest, Nat.add(position, 2n)}
    case SCon{'!', SCon{'[', rest}}:
      bracket_label(rest, Nat.add(position, 2n), True{}, True{}, False{}, "", "[!")
    case SCon{'[', rest}:
      bracket_label(rest, 1n+position, False{}, True{}, False{}, "", "[")
    case SCon{'*', rest}:
      delimiter_start('*', delimiter_run(SCon{'*', rest}, position, '*', 0n, "", True{}))
    case SCon{'`', rest}:
      delimiter_start('`',
        delimiter_run(SCon{'`', rest}, position, '`', 0n, "", True{}))
    case SCon{c, rest}:
      Step{Literal{SCon{c, ""}}, rest, 1n+position}

def inline_event(source: String) -> Bool:
  match source:
    case SCon{'!', SCon{'[', rest}}:
      True{}
    case SCon{'[', rest}:
      True{}
    case SCon{'*', rest}:
      True{}
    case SCon{'`', rest}:
      True{}
    case _:
      False{}

def emission_wrap(result: Result<&2, &2, Error, Fragment>, open: String, close: String)
  -> Result<&2, &2, Error, Emission>:
  match result:
    case Fail{error}:
      Fail{error}
    case Done{Fragment{html, remaining}}:
      Done{Emission{open ++ html ++ close, remaining, None{}}}

def emission_data(fits: Bool, data: String, room: Nat,
  open: String, close: String, cost: Nat) -> Result<&2, &2, Error, Emission>:
  match fits:
    case False{}:
      Fail{OutputLimit{}}
    case True{}:
      emission_wrap(escape_data(data, Nat.sub(room, cost)), open, close)

def emission_link.label(result: Result<&2, &2, Error, Fragment>,
  +href: String, source: Span) -> Result<&2, &2, Error, Emission>:
  match result:
    case Fail{error}:
      Fail{error}
    case Done{Fragment{label, remaining}}:
      Span{start, end} = source
      Done{Emission{"<a href=\"" ++ href ++ "\">" ++ label ++ "</a>", remaining,
        Some{Anchor{start, end, 9n, Nat.add(9n, String.length(href))}}}}

def emission_link.href(result: Result<&2, &2, Error, Fragment>,
  label: String, source: Span) -> Result<&2, &2, Error, Emission>:
  match result:
    case Fail{error}:
      Fail{error}
    case Done{Fragment{href, remaining}}:
      emission_link.label(escape_data(label, remaining), href, source)

def emission_link(fits: Bool, label: String, destination: String, source: Span, room: Nat)
  -> Result<&2, &2, Error, Emission>:
  match fits:
    case False{}:
      Fail{OutputLimit{}}
    case True{}:
      emission_link.href(escape_data(destination, Nat.sub(room, 15n)), label, source)

def emit_token(token: Token, +room: Nat) -> Result<&2, &2, Error, Emission>:
  match token:
    case Literal{data}:
      emission_wrap(escape_data(data, room), "", "")
    case Code{data}:
      emission_data(Nat.is_ge(room, 13n), data, room, "<code>", "</code>", 13n)
    case Emphasis{data}:
      emission_data(Nat.is_ge(room, 9n), data, room, "<em>", "</em>", 9n)
    case Strong{data}:
      emission_data(Nat.is_ge(room, 17n), data, room, "<strong>", "</strong>", 17n)
    case Link{label, destination, source}:
      emission_link(Nat.is_ge(room, 15n), label, destination, source, room)

def anchor_put(anchor: Maybe<&2, Anchor>, +offset: Nat, anchors: List<&2, Anchor>)
  -> List<&2, Anchor>:
  match anchor:
    case None{}:
      anchors
    case Some{Anchor{start, end, html_start, html_end}}:
      Anchor{start, end, Nat.add(html_start, offset), Nat.add(html_end, offset)} <> anchors

def inline_store(emitted: Result<&2, &2, Error, Emission>, rest: String, position: Nat,
  events: Nat, +html_length: Nat, chunks: List<&2, String>, anchors: List<&2, Anchor>)
  -> Result<&2, &2, Error, InlineState>:
  match emitted:
    case Fail{error}:
      Fail{error}
    case Done{Emission{+html, remaining, anchor}}:
      Done{InlineState{rest, position, remaining, events,
        Nat.add(String.length(html), html_length), html <> chunks,
        anchor_put(anchor, html_length, anchors)}}

def inline_consume(step: Step, remaining: Nat, events: Nat, html_length: Nat,
  chunks: List<&2, String>, anchors: List<&2, Anchor>)
  -> Result<&2, &2, Error, InlineState>:
  Step{token, rest, position} = step
  inline_store(emit_token(token, remaining), rest, position, events, html_length, chunks, anchors)

def inline_charge(events: Nat, event: Bool, source: String, position: Nat, remaining: Nat,
  html_length: Nat, chunks: List<&2, String>, anchors: List<&2, Anchor>)
  -> Result<&2, &2, Error, InlineState>:
  match events event:
    case 0n True{}:
      Fail{StructureLimit{}}
    case 1n+left True{}:
      inline_consume(token_at(source, position), remaining, left, html_length, chunks, anchors)
    case _ False{}:
      inline_consume(token_at(source, position), remaining, events, html_length, chunks, anchors)

def inline_advance(state: InlineState) -> Result<&2, &2, Error, InlineState>:
  InlineState{+rest, position, remaining, events, html_length, chunks, anchors} = state
  inline_charge(events, inline_event(rest), rest, position, remaining, html_length, chunks, anchors)

def inline_scan(fuel: Nat, state: Result<&2, &2, Error, InlineState>)
  -> Result<&2, &2, Error, Inline>:
  match fuel state:
    case _ Fail{error}:
      Fail{error}
    case _ Done{InlineState{SNil{}, position, remaining, events, html_length, chunks, anchors}}:
      Done{Inline{String.join(List.reverse(&2, String, chunks), ""), remaining, events,
        List.reverse(&2, Anchor, anchors)}}
    case 0n Done{unfinished}:
      Fail{ParserInvariant{}}
    case 1n+left Done{ready}:
      inline_scan(left, inline_advance(ready))

type LineInfo is Data:
  LineInfo{scalars: Nat, nonblank: Bool}

def scalar_valid(c: Char) -> Bool:
  +n = Char.to_u32(c)
  U32.is_le(n, 1114111) && Bool.not(U32.is_ge(n, 55296) && U32.is_le(n, 57343))

def control_allowed(+c: Char) -> Bool:
  +n = Char.to_u32(c)
  (U32.is_ge(n, 32) || Char.is_eq(c, '\t') || Char.is_eq(c, '\r') || Char.is_eq(c, '\n')) &&
    Bool.not(U32.is_ge(n, 128) && U32.is_le(n, 159))

def line_info(controls: Bool, scalars_valid: Bool, multiline: Bool,
  scalars: Nat, nonblank: Bool) -> Result<&2, &2, Error, LineInfo>:
  match controls scalars_valid multiline:
    case False{} _ _:
      Fail{ControlInput{}}
    case True{} False{} _:
      Fail{InvalidScalar{}}
    case True{} True{} True{}:
      Fail{InlineLineRequired{}}
    case True{} True{} False{}:
      Done{LineInfo{scalars, nonblank}}

def line_check(source: String, +room: Nat, scalars: Nat, nonblank: Bool,
  controls: Bool, valid: Bool, multiline: Bool, fits: Bool)
  -> Result<&2, &2, Error, LineInfo>:
  match source fits:
    case _ False{}:
      Fail{InputLimit{}}
    case SNil{} True{}:
      line_info(controls, valid, multiline, scalars, nonblank)
    case SCon{+c, rest} True{}:
      +width = U32.to_nat(Codec.utf8_width(Char.to_u32(c)))
      line_check(rest, Nat.sub(room, width), 1n+scalars,
        nonblank || Bool.not(Char.is_eq(c, ' ') || Char.is_eq(c, '\t')),
        controls && control_allowed(c), valid && scalar_valid(c),
        multiline || Char.is_eq(c, '\r') || Char.is_eq(c, '\n'), Nat.is_le(width, room))

def inline_begin(events: Nat, source: String, scalars: Nat, room: Nat)
  -> Result<&2, &2, Error, Inline>:
  match events:
    case 0n:
      Fail{StructureLimit{}}
    case 1n+left:
      inline_scan(scalars, Done{InlineState{source, 0n, room, left, 0n, [], []}})

def render_inline_line.checked(result: Result<&2, &2, Error, LineInfo>,
  source: String, room: Nat, events: Nat) -> Result<&2, &2, Error, Inline>:
  match result:
    case Fail{error}:
      Fail{error}
    case Done{LineInfo{scalars, False{}}}:
      Done{Inline{"", room, events, []}}
    case Done{LineInfo{scalars, True{}}}:
      inline_begin(events, source, scalars, room)

def render_inline_line(+source: String, room: Nat, events: Nat)
  -> Result<&2, &2, Error, Inline>:
  render_inline_line.checked(
    line_check(source, caller_limit(), 0n, False{}, True{}, True{}, False{}, True{}),
    source, Nat.min(room, html_limit()), Nat.min(events, structure_limit()))




