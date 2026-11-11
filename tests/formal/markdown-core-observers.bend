# Independent fragment observers and unverified Markdown core obligations.

import Base
import ../../src/markdown.bend as Markdown
import ../../src/codec.bend as Codec

def escaped_fragment(text: String) -> Bool:
  match text:
    case SNil{}:
      True{}
    case SCon{'&', SCon{'a', SCon{'m', SCon{'p', SCon{';', rest}}}}}:
      escaped_fragment(rest)
    case SCon{'&', SCon{'l', SCon{'t', SCon{';', rest}}}}:
      escaped_fragment(rest)
    case SCon{'&', SCon{'g', SCon{'t', SCon{';', rest}}}}:
      escaped_fragment(rest)
    case SCon{'&', SCon{'q', SCon{'u', SCon{'o', SCon{'t', SCon{';', rest}}}}}}:
      escaped_fragment(rest)
    case SCon{'&', SCon{'#', SCon{'3', SCon{'9', SCon{';', rest}}}}}:
      escaped_fragment(rest)
    case SCon{'&', rest}:
      False{}
    case SCon{'<', rest}:
      False{}
    case SCon{'>', rest}:
      False{}
    case SCon{'"', rest}:
      False{}
    case SCon{'\'', rest}:
      False{}
    case SCon{c, rest}:
      escaped_fragment(rest)

def escaped_result(result: Result<&2, &2, Markdown.Error, Markdown.Fragment>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Fragment{html, remaining}}:
      escaped_fragment(html)

def bytes_conserved(+room: Nat,
  result: Result<&2, &2, Markdown.Error, Markdown.Fragment>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Fragment{html, remaining}}:
      Nat.is_eq(Nat.add(String.length(Codec.utf8_encode(html)), remaining),
        Nat.min(room, 4194304n))

def no_anchor(result: Result<&2, &2, Markdown.Error, Markdown.Fragment>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Fragment{html, remaining}}:
      Bool.not(String.contains(html, "<a"))

def suffix_fragment.if(framed: Bool, text: String) -> Bool:
  match framed:
    case False{}:
      False{}
    case True{}:
      +content_and_close = String.drop(text, 17n)
      escaped_fragment(String.take(content_and_close,
        Nat.sub(String.length(content_and_close), 19n)))

def suffix_fragment(text: String) -> Bool:
  match text:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      +html = SCon{c, rest}
      suffix_fragment.if(Nat.is_ge(String.length(html), 36n) &&
        String.starts_with(html, "<blockquote><pre>") &&
        String.ends_with(html, "</pre></blockquote>"), html)

def suffix_result(result: Result<&2, &2, Markdown.Error, Markdown.Fragment>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Fragment{html, remaining}}:
      suffix_fragment(html)

law text_projection:
  for text: String
  {Markdown.plain(Markdown.TextBody{text}) == text : String}

def text_projection(text):
  {==}

law markdown_projection:
  for caller: String
  for suffix: String
  {Markdown.plain(Markdown.MarkdownBody{caller, suffix}) == caller ++ suffix : String}

def markdown_projection(caller, suffix):
  {==}

law escape_language:
  for source: String
  for room: Nat
  {escaped_result(Markdown.escape_data(source, room)) == True{} : Bool}

law escape_byte_accounting:
  for source: String
  for room: Nat
  {bytes_conserved(room, Markdown.escape_data(source, room)) == True{} : Bool}

law suffix_byte_accounting:
  for source: String
  for room: Nat
  {bytes_conserved(room, Markdown.render_suffix(source, room)) == True{} : Bool}

law suffix_no_anchor:
  for source: String
  for room: Nat
  {no_anchor(Markdown.render_suffix(source, room)) == True{} : Bool}

law suffix_language:
  for source: String
  for room: Nat
  {suffix_result(Markdown.render_suffix(source, room)) == True{} : Bool}

law fragment_concatenation:
  for left: String
  for right: String
  for left_ok: {escaped_fragment(left) == True{} : Bool}
  for right_ok: {escaped_fragment(right) == True{} : Bool}
  {escaped_fragment(left ++ right) == True{} : Bool}

law fragment_accepts_fixed_entities:
  {escaped_fragment("&amp;&lt;&gt;&quot;&#39;é😀") == True{} : Bool}

def fragment_accepts_fixed_entities():
  {==}

law fragment_rejects_raw_tag:
  {escaped_fragment("<a href='x'>") == False{} : Bool}

def fragment_rejects_raw_tag():
  {==}

law fragment_rejects_unknown_entity:
  {escaped_fragment("&copy;") == False{} : Bool}

def fragment_rejects_unknown_entity():
  {==}

law fragment_rejects_unfinished_entity:
  {escaped_fragment("safe &amp") == False{} : Bool}

def fragment_rejects_unfinished_entity():
  {==}

law suffix_observer_rejects_markup:
  {suffix_fragment("<blockquote><pre><script>x</script></pre></blockquote>") == False{} : Bool}

def suffix_observer_rejects_markup():
  {==}

law suffix_observer_accepts_literal_link:
  {suffix_fragment("<blockquote><pre>[x](https://x)&amp;</pre></blockquote>") == True{} : Bool}

def suffix_observer_accepts_literal_link():
  {==}

type HtmlMode is Data:
  Outside{}
  InCode{}
  InEmphasis{}
  InStrong{}
  InHref{start: Nat}
  InLabel{}

type SeenHref is Data:
  SeenHref{start: Nat, end: Nat, value: String}

type HtmlState is Data:
  HtmlState{
    rest: String, position: Nat, mode: HtmlMode,
    decoded: String, links: List<&2, SeenHref>
  }

type DataUnit is Data:
  DataUnit{rest: String, value: Char, width: Nat}

def data_unit(text: String) -> Maybe<&2, DataUnit>:
  match text:
    case SCon{'&', SCon{'a', SCon{'m', SCon{'p', SCon{';', rest}}}}}:
      Some{DataUnit{rest, '&', 5n}}
    case SCon{'&', SCon{'l', SCon{'t', SCon{';', rest}}}}:
      Some{DataUnit{rest, '<', 4n}}
    case SCon{'&', SCon{'g', SCon{'t', SCon{';', rest}}}}:
      Some{DataUnit{rest, '>', 4n}}
    case SCon{'&', SCon{'q', SCon{'u', SCon{'o', SCon{'t', SCon{';', rest}}}}}}:
      Some{DataUnit{rest, '"', 6n}}
    case SCon{'&', SCon{'#', SCon{'3', SCon{'9', SCon{';', rest}}}}}:
      Some{DataUnit{rest, '\'', 5n}}
    case SCon{'&', rest}:
      None{}
    case SCon{'<', rest}:
      None{}
    case SCon{'>', rest}:
      None{}
    case SCon{'"', rest}:
      None{}
    case SCon{'\'', rest}:
      None{}
    case SCon{c, rest}:
      Some{DataUnit{rest, c, 1n}}
    case SNil{}:
      None{}

def html_tag(+text: String) -> U32:
  Bool.pick(U32, String.starts_with(text, "<code>"), 1,
    Bool.pick(U32, String.starts_with(text, "<em>"), 2,
      Bool.pick(U32, String.starts_with(text, "<strong>"), 3,
        Bool.pick(U32, String.starts_with(text, "<a href=\""), 4,
          Bool.pick(U32, String.starts_with(text, "</code>"), 5,
            Bool.pick(U32, String.starts_with(text, "</em>"), 6,
              Bool.pick(U32, String.starts_with(text, "</strong>"), 7,
                Bool.pick(U32, String.starts_with(text, "</a>"), 8, 0))))))))

def html_after_tag(mode: HtmlMode, text: String, position: Nat, +width: Nat,
  links: List<&2, SeenHref>) -> Maybe<&2, HtmlState>:
  Some{HtmlState{String.drop(text, width), Nat.add(width, position), mode, "", links}}

def html_transition(mode: HtmlMode, tag: U32, text: String, +position: Nat,
  links: List<&2, SeenHref>) -> Maybe<&2, HtmlState>:
  match mode tag:
    case Outside{} 1:
      html_after_tag(InCode{}, text, position, 6n, links)
    case Outside{} 2:
      html_after_tag(InEmphasis{}, text, position, 4n, links)
    case Outside{} 3:
      html_after_tag(InStrong{}, text, position, 8n, links)
    case Outside{} 4:
      html_after_tag(InHref{Nat.add(9n, position)}, text, position, 9n, links)
    case InCode{} 5:
      html_after_tag(Outside{}, text, position, 7n, links)
    case InEmphasis{} 6:
      html_after_tag(Outside{}, text, position, 5n, links)
    case InStrong{} 7:
      html_after_tag(Outside{}, text, position, 9n, links)
    case InLabel{} 8:
      html_after_tag(Outside{}, text, position, 4n, links)
    case _ _:
      None{}

def html_data.put(mode: HtmlMode, c: Char, decoded: String) -> String:
  match mode:
    case InHref{start}:
      SCon{c, decoded}
    case _:
      decoded

def html_data(unit: Maybe<&2, DataUnit>, position: Nat, +mode: HtmlMode,
  decoded: String, links: List<&2, SeenHref>) -> Maybe<&2, HtmlState>:
  match unit:
    case None{}:
      None{}
    case Some{DataUnit{rest, c, width}}:
      Some{HtmlState{rest, Nat.add(width, position), mode,
        html_data.put(mode, c, decoded), links}}

def html_step(text: String, +position: Nat, mode: HtmlMode,
  decoded: String, links: List<&2, SeenHref>) -> Maybe<&2, HtmlState>:
  match text mode:
    case SCon{'"', SCon{'>', rest}} InHref{start}:
      Some{HtmlState{rest, Nat.add(2n, position), InLabel{}, "",
        SeenHref{start, position, String.reverse(decoded)} <> links}}
    case SCon{'<', rest} _:
      +html = SCon{'<', rest}
      html_transition(mode, html_tag(html), html, position, links)
    case _ _:
      html_data(data_unit(text), position, mode, decoded, links)

def html_observe.go(fuel: Nat, state: Maybe<&2, HtmlState>)
  -> Maybe<&2, List<&2, SeenHref>>:
  match fuel state:
    case _ None{}:
      None{}
    case _ Some{HtmlState{SNil{}, position, Outside{}, decoded, links}}:
      Some{List.reverse(&2, SeenHref, links)}
    case _ Some{HtmlState{SNil{}, position, mode, decoded, links}}:
      None{}
    case 0n _:
      None{}
    case 1n+left Some{HtmlState{text, position, mode, decoded, links}}:
      html_observe.go(left, html_step(text, position, mode, decoded, links))

def html_observe(+text: String) -> Maybe<&2, List<&2, SeenHref>>:
  html_observe.go(String.length(text), Some{HtmlState{text, 0n, Outside{}, "", []}})

def observed_valid(result: Maybe<&2, List<&2, SeenHref>>) -> Bool:
  match result:
    case None{}:
      False{}
    case Some{links}:
      True{}

def hrefs_match(seen: List<&2, SeenHref>, claims: List<&2, Markdown.Anchor>,
  source: String, offset: Nat, +cap: Nat) -> Bool:
  match seen claims:
    case Nil{} Nil{}:
      True{}
    case SeenHref{html_start, html_end, value} <> rest
      Markdown.Anchor{+start, +end, claimed_start, claimed_end} <> later:
      +at = String.drop(source, Nat.sub(start, offset))
      +width = Nat.sub(end, start)
      +destination = String.take(at, width)
      Nat.is_ge(start, offset) && Nat.is_lt(start, end) && Nat.is_le(end, cap) &&
        Nat.is_eq(html_start, claimed_start) && Nat.is_eq(html_end, claimed_end) &&
        String.eq(value, destination) && Markdown.valid_destination(destination) &&
        hrefs_match(rest, later, String.drop(at, width), end, cap)
    case _ _:
      False{}

def provenance_observed(observed: Maybe<&2, List<&2, SeenHref>>, +source: String,
  claims: List<&2, Markdown.Anchor>) -> Bool:
  match observed:
    case None{}:
      False{}
    case Some{seen}:
      hrefs_match(seen, claims, source, 0n, String.length(source))

def inline_provenance(source: String,
  result: Result<&2, &2, Markdown.Error, Markdown.Inline>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Inline{html, remaining, events, anchors}}:
      provenance_observed(html_observe(html), source, anchors)

def inline_bytes(room: Nat,
  result: Result<&2, &2, Markdown.Error, Markdown.Inline>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Inline{html, remaining, events, anchors}}:
      Nat.is_eq(Nat.add(String.length(Codec.utf8_encode(html)), remaining),
        Nat.min(room, 4194304n))

def destination_shape(+source: String) -> Bool:
  (String.starts_with(source, "http://") || String.starts_with(source, "https://") ||
    String.starts_with(source, "mailto:")) &&
    Bool.not(String.contains(source, "%") || String.contains(source, "\\")) &&
    Nat.is_le(String.length(Codec.utf8_encode(source)), 2048n)

def step_progress(+source: String, +start: Nat, step: Markdown.Step) -> Bool:
  Markdown.Step{token, rest, +end} = step
  Nat.is_gt(end, start) && Nat.is_le(end, Nat.add(String.length(source), start)) &&
    String.eq(rest, String.drop(source, Nat.sub(end, start)))

def never_invariant(result: Result<&2, &2, Markdown.Error, Markdown.Inline>) -> Bool:
  match result:
    case Fail{Markdown.ParserInvariant{}}:
      False{}
    case _:
      True{}

law inline_actual_href_provenance:
  for source: String
  for room: Nat
  for events: Nat
  {inline_provenance(source, Markdown.render_inline_line(source, room, events)) == True{} : Bool}

law inline_byte_accounting:
  for source: String
  for room: Nat
  for events: Nat
  {inline_bytes(room, Markdown.render_inline_line(source, room, events)) == True{} : Bool}

law admitted_destination_shape:
  for source: String
  for admitted: {Markdown.valid_destination(source) == True{} : Bool}
  {destination_shape(source) == True{} : Bool}

law token_consumes_exact_prefix:
  for first: Char
  for rest: String
  for start: Nat
  {step_progress(SCon{first, rest}, start,
    Markdown.token_at(SCon{first, rest}, start)) == True{} : Bool}

law inline_fuel_is_sufficient:
  for source: String
  for room: Nat
  for events: Nat
  {never_invariant(Markdown.render_inline_line(source, room, events)) == True{} : Bool}

law suffix_observer_rejects_bad_open:
  {suffix_fragment("<blockquote><prex>x</pre></blockquote>") == False{} : Bool}

def suffix_observer_rejects_bad_open():
  {==}

law suffix_observer_rejects_bad_close:
  {suffix_fragment("<blockquote><pre>x</pre></blockquoteX>") == False{} : Bool}

def suffix_observer_rejects_bad_close():
  {==}

law suffix_observer_rejects_missing_close:
  {suffix_fragment("<blockquote><pre>x") == False{} : Bool}

def suffix_observer_rejects_missing_close():
  {==}

law suffix_observer_rejects_outside_text:
  {suffix_fragment("x<blockquote><pre>y</pre></blockquote>") == False{} : Bool}

def suffix_observer_rejects_outside_text():
  {==}

law inline_observer_rejects_script:
  {observed_valid(html_observe("<script>x</script>")) == False{} : Bool}

def inline_observer_rejects_script():
  {==}

law inline_observer_rejects_extra_attribute:
  {observed_valid(html_observe("<a href=\"https://x\" onclick=\"x\">x</a>")) == False{} : Bool}

def inline_observer_rejects_extra_attribute():
  {==}

law inline_observer_rejects_nested_tag:
  {observed_valid(html_observe("<em><a href=\"https://x\">x</a></em>")) == False{} : Bool}

def inline_observer_rejects_nested_tag():
  {==}

law inline_observer_rejects_missing_metadata:
  {provenance_observed(html_observe("<a href=\"https://x\">x</a>"),
    "[x](https://x)", []) == False{} : Bool}

def inline_observer_rejects_missing_metadata():
  {==}

law inline_observer_accepts_actual_span:
  {provenance_observed(html_observe("é <a href=\"https://x?a=1&amp;b=2\">x</a>"),
    "é [x](https://x?a=1&b=2)", [Markdown.Anchor{6n, 23n, 11n, 32n}]) == True{} : Bool}

def inline_observer_accepts_actual_span():
  {==}

law inline_observer_rejects_wrong_source_span:
  {provenance_observed(html_observe("<a href=\"https://x\">x</a>"),
    "[x](https://y)", [Markdown.Anchor{4n, 13n, 9n, 18n}]) == False{} : Bool}

def inline_observer_rejects_wrong_source_span():
  {==}

type EventCount is Data:
  EventCount{rest: String, count: Nat}

def event_head(source: String, delimiter: Char) -> Bool:
  match source:
    case SNil{}:
      False{}
    case SCon{c, rest}:
      Char.is_eq(c, delimiter)

def event_skip_run(source: String, +delimiter: Char, same: Bool) -> String:
  match source same:
    case _ False{}:
      source
    case SNil{} True{}:
      ""
    case SCon{c, +rest} True{}:
      event_skip_run(rest, delimiter, event_head(rest, delimiter))

def event_skip_until(source: String, +delimiter: Char, closing: Bool) -> String:
  match source closing:
    case SNil{} _:
      ""
    case _ True{}:
      event_skip_run(source, delimiter, True{})
    case SCon{c, +rest} False{}:
      event_skip_until(rest, delimiter, event_head(rest, delimiter))

def event_skip_destination(source: String) -> String:
  match source:
    case SNil{}:
      ""
    case SCon{')', rest}:
      rest
    case SCon{c, rest}:
      event_skip_destination(rest)

def event_after_label(source: String) -> String:
  match source:
    case SCon{'(', rest}:
      event_skip_destination(rest)
    case _:
      ""

def event_skip_label(source: String) -> String:
  match source:
    case SNil{}:
      ""
    case SCon{']', rest}:
      event_after_label(rest)
    case SCon{c, rest}:
      event_skip_label(rest)

def event_next(source: String) -> EventCount:
  match source:
    case SNil{}:
      EventCount{"", 0n}
    case SCon{'\\', SCon{c, rest}}:
      EventCount{rest, 0n}
    case SCon{'!', SCon{'[', rest}}:
      EventCount{event_skip_label(rest), 1n}
    case SCon{'[', rest}:
      EventCount{event_skip_label(rest), 1n}
    case SCon{'*', SCon{'*', SCon{'*', +rest}}}:
      EventCount{event_skip_run(rest, '*', event_head(rest, '*')), 1n}
    case SCon{'*', SCon{'*', +rest}}:
      EventCount{event_skip_until(rest, '*', event_head(rest, '*')), 1n}
    case SCon{'*', +rest}:
      EventCount{event_skip_until(rest, '*', event_head(rest, '*')), 1n}
    case SCon{'`', SCon{'`', +rest}}:
      EventCount{event_skip_run(rest, '`', event_head(rest, '`')), 1n}
    case SCon{'`', +rest}:
      EventCount{event_skip_until(rest, '`', event_head(rest, '`')), 1n}
    case SCon{c, rest}:
      EventCount{rest, 0n}

def event_accumulate(next: EventCount, count: Nat) -> EventCount:
  EventCount{rest, added} = next
  EventCount{rest, Nat.add(added, count)}

def event_count(fuel: Nat, state: EventCount) -> Maybe<&2, Nat>:
  match fuel state:
    case _ EventCount{SNil{}, count}:
      Some{count}
    case 0n _:
      None{}
    case 1n+left EventCount{source, count}:
      event_count(left, event_accumulate(event_next(source), count))

def source_nonblank(source: String) -> Bool:
  match source:
    case SNil{}:
      False{}
    case SCon{' ', rest}:
      source_nonblank(rest)
    case SCon{'\t', rest}:
      source_nonblank(rest)
    case _:
      True{}

def independent_events(+source: String) -> Maybe<&2, Nat>:
  event_count(String.length(source),
    EventCount{source, Bool.pick(Nat, source_nonblank(source), 1n, 0n)})

def inline_events.if(count: Maybe<&2, Nat>, events: Nat, remaining: Nat) -> Bool:
  match count:
    case None{}:
      False{}
    case Some{used}:
      Nat.is_eq(Nat.add(used, remaining), Nat.min(events, 65536n))

def inline_events(source: String, events: Nat,
  result: Result<&2, &2, Markdown.Error, Markdown.Inline>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{Markdown.Inline{html, room, remaining, anchors}}:
      inline_events.if(independent_events(source), events, remaining)

def source_characters(source: String) -> Bool:
  match source:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      +n = Char.to_u32(c)
      (U32.is_eq(n, 9) || U32.is_ge(n, 32)) &&
        Bool.not(U32.is_ge(n, 128) && U32.is_le(n, 159)) &&
        Bool.not(U32.is_ge(n, 55296) && U32.is_le(n, 57343)) &&
        U32.is_le(n, 1114111) && source_characters(rest)

def inline_admission(+source: String,
  result: Result<&2, &2, Markdown.Error, Markdown.Inline>) -> Bool:
  match result:
    case Fail{error}:
      True{}
    case Done{value}:
      Nat.is_le(String.length(Codec.utf8_encode(source)), 262144n) && source_characters(source)

law inline_source_events:
  for source: String
  for room: Nat
  for events: Nat
  {inline_events(source, events, Markdown.render_inline_line(source, room, events)) == True{} : Bool}

law inline_source_admission:
  for source: String
  for room: Nat
  for events: Nat
  {inline_admission(source, Markdown.render_inline_line(source, room, events)) == True{} : Bool}

law event_observer_counts_failed_span_once:
  {independent_events("*a[b](https://x)*") == Some{2n} : Maybe<&2, Nat>}

def event_observer_counts_failed_span_once():
  {==}

law event_observer_counts_mismatched_run_once:
  {independent_events("*a** [b](https://x)") == Some{3n} : Maybe<&2, Nat>}

def event_observer_counts_mismatched_run_once():
  {==}

law event_observer_keeps_image_whole:
  {independent_events("![a](https://x) [b](https://x)") == Some{3n} : Maybe<&2, Nat>}

def event_observer_keeps_image_whole():
  {==}

def destination_ascii(source: String) -> Bool:
  match source:
    case SNil{}:
      True{}
    case SCon{c, rest}:
      +n = Char.to_u32(c)
      U32.is_ge(n, 33) && U32.is_le(n, 126) && destination_ascii(rest)

def spec_alnum(c: Char) -> Bool:
  +n = Char.to_u32(c)
  (U32.is_ge(n, 48) && U32.is_le(n, 57)) ||
    (U32.is_ge(n, 65) && U32.is_le(n, 90)) ||
    (U32.is_ge(n, 97) && U32.is_le(n, 122))

def spec_characters(source: String, +extras: String) -> Bool:
  match source:
    case SNil{}:
      True{}
    case SCon{+c, rest}:
      (spec_alnum(c) || String.contains(extras, SCon{c, ""})) &&
        spec_characters(rest, extras)

def spec_first_alnum(source: String) -> Bool:
  match source:
    case SNil{}:
      False{}
    case SCon{c, rest}:
      spec_alnum(c)

def spec_labels(labels: List<&2, String>) -> Bool:
  match labels:
    case Nil{}:
      True{}
    case +label <> rest:
      Nat.is_le(String.length(label), 63n) && spec_first_alnum(label) &&
        spec_first_alnum(String.reverse(label)) && spec_characters(label, "-") &&
        spec_labels(rest)

def spec_numeric(source: String, +dots: Bool) -> Bool:
  match source:
    case SNil{}:
      True{}
    case SCon{'.', rest}:
      dots && spec_numeric(rest, dots)
    case SCon{c, rest}:
      +n = Char.to_u32(c)
      U32.is_ge(n, 48) && U32.is_le(n, 57) && spec_numeric(rest, dots)

def spec_host(+source: String) -> Bool:
  Nat.is_le(String.length(source), 253n) && spec_labels(String.split(source, '.')) &&
    Bool.not(String.contains(source, ".") && spec_numeric(source, True{}))

def spec_port_value(value: Maybe<&2, Nat>) -> Bool:
  match value:
    case None{}:
      False{}
    case Some{+number}:
      Nat.is_ge(number, 1n) && Nat.is_le(number, 65535n)

def spec_port(+source: String) -> Bool:
  Nat.is_ge(String.length(source), 1n) && Nat.is_le(String.length(source), 5n) &&
    spec_numeric(source, False{}) && spec_port_value(Nat.read(source))

def spec_authority(parts: List<&2, String>) -> Bool:
  match parts:
    case host <> Nil{}:
      spec_host(host)
    case host <> port <> Nil{}:
      spec_host(host) && spec_port(port)
    case _:
      False{}

def spec_http_parts(source: String, reversed: String) -> String & String:
  match source:
    case SNil{}:
      (String.reverse(reversed), "")
    case SCon{'/', rest}:
      (String.reverse(reversed), SCon{'/', rest})
    case SCon{'?', rest}:
      (String.reverse(reversed), SCon{'?', rest})
    case SCon{'#', rest}:
      (String.reverse(reversed), SCon{'#', rest})
    case SCon{c, rest}:
      spec_http_parts(rest, SCon{c, reversed})

def spec_http(source: String) -> Bool:
  (authority, tail) = spec_http_parts(source, "")
  spec_authority(String.split(authority, ':')) &&
    spec_characters(tail, "-._~:/?&=+#,@!$")

def spec_local(+source: String) -> Bool:
  Nat.is_ge(String.length(source), 1n) && Nat.is_le(String.length(source), 64n) &&
    spec_characters(source, "._+-") && Bool.not(String.starts_with(source, ".")) &&
    Bool.not(String.ends_with(source, ".")) && Bool.not(String.contains(source, ".."))

def spec_mailto(parts: List<&2, String>) -> Bool:
  match parts:
    case local <> domain <> Nil{}:
      spec_local(local) && spec_host(domain)
    case _:
      False{}

def spec_scheme(kind: U32, source: String) -> Bool:
  match kind:
    case 1:
      spec_http(String.drop(source, 7n))
    case 2:
      spec_http(String.drop(source, 8n))
    case 3:
      spec_mailto(String.split(String.drop(source, 7n), '@'))
    case _:
      False{}

def destination_grammar.if(bounded_ascii: Bool, +source: String) -> Bool:
  match bounded_ascii:
    case False{}:
      False{}
    case True{}:
      spec_scheme(Bool.pick(U32, String.starts_with(source, "http://"), 1,
        Bool.pick(U32, String.starts_with(source, "https://"), 2,
          Bool.pick(U32, String.starts_with(source, "mailto:"), 3, 0))), source)

def destination_grammar(+source: String) -> Bool:
  destination_grammar.if(Nat.is_le(String.length(source), 2048n) &&
    destination_ascii(source), source)

law admitted_destination_grammar:
  for source: String
  for admitted: {Markdown.valid_destination(source) == True{} : Bool}
  {destination_grammar(source) == True{} : Bool}

law destination_observer_accepts_numeric_single_label:
  {destination_grammar("https://2130706433") == True{} : Bool}

def destination_observer_accepts_numeric_single_label():
  {==}

law destination_observer_rejects_numeric_dotted_host:
  {destination_grammar("https://127.0.0.1") == False{} : Bool}

def destination_observer_rejects_numeric_dotted_host():
  {==}

law destination_observer_rejects_mailto_headers:
  {destination_grammar("mailto:a@x?bcc=b@y") == False{} : Bool}

def destination_observer_rejects_mailto_headers():
  {==}




