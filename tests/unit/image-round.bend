# Request-level image rounds preserve candidate order and group selected
# sections by UID without granting more count or fetch slots.

import Base
import ../../src/imap.bend as I
import ../../src/ops.bend as Ops
import ../../src/image.bend as Image
import ../../src/sections.bend as Part
import ../../src/tools.bend as Tools

def part(uid: U32, section: U32, typ: String, size: U32) -> Tools.ImgPart:
  Tools.ImgPart{uid, Part.Part{[section], typ, "", "base64", size}}

def candidates() -> List<&2, Tools.ImgPart>:
  [part(3, 2, "image/gif", 10), part(3, 3, "image/png", 10),
    part(3, 4, "image/jpeg", 12), part(9, 2, "image/png", 14),
    part(9, 3, "image/png", 0), part(15, 2, "image/png", 16),
    part(20, 2, "image/png", 18)]

def chosen(ps: List<&2, Tools.ImgFetch>) -> String:
  match ps:
    case Nil{}:
      ""
    case Tools.ImgFetch{uid, p, max} <> rest:
      U32.show(uid) ++ "/" ++ I.section_str(Part.path(p)) ++ ":" ++ U32.show(max) ++
        ";" ++ chosen(rest)

def one_line(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', SCon{'\n', SNil{}}}:
      ""
    case SCon{'\r', SCon{'\n', t}}:
      " | " ++ one_line(t)
    case SCon{c, t}:
      SCon{c, one_line(t)}

def slots(count: U32, bytes: U32, fetches: U32) -> String:
  U32.show(Image.quota_round(Image.Quota{Image.Room{count, bytes}, fetches}))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("slots " ++ slots(4, 1572864, 8) ++ " " ++ slots(3, 20, 1) ++ " " ++
      slots(0, 20, 8) ++ " " ++ slots(4, 0, 8) ++ " " ++ slots(4, 20, 0))
    IO.print("none [" ++ chosen(Tools.round_parts(candidates(), 0n)) ++ "]")
    IO.print("first " ++ chosen(Tools.round_parts(candidates(), 4n)))
    IO.print("short " ++ chosen(Tools.round_parts(candidates(), 8n)))
    IO.print(one_line(I.script(Ops.plan_image_round("INBOX", 42,
      Tools.round_reads(Tools.round_parts(candidates(), 4n))))))
    IO.print("writes " ++ Bool.show(I.any_writes(Ops.plan_image_round("INBOX", 42,
      Tools.round_reads(Tools.round_parts(candidates(), 4n))))))

#|slots 4 1 0 0 0
#|none []
#|first 3/3:11;3/4:13;9/2:15;15/2:17;
#|short 3/3:11;3/4:13;9/2:15;15/2:17;20/2:19;
#|a1 EXAMINE "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a2 UID FETCH 3 (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST AUTO-SUBMITTED PRECEDENCE)] BODYSTRUCTURE BODY.PEEK[3]<0.11> BODY.PEEK[4]<0.13>) | a3 UID FETCH 9 (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST AUTO-SUBMITTED PRECEDENCE)] BODYSTRUCTURE BODY.PEEK[2]<0.15>) | a4 UID FETCH 15 (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST AUTO-SUBMITTED PRECEDENCE)] BODYSTRUCTURE BODY.PEEK[2]<0.17>)
#|writes False
