# Read identities bind each folder's own generation before UID work.

import Base
import ../../src/imap.bend as I
import ../../src/ops.bend as Ops

# An unknown folder is opened normally; known identities stay with their folder.
def multi_folder() -> Bool:
  +cs : List<&2, I.Cmd> = [I.CExamine{"inbox"}, I.CSearch{[I.KAll{}]},
    I.CExamine{"Sent"}, I.CFetch{[7], [I.IUid{}, I.IHeaders{}]},
    I.CExamine{"Other"}, I.CSearch{[I.KAll{}]}]
  +pinned = Ops.plan_read_checked(cs,
    [Ops.ReadIdentity{"INBOX", 17}, Ops.ReadIdentity{"Sent", 99}])
  String.eq(I.script(pinned),
    "a1 EXAMINE \"inbox\"\r\n=EXPECT * OK [UIDVALIDITY 17]\r\na2 UID SEARCH ALL\r\n" ++
    "a3 EXAMINE \"Sent\"\r\n=EXPECT * OK [UIDVALIDITY 99]\r\n" ++
    "a4 UID FETCH 7 (UID BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE " ++
    "MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID LIST-UNSUBSCRIBE AUTO-SUBMITTED PRECEDENCE)])\r\n" ++
    "a5 EXAMINE \"Other\"\r\na6 UID SEARCH ALL\r\n") &&
    Bool.not(I.any_writes(pinned)) &&
    String.eq(I.script(Ops.plan_read_checked(cs, [])), I.script(cs))

def classify_expected(body: Bool) -> String:
  "a1 CAPABILITY\r\na2 LIST \"\" \"*\"\r\na3 EXAMINE \"Work\"\r\n" ++
  "=EXPECT * OK [UIDVALIDITY 88]\r\na4 UID FETCH 3,5 (UID FLAGS INTERNALDATE RFC822.SIZE " ++
  "BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO " ++
  "REFERENCES LIST-ID LIST-UNSUBSCRIBE AUTO-SUBMITTED PRECEDENCE)] BODYSTRUCTURE" ++
  Bool.pick(String, body, " BODY.PEEK[]<0.1000>", "") ++ ")\r\n"

def classify(+body: Bool) -> Bool:
  +pinned = Ops.plan_classify_checked("Work", [3, 5], body, 1000, Some{88})
  String.eq(I.script(pinned), classify_expected(body)) && Bool.not(I.any_writes(pinned)) &&
    String.eq(I.script(Ops.plan_classify_checked("Work", [3, 5], body, 1000, None{})),
      I.script(Ops.plan_classify("Work", [3, 5], body, 1000)))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(multi_folder()))
    IO.print(Bool.show(classify(False{})))
    IO.print(Bool.show(classify(True{})))

#|True
#|True
#|True
