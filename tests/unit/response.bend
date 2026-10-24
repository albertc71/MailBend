# UTF-8 result budgets include JSON escapes and preserve protected fields.

import Base
import ../../src/codec.bend as C
import ../../src/json.bend as J
import ../../src/response.bend as R
import ../../src/tools.bend as T

def fixture() -> J.Json:
  J.obj([
    J.kv("uid", J.num(7)), J.kv("uidvalidity", J.num(99)),
    J.kv("truncated", J.bool(True{})),
    J.kv("text", J.str("é😀\"\\\nquoted history")),
    J.kv("html", J.str("<p>é😀</p>")),
    J.kv("jev", J.obj([J.kv("status", J.str("unchecked")),
      J.kv("text", J.str("must survive"))])),
    J.kv("messages", J.arr([J.obj([J.kv("uid", J.num(8))])])),
    J.kv("next_since_uid", J.num(8)), J.kv("has_more", J.bool(True{}))
  ])

def fits(r: Result<&2, &2, String, J.Json>, max: U32) -> Bool:
  match r:
    case Done{j}:
      U32.is_le(C.utf8_len(J.show(j)), max)
    case _:
      False{}

def rejected(r: Result<&2, &2, String, J.Json>) -> Bool:
  match r:
    case Fail{m}:
      True{}
    case _:
      False{}

def protected(r: Result<&2, &2, String, J.Json>, original: J.Json) -> Bool:
  match r:
    case Done{j}:
      String.eq(J.show(R.empty_body(j)),
        J.show(R.with_notice(R.empty_body(original), "full", 450, True{})))
    case _:
      False{}

def say(name: String, ok: Bool) -> IO(Unit):
  IO.print(name ++ ": " ++ Bool.pick(String, ok, "true", "false"))

def default_out(o: T.Out, original: J.Json) -> Bool:
  match o:
    case T.Ok{j}:
      String.eq(J.show(j), J.show(original))
    case _:
      False{}

def budgets(n: Nat, +j: J.Json, +max: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+k:
      fits(R.apply(j, "full", max), max) && budgets(k, j, (max + 1 : U32))

def error_unchanged(o: T.Out) -> Bool:
  match o:
    case T.Err{"original failure"}:
      True{}
    case _:
      False{}

def selected_fixture(media: String, encoding: String, content: String) -> J.Json:
  J.obj([J.kv("uid", J.num(7)), J.kv("uidvalidity", J.num(99)),
    J.kv("section", J.str("2.1")), J.kv("scope", J.str("selected_part")),
    J.kv("complete", J.bool(True{})), J.kv("message_complete", J.bool(False{})),
    J.kv("content_type", J.str(media)), J.kv("content_encoding", J.str(encoding)),
    J.kv("content", J.str(content)),
    J.kv("jev", J.obj([J.kv("status", J.str("unchecked"))]))])

def result(r: Result<&2, &2, String, J.Json>) -> J.Json:
  match r:
    case Done{j}:
      j
    case _:
      J.JNull{}

def selected_short(+j: J.Json, max: U32) -> Bool:
  +response = T.object_field(j, "response")
  U32.is_le(C.utf8_len(J.show(j)), max) && T.bool_arg(j, "complete", False{}) &&
    Bool.not(T.bool_arg(j, "message_complete", True{})) &&
    T.bool_arg(response, "output_truncated", False{}) &&
    Bool.not(T.bool_arg(response, "content_complete", True{})) &&
    String.eq(J.show(T.object_field(j, "jev")), "{\"status\":\"unchecked\"}")

def binary_budget(+j: J.Json, +max: U32) -> Bool:
  +out = result(R.apply(j, "full", max))
  +content = T.str_arg(out, "content", "?")
  U32.is_le(C.utf8_len(J.show(out)), max) &&
    (String.is_empty(content) || String.eq(content, T.str_arg(j, "content", "?"))) &&
    String.eq(C.b64_encode(C.b64_decode(content), False{}), content)

def binary_budgets(n: Nat, +j: J.Json, +max: U32) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+k:
      binary_budget(j, max) && binary_budgets(k, j, (max + 1 : U32))

def main() -> IO(Unit):
  +j = fixture()
  +mixed = J.arr([j, J.JNull{}, J.bool(False{}), J.num(12), J.obj([]), J.arr([])])
  +part = selected_fixture("Text/Plain; charset=utf-8", "text", "é😀quoted history")
  +html = selected_fixture("text/html; charset=utf-8", "text", "<p>é😀quoted</p>")
  +binary = selected_fixture("application/octet-stream", "base64",
    C.b64_encode("abcdefghijklmnopqrstuvwxyz0123456789", False{}))
  +small = (R.bytes(R.with_notice(R.empty_body(part), "full", 1000, False{})) + 1 : U32)
  +binary_small = (R.bytes(R.with_notice(R.empty_body(binary), "full", 1000, False{})) + 1 : U32)
  +metadata = result(R.apply(part, "metadata", 0))
  do IO<Unit>:
    say("exact escaped UTF-8 size", U32.is_eq(R.bytes(mixed), C.utf8_len(J.show(mixed))))
    say("default untouched", default_out(T.projected.if(False{}, T.Ok{j}, J.obj([])), j))
    say("text projection", Maybe.is_none(&2, J.Json, J.get(R.select(j, "text"), "html")))
    say("HTML projection", Maybe.is_none(&2, J.Json, J.get(R.select(j, "html"), "text")))
    say("metadata projection", Maybe.is_none(&2, J.Json,
      J.get(R.select(j, "metadata"), "text")) && Maybe.is_none(&2, J.Json,
      J.get(R.select(j, "metadata"), "html")))
    say("tiny rejected", rejected(R.apply(j, "full", 1)))
    say("UTF-8 bounded", fits(R.apply(j, "full", 450), 450))
    say("escape boundary", fits(R.apply(j, "full", 440), 440))
    say("protected fields", protected(R.apply(j, "full", 450), j))
    say("all byte boundaries", budgets(80n, j, 436))
    say("errors untouched", error_unchanged(T.projected.out(
      T.Err{"original failure"}, "metadata", 1)))
    say("zero budget rejected", Bool.not(String.is_empty(T.call_problem(
      "mail_get", J.obj([J.kv("uid", J.num(1)),
        J.kv("max_response_bytes", J.num(0))])))))
    say("unknown projection rejected", Bool.not(String.is_empty(T.call_problem(
      "mail_get", J.obj([J.kv("uid", J.num(1)),
        J.kv("projection", J.str("jsonpath"))])))))
    say("selected metadata omits content", Maybe.is_none(&2, J.Json,
      J.get(metadata, "content")) && Bool.not(T.bool_arg(T.object_field(metadata, "response"),
        "content_complete", True{})) && Bool.not(T.bool_arg(T.object_field(metadata, "response"),
        "output_truncated", True{})))
    say("selected text projection", Maybe.is_some(&2, J.Json,
      J.get(R.select(part, "text"), "content")) &&
      Maybe.is_none(&2, J.Json, J.get(R.select(html, "text"), "content")))
    say("selected HTML projection", Maybe.is_some(&2, J.Json,
      J.get(R.select(html, "html"), "content")) &&
      Maybe.is_none(&2, J.Json, J.get(R.select(part, "html"), "content")))
    say("binary excluded from text and HTML", Maybe.is_none(&2, J.Json,
      J.get(R.select(binary, "text"), "content")) &&
      Maybe.is_none(&2, J.Json, J.get(R.select(binary, "html"), "content")))
    say("selected text completeness", selected_short(result(R.apply(part, "full", small)), small))
    say("selected binary completeness", selected_short(
      result(R.apply(binary, "full", binary_small)), binary_small))
    say("binary budgets preserve valid base64", binary_budgets(100n, binary, binary_small))
    say("selected text byte boundaries", budgets(80n, part, small))
    say("selected default untouched", default_out(T.projected.if(False{},
      T.Ok{part}, J.obj([])), part))
    say("binary full content complete", T.bool_arg(T.object_field(
      result(R.apply(binary, "full", 65536)), "response"), "content_complete", False{}) &&
      String.eq(T.str_arg(result(R.apply(binary, "full", 65536)), "content", "?"),
        T.str_arg(binary, "content", "")))

#|exact escaped UTF-8 size: true
#|default untouched: true
#|text projection: true
#|HTML projection: true
#|metadata projection: true
#|tiny rejected: true
#|UTF-8 bounded: true
#|escape boundary: true
#|protected fields: true
#|all byte boundaries: true
#|errors untouched: true
#|zero budget rejected: true
#|unknown projection rejected: true
#|selected metadata omits content: true
#|selected text projection: true
#|selected HTML projection: true
#|binary excluded from text and HTML: true
#|selected text completeness: true
#|selected binary completeness: true
#|binary budgets preserve valid base64: true
#|selected text byte boundaries: true
#|selected default untouched: true
#|binary full content complete: true
