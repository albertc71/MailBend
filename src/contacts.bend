# Stored-header observations, not an address book or envelope history.
import Base
import ./codec.bend as C
import ./mime.bend as M
import ./imap.bend as I
import ./thread.bend as T
import ./awaiting.bend as A

type Contact is Data:
  Contact{address: String, name: String, count: U32, latest: U32, matches: Bool}

type Observed is Data:
  Observed{contacts: List<&2, Contact>, complete: Bool}

def occurrences(s: String, +needle: Char) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{c, t}:
      (Bool.pick(Nat, Char.is_eq(c, needle), 1n, 0n) + occurrences(t, needle) : Nat)

def bare_small(+s: String) -> Bool:
  M.addr_ok(s) && String.eq(M.addr_spec(s), s) &&
    Bool.not(String.contains(s, "(") || String.contains(s, ")") ||
      String.contains(s, "<") || String.contains(s, ">") || String.contains(s, "=?") ||
      String.contains(s, ":") || String.contains(s, "[") || String.contains(s, "]"))

def bare.if(short: Bool, s: String) -> Bool:
  match short:
    case False{}:
      False{}
    case True{}:
      bare_small(s)

def bare(+s: String) -> Bool:
  bare.if(Nat.is_le(String.length(String.take(s, 255n)), 254n), s)

def key(s: String) -> String:
  String.to_lower(M.addr_spec(s))

def syntax.go(s: String, +quoted: Bool, +escaped: Bool, +angle: Bool, +group: Bool,
  +valid: Bool) -> Bool:
  match s:
    case SNil{}:
      valid && Bool.not(quoted || escaped || angle || group)
    case SCon{+c, t}:
      +plain = Bool.not(quoted || escaped)
      +open = plain && Char.is_eq(c, '<')
      +close = plain && Char.is_eq(c, '>')
      +start = plain && Bool.not(angle) && Char.is_eq(c, ':')
      +end = plain && Bool.not(angle) && Char.is_eq(c, ';')
      quote = Bool.not(escaped || angle) && Char.is_eq(c, '"')
      +slash = Bool.not(escaped) && Char.is_eq(c, '\\')
      syntax.go(t, Bool.pick(Bool, quote, Bool.not(quoted), quoted), quoted && slash,
        Bool.pick(Bool, open, True{}, Bool.pick(Bool, close, False{}, angle)),
        Bool.pick(Bool, start, True{}, Bool.pick(Bool, end, False{}, group)),
        valid && Bool.not((open && angle) || (close && Bool.not(angle)) ||
          (start && group) || (end && Bool.not(group)) || (slash && Bool.not(quoted))))

def syntax(s: String) -> Bool:
  syntax.go(s, False{}, False{}, False{}, False{}, True{})

def address_small(+s: String) -> Bool:
  M.no_ctl(s) && syntax(s) &&
    Bool.not(String.contains(s, "(") || String.contains(s, ")")) && bare(M.addr_spec(s)) &&
    ((Nat.is_eq(occurrences(s, '<'), 0n) && Nat.is_eq(occurrences(s, '>'), 0n)) ||
     (Nat.is_eq(occurrences(s, '<'), 1n) && Nat.is_eq(occurrences(s, '>'), 1n) &&
      String.ends_with(String.trim(s), ">")))

def address_ok.if(short: Bool, s: String) -> Bool:
  match short:
    case False{}:
      False{}
    case True{}:
      address_small(s)

def address_ok(+s: String) -> Bool:
  address_ok.if(Nat.is_le(String.length(String.take(s, 513n)), 512n), s)

def label(s: String) -> String:
  M.header_line.text(M.decode_header(String.take(M.display_part(s), 256n)))

def largest.insert(+u: U32, xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      [u]
    case +h <> +t:
      rest = largest.insert(u, t)
      Bool.pick(List<&2, U32>, U32.is_eq(u, h), h <> t,
        Bool.pick(List<&2, U32>, U32.is_gt(u, h), u <> h <> t, h <> rest))

def largest.go(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case u <> t:
      largest.go(t, List.take(&2, U32, largest.insert(u, acc), 101n))

def largest(xs: List<&2, U32>) -> List<&2, U32>:
  largest.go(xs, [])

def contact_key(c: Contact) -> String:
  Contact{address, name, count, latest, matches} = c
  address

def keys(xs: List<&2, Contact>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case c <> t:
      contact_key(c) <> keys(t)

def add(xs: List<&2, Contact>, +address: String, +name: String, +time: U32, +matched: Bool)
  -> List<&2, Contact>:
  match xs:
    case Nil{}:
      [Contact{address, name, 1, time, matched}]
    case Contact{+a, +n, +count, +latest, +m} <> +t:
      Bool.pick(List<&2, Contact>, String.eq(a, address),
        Contact{a, Bool.pick(String, U32.is_ge(time, latest), name, n),
          (count + 1 : U32), Bool.pick(U32, U32.is_ge(time, latest), time, latest), m || matched} <> t,
        Contact{a, n, count, latest, m} <> add(t, address, name, time, matched))

# A repeated recipient can add name evidence without adding a second occurrence.
def touch(xs: List<&2, Contact>, +address: String, +name: String, +matched: Bool)
  -> List<&2, Contact>:
  match xs:
    case Nil{}:
      []
    case Contact{+a, n, count, latest, m} <> t:
      +same = String.eq(a, address)
      Contact{a, Bool.pick(String, same && matched, name, n), count, latest,
        m || (same && matched)} <> touch(t, address, name, matched)

def values(hs: List<&2, M.Hdr>, +sent: Bool) -> List<&2, String>:
  match hs:
    case Nil{}:
      []
    case M.Hdr{+n, v} <> t:
      List.filter.put(String, v, values(t, sent),
        Bool.pick(Bool, sent, String.eq(n, "to") || String.eq(n, "cc") || String.eq(n, "bcc"),
          String.eq(n, "from")))

def tokens(vs: List<&2, String>) -> List<&2, String>:
  match vs:
    case Nil{}:
      []
    case v <> t:
      List.append(&2, String, M.addr_list(v), tokens(t))

type TokenScan is Data:
  TokenScan{seen: List<&2, String>, observed: Observed}

def token(valid: Bool, +raw: String, time: U32, +query: String, scan: TokenScan) -> TokenScan:
  match valid scan:
    case False{} TokenScan{seen, Observed{cs, complete}}:
      TokenScan{seen, Observed{cs, False{}}}
    case True{} TokenScan{+seen, Observed{+cs, complete}}:
      +address = key(raw)
      +fresh = Bool.not(C.is_in(address, seen))
      +room = Nat.is_lt(List.length(&2, Contact, cs), 501n) || C.is_in(address, keys(cs))
      +name = label(raw)
      +matched = String.contains(address, query) || String.contains(String.to_lower(name), query)
      TokenScan{address <> seen,
        Observed{Bool.pick(List<&2, Contact>, fresh && room,
          add(cs, address, name, time, matched),
          Bool.pick(List<&2, Contact>, Bool.not(fresh), touch(cs, address, name, matched), cs)),
          complete && room}}

def token_observed(scan: TokenScan) -> Observed:
  TokenScan{seen, observed} = scan
  observed

def add_tokens(xs: List<&2, String>, +time: U32, +query: String,
  scan: TokenScan) -> Observed:
  match xs:
    case Nil{}:
      token_observed(scan)
    case +raw <> t:
      add_tokens(t, time, query, token(address_ok(raw), raw, time, query, scan))

def observe_tokens.if(valid: Bool, xs: List<&2, String>, time: U32, query: String,
  state: Observed) -> Observed:
  match valid:
    case True{}:
      add_tokens(xs, time, query, TokenScan{[], state})
    case False{}:
      Observed{cs, complete} = state
      Observed{cs, False{}}

def observe_tokens(+xs: List<&2, String>, sent: Bool, time: U32, query: String,
  state: Observed) -> Observed:
  +n = List.length(&2, String, xs)
  observe_tokens.if(Nat.is_ge(n, 1n) && Nat.is_le(n, 100n) && (sent || Nat.is_eq(n, 1n)),
    xs, time, query, state)

def field_count(hs: List<&2, M.Hdr>, +name: String) -> Nat:
  match hs:
    case Nil{}:
      0n
    case M.Hdr{n, v} <> t:
      (Bool.pick(Nat, String.eq(n, name), 1n, 0n) + field_count(t, name) : Nat)

def valid_fields(vs: List<&2, String>) -> Bool:
  match vs:
    case Nil{}:
      True{}
    case v <> t:
      syntax(v) && valid_fields(t)

def observe_fields.if(valid: Bool, hs: List<&2, M.Hdr>, +sent: Bool, time: U32,
  query: String, state: Observed) -> Observed:
  match valid:
    case False{}:
      Observed{cs, complete} = state
      Observed{cs, False{}}
    case True{}:
      observe_tokens(tokens(values(hs, sent)), sent, time, query, state)

def observe_fields(+hs: List<&2, M.Hdr>, +sent: Bool, time: U32, query: String,
  state: Observed) -> Observed:
  valid = Bool.pick(Bool, sent,
    Nat.is_le(field_count(hs, "to"), 1n) && Nat.is_le(field_count(hs, "cc"), 1n) &&
      Nat.is_le(field_count(hs, "bcc"), 1n), Nat.is_eq(field_count(hs, "from"), 1n))
  observe_fields.if(valid && valid_fields(values(hs, sent)), hs, sent, time, query, state)

def observe_header(valid: Bool, hs: String, sent: Bool, time: U32, query: String,
  state: Observed) -> Observed:
  match valid:
    case False{}:
      Observed{cs, complete} = state
      Observed{cs, False{}}
    case True{}:
      observe_fields(M.headers(hs), sent, time, query, state)

def observe(ns: List<&2, T.Node>, +sent: Bool, +query: String, +now: U32,
  state: Observed) -> Observed:
  match ns:
    case Nil{}:
      state
    case +n <> t:
      T.Node{f, v, I.Msg{u, flags, date, size, +hs, body, st}, +time, id, p, refs} = n
      valid = U32.is_le(C.utf8_len(hs), 4096) &&
        (String.ends_with(hs, "\r\n\r\n") || String.eq(hs, "\r\n")) &&
        A.date_valid(n) && U32.is_le(time, now)
      observe(t, sent, query, now, observe_header(valid, hs, sent, time, query, state))

def before(+a: Contact, +b: Contact) -> Bool:
  Contact{aa, an, +ac, +at, am} = a
  Contact{ba, bn, bc, bt, bm} = b
  U32.is_gt(ac, bc) || (U32.is_eq(ac, bc) && U32.is_ge(at, bt))

def matching(xs: List<&2, Contact>) -> List<&2, Contact>:
  match xs:
    case Nil{}:
      []
    case +c <> t:
      Contact{a, n, count, time, matched} = c
      List.filter.put(Contact, c, matching(t), matched)

def find(xs: List<&2, Contact>, +address: String) -> Contact:
  match xs:
    case Nil{}:
      Contact{address, "", 0, 0, False{}}
    case +c <> t:
      Bool.pick(Contact, String.eq(contact_key(c), address), c, find(t, address))
