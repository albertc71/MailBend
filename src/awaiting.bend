# Bounded reply evidence. Only complete searches can establish absence.

import Base
import ./codec.bend as C
import ./imap.bend as I
import ./mime.bend as M
import ./thread.bend as T

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

def candidates(ns: List<&2, T.Node>, +now: U32, +min_age: U32) -> List<&2, T.Node>:
  match ns:
    case Nil{}:
      []
    case +n <> t:
      List.filter.put(T.Node, n, candidates(t, now, min_age), eligible(n, now, min_age))

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

def search_numbers(ws: List<&2, String>) -> Maybe<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Some{[]}
    case +w <> t:
      do Maybe<&2, List<&2, U32>>:
        +u : U32 <- U32.read(w)
        valid : Unit <- Bool.pick(Maybe<&2, Unit>,
          String.eq(U32.show(u), w) && Bool.not(U32.is_zero(u)), Some{Unit{}}, None{})
        rest : List<&2, U32> <- search_numbers(t)
        return u <> rest

def search_line(text: String) -> Maybe<&2, List<&2, U32>>:
  match text:
    case "* SEARCH":
      Some{[]}
    case _:
      search_numbers(String.split(String.drop(text, 9n), ' '))

def search.only(lines: List<&2, I.RLine>) -> Maybe<&2, List<&2, U32>>:
  match lines:
    case I.RLine{+text, Nil{}} <> Nil{}:
      do Maybe<&2, List<&2, U32>>:
        prefix : Unit <- Bool.pick(Maybe<&2, Unit>,
          String.eq(String.to_upper(text), "* SEARCH") ||
            String.starts_with(String.to_upper(text), "* SEARCH "),
          Some{Unit{}}, None{})
        found : List<&2, U32> <- search_line(String.to_upper(text))
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
        String.starts_with(String.to_upper(text), "* SEARCH"))

def search(lines: List<&2, I.RLine>) -> Maybe<&2, List<&2, U32>>:
  search.only(search.lines(lines))
