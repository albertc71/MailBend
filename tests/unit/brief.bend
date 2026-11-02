import Base
import ../../src/brief.bend as B
import ../../src/imap.bend as I
import ../../src/contacts.bend as C
import ../../src/mime.bend as M

def msg(u: U32, hs: String) -> I.Msg:
  I.Msg{u, [], "", 0, hs, "", I.VNil{}}

def label(i: B.Item) -> String:
  B.Item{m, g, d, k} = i
  B.group_name(g) ++ ":" ++ B.delivery_name(d) ++ ":" ++ k

def observed(hs: String) -> String:
  label(B.item(msg(7, hs), [C.Contact{"known@x", "", 1, 0, True{}}], ["known@x"], "me@x"))

# Independent fixtures: base From/To cost 25; List-Id/Precedence overhead 25.
# Two 2023-byte values therefore total 4096. UTF-8 é takes two bytes.
def edge_fields(a: String, b: String) -> List<&2, M.Hdr>:
  [M.Hdr{"from", "known@x"}, M.Hdr{"to", "me@x"},
    M.Hdr{"list-id", a}, M.Hdr{"precedence", b}]

def edge_headers(a: String, b: String) -> String:
  "From: known@x\r\nTo: me@x\r\nList-Id: " ++ a ++ "\r\nPrecedence: " ++ b ++ "\r\n\r\n"

def edge_result(n: U32, i: B.Item) -> String:
  B.Item{m, g, d, key} = i
  U32.show(n) ++ ":" ++ B.group_name(g) ++ ":" ++ B.delivery_name(d)

def edge(+a: String, +b: String) -> String:
  edge_result(B.fields_bytes(edge_fields(a, b)),
    B.item(msg(7, edge_headers(a, b)), [], [], "me@x"))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(observed("From: known@x\r\nTo: me@x\r\n\r\n"))
    IO.print(observed("From: absent@x\r\nCc: me@x\r\n\r\n"))
    IO.print(observed("From: broken\r\nTo: me@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: me@x.extra\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: me@x\r\nCc: me@x\r\n\r\n"))
    IO.print(observed("From: known@x\r\nList-Id: news <news.x>\r\nAuto-Submitted: auto-generated\r\n\r\n"))
    IO.print(observed("From: known@x\r\nAuto-Submitted: auto-generated\r\n\r\n"))
    IO.print(observed("From: absent@x\r\nPrecedence: bulk\r\n\r\n"))
    IO.print(observed("From: absent@x\r\nAuto-Submitted: no\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: bad@x tail, me@x\r\n\r\n"))
    IO.print(observed("From: absent@x\r\nList-Id: first\r\nList-Id: second\r\n\r\n"))
    IO.print(observed("From: known@x\r\nTo: me@x\r\n"))
    IO.print(label(B.item(msg(1, "From: known@x\r\n\r\n"),
      [C.Contact{"known@x", "", 1, 0, True{}}], [], "me@x")))
    IO.print(I.uid_set(B.uids(B.items([msg(2, ""), msg(1, ""), msg(2, "")], [], [], ""))))
    IO.print(U32.show(B.checkpoint(B.UnseenWindow{8}, False{}, 0)))
    IO.print(U32.show(B.checkpoint(B.UnseenWindow{8}, False{}, 2)))
    IO.print(U32.show(B.checkpoint(B.UnseenWindow{8}, True{}, 2)))
    IO.print(I.uid_set(B.window_uids([0, 2, 4, 5, 6], B.UnseenWindow{4})))
    IO.print(I.uid_set(B.window_uids([0, 2, 4, 5, 6], B.ArrivalWindow{4})))
    IO.print(edge(String.repeat("x", 2023n), String.repeat("x", 2023n)))
    IO.print(edge(String.repeat("x", 2023n), String.repeat("x", 2024n)))
    IO.print(edge(String.repeat("é", 1011n) ++ "x", String.repeat("x", 2023n)))
    IO.print(edge(String.repeat("é", 1011n) ++ "x", String.repeat("x", 2024n)))

#|people:direct:
#|unknown_people:cc_only:
#|unknown_people:direct:
#|people:other_or_unknown:
#|people:direct:
#|lists:other_or_unknown:news <news.x>
#|automated:other_or_unknown:
#|automated:other_or_unknown:
#|unknown_people:other_or_unknown:
#|people:other_or_unknown:
#|unknown_people:other_or_unknown:
#|unknown_people:other_or_unknown:
#|unknown_people:other_or_unknown:
#|2,1,2
#|8
#|8
#|2
#|2,4
#|5,6
#|4096:lists:direct
#|4097:unknown_people:other_or_unknown
#|4096:lists:direct
#|4097:unknown_people:other_or_unknown
