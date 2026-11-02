import Base
import ../../src/contacts.bend as C
import ../../src/imap.bend as I
import ../../src/thread.bend as T
import ../../src/ops.bend as O

def show(o: C.Observed) -> String:
  C.Observed{cs, complete} = o
  Bool.show(complete) ++ ":" ++ String.join(C.keys(cs), ",")

def observation(hs: String) -> String:
  n = T.node("Sent", Some{7}, I.Msg{1, [], "01-Oct-2026 09:00:00 +0000", 0, hs, "", I.VNil{}})
  show(C.observe([n], True{}, "", 1800000000, C.Observed{[], True{}}))

def show_match(c: C.Contact, complete: Bool) -> String:
  C.Contact{a, name, count, time, matches} = c
  Bool.show(complete) ++ ":" ++ U32.show(count) ++ ":" ++ Bool.show(matches)

def repeated_result(o: C.Observed) -> String:
  C.Observed{cs, complete} = o
  show_match(C.find(cs, "a@x"), complete)

def repeated_name() -> String:
  n = T.node("Sent", Some{7}, I.Msg{1, [], "01-Oct-2026 09:00:00 +0000", 0,
    "To: a@x\r\nCc: Sam <a@x>\r\n\r\n", "", I.VNil{}})
  repeated_result(C.observe([n], True{}, "sam", 1800000000, C.Observed{[], True{}}))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(observation("To: Sam <sam@x>\r\nCc: sam@x\r\nBcc: hidden@x\r\n\r\n"))
    IO.print(observation("To: Sam <sam@x> tail\r\n\r\n"))
    IO.print(observation("To: =?utf-8?b?c2FtQHg=?=\r\n\r\n"))
    IO.print(observation("To: sam@x\r\n"))
    IO.print(observation("To: \"Sam <sam@x>\r\n\r\n"))
    IO.print(observation("To: Group: sam@x\r\n\r\n"))
    IO.print(observation("To: Bad <a:b@x>\r\n\r\n"))
    IO.print(observation("To: Bad <a@x> tail, a@x\r\n\r\n"))
    IO.print(repeated_name())
    IO.print(Bool.show(C.address_ok("sam@x.extra")) ++ ":" ++ C.key("Sam <SAM@X>"))
    IO.print(Bool.show(C.bare("$(id)@x")))
    IO.print(I.uid_set(C.largest([9, 1, 8, 9, 3])))
    IO.print(I.item_str(I.IContactHeaders{}))
    IO.print(Bool.show(I.any_writes(O.plan_contacts_headers("Sent", [1], 7))))

#|True:sam@x,hidden@x
#|False:
#|False:
#|False:
#|False:
#|False:
#|False:
#|False:a@x
#|True:1:True
#|True:sam@x
#|False
#|9,8,3,1
#|BODY.PEEK[HEADER.FIELDS (FROM TO CC BCC)]<0.4097>
#|False
