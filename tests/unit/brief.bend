import Base
import ../../src/brief.bend as B
import ../../src/imap.bend as I
import ../../src/contacts.bend as C

def msg(u: U32, hs: String) -> I.Msg:
  I.Msg{u, [], "", 0, hs, "", I.VNil{}}

def label(i: B.Item) -> String:
  B.Item{m, g, d, k} = i
  B.group_name(g) ++ ":" ++ B.delivery_name(d) ++ ":" ++ k

def observed(hs: String) -> String:
  label(B.item(msg(7, hs), [C.Contact{"known@x", "", 1, 0, True{}}], ["known@x"], "me@x"))

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
