# Each selected message has one primary group. Header evidence is not trust.
import Base
import ./imap.bend as I
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

type Item is Data:
  Item{message: I.Msg, group: Group, delivery: Delivery, list_key: String}

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

def headers_bytes(small: Bool, +hs: String) -> Bool:
  match small:
    case False{}:
      False{}
    case True{}:
      U32.is_le(Codec.utf8_len(hs), 4096) &&
        (String.ends_with(hs, "\r\n\r\n") || String.eq(hs, "\r\n"))

def headers_small(m: I.Msg) -> Bool:
  I.Msg{u, flags, date, size, +hs, body, st} = m
  headers_bytes(Nat.is_le(String.length(String.take(hs, 4097n)), 4096n), hs)

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

def sender.small(small: Bool, m: I.Msg) -> Maybe<&2, String>:
  match small:
    case False{}:
      None{}
    case True{}:
      I.Msg{u, flags, date, size, hs, body, st} = m
      +fields = M.headers(hs)
      sender.fields(Nat.is_eq(C.field_count(fields, "from"), 1n) &&
        C.valid_fields(C.values(fields, False{})), fields)

def sender(+m: I.Msg) -> Maybe<&2, String>:
  sender.small(headers_small(m), m)

def senders.put(a: Maybe<&2, String>, +seen: List<&2, String>)
  -> List<&2, String>:
  match a:
    case None{}:
      seen
    case Some{+s}:
      Bool.pick(List<&2, String>, List.contains(~String, ~String.eq, seen, s), seen,
        List.append(&2, String, seen, [s]))

def senders.go(ms: List<&2, I.Msg>, seen: List<&2, String>) -> List<&2, String>:
  match ms:
    case Nil{}:
      seen
    case m <> t:
      senders.go(t, senders.put(sender(m), seen))

def senders(ms: List<&2, I.Msg>) -> List<&2, String>:
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

def item.small(small: Bool, +m: I.Msg, cs: List<&2, C.Contact>,
  allowed: List<&2, String>, me: String) -> Item:
  match small:
    case False{}:
      Item{m, UnknownPeople{}, OtherOrUnknown{}, ""}
    case True{}:
      I.Msg{u, flags, date, size, hs, body, st} = m
      +fields = M.headers(hs)
      +list_id = M.header(fields, "list-id")
      Item{m, group(bulk(fields), known.sender(sender(m), cs, allowed)),
        delivery(fields, me), list_key(bulk(fields), list_id)}

def item(+m: I.Msg, cs: List<&2, C.Contact>, allowed: List<&2, String>, me: String) -> Item:
  item.small(headers_small(m), m, cs, allowed, me)

def items(ms: List<&2, I.Msg>, +cs: List<&2, C.Contact>, +allowed: List<&2, String>, +me: String)
  -> List<&2, Item>:
  match ms:
    case Nil{}:
      []
    case m <> t:
      item(m, cs, allowed, me) <> items(t, cs, allowed, me)

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
