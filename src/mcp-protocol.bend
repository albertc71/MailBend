# MCP 2026-07-28 metadata and complete-result envelopes; no mail policy.

import Base
import ./json.bend as J

def modern_version() -> String:
  "2026-07-28"

def latest_legacy_version() -> String:
  "2025-06-18"

def legacy_versions() -> List<&2, String>:
  [latest_legacy_version(), "2025-03-26", "2024-11-05"]

def versions() -> J.Json:
  J.strs(modern_version() <> legacy_versions())

def line_cap() -> U32:
  8388608

def field(s: String) -> String:
  "io.modelcontextprotocol/" ++ s

def has(j: J.Json, key: String) -> Bool:
  Maybe.is_some(&2, J.Json, J.get(j, key))

def is_object(m: Maybe<&2, J.Json>) -> Bool:
  match m:
    case Some{J.JObj{items}}:
      True{}
    case _:
      False{}

def is_string(m: Maybe<&2, J.Json>) -> Bool:
  Maybe.is_some(&2, String, J.as_str(m))

def meta(p: J.Json) -> J.Json:
  Maybe.default(&2, J.Json, J.get(p, "_meta"), J.JNull{})

# A malformed modern marker cannot fall through to legacy semantics.
def is_modern_marked(+p: J.Json) -> Bool:
  +m = meta(p)
  (has(p, "_meta") && Bool.not(is_object(Some{m}))) ||
  has(m, field("protocolVersion")) || has(m, field("clientCapabilities")) ||
  has(m, field("clientInfo"))

def optional_object(+j: J.Json, +key: String) -> Bool:
  Bool.not(has(j, key)) || is_object(J.get(j, key))

def client_info_ok(m: Maybe<&2, J.Json>) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{+j}:
      is_object(Some{j}) && is_string(J.get(j, "name")) && is_string(J.get(j, "version"))

def object_values(j: J.Json) -> Bool:
  match j:
    case J.JObj{items}:
      object_values(items)
    case J.JCons{J.JKv{k, v}, tail}:
      is_object(Some{v}) && object_values(tail)
    case J.JEnd{}:
      True{}
    case _:
      False{}

def capability_map(m: Maybe<&2, J.Json>) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{+j}:
      is_object(Some{j}) && object_values(j)

def capability_options(m: Maybe<&2, J.Json>, a: String, b: String) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{+j}:
      is_object(Some{j}) && optional_object(j, a) && optional_object(j, b)

# MailBend never requests client capabilities. Validate their container and
# known object fields; unknown extension capabilities remain forward compatible.
def capabilities(+j: J.Json) -> Bool:
  is_object(Some{j}) && optional_object(j, "roots") &&
  capability_options(J.get(j, "sampling"), "context", "tools") &&
  capability_options(J.get(j, "elicitation"), "form", "url") &&
  capability_map(J.get(j, "extensions")) && capability_map(J.get(j, "experimental"))

def metadata_ok(+p: J.Json) -> Bool:
  +m = meta(p)
  caps = Maybe.default(&2, J.Json, J.get(m, field("clientCapabilities")), J.JNull{})
  is_object(Some{m}) && is_string(J.get(m, field("protocolVersion"))) &&
  capabilities(caps) && client_info_ok(J.get(m, field("clientInfo")))

def requested(p: J.Json) -> String:
  Maybe.default(&2, String, J.as_str(J.get(meta(p), field("protocolVersion"))), "")

def server_info(v: String) -> J.Json:
  J.obj([J.kv("name", J.str("mailbend")), J.kv("version", J.str(v))])

def complete_result(j: J.Json, v: String) -> J.Json:
  match j:
    case J.JObj{items}:
      m = J.obj([J.kv(field("serverInfo"), server_info(v))])
      J.JObj{J.JCons{J.kv("resultType", J.str("complete")),
        J.JCons{J.kv("_meta", m), items}}}
    case _:
      j

def result(modern: Bool, j: J.Json, v: String) -> J.Json:
  match modern:
    case True{}:
      complete_result(j, v)
    case False{}:
      j

def unsupported(id: J.Json, p: J.Json) -> String:
  data = J.obj([J.kv("supported", versions()), J.kv("requested", J.str(requested(p)))])
  error = J.obj([J.kv("code", J.JNum{"-32022"}),
    J.kv("message", J.str("Unsupported protocol version")), J.kv("data", data)])
  J.show(J.obj([J.kv("jsonrpc", J.str("2.0")), J.kv("id", id), J.kv("error", error)]))

# Modern MCP ids are strings or integers, never null or fractional numbers.
# Saturate exponents above the maximum request size. This avoids overflow
# without rejecting integer-valued ids such as 1.0, 1e3 or arbitrarily large
# exponents; no mantissa in a request can have that many decimal places.
def integer.magnitude(s: String, n: U32) -> U32:
  match s:
    case SNil{}:
      n
    case SCon{c, t}:
      +next = (n * 10 + Char.to_u32(c) - 48 : U32)
      +cap = (line_cap() + 1 : U32)
      integer.magnitude(t, Bool.pick(U32, U32.is_gt(next, cap), cap, next))

def integer.exponent(s: String, places: U32, zeros: U32, all_zero: Bool) -> Bool:
  match s:
    case SCon{'-', t}:
      all_zero || U32.is_ge(zeros, (places + integer.magnitude(t, 0) : U32))
    case SCon{'+', t}:
      all_zero || U32.is_ge((zeros + integer.magnitude(t, 0) : U32), places)
    case _:
      all_zero || U32.is_ge((zeros + integer.magnitude(s, 0) : U32), places)

def integer.go(
  s: String, +fractional: Bool, places: U32, zeros: U32, all_zero: Bool
) -> Bool:
  match s:
    case SNil{}:
      all_zero || U32.is_ge(zeros, places)
    case SCon{'e', t}:
      integer.exponent(t, places, zeros, all_zero)
    case SCon{'E', t}:
      integer.exponent(t, places, zeros, all_zero)
    case SCon{'.', t}:
      integer.go(t, True{}, places, zeros, all_zero)
    case SCon{c, t}:
      +zero = U32.is_eq(Char.to_u32(c), 48)
      integer.go(t, fractional, (places + Bool.pick(U32, fractional, 1, 0) : U32),
        Bool.pick(U32, zero, (zeros + 1 : U32), 0), all_zero && zero)

# Called only with a number already checked by the JSON parser.
def integer(s: String) -> Bool:
  match s:
    case SCon{'-', t}:
      integer.go(t, False{}, 0, 0, True{})
    case _:
      integer.go(s, False{}, 0, 0, True{})

def id_ok(id: J.Json) -> Bool:
  match id:
    case J.JStr{s}:
      True{}
    case J.JNum{s}:
      integer(s)
    case _:
      False{}
