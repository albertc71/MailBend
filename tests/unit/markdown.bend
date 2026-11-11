# Literal examples for the structured-body and escaped-data interfaces.

import Base
import ../../src/markdown.bend as Markdown

def inline_is(result: Result<&2, &2, Markdown.Error, Markdown.Inline>,
  expected: String, events: Nat) -> Bool:
  match result:
    case Done{Markdown.Inline{html, remaining, events_left, anchors}}:
      String.eq(html, expected) && Nat.is_eq(Nat.sub(65536n, events_left), events)
    case Fail{error}:
      False{}

def inline_html(source: String, expected: String, events: Nat) -> Bool:
  inline_is(Markdown.render_inline_line(source, 4194304n, 65536n), expected, events)

def inline_refused(result: Result<&2, &2, Markdown.Error, Markdown.Inline>,
  expected: Markdown.Error) -> Bool:
  match result expected:
    case Fail{Markdown.OutputLimit{}} Markdown.OutputLimit{}:
      True{}
    case Fail{Markdown.StructureLimit{}} Markdown.StructureLimit{}:
      True{}
    case Fail{Markdown.InputLimit{}} Markdown.InputLimit{}:
      True{}
    case Fail{Markdown.ControlInput{}} Markdown.ControlInput{}:
      True{}
    case Fail{Markdown.InlineLineRequired{}} Markdown.InlineLineRequired{}:
      True{}
    case _ _:
      False{}

def href_span_is(result: Result<&2, &2, Markdown.Error, Markdown.Inline>) -> Bool:
  match result:
    case Done{Markdown.Inline{html, remaining, events_left,
      Markdown.Anchor{source_start, source_end, html_start, html_end} <> Nil{}}}:
      Nat.is_eq(source_start, 6n) && Nat.is_eq(source_end, 23n) &&
        Nat.is_eq(html_start, 11n) && Nat.is_eq(html_end, 32n) &&
        String.eq(String.take(String.drop(html, 11n), 21n), "https://x?a=1&amp;b=2") &&
        Nat.is_eq(remaining, 60n) && Nat.is_eq(events_left, 8n)
    case _:
      False{}

def inline_budgets(result: Result<&2, &2, Markdown.Error, Markdown.Inline>,
  expected_room: Nat, expected_events: Nat) -> Bool:
  match result:
    case Done{Markdown.Inline{html, remaining, events, anchors}}:
      Nat.is_eq(remaining, expected_room) && Nat.is_eq(events, expected_events)
    case Fail{error}:
      False{}

def same_bool(a: Bool, b: Bool) -> Bool:
  match a b:
    case True{} True{}:
      True{}
    case False{} False{}:
      True{}
    case _ _:
      False{}

def destination_cases(+expected: Bool, values: List<&2, String>) -> Bool:
  match values:
    case Nil{}:
      True{}
    case value <> rest:
      same_bool(Markdown.valid_destination(value), expected) && destination_cases(expected, rest)

def fragment_is(result: Result<&2, &2, Markdown.Error, Markdown.Fragment>,
  expected: String, remaining: Nat) -> Bool:
  match result:
    case Done{Markdown.Fragment{html, room}}:
      String.eq(html, expected) && Nat.is_eq(room, remaining)
    case Fail{error}:
      False{}

def output_refused(result: Result<&2, &2, Markdown.Error, Markdown.Fragment>) -> Bool:
  match result:
    case Fail{Markdown.OutputLimit{}}:
      True{}
    case _:
      False{}

def say(name: String, result: Bool) -> IO(Unit):
  IO.print(name ++ ": " ++ Bool.pick(String, result, "true", "false"))

def main() -> IO(Unit):
  do IO<Unit>:
    say("legacy projection retains CR LF markup and Unicode",
      String.eq(Markdown.plain(Markdown.TextBody{"<b>é</b>\r\n*raw*\r😀\n"}),
        "<b>é</b>\r\n*raw*\r😀\n"))
    say("markdown projection joins caller and exact suffix",
      String.eq(Markdown.plain(Markdown.MarkdownBody{"**hello**\r", "\n> quoted & <tag>\n"}),
        "**hello**\r\n> quoted & <tag>\n"))
    say("empty caller retains suffix",
      String.eq(Markdown.plain(Markdown.MarkdownBody{"", "\n\noriginal"}), "\n\noriginal"))
    say("empty suffix retains caller",
      String.eq(Markdown.plain(Markdown.MarkdownBody{"[x](https://x)", ""}), "[x](https://x)"))
    say("all five data characters are escaped",
      fragment_is(Markdown.escape_data("&<>\"'", 25n), "&amp;&lt;&gt;&quot;&#39;", 1n))
    say("entity spelling is escaped again",
      fragment_is(Markdown.escape_data("&lt;script&gt;", 22n), "&amp;lt;script&amp;gt;", 0n))
    say("Unicode and line endings are not normalized",
      fragment_is(Markdown.escape_data("é😀\r\n\t", 9n), "é😀\r\n\t", 0n))
    say("empty data fits zero room",
      fragment_is(Markdown.escape_data("", 0n), "", 0n))
    say("ampersand fits exactly five bytes",
      fragment_is(Markdown.escape_data("&", 5n), "&amp;", 0n))
    say("entity cannot cross output budget",
      output_refused(Markdown.escape_data("&", 4n)))
    say("failure discards an already escaped prefix",
      output_refused(Markdown.escape_data("a&", 5n)))
    say("multibyte scalar cannot cross output budget",
      output_refused(Markdown.escape_data("😀", 3n)))
    say("exact Unicode byte budget succeeds",
      fragment_is(Markdown.escape_data("😀", 4n), "😀", 0n))
    say("empty suffix emits no wrapper",
      fragment_is(Markdown.render_suffix("", 0n), "", 0n))
    say("suffix link syntax stays literal",
      fragment_is(Markdown.render_suffix("[x](https://x)", 50n),
        "<blockquote><pre>[x](https://x)</pre></blockquote>", 0n))
    say("suffix HTML is escaped inside fixed wrapper",
      fragment_is(Markdown.render_suffix("</pre><a href=\"x\">&", 100n),
        "<blockquote><pre>&lt;/pre&gt;&lt;a href=&quot;x&quot;&gt;&amp;</pre></blockquote>", 19n))
    say("wrapper and data use one budget",
      fragment_is(Markdown.render_suffix("x", 37n), "<blockquote><pre>x</pre></blockquote>", 0n))
    say("wrapper cannot cross output budget",
      output_refused(Markdown.render_suffix("x", 35n)))
    say("suffix content cannot cross remaining budget",
      output_refused(Markdown.render_suffix("x", 36n)))
    say("suffix CR LF and Unicode are preserved",
      fragment_is(Markdown.render_suffix("é\r\n😀\n", 45n),
        "<blockquote><pre>é\r\n😀\n</pre></blockquote>", 0n))

    say("inline empty has no event", inline_html("",
      "", 0n))
    say("inline ASCII blank has no event", inline_html(" \t",
      "", 0n))
    say("inline literal data is escaped", inline_html("<b>&\"'",
      "&lt;b&gt;&amp;&quot;&#39;", 1n))
    say("inline code is escaped without nesting", inline_html("`*x*<&`",
      "<code>*x*&lt;&amp;</code>", 2n))
    say("inline emphasis", inline_html("*x* **y**",
      "<em>x</em> <strong>y</strong>", 3n))
    say("mismatched star close consumes full run", inline_html("*a** [b](https://x)",
      "*a** <a href=\"https://x\">b</a>", 3n))
    say("mismatched tick close consumes full run", inline_html("`a`` [b](https://x)",
      "`a`` <a href=\"https://x\">b</a>", 3n))
    say("forbidden emphasis interior is not rescanned", inline_html("*a[b](https://x)*",
      "*a[b](https://x)*", 2n))
    say("mismatched strong close resumes afterward", inline_html("**a* [b](https://x)",
      "**a* <a href=\"https://x\">b</a>", 3n))
    say("incomplete bracket consumes line", inline_html("[a] [b](https://x)",
      "[a] [b](https://x)", 2n))
    say("image consumes one token before next link", inline_html("![a](https://x) [b](https://x)",
      "![a](https://x) <a href=\"https://x\">b</a>", 3n))
    say("backslash keeps following bracket literal", inline_html("\\[x](https://x)",
      "\\[x](https://x)", 1n))
    say("unsupported maximal runs cost one each", inline_html("*** ``",
      "*** ``", 3n))
    say("no closing delimiter consumes remainder", inline_html("*a [x](https://x)",
      "*a [x](https://x)", 2n))
    say("empty code is literal maximal run", inline_html("``",
      "``", 2n))
    say("empty emphasis is literal maximal run", inline_html("**",
      "**", 2n))
    say("ASCII edge whitespace rejects emphasis", inline_html("* x* *x *",
      "* x* *x *", 3n))
    say("Unicode edge whitespace rejects emphasis", inline_html("* x* *x *",
      "* x* *x *", 3n))
    say("nested bracket invalidates complete token", inline_html("[a[b](https://x) [c](https://y)",
      "[a[b](https://x) <a href=\"https://y\">c</a>", 3n))
    say("first parenthesis ends rejected destination", inline_html("[a](https://x/(q)) [b](https://y)",
      "[a](https://x/(q)) <a href=\"https://y\">b</a>", 3n))
    say("invalid link does not disable later link", inline_html("[a](javascript:bad) [b](https://y)",
      "[a](javascript:bad) <a href=\"https://y\">b</a>", 3n))
    say("label markers are literal text", inline_html("[*x*](https://x)",
      "<a href=\"https://x\">*x*</a>", 2n))
    say("entity spelling cannot create scheme", inline_html("[x](&#104;ttps://x)",
      "[x](&amp;#104;ttps://x)", 2n))
    say("image with invalid link stays whole literal", inline_html("![x](javascript:bad)",
      "![x](javascript:bad)", 2n))
    say("Unicode source preserves href offsets", inline_html("é [x](https://x?a=1&b=2)",
      "é <a href=\"https://x?a=1&amp;b=2\">x</a>", 2n))
    say("global escape allowance is capped",
      fragment_is(Markdown.escape_data("", 4194305n), "", 4194304n))
    say("global suffix allowance includes wrapper",
      fragment_is(Markdown.render_suffix("x", 4194305n),
        "<blockquote><pre>x</pre></blockquote>", 4194267n))
    say("actual href spans retain original caller coordinates",
      href_span_is(Markdown.render_inline_line("é [x](https://x?a=1&b=2)", 100n, 10n)))
    say("structure refuses before second candidate",
      inline_refused(Markdown.render_inline_line("*x* *y*", 100n, 2n), Markdown.StructureLimit{}))
    say("nonblank line consumes first event",
      inline_refused(Markdown.render_inline_line("x", 100n, 0n), Markdown.StructureLimit{}))
    say("inline code includes wrapper in byte limit",
      inline_refused(Markdown.render_inline_line("`x`", 13n, 10n), Markdown.OutputLimit{}))
    say("inline source rejects line break",
      inline_refused(Markdown.render_inline_line("a\nb", 100n, 10n), Markdown.InlineLineRequired{}))
    say("inline source rejects NUL",
      inline_refused(Markdown.render_inline_line(SCon{Char.from_u32(0), ""}, 100n, 10n),
        Markdown.ControlInput{}))
    say("inline source rejects C1",
      inline_refused(Markdown.render_inline_line(SCon{Char.from_u32(133), ""}, 100n, 10n),
        Markdown.ControlInput{}))
    say("caller byte cap rejects multibyte excess",
      inline_refused(Markdown.render_inline_line(String.repeat("é", 131073n), 4194304n, 65536n),
        Markdown.InputLimit{}))
    say("URL allowed forms", destination_cases(True{}, [
      "http://x", "https://Example-1.test:00001/p?q=1&b=2#f", "https://x:65535",
      "mailto:a.b_+-@example.test", "https://2130706433", "https://0x7f000001",
      "https://x/@name,!$+~", "https://x?x", "https://x#x"]))
    say("URL rejected forms", destination_cases(False{}, [
      "", "HTTPS://x", "Http://x", "javascript:x", "data:text/x", "//x", "/x",
      "https://", "https://x.", "https://.x", "https://x..y", "https://-x",
      "https://x-", "https://a@x", "https://[::1]", "https://127.0.0.1",
      "https://x:0", "https://x:65536", "https://x:000001", "https://x:",
      "https://x:1:2", "https://é", "https://x/%20", "https://x/\\evil",
      "https://x/a b", "https://x/;", "https://x/&#39;", "https://x/\"",
      "mailto:a@x?bcc=z@y", "mailto:a@x#x", "mailto:a@x,y@z", "mailto:a@@x",
      "mailto:.a@x", "mailto:a.@x", "mailto:a..b@x", "mailto:a@127.0.0.1",
      "mailto:a%0d@x", "mailto:a b@x"]))

    say("URL destination accepts exactly 2048 ASCII bytes",
      Markdown.valid_destination("https://x/" ++ String.repeat("a", 2038n)))
    say("URL destination refuses 2049 ASCII bytes",
      Bool.not(Markdown.valid_destination("https://x/" ++ String.repeat("a", 2039n))))
    say("overlong destination consumes its complete token",
      inline_html("[x](https://x/" ++ String.repeat("a", 2039n) ++ ") [b](https://y)",
        "[x](https://x/" ++ String.repeat("a", 2039n) ++ ") <a href=\"https://y\">b</a>", 3n))
    say("URL host accepts 63 byte label",
      Markdown.valid_destination("https://" ++ String.repeat("a", 63n)))
    say("URL host refuses 64 byte label",
      Bool.not(Markdown.valid_destination("https://" ++ String.repeat("a", 64n))))
    say("URL host accepts 253 bytes",
      Markdown.valid_destination("https://" ++ String.repeat("a", 63n) ++ "." ++
        String.repeat("b", 63n) ++ "." ++ String.repeat("c", 63n) ++ "." ++ String.repeat("d", 61n)))
    say("URL host refuses 254 bytes",
      Bool.not(Markdown.valid_destination("https://" ++ String.repeat("a", 63n) ++ "." ++
        String.repeat("b", 63n) ++ "." ++ String.repeat("c", 63n) ++ "." ++ String.repeat("d", 62n))))
    say("mailto accepts 64 byte local",
      Markdown.valid_destination("mailto:" ++ String.repeat("a", 64n) ++ "@x"))
    say("mailto refuses 65 byte local",
      Bool.not(Markdown.valid_destination("mailto:" ++ String.repeat("a", 65n) ++ "@x")))
    say("exact caller byte limit retains multibyte text",
      inline_budgets(Markdown.render_inline_line(String.repeat("é", 131072n), 4194304n, 65536n),
        3932160n, 65535n))
    say("caller byte limit plus one refuses",
      inline_refused(Markdown.render_inline_line(String.repeat("x", 262145n), 4194304n, 65536n),
        Markdown.InputLimit{}))
    say("exact structure event limit succeeds",
      inline_budgets(Markdown.render_inline_line(String.repeat("*x* ", 65535n), 4194304n, 65536n),
        3473419n, 0n))
    say("structure event limit plus one refuses",
      inline_refused(Markdown.render_inline_line(String.repeat("*x* ", 65536n), 4194304n, 65536n),
        Markdown.StructureLimit{}))
    say("structure allowance cannot exceed fixed cap",
      inline_budgets(Markdown.render_inline_line("", 0n, 65537n), 0n, 65536n))

#|legacy projection retains CR LF markup and Unicode: true
#|markdown projection joins caller and exact suffix: true
#|empty caller retains suffix: true
#|empty suffix retains caller: true
#|all five data characters are escaped: true
#|entity spelling is escaped again: true
#|Unicode and line endings are not normalized: true
#|empty data fits zero room: true
#|ampersand fits exactly five bytes: true
#|entity cannot cross output budget: true
#|failure discards an already escaped prefix: true
#|multibyte scalar cannot cross output budget: true
#|exact Unicode byte budget succeeds: true
#|empty suffix emits no wrapper: true
#|suffix link syntax stays literal: true
#|suffix HTML is escaped inside fixed wrapper: true
#|wrapper and data use one budget: true
#|wrapper cannot cross output budget: true
#|suffix content cannot cross remaining budget: true
#|suffix CR LF and Unicode are preserved: true
#|inline empty has no event: true
#|inline ASCII blank has no event: true
#|inline literal data is escaped: true
#|inline code is escaped without nesting: true
#|inline emphasis: true
#|mismatched star close consumes full run: true
#|mismatched tick close consumes full run: true
#|forbidden emphasis interior is not rescanned: true
#|mismatched strong close resumes afterward: true
#|incomplete bracket consumes line: true
#|image consumes one token before next link: true
#|backslash keeps following bracket literal: true
#|unsupported maximal runs cost one each: true
#|no closing delimiter consumes remainder: true
#|empty code is literal maximal run: true
#|empty emphasis is literal maximal run: true
#|ASCII edge whitespace rejects emphasis: true
#|Unicode edge whitespace rejects emphasis: true
#|nested bracket invalidates complete token: true
#|first parenthesis ends rejected destination: true
#|invalid link does not disable later link: true
#|label markers are literal text: true
#|entity spelling cannot create scheme: true
#|image with invalid link stays whole literal: true
#|Unicode source preserves href offsets: true
#|global escape allowance is capped: true
#|global suffix allowance includes wrapper: true
#|actual href spans retain original caller coordinates: true
#|structure refuses before second candidate: true
#|nonblank line consumes first event: true
#|inline code includes wrapper in byte limit: true
#|inline source rejects line break: true
#|inline source rejects NUL: true
#|inline source rejects C1: true
#|caller byte cap rejects multibyte excess: true
#|URL allowed forms: true
#|URL rejected forms: true
#|URL destination accepts exactly 2048 ASCII bytes: true
#|URL destination refuses 2049 ASCII bytes: true
#|overlong destination consumes its complete token: true
#|URL host accepts 63 byte label: true
#|URL host refuses 64 byte label: true
#|URL host accepts 253 bytes: true
#|URL host refuses 254 bytes: true
#|mailto accepts 64 byte local: true
#|mailto refuses 65 byte local: true
#|exact caller byte limit retains multibyte text: true
#|caller byte limit plus one refuses: true
#|exact structure event limit succeeds: true
#|structure event limit plus one refuses: true
#|structure allowance cannot exceed fixed cap: true

