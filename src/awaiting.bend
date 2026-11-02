# Bounded reply evidence. Only complete searches can establish absence.

import Base
import ./codec.bend as C
import ./imap.bend as I
import ./mime.bend as M
import ./thread.bend as T

type Filters is Data:
  Filters{lists: Bool, automated: Bool}

type Status is Data:
  Replied{}
  Awaiting{}
  Unknown{}

def status_name(s: Status) -> String:
  match s:
    case Replied{}:
      "replied"
    case Awaiting{}:
      "awaiting"
    case Unknown{}:
      "unknown"

def digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Char.is_digit(c) && digits(t)

def number.put(value: Maybe<&2, U32>, low: U32, high: U32) -> Bool:
  match value:
    case Some{+n}:
      U32.is_ge(n, low) && U32.is_le(n, high)
    case None{}:
      False{}

def number(+s: String, low: U32, high: U32) -> Bool:
  digits(s) && Bool.not(String.is_empty(s)) && number.put(U32.read(s), low, high)

def zone(z: String) -> Bool:
  match z:
    case SCon{+sign, +t}:
      (Char.is_eq(sign, '+') || Char.is_eq(sign, '-')) && Nat.is_eq(String.length(t), 4n) &&
        number(String.take(t, 2n), 0, 23) && number(String.drop(t, 2n), 0, 59)
    case _:
      False{}

def date_roundtrip(civil: U32 & (U32 & U32), y: U32, m: U32, d: U32) -> Bool:
  (yy, (mm, dd)) = civil
  U32.is_eq(yy, y) && U32.is_eq(mm, m) && U32.is_eq(dd, d)

def date_parts(dmy: List<&2, String>, hms: List<&2, String>, z: String) -> Bool:
  match dmy hms:
    case +d <> mon <> +y <> Nil{} h <> mi <> sec <> Nil{}:
      +month = I.month_number(mon)
      number(y, 1970, 2105) && number(d, 1, 31) && Bool.not(U32.is_zero(month)) &&
        date_roundtrip(C.civil(C.days_from_civil(I.date_num(y), month, I.date_num(d))),
          I.date_num(y), month, I.date_num(d)) &&
        number(h, 0, 23) && number(mi, 0, 59) && number(sec, 0, 59) && zone(z)
    case _ _:
      False{}

def date_valid.parts(ps: List<&2, String>) -> Bool:
  match ps:
    case dmy <> hms <> z <> Nil{}:
      date_parts(String.split(dmy, '-'), String.split(hms, ':'), z)
    case _:
      False{}

def date_valid(n: T.Node) -> Bool:
  T.Node{f, v, I.Msg{u, flags, date, size, headers, body, st}, time, id, parents, refs} = n
  date_valid.parts(String.split(String.trim(date), ' ')) && Bool.not(U32.is_zero(time))

def header_count(hs: List<&2, M.Hdr>, +name: String) -> Nat:
  match hs:
    case Nil{}:
      0n
    case M.Hdr{key, value} <> t:
      (Bool.pick(Nat, String.eq(key, name), 1n, 0n) + header_count(t, name) : Nat)

def valid_id(+n: T.Node) -> Bool:
  T.Node{folder, uidv, I.Msg{uid, flags, date, size, headers, body, st}, time,
    +id, replies_to, refs} = n
  +hs = M.headers(headers)
  ids = T.msg_ids(M.header(hs, "message-id"))
  Nat.is_eq(header_count(hs, "message-id"), 1n) &&
    Nat.is_eq(List.length(&2, String, ids), 1n) &&
    Bool.not(String.is_empty(id)) && T.is_searchable(id) && date_valid(n)

def header_ids(hs: List<&2, M.Hdr>, +name: String) -> List<&2, String>:
  match hs:
    case Nil{}:
      []
    case M.Hdr{key, value} <> t:
      List.append(&2, String,
        Bool.pick(List<&2, String>, String.eq(key, name), T.msg_ids(value), []),
        header_ids(t, name))

def replies_to(+sent: T.Node, +reply: T.Node, now: U32) -> Bool:
  T.Node{folder, uidv, I.Msg{uid, flags, date, size, headers, body, st}, +time,
    id, parents, refs} = reply
  +hs = M.headers(headers)
  date_valid(reply) && U32.is_le(time, now) && U32.is_gt(time, T.node_time(sent)) &&
    (C.is_in(T.node_id(sent), header_ids(hs, "in-reply-to")) ||
      C.is_in(T.node_id(sent), header_ids(hs, "references")))

def has_reply(+sent: T.Node, replies: List<&2, T.Node>, +now: U32) -> Bool:
  match replies:
    case Nil{}:
      False{}
    case r <> t:
      replies_to(sent, r, now) || has_reply(sent, t, now)

def classify.if(valid: Bool, replied: Bool, complete: Bool) -> Status:
  match valid replied complete:
    case True{} True{} _:
      Replied{}
    case True{} False{} True{}:
      Awaiting{}
    case _ _ _:
      Unknown{}

def classify(+sent: T.Node, replies: List<&2, T.Node>, complete: Bool, now: U32) -> Status:
  classify.if(valid_id(sent), has_reply(sent, replies, now), complete)

def eligible(+n: T.Node, +now: U32, min_age: U32) -> Bool:
  +at = T.node_time(n)
  Bool.not(date_valid(n)) ||
    (U32.is_le(at, now) && U32.is_ge((now - at : U32), (min_age * 86400 : U32)))

def list_word(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      U32.is_lt(Char.to_u32(c), 128) &&
        (Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '-')) && list_word(t)

def list_label(+s: String) -> Bool:
  Bool.not(String.is_empty(s)) && list_word(s) &&
    Bool.not(String.starts_with(s, "-")) && Bool.not(String.ends_with(s, "-"))

def list_labels(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      list_label(h) && list_labels(t)

def list_display(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{+c, t}:
      U32.is_lt(Char.to_u32(c), 128) &&
        (Char.is_alpha(c) || Char.is_digit(c) || Char.is_eq(c, '-') ||
          Char.is_eq(c, ' ') || Char.is_eq(c, '\t')) && list_display(t)

def list_value.parts(xs: List<&2, String>) -> Bool:
  match xs:
    case display <> +tail <> Nil{}:
      +id = String.take(tail, Nat.sub(String.length(tail), 1n))
      list_display(display) && String.ends_with(tail, ">") &&
        String.contains(id, ".") && list_labels(String.split(id, '.'))
    case _:
      False{}

def within(text: String, fuel: Nat) -> Bool:
  match text fuel:
    case SNil{} _:
      True{}
    case _ 0n:
      False{}
    case SCon{c, t} 1n+n:
      within(t, n)

def list_value.bounded(ok: Bool, value: String) -> Bool:
  match ok:
    case False{}:
      False{}
    case True{}:
      list_value.parts(String.split(String.trim(value), '<'))

def list_value(+value: String) -> Bool:
  list_value.bounded(within(value, 998n), value)

def auto_value(value: String) -> Bool:
  +v = String.to_lower(String.trim(value))
  String.eq(v, "auto-generated") || String.eq(v, "auto-replied")

# The shared MIME parser recovers malformed field names. Such recovery must not
# turn ambiguous metadata into positive evidence for hiding a candidate.
def filter_header_line(+line: String, +name: String) -> Bool:
  +key = String.to_lower(M.before_colon(line))
  Bool.not(String.eq(String.trim(key), name) ||
    (Bool.not(String.contains(line, ":")) && String.starts_with(String.to_lower(line), name))) ||
    (String.contains(line, ":") && String.eq(key, name))

def filter_header_lines(xs: List<&2, String>, +name: String) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      filter_header_line(M.strip_cr(h), name) && filter_header_lines(t, name)

def excluded.headers(n: T.Node, filters: Filters) -> Bool:
  T.Node{f, v, I.Msg{u, flags, date, size, +headers, body, st}, time, id, parents, refs} = n
  Filters{lists, automated} = filters
  +hs = M.headers(headers)
  +lines = String.split(headers, '\n')
  (lists && filter_header_lines(lines, "list-id") &&
    Nat.is_eq(header_count(hs, "list-id"), 1n) && list_value(M.header(hs, "list-id"))) ||
  (automated && filter_header_lines(lines, "auto-submitted") &&
    Nat.is_eq(header_count(hs, "auto-submitted"), 1n) &&
    auto_value(M.header(hs, "auto-submitted")))

def excluded.bounded(ok: Bool, n: T.Node, filters: Filters) -> Bool:
  match ok:
    case False{}:
      False{}
    case True{}:
      excluded.headers(n, filters)

def excluded.within(+n: T.Node, filters: Filters) -> Bool:
  T.Node{f, v, I.Msg{u, flags, date, size, headers, body, st}, time, id, parents, refs} = n
  excluded.bounded(within(headers, 4096n), n, filters)

def excluded(n: T.Node, filters: Filters) -> Bool:
  match filters:
    case Filters{False{}, False{}}:
      False{}
    case _:
      excluded.within(n, filters)

def candidates(ns: List<&2, T.Node>, +now: U32, +min_age: U32, +filters: Filters)
  -> List<&2, T.Node>:
  match ns:
    case Nil{}:
      []
    case +n <> t:
      List.filter.put(T.Node, n, candidates(t, now, min_age, filters),
        eligible(n, now, min_age) && Bool.not(excluded(n, filters)))

def ids(ns: List<&2, T.Node>) -> List<&2, String>:
  match ns:
    case Nil{}:
      []
    case +n <> t:
      List.filter.put(String, T.node_id(n), ids(t), valid_id(n))

def valid_candidates(ns: List<&2, T.Node>) -> Bool:
  match ns:
    case Nil{}:
      True{}
    case n <> t:
      valid_id(n) && valid_candidates(t)

def valid_dates(ns: List<&2, T.Node>, +now: U32) -> Bool:
  match ns:
    case Nil{}:
      True{}
    case +n <> t:
      date_valid(n) && U32.is_le(T.node_time(n), now) && valid_dates(t, now)

def reply_key(+id: String) -> I.Key:
  I.KOr{I.KHeader{"References", id}, I.KHeader{"In-Reply-To", id}}

def batch_key(ids: List<&2, String>) -> I.Key:
  match ids:
    case Nil{}:
      I.KHeader{"Message-ID", "<mailbend-empty-batch.invalid>"}
    case id <> Nil{}:
      reply_key(id)
    case id <> t:
      I.KOr{reply_key(id), batch_key(t)}

def batches.go(fuel: Nat, ids: List<&2, String>) -> List<&2, I.Key>:
  match fuel ids:
    case 0n _:
      []
    case _ Nil{}:
      []
    case 1n+rest +id <> +t:
      batch_key(List.take(&2, String, id <> t, 10n)) <>
        batches.go(rest, List.drop(&2, String, id <> t, 10n))

def batches(ids: List<&2, String>) -> List<&2, I.Key>:
  batches.go(5n, ids)

def prepend(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case u <> t:
      prepend(t, u <> acc)

def append(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  prepend(List.reverse(&2, U32, xs), ys)

def smallest.insert(+u: U32, xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      [u]
    case +h <> +t:
      rest = smallest.insert(u, t)
      Bool.pick(List<&2, U32>, U32.is_eq(u, h), h <> t,
        Bool.pick(List<&2, U32>, U32.is_lt(u, h), u <> h <> t, h <> rest))

def smallest.go(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case u <> t:
      smallest.go(t, List.take(&2, U32, smallest.insert(u, acc), 101n))

def smallest(xs: List<&2, U32>) -> List<&2, U32>:
  smallest.go(xs, [])

def search_numbers.reject(acc: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match acc:
    case Nil{}:
      None{}
    case u <> t:
      search_numbers.reject(t)

def search_numbers.finish(valid: Bool, u: U32, acc: List<&2, U32>)
  -> Maybe<&2, List<&2, U32>>:
  match valid:
    case False{}:
      search_numbers.reject(acc)
    case True{}:
      Some{List.reverse(&2, U32, u <> acc)}

def search_numbers.go(text: String, left: Nat, valid: Bool, +word: String,
  acc: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match text left valid:
    case _ _ False{}:
      search_numbers.reject(acc)
    case _ 0n True{}:
      search_numbers.reject(acc)
    case SNil{} _ True{}:
      +u = Maybe.default(&2, U32, U32.read(word), 0)
      search_numbers.finish(String.eq(U32.show(u), word) && Bool.not(U32.is_zero(u)), u, acc)
    case SCon{' ', t} 1n+rest True{}:
      +u = Maybe.default(&2, U32, U32.read(word), 0)
      search_numbers.go(t, rest, String.eq(U32.show(u), word) && Bool.not(U32.is_zero(u)),
        "", u <> acc)
    case SCon{+c, t} _ True{}:
      search_numbers.go(t, left, Char.is_digit(c) && Nat.is_lt(String.length(word), 10n),
        word ++ SCon{c, SNil{}}, acc)

def search_numbers(text: String) -> Maybe<&2, List<&2, U32>>:
  search_numbers.go(text, 10000n, True{}, "", [])

def search_line.empty(empty: Bool, text: String) -> Maybe<&2, List<&2, U32>>:
  match empty:
    case True{}:
      Some{[]}
    case False{}:
      search_numbers(String.drop(text, 9n))

def search_line(+text: String) -> Maybe<&2, List<&2, U32>>:
  search_line.empty(String.eq(String.to_upper(String.take(text, 9n)), "* SEARCH"), text)

def search.only(lines: List<&2, I.RLine>) -> Maybe<&2, List<&2, U32>>:
  match lines:
    case I.RLine{+text, Nil{}} <> Nil{}:
      do Maybe<&2, List<&2, U32>>:
        prefix : Unit <- Bool.pick(Maybe<&2, Unit>,
          String.eq(String.to_upper(String.take(text, 9n)), "* SEARCH") ||
            String.starts_with(String.to_upper(String.take(text, 9n)), "* SEARCH "),
          Some{Unit{}}, None{})
        found : List<&2, U32> <- search_line(text)
        return found
    case _:
      None{}

def search.lines(lines: List<&2, I.RLine>) -> List<&2, I.RLine>:
  match lines:
    case Nil{}:
      []
    case +r <> t:
      I.RLine{text, literals} = r
      List.filter.put(I.RLine, r, search.lines(t),
        String.starts_with(String.to_upper(String.take(text, 9n)), "* SEARCH"))

def search(lines: List<&2, I.RLine>) -> Maybe<&2, List<&2, U32>>:
  search.only(search.lines(lines))
