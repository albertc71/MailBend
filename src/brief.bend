# Each selected message has one primary group. Header evidence is not trust.
import Base
import ./imap.bend as I
import ./json.bend as J
import ./mime.bend as M
import ./contacts.bend as C
import ./codec.bend as Codec
import ./message-metadata.bend as Meta

type Group is Data:
  People{}
  Lists{}
  Automated{}
  UnknownPeople{}

type Delivery is Data:
  Direct{}
  CcOnly{}
  OtherOrUnknown{}

# Classification evidence is prepared once, then retained across contact IO.
# The original message is kept for summaries and annotation.
type Prepared is Data:
  Prepared{message: I.Msg, fields: List<&2, M.Hdr>, valid: Bool, sender: Maybe<&2, String>}

type Item is Data:
  Item{message: I.Msg, group: Group, delivery: Delivery, list_key: String}

type SelectionWindow is Data:
  ArrivalWindow{since: U32}
  UnseenWindow{after: U32, high: U32}

def window_mode(w: SelectionWindow) -> String:
  match w:
    case ArrivalWindow{s}:
      "arrivals"
    case UnseenWindow{l, h}:
      "unseen"

def window_floor(w: SelectionWindow) -> U32:
  match w:
    case ArrivalWindow{s}:
      s
    case UnseenWindow{l, h}:
      l

def window_contains(w: SelectionWindow, +u: U32) -> Bool:
  match w:
    case ArrivalWindow{s}:
      U32.is_gt(u, s)
    case UnseenWindow{l, h}:
      U32.is_gt(u, l) && U32.is_le(u, h)

def window_uids(xs: List<&2, U32>, +w: SelectionWindow) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case +u <> t:
      List.filter.put(U32, u, window_uids(t, w), window_contains(w, u))

def checkpoint(w: SelectionWindow, more: Bool, last: U32) -> U32:
  match w:
    case ArrivalWindow{s}:
      last
    case UnseenWindow{l, h}:
      Bool.pick(U32, more, last, h)

def checkpoint_basis(w: SelectionWindow, more: Bool) -> String:
  match w:
    case ArrivalWindow{s}:
      "selected_prefix"
    case UnseenWindow{l, h}:
      Bool.pick(String, more, "selected_prefix", "high_water")

# This is an untrusted consistency token, not authority or a frozen flag snapshot.
type UnseenCursor is Data:
  UnseenCursor{folder: String, uidv: U32, after: U32, high: U32}

def CursorResult() -> Data:
  Result<&2, &2, String, UnseenCursor>

def cursor_invalid() -> CursorResult():
  Fail{"invalid brief continuation: use next_continuation unchanged, without since_uid"}

def cursor_number.value(n: Maybe<&2, U32>, raw: String) -> Maybe<&2, U32>:
  match n:
    case Some{+v}:
      Bool.pick(Maybe<&2, U32>, String.eq(raw, U32.show(v)), Some{v}, None{})
    case None{}:
      None{}

def cursor_number(m: Maybe<&2, J.Json>) -> Maybe<&2, U32>:
  match m:
    case Some{J.JNum{+raw}}:
      cursor_number.value(U32.read(raw), raw)
    case _:
      None{}

# Six required fields plus an exact bounded member count reject unknown and
# duplicate members too: any such member displaces a required one.
def cursor_members(xs: J.Json, left: Nat) -> Bool:
  match xs left:
    case J.JEnd{} 0n:
      True{}
    case J.JCons{J.JKv{k, v}, t} 1n+n:
      cursor_members(t, n)
    case _ _:
      False{}

def cursor_checked(valid: Bool, f: String, v: U32, l: U32, h: U32) -> CursorResult():
  match valid:
    case True{}:
      Done{UnseenCursor{f, v, l, h}}
    case False{}:
      cursor_invalid()

def cursor_folder_valid(+f: String) -> Bool:
  Bool.not(String.is_empty(f)) && M.no_ctl(f) &&
    Nat.is_le(String.length(String.take(f, 4001n)), 4000n)

def cursor_values(version: Maybe<&2, U32>, mode: Maybe<&2, String>, folder: Maybe<&2, String>,
  uidv: Maybe<&2, U32>, after: Maybe<&2, U32>, high: Maybe<&2, U32>, members: Bool) -> CursorResult():
  match version mode folder uidv after high:
    case Some{ver} Some{m} Some{+f} Some{+v} Some{+l} Some{+h}:
      cursor_checked(members && U32.is_eq(ver, 1) && String.eq(m, "unseen") &&
        cursor_folder_valid(f) &&
        U32.is_gt(v, 0) && U32.is_le(l, h), f, v, l, h)
    case _ _ _ _ _ _:
      cursor_invalid()

def cursor_read(+j: J.Json) -> CursorResult():
  match j:
    case J.JObj{xs}:
      cursor_values(cursor_number(J.get(j, "version")), J.as_str(J.get(j, "mode")),
        J.as_str(J.get(j, "folder")), cursor_number(J.get(j, "uidvalidity")),
        cursor_number(J.get(j, "after_uid")), cursor_number(J.get(j, "high_uid")),
        cursor_members(xs, 6n))
    case _:
      cursor_invalid()

def cursor_json(c: UnseenCursor) -> J.Json:
  UnseenCursor{f, v, l, h} = c
  J.obj([J.kv("version", J.num(1)), J.kv("mode", J.str("unseen")),
    J.kv("folder", J.str(f)), J.kv("uidvalidity", J.num(v)),
    J.kv("after_uid", J.num(l)), J.kv("high_uid", J.num(h))])

def next_cursor(w: SelectionWindow, more: Bool, folder: String, uidv: U32, last: U32) -> J.Json:
  match w more:
    case UnseenWindow{l, h} True{}:
      cursor_json(UnseenCursor{folder, uidv, last, h})
    case _ _:
      J.JNull{}

def group_name(g: Group) -> String:
  match g:
    case People{}:
      "people"
    case Lists{}:
      "lists"
    case Automated{}:
      "automated"
    case UnknownPeople{}:
      "unknown_people"

def delivery_name(d: Delivery) -> String:
  match d:
    case Direct{}:
      "direct"
    case CcOnly{}:
      "cc_only"
    case OtherOrUnknown{}:
      "other_or_unknown"

def uid(m: I.Msg) -> U32:
  I.Msg{u, flags, date, size, hs, body, st} = m
  u

def classification_field(+name: String) -> Bool:
  String.eq(name, "from") || String.eq(name, "to") || String.eq(name, "cc") ||
    String.eq(name, "list-id") || String.eq(name, "auto-submitted") || String.eq(name, "precedence")

# Retain duplicate relevant fields; irrelevant header size is not classification evidence.
def classification_fields(xs: List<&2, M.Hdr>) -> List<&2, M.Hdr>:
  match xs:
    case Nil{}:
      []
    case +h <> t:
      M.Hdr{name, value} = h
      List.filter.put(M.Hdr, h, classification_fields(t), classification_field(name))

def evidence(hs: String) -> List<&2, M.Hdr>:
  classification_fields(M.headers(hs))

def fields_bytes(xs: List<&2, M.Hdr>) -> U32:
  match xs:
    case Nil{}:
      0
    case M.Hdr{+name, value} <> t:
      # Saturation also bounds the work on a single oversized value.
      +tail = fields_bytes(t)
      +size = (Codec.utf8_len(String.take(value, 4097n)) + Codec.utf8_len(name) + 4 : U32)
      Bool.pick(U32, U32.is_gt(size, 4096) || U32.is_gt(tail, 4096), 4097,
        (size + tail : U32))

def sender.one(xs: List<&2, String>) -> Maybe<&2, String>:
  match xs:
    case +s <> Nil{}:
      Bool.pick(Maybe<&2, String>, C.address_ok(s), Some{C.key(s)}, None{})
    case _:
      None{}

def sender.fields(valid: Bool, hs: List<&2, M.Hdr>) -> Maybe<&2, String>:
  match valid:
    case False{}:
      None{}
    case True{}:
      sender.one(C.tokens(C.values(hs, False{})))

def sender.small(small: Bool, +fields: List<&2, M.Hdr>) -> Maybe<&2, String>:
  match small:
    case False{}:
      None{}
    case True{}:
      sender.fields(Nat.is_eq(C.field_count(fields, "from"), 1n) &&
        C.valid_fields(C.values(fields, False{})), fields)

def prepare.fields(m: I.Msg, +fields: List<&2, M.Hdr>) -> Prepared:
  +small = U32.is_le(fields_bytes(fields), 4096)
  # Invalid evidence is never consulted again; do not retain oversized parsed values.
  Prepared{m, Bool.pick(List<&2, M.Hdr>, small, fields, []),
    small, sender.small(small, fields)}

def prepare.complete(complete: Bool, m: I.Msg, hs: String) -> Prepared:
  match complete:
    case False{}:
      Prepared{m, [], False{}, None{}}
    case True{}:
      prepare.fields(m, evidence(hs))

def prepare(+m: I.Msg) -> Prepared:
  I.Msg{u, flags, date, size, +hs, body, st} = m
  prepare.complete(String.ends_with(hs, "\r\n\r\n") || String.eq(hs, "\r\n"), m, hs)

def prepare_all(ms: List<&2, I.Msg>) -> List<&2, Prepared>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      prepare(m) <> prepare_all(t)

def prepared_message(p: Prepared) -> I.Msg:
  Prepared{m, fields, valid, a} = p
  m

def sender(p: Prepared) -> Maybe<&2, String>:
  Prepared{m, fields, valid, a} = p
  a

def senders.put(a: Maybe<&2, String>, +seen: List<&2, String>)
  -> List<&2, String>:
  match a:
    case None{}:
      seen
    case Some{+s}:
      Bool.pick(List<&2, String>, List.contains(~String, ~String.eq, seen, s), seen,
        List.append(&2, String, seen, [s]))

def senders.go(ms: List<&2, Prepared>, seen: List<&2, String>) -> List<&2, String>:
  match ms:
    case Nil{}:
      seen
    case m <> t:
      senders.go(t, senders.put(sender(m), seen))

def senders(ms: List<&2, Prepared>) -> List<&2, String>:
  senders.go(ms, [])

def positive(c: C.Contact) -> Bool:
  C.Contact{address, name, count, latest, matches} = c
  U32.is_gt(count, 0)

def known.sender(a: Maybe<&2, String>, cs: List<&2, C.Contact>, allowed: List<&2, String>) -> Bool:
  match a:
    case None{}:
      False{}
    case Some{+s}:
      List.contains(~String, ~String.eq, allowed, s) && positive(C.find(cs, s))

def recipients_ok(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      C.address_ok(x) && recipients_ok(t)

def recipient(xs: List<&2, String>, +me: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      String.eq(C.key(x), me) || recipient(t, me)

def delivery.checked(valid: Bool, to: List<&2, String>, cc: List<&2, String>, +me: String)
  -> Delivery:
  match valid:
    case False{}:
      OtherOrUnknown{}
    case True{}:
      Bool.pick(Delivery, recipient(to, me), Direct{},
        Bool.pick(Delivery, recipient(cc, me), CcOnly{}, OtherOrUnknown{}))

def delivery(+hs: List<&2, M.Hdr>, +me: String) -> Delivery:
  +to = M.addr_list(M.header(hs, "to"))
  +cc = M.addr_list(M.header(hs, "cc"))
  delivery.checked(C.bare(me) && Nat.is_le(C.field_count(hs, "to"), 1n) &&
    Nat.is_le(C.field_count(hs, "cc"), 1n) && C.syntax(M.header(hs, "to")) &&
    C.syntax(M.header(hs, "cc")) && recipients_ok(to) && recipients_ok(cc), to, cc, me)

def bulk(+hs: List<&2, M.Hdr>) -> Meta.Bulk:
  Bool.pick(Meta.Bulk, Nat.is_le(C.field_count(hs, "list-id"), 1n) &&
    Nat.is_le(C.field_count(hs, "auto-submitted"), 1n) &&
    Nat.is_le(C.field_count(hs, "precedence"), 1n),
    Meta.bulk(M.header(hs, "list-id"), M.header(hs, "auto-submitted"),
      M.header(hs, "precedence")), Meta.Unspecified{})

def group(b: Meta.Bulk, known: Bool) -> Group:
  match b:
    case Meta.ListMail{}:
      Lists{}
    case Meta.AutoMail{}:
      Automated{}
    case Meta.PrecedenceBulk{}:
      Automated{}
    case Meta.Unspecified{}:
      Bool.pick(Group, known, People{}, UnknownPeople{})

def list_key(b: Meta.Bulk, s: String) -> String:
  match b:
    case Meta.ListMail{}:
      s
    case _:
      ""

def prepared_item.small(small: Bool, m: I.Msg, +fields: List<&2, M.Hdr>,
  a: Maybe<&2, String>, cs: List<&2, C.Contact>, allowed: List<&2, String>, me: String) -> Item:
  match small:
    case False{}:
      Item{m, UnknownPeople{}, OtherOrUnknown{}, ""}
    case True{}:
      +b = bulk(fields)
      Item{m, group(b, known.sender(a, cs, allowed)),
        delivery(fields, me), list_key(b, M.header(fields, "list-id"))}

def prepared_item(p: Prepared, cs: List<&2, C.Contact>,
  allowed: List<&2, String>, me: String) -> Item:
  Prepared{m, fields, small, a} = p
  prepared_item.small(small, m, fields, a, cs, allowed, me)

def prepared_items(ps: List<&2, Prepared>, +cs: List<&2, C.Contact>,
  +allowed: List<&2, String>, +me: String) -> List<&2, Item>:
  match ps:
    case Nil{}:
      []
    case p <> t:
      prepared_item(p, cs, allowed, me) <> prepared_items(t, cs, allowed, me)

# Raw-message convenience APIs use the same prepared classifier as production.
def item(m: I.Msg, cs: List<&2, C.Contact>, allowed: List<&2, String>, me: String) -> Item:
  prepared_item(prepare(m), cs, allowed, me)

def items(ms: List<&2, I.Msg>, cs: List<&2, C.Contact>, allowed: List<&2, String>, me: String)
  -> List<&2, Item>:
  prepared_items(prepare_all(ms), cs, allowed, me)

def item_uid(i: Item) -> U32:
  Item{m, g, d, k} = i
  uid(m)

def uids(xs: List<&2, Item>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      []
    case i <> t:
      item_uid(i) <> uids(t)

def message_uids(ms: List<&2, I.Msg>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      uid(m) <> message_uids(t)

def occurrences(xs: List<&2, U32>, +u: U32) -> Nat:
  match xs:
    case Nil{}:
      0n
    case x <> t:
      (Bool.pick(Nat, U32.is_eq(x, u), 1n, 0n) + occurrences(t, u) : Nat)

def same_uids(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      U32.is_eq(x, y) && same_uids(xt, yt)
    case _ _:
      False{}
