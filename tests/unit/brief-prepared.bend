# Frozen pre-cache orchestration versus prepared evidence and explicit goldens.

import Base
import ../../src/brief.bend as B
import ../../src/imap.bend as I
import ../../src/contacts.bend as C
import ../../src/mime.bend as M

# Keep these old orchestration definitions independent of prepare/prepared_item.
# Shared classification primitives are deliberately unchanged by this patch.
def legacy.complete(complete: Bool, hs: String) -> Bool:
  match complete:
    case False{}:
      False{}
    case True{}:
      U32.is_le(B.fields_bytes(B.classification_fields(M.headers(hs))), 4096)

def legacy.small(+hs: String) -> Bool:
  legacy.complete(String.ends_with(hs, "\r\n\r\n") || String.eq(hs, "\r\n"), hs)

def legacy.sender.if(small: Bool, hs: String) -> Maybe<&2, String>:
  match small:
    case False{}:
      None{}
    case True{}:
      +fields = B.classification_fields(M.headers(hs))
      B.sender.fields(Nat.is_eq(C.field_count(fields, "from"), 1n) &&
        C.valid_fields(C.values(fields, False{})), fields)

def legacy.sender(+hs: String) -> Maybe<&2, String>:
  legacy.sender.if(legacy.small(hs), hs)

def legacy.item(small: Bool, +m: I.Msg, cs: List<&2, C.Contact>,
  allowed: List<&2, String>) -> B.Item:
  match small:
    case False{}:
      B.Item{m, B.UnknownPeople{}, B.OtherOrUnknown{}, ""}
    case True{}:
      I.Msg{u, flags, date, size, +hs, body, st} = m
      +fields = B.classification_fields(M.headers(hs))
      B.Item{m, B.group(B.bulk(fields), B.known.sender(legacy.sender(hs), cs, allowed)),
        B.delivery(fields, "me@x"), B.list_key(B.bulk(fields), M.header(fields, "list-id"))}

def msg(hs: String) -> I.Msg:
  I.Msg{7, ["\\Seen"], "date", 42, hs, "original body", I.VList{[I.VStr{"original structure"}]}}

def label(i: B.Item) -> String:
  B.Item{m, g, d, k} = i
  B.group_name(g) ++ ":" ++ B.delivery_name(d) ++ ":" ++ k

def structure_kept(st: I.Value) -> Bool:
  match st:
    case I.VList{I.VStr{s} <> Nil{}}:
      String.eq(s, "original structure")
    case _:
      False{}

def item_message(i: B.Item) -> I.Msg:
  B.Item{m, g, d, k} = i
  m

def same_message(a: I.Msg, b: I.Msg) -> Bool:
  I.Msg{u, flags, date, size, hs, body, st} = a
  I.Msg{v, flags2, date2, size2, hs2, body2, st2} = b
  U32.is_eq(u, v) && String.eq(String.join(flags, ","), String.join(flags2, ",")) &&
    String.eq(date, date2) && U32.is_eq(size, size2) && String.eq(hs, hs2) && String.eq(body, body2) &&
    structure_kept(st) && structure_kept(st2)

def check(+hs: String, +cs: List<&2, C.Contact>, +allowed: List<&2, String>) -> String:
  +m = msg(hs)
  +p = B.prepare(m)
  a = B.sender(p)
  original = B.prepared_message(p)
  +result = B.prepared_item(p, cs, allowed, "me@x")
  label(legacy.item(legacy.small(hs), m, cs, allowed)) ++ "|" ++
    label(result) ++ "|" ++
    Bool.show(same_message(m, original) && same_message(m, item_message(result))) ++ "|" ++
    Bool.show(String.eq(Maybe.default(&2, String, a, ""),
      Maybe.default(&2, String, legacy.sender(hs), "")))

def observed(hs: String) -> String:
  check(hs, [C.Contact{"known@x", "", 1, 0, True{}}], ["known@x"])

def boundary.prepared(+p: B.Prepared, +hs: String) -> String:
  B.Prepared{m, fields, valid, a} = p
  old = label(legacy.item(legacy.small(hs), msg(hs), [], []))
  new = label(B.prepared_item(p, [], [], "me@x"))
  Bool.show(valid) ++ ":" ++ Bool.show(String.eq(old, new)) ++ ":" ++
    Maybe.default(&2, String, a, "none") ++ ":" ++ Bool.show(List.is_empty(&2, M.Hdr, fields))

def boundary(+hs: String) -> String:
  boundary.prepared(B.prepare(msg(hs)), hs)

def boundary_headers(a: String, b: String) -> String:
  "From: known@x\r\nTo: me@x\r\nList-Id: " ++ a ++ "\r\nPrecedence: " ++ b ++ "\r\n\r\n"

# A deliberately inconsistent internal record detects fallback to raw headers:
# classification must use prepared fields/sender, while retaining the raw message.
def cached_only(p: B.Prepared) -> String:
  B.Prepared{m, fields, valid, a} = p
  +raw = msg("From: absent@x\r\n\r\n")
  +cached = {B.Prepared{raw, fields, valid, a} : B.Prepared}
  +result = B.prepared_item(cached, [C.Contact{"known@x", "", 1, 0, True{}}],
    ["known@x"], "me@x")
  String.join(B.senders([cached]), ",") ++ ":" ++ label(result) ++ ":" ++
    Bool.show(same_message(B.prepared_message(cached), raw) &&
      same_message(item_message(result), raw))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(observed("From: known@x\r\nTo: me@x\r\n\r\n"))
    IO.print(observed("fRoM: Known <KNOWN@X>\r\nTo:\r\n me@x\r\n\r\n"))
    IO.print(observed("From: unknown@x\r\nCc: me@x\r\n\r\n"))
    IO.print(observed("From: broken\r\nTo: me@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nFrom: known@x\r\nTo: me@x\r\n\r\n"))
    IO.print(observed("From: known@x, other@x\r\nTo: me@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: me@x\r\nTo: other@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nCc: me@x\r\nCc: other@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: bad@x tail, me@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nList-Id: news <news.x>\r\nAuto-Submitted: auto-generated\r\n\r\n"))
    IO.print(observed("From: known@x\r\nList-Id: one\r\nList-Id: two\r\n\r\n"))
    IO.print(observed("From: known@x\r\nAuto-Submitted: auto-generated\r\nAuto-Submitted: no\r\n\r\n"))
    IO.print(observed("From: known@x\r\nPrecedence: bulk\r\nPrecedence: bulk\r\n\r\n"))
    IO.print(observed("From: known@x\r\nAuto-Submitted: auto-generated\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: me@x\r\n"))
    IO.print(observed("From: known@x\nTo: me@x\n\n"))
    IO.print(observed("\r\n"))
    IO.print(observed(""))
    IO.print(observed("From: known@x\r\nTo: me@x\r\nReferences: " ++ String.repeat("x", 5000n) ++ "\r\n\r\n"))
    IO.print(check("From: known@x\r\nTo: me@x\r\n\r\n", [C.Contact{"known@x", "", 0, 0, True{}}], ["known@x"]))
    IO.print(check("From: known@x\r\nTo: me@x\r\n\r\n", [C.Contact{"known@x", "", 1, 0, True{}}], []))
    IO.print(String.join(B.senders(B.prepare_all([msg("From: known@x\r\n\r\n"), msg("From: KNOWN@X\r\n\r\n"), msg("From: broken\r\n\r\n"), msg("From: other@x\r\n\r\n")])), ","))
    IO.print(I.uid_set(B.uids(B.prepared_items(B.prepare_all([msg(""), msg("\r\n"), msg("From: known@x\r\n\r\n")]), [], [], "me@x"))))
    IO.print(cached_only(B.prepare(msg("From: known@x\r\nTo: me@x\r\n\r\n"))))
    IO.print(boundary(boundary_headers(String.repeat("x", 2023n), String.repeat("x", 2023n))))
    IO.print(boundary(boundary_headers(String.repeat("x", 2023n), String.repeat("x", 2024n))))
    IO.print(boundary(boundary_headers(String.repeat("é", 1011n) ++ "x", String.repeat("x", 2023n))))
    IO.print(boundary(boundary_headers(String.repeat("é", 1011n) ++ "x", String.repeat("x", 2024n))))

#|people:direct:|people:direct:|True|True
#|people:direct:|people:direct:|True|True
#|unknown_people:cc_only:|unknown_people:cc_only:|True|True
#|unknown_people:direct:|unknown_people:direct:|True|True
#|unknown_people:direct:|unknown_people:direct:|True|True
#|unknown_people:direct:|unknown_people:direct:|True|True
#|people:other_or_unknown:|people:other_or_unknown:|True|True
#|people:other_or_unknown:|people:other_or_unknown:|True|True
#|people:other_or_unknown:|people:other_or_unknown:|True|True
#|lists:other_or_unknown:news <news.x>|lists:other_or_unknown:news <news.x>|True|True
#|people:other_or_unknown:|people:other_or_unknown:|True|True
#|people:other_or_unknown:|people:other_or_unknown:|True|True
#|people:other_or_unknown:|people:other_or_unknown:|True|True
#|automated:other_or_unknown:|automated:other_or_unknown:|True|True
#|unknown_people:other_or_unknown:|unknown_people:other_or_unknown:|True|True
#|unknown_people:other_or_unknown:|unknown_people:other_or_unknown:|True|True
#|unknown_people:other_or_unknown:|unknown_people:other_or_unknown:|True|True
#|unknown_people:other_or_unknown:|unknown_people:other_or_unknown:|True|True
#|people:direct:|people:direct:|True|True
#|unknown_people:direct:|unknown_people:direct:|True|True
#|unknown_people:direct:|unknown_people:direct:|True|True
#|known@x,other@x
#|7,7,7
#|known@x:people:direct::True
#|True:True:known@x:False
#|False:True:none:True
#|True:True:known@x:False
#|False:True:none:True
