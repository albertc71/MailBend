# Bounded read projections after all mail interpretation and Jev checks.

import Base
import ./codec.bend as C
import ./json.bend as J
import ./mime.bend as M

# Exact UTF-8 size of shared JSON, including its quotes and escapes.
def bytes.separator(j: J.Json) -> U32:
  match j:
    case J.JEnd{}:
      0
    case _:
      1

def bytes(j: J.Json) -> U32:
  match j:
    case J.JNull{}:
      4
    case J.JBool{b}:
      Bool.pick(U32, b, 4, 5)
    case J.JNum{s}:
      C.utf8_len(s)
    case J.JStr{s}:
      (2 + C.utf8_len(J.esc(s)) : U32)
    case J.JArr{xs}:
      (2 + bytes(xs) : U32)
    case J.JObj{xs}:
      (2 + bytes(xs) : U32)
    case J.JCons{h, +t}:
      ((bytes(h) + bytes.separator(t) : U32) + bytes(t) : U32)
    case J.JEnd{}:
      0
    case J.JKv{k, v}:
      ((3 + C.utf8_len(J.esc(k)) : U32) + bytes(v) : U32)

# Projection only selects body text, HTML or selected-part content. Everything else, including
# every selected summary and every Jev answer, remains untouched.
def keep(+mode: String, +key: String) -> Bool:
  Bool.not((String.eq(key, "text") &&
    (String.eq(mode, "html") || String.eq(mode, "metadata"))) ||
    (String.eq(key, "html") &&
    (String.eq(mode, "text") || String.eq(mode, "metadata"))) ||
    (String.eq(key, "content") && String.eq(mode, "metadata")))

def fields.put(yes: Bool, kv: J.Json, rest: List<&2, J.Json>) -> List<&2, J.Json>:
  match yes:
    case True{}:
      kv <> rest
    case False{}:
      rest

def fields(xs: List<&2, J.Json>, +mode: String, +content: Bool) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case +kv <> t:
      match kv:
        case J.JKv{+key, v}:
          fields.put(keep(mode, key) && (Bool.not(String.eq(key, "content")) || content),
            kv, fields(t, mode, content))
        case _:
          kv <> fields(t, mode, content)

def text(j: J.Json, key: String) -> String:
  Maybe.default(&2, String, J.as_str(J.get(j, key)), "")

def selected(j: J.Json) -> Bool:
  String.eq(text(j, "scope"), "selected_part")

def content_allowed(mode: String, +media: String) -> Bool:
  match mode:
    case "full":
      True{}
    case "text":
      String.starts_with(media, "text/") && Bool.not(String.eq(media, "text/html"))
    case "html":
      String.eq(media, "text/html")
    case _:
      False{}

def select(+j: J.Json, +mode: String) -> J.Json:
  match j:
    case J.JObj{xs}:
      media = M.main_value(text(j, "content_type"))
      content = Bool.not(selected(j)) || content_allowed(mode, media)
      J.obj(fields(J.unchain(xs), mode, content))
    case _:
      j

# Only top-level body strings are shortened. In particular this never
# descends into messages, attachments, Jev answers or error objects.
def body_key(+k: String) -> Bool:
  String.eq(k, "text") || String.eq(k, "html") || String.eq(k, "content")

def empty_field(kv: J.Json) -> J.Json:
  match kv:
    case J.JKv{+k, J.JStr{s}}:
      J.kv(k, J.str(Bool.pick(String, body_key(k), "", s)))
    case _:
      kv

def empty_fields(xs: List<&2, J.Json>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case kv <> t:
      empty_field(kv) <> empty_fields(t)

def empty_body(j: J.Json) -> J.Json:
  match j:
    case J.JObj{xs}:
      J.obj(empty_fields(J.unchain(xs)))
    case _:
      j

# A prefix with its unused JSON-string byte allowance. Cut only between
# Unicode scalars, counting the JSON escape of each scalar before taking it.
type Prefix is Data:
  Prefix{text: String, left: U32}

def prefix.put(p: Prefix, enough: Bool, c: Char, left: U32) -> Prefix:
  Prefix{tail, remain} = p
  match enough:
    case True{}:
      Prefix{SCon{c, tail}, remain}
    case False{}:
      Prefix{"", left}

def prefix(s: String, +left: U32) -> Prefix:
  match s left:
    case _ 0:
      Prefix{"", 0}
    case SNil{} _:
      Prefix{"", left}
    case SCon{+c, t} _:
      +n = C.utf8_len(J.esc_char(c))
      +enough = U32.is_ge(left, n)
      prefix.put(prefix(t, Bool.pick(U32, enough, (left - n : U32), 0)), enough, c, left)

type Field is Data:
  Field{kv: J.Json, left: U32, cut: Bool}

def fit_field.put(p: Prefix, k: String, s: String) -> Field:
  Prefix{+part, remain} = p
  Field{J.kv(k, J.str(part)), remain, Bool.not(String.eq(s, part))}

def fit_field.if(body: Bool, k: String, +s: String, left: U32) -> Field:
  match body:
    case True{}:
      fit_field.put(prefix(s, left), k, s)
    case False{}:
      Field{J.kv(k, J.str(s)), left, False{}}

def fit_field(kv: J.Json, left: U32) -> Field:
  match kv:
    case J.JKv{+k, J.JStr{s}}:
      fit_field.if(body_key(k), k, s, left)
    case _:
      Field{kv, left, False{}}

# Base64 content is indivisible: preserve it whole or return the valid empty
# encoding with an explicit output-truncation notice. Never slice a quartet.
def fit_field.binary(kv: J.Json, +left: U32) -> Field:
  match kv:
    case J.JKv{"content", J.JStr{+s}}:
      +n = C.utf8_len(J.esc(s))
      +fits = U32.is_le(n, left)
      Field{J.kv("content", J.str(Bool.pick(String, fits, s, ""))),
        Bool.pick(U32, fits, (left - n : U32), left), Bool.not(fits)}
    case _:
      fit_field(kv, left)

def fit_field.encoded(binary: Bool, kv: J.Json, left: U32) -> Field:
  match binary:
    case True{}:
      fit_field.binary(kv, left)
    case False{}:
      fit_field(kv, left)

def fit_field.left(f: Field) -> U32:
  Field{_, left, _} = f
  left

type Fields is Data:
  Fields{items: List<&2, J.Json>, cut: Bool}

def fit_fields.put(f: Field, rest: Fields) -> Fields:
  Field{kv, _, cut} = f
  Fields{items, more} = rest
  Fields{kv <> items, cut || more}

def fit_fields(xs: List<&2, J.Json>, left: U32, +binary: Bool) -> Fields:
  match xs:
    case Nil{}:
      Fields{[], False{}}
    case kv <> t:
      +f = fit_field.encoded(binary, kv, left)
      fit_fields.put(f, fit_fields(t, fit_field.left(f), binary))

def notice(mode: String, max: U32, cut: Bool, extra: List<&2, J.Json>) -> J.Json:
  J.kv("response", J.obj(List.append(&2, J.Json, [
    J.kv("projection", J.str(mode)),
    J.kv("max_bytes", J.num(max)),
    J.kv("budget_scope", J.str("result_json_utf8")),
    J.kv("output_truncated", J.bool(cut)),
    J.kv("request_more", J.str("Use projection=full and raise max_response_bytes; " ++
      "raise max_bytes if truncated=true. For lists, reduce limit and keep the same checkpoint."))
  ], extra)))

def content_notice.if(yes: Bool, +j: J.Json, cut: Bool) -> List<&2, J.Json>:
  match yes:
    case True{}:
      complete = Maybe.default(&2, Bool, J.as_bool(J.get(j, "complete")), False{})
      [J.kv("content_complete", J.bool(complete && Bool.not(cut) &&
        Maybe.is_some(&2, J.Json, J.get(j, "content"))))]
    case False{}:
      []

def with_notice(+j: J.Json, mode: String, max: U32, +cut: Bool) -> J.Json:
  match j:
    case J.JObj{xs}:
      extra = content_notice.if(selected(j), j, cut)
      J.obj(List.append(&2, J.Json, J.unchain(xs), [notice(mode, max, cut, extra)]))
    case _:
      j

def fit.put(f: Fields, mode: String, max: U32) -> J.Json:
  Fields{items, cut} = f
  with_notice(J.obj(items), mode, max, cut)

def fit(+j: J.Json, mode: String, max: U32, left: U32) -> J.Json:
  match j:
    case J.JObj{xs}:
      fit.put(fit_fields(J.unchain(xs), left,
        selected(j) && String.eq(text(j, "content_encoding"), "base64")), mode, max)
    case _:
      j

def bounded.if(over: Bool, j: J.Json, mode: String, +max: U32, floor: U32)
  -> Result<&2, &2, String, J.Json>:
  match over:
    case True{}:
      Fail{"max_response_bytes is too small: need at least " ++ U32.show(floor) ++
        " bytes to preserve identities, completeness, Jev and cursor state; " ++
        "raise the budget or reduce limit and retry the same checkpoint"}
    case False{}:
      Done{fit(j, mode, max, (max - floor : U32))}

def bounded(+j: J.Json, +mode: String, +max: U32) -> Result<&2, &2, String, J.Json>:
  # false is one byte longer than true, so the immutable floor reserves
  # enough space for either flag; selected content_complete changes the other
  # way, consuming that spare byte when a fetched-complete part is shortened.
  +floor = bytes(with_notice(empty_body(j), mode, max, False{}))
  bounded.if(U32.is_gt(floor, max), j, mode, max, floor)

def apply(j: J.Json, +mode: String, max: U32) -> Result<&2, &2, String, J.Json>:
  match max:
    case 0:
      Done{with_notice(select(j, mode), mode, 0, False{})}
    case _:
      bounded(select(j, mode), mode, max)
