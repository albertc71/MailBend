# Untrusted header signals for read results. No value here authorizes an action.

import Base
import ./mime.bend as M
import ./imap.bend as I
import ./json.bend as J

type Scan is Data:
  Start{}
  Uri{}
  After{}
  Comment{depth: U32, escaped: Bool, after: Bool}
  Stop{}

def whitespace(+c: Char) -> Bool:
  Char.is_eq(c, ' ') || Char.is_eq(c, '\t') || Char.is_eq(c, '\r') || Char.is_eq(c, '\n')

def scan.step(+c: Char, state: Scan) -> Scan:
  match c state:
    case _ Stop{}:
      Stop{}
    case _ Comment{depth, True{}, after}:
      Comment{depth, False{}, after}
    case '\\' Comment{depth, False{}, after}:
      Comment{depth, True{}, after}
    case '(' Comment{depth, False{}, after}:
      Comment{(depth + 1 : U32), False{}, after}
    case ')' Comment{+depth, False{}, +after}:
      Bool.pick(Scan, U32.is_eq(depth, 1), Bool.pick(Scan, after, After{}, Start{}),
        Comment{(depth - 1 : U32), False{}, after})
    case _ Comment{depth, False{}, after}:
      Comment{depth, False{}, after}
    case '(' Start{}:
      Comment{1, False{}, False{}}
    case '(' After{}:
      Comment{1, False{}, True{}}
    case '<' Start{}:
      Uri{}
    case '>' Uri{}:
      After{}
    case '<' Uri{}:
      Stop{}
    case ',' After{}:
      Start{}
    case _ Start{}:
      Bool.pick(Scan, whitespace(c), Start{}, Stop{})
    case _ After{}:
      Bool.pick(Scan, whitespace(c), After{}, Stop{})
    case _ Uri{}:
      Uri{}

def urls.go(s: String, +state: Scan, +rev: String, acc: List<&2, String>)
  -> List<&2, String>:
  match s state:
    case SNil{} _:
      List.reverse(&2, String, acc)
    case _ Stop{}:
      List.reverse(&2, String, acc)
    case SCon{'>', t} Uri{}:
      urls.go(t, After{}, "", String.reverse(rev) <> acc)
    case SCon{+c, t} Uri{}:
      urls.go(t, scan.step(c, Uri{}),
        Bool.pick(String, whitespace(c), rev, SCon{c, rev}), acc)
    case SCon{+c, t} _:
      urls.go(t, scan.step(c, state), "", acc)

def complete(s: String, +state: Scan) -> Bool:
  match s state:
    case SNil{} After{}:
      True{}
    case SNil{} _:
      False{}
    case _ Stop{}:
      False{}
    case SCon{c, t} _:
      complete(t, scan.step(c, state))

def uri_chars(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      U32.is_gt(Char.to_u32(c), 32) && U32.is_lt(Char.to_u32(c), 127) &&
        Bool.not(Char.is_eq(c, '"') || Char.is_eq(c, '<') || Char.is_eq(c, '>') ||
          Char.is_eq(c, '\\')) && uri_chars(t)

def first(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> _:
      h

def authority(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'/', _}:
      ""
    case SCon{'?', _}:
      ""
    case SCon{'#', _}:
      ""
    case SCon{c, t}:
      SCon{c, authority(t)}

def last(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> Nil{}:
      h
    case _ <> t:
      last(t)

def digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Char.is_digit(c) && digits(t)

def port(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{':', t}:
      digits(t)
    case _:
      False{}

def host(+s: String) -> Bool:
  match s:
    case SCon{'[', +t}:
      +name = first(String.split(t, ']'))
      Bool.not(String.is_empty(name)) && String.contains(t, "]") &&
        port(String.drop(t, 1n+String.length(name)))
    case _:
      +name = first(String.split(s, ':'))
      Bool.not(String.is_empty(name) || String.contains(name, "[") ||
        String.contains(name, "]")) && port(String.drop(s, String.length(name)))

def https_authority(s: String, scheme: String) -> Bool:
  Bool.not(String.eq(scheme, "https://")) ||
    host(last(String.split(authority(String.drop(s, 8n)), '@')))

def uri_matches(+s: String, +scheme: String) -> Bool:
  String.starts_with(String.to_lower(s), scheme) &&
    Nat.is_gt(String.length(s), String.length(scheme)) && uri_chars(s) &&
    https_authority(s, scheme)

def scheme.go(s: String, rev: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{':', _}:
      String.to_lower(String.reverse(rev))
    case SCon{+c, t}:
      Bool.pick(String, Char.is_alpha(c) || Char.is_digit(c) ||
        Char.is_eq(c, '+') || Char.is_eq(c, '-') || Char.is_eq(c, '.'),
        scheme.go(t, SCon{c, rev}), "")

def scheme(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      Bool.pick(String, Char.is_alpha(c), scheme.go(t, SCon{c, SNil{}}), "")

def valid_urls(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      +kind = scheme(h)
      Bool.not(String.is_empty(kind)) && uri_chars(h) &&
        (Bool.not(String.eq(kind, "https")) || uri_matches(h, "https://")) &&
        (Bool.not(String.eq(kind, "mailto")) || uri_matches(h, "mailto:")) && valid_urls(t)

def first_uri(xs: List<&2, String>, +scheme: String) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> t:
      Bool.pick(String, uri_matches(h, scheme), h, first_uri(t, scheme))

def uri_count(xs: List<&2, String>, +kind: String) -> U32:
  match xs:
    case Nil{}:
      0
    case h <> t:
      (Bool.pick(U32, String.eq(scheme(h), kind), 1, 0) + uri_count(t, kind) : U32)

def header_count(hs: List<&2, M.Hdr>, +name: String) -> U32:
  match hs:
    case Nil{}:
      0
    case M.Hdr{n, _} <> t:
      (Bool.pick(U32, String.eq(n, name), 1, 0) + header_count(t, name) : U32)

def nullable(s: String) -> J.Json:
  match s:
    case SNil{}:
      J.JNull{}
    case SCon{h, t}:
      J.str(SCon{h, t})

def uncomment(s: String, +depth: U32, escaped: Bool) -> String:
  match s escaped:
    case SNil{} _:
      Bool.pick(String, U32.is_zero(depth), "", "(")
    case SCon{_, t} True{}:
      uncomment(t, depth, False{})
    case SCon{'\\', t} False{}:
      Bool.pick(String, U32.is_zero(depth), "\\", "") ++
        uncomment(t, depth, Bool.not(U32.is_zero(depth)))
    case SCon{'(', t} False{}:
      " " ++ uncomment(t, (depth + 1 : U32), False{})
    case SCon{')', t} False{}:
      Bool.pick(String, U32.is_zero(depth), ")", " ") ++
        uncomment(t, Bool.pick(U32, U32.is_zero(depth), 0,
          (depth - 1 : U32)), False{})
    case SCon{+c, t} False{}:
      Bool.pick(String, U32.is_zero(depth), SCon{c, SNil{}}, "") ++
        uncomment(t, depth, False{})

def keyword(s: String) -> String:
  String.to_lower(String.trim(first(String.split(uncomment(s, 0, False{}), ';'))))

def token(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      U32.is_gt(Char.to_u32(c), 32) && U32.is_lt(Char.to_u32(c), 127) &&
        Bool.not(String.contains("()<>@,;:\\\"/[]?=", SCon{c, SNil{}})) && token(t)

type Bulk is Data:
  ListMail{}
  AutoMail{}
  PrecedenceBulk{}
  Unspecified{}

def bulk(list_id: String, auto: String, precedence: String) -> Bulk:
  +a = keyword(auto)
  +p = keyword(precedence)
  Bool.pick(Bulk, Bool.not(String.is_empty(list_id)), ListMail{},
    Bool.pick(Bulk, Bool.not(String.is_empty(a) || String.eq(a, "no")) && token(a), AutoMail{},
      Bool.pick(Bulk, String.eq(p, "bulk") || String.eq(p, "list") || String.eq(p, "junk"),
        PrecedenceBulk{}, Unspecified{})))

def bulk_json(b: Bulk) -> J.Json:
  match b:
    case ListMail{}:
      J.str("list")
    case AutoMail{}:
      J.str("auto")
    case PrecedenceBulk{}:
      J.str("precedence-bulk")
    case Unspecified{}:
      J.JNull{}

def unsubscribe(+hs: List<&2, M.Hdr>) -> J.Json:
  +raw = M.header(hs, "list-unsubscribe")
  +urls = urls.go(raw, Start{}, "", [])
  one = complete(raw, Start{}) && valid_urls(urls) && U32.is_zero(uri_count(urls, "http")) &&
    U32.is_eq(header_count(hs, "list-unsubscribe"), 1) &&
    U32.is_eq(header_count(hs, "list-unsubscribe-post"), 1) &&
    U32.is_eq(uri_count(urls, "https"), 1) &&
    Bool.not(String.contains(authority(String.drop(first_uri(urls, "https://"), 8n)), "@")) &&
    String.eq(String.to_lower(M.header(hs, "list-unsubscribe-post")), "list-unsubscribe=one-click")
  J.obj([J.kv("mailto", nullable(first_uri(urls, "mailto:"))),
    J.kv("https", nullable(first_uri(urls, "https://"))), J.kv("one_click", J.bool(one))])

def fields(+hs: List<&2, M.Hdr>, +flags: List<&2, String>) -> List<&2, J.Json>:
  +list_id = M.header(hs, "list-id")
  +auto = M.header(hs, "auto-submitted")
  [J.kv("list_id", nullable(list_id)), J.kv("auto_submitted", nullable(auto)),
    J.kv("bulk", bulk_json(bulk(list_id, auto, M.header(hs, "precedence")))),
    J.kv("unsubscribe", unsubscribe(hs)),
    J.kv("answered", J.bool(I.has_attr(flags, "\\Answered"))),
    J.kv("forwarded", J.bool(I.has_attr(flags, "$Forwarded")))]
