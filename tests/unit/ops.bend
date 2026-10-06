# Operations and the IMAP command plans behind them: names, the read-only
# set, every plan's wire form, and the classifiers the laws are stated with.

import Base
import ../../src/imap.bend as I
import ../../src/ops.bend as Ops

# A script on one line: each CRLF but the last becomes " | ".
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

def wire(cs: List<&2, I.Cmd>) -> String:
  one_line(I.script(cs))

def flag(b: Bool) -> String:
  Bool.show(b)

def uid_strs(us: List<&2, U32>) -> List<&2, String>:
  match us:
    case Nil{}:
      []
    case Con{u, t}:
      U32.show(u) <> uid_strs(t)

def uids(us: List<&2, U32>) -> String:
  "[" ++ String.join(uid_strs(us), ",") ++ "]"

def maybe_uids(m: Maybe<&2, List<&2, U32>>) -> String:
  match m:
    case None{}:
      "none"
    case Some{us}:
      uids(us)

def maybe_op(m: Maybe<&2, Ops.Op>) -> String:
  match m:
    case None{}:
      "none"
    case Some{op}:
      Ops.name(op)

# One line per operation: its name, whether it is read-only, whether it is
# destructive, and whether its name maps back to it.
def op_lines(ops: List<&2, Ops.Op>) -> List<&2, String>:
  match ops:
    case Nil{}:
      []
    case Con{+op, t}:
      (Ops.name(op) ++ " ro=" ++ flag(Ops.is_read_only(op))
        ++ " destructive=" ++ flag(Ops.is_destructive(op))
        ++ " back=" ++ maybe_op(Ops.from_name(Ops.name(op)))) <> op_lines(t)

def mark(seen: Bool) -> List<&2, I.Cmd>:
  Ops.plan_mark("INBOX", [3, 4], seen, 77)

def flag_plan(colour: Maybe<&2, I.Colour>) -> List<&2, I.Cmd>:
  Ops.plan_flag("INBOX", [5], colour, 9)

def move(has_move: Bool, uidplus: Bool) -> List<&2, I.Cmd>:
  Ops.plan_move("INBOX", [1, 2], "Archive", has_move, uidplus, 42)

def delete(confirm: String, uidplus: Bool) -> List<&2, I.Cmd>:
  Ops.plan_delete("INBOX", [8], confirm, uidplus, 6)

def rename(moved: List<&2, String>) -> List<&2, I.Cmd>:
  Ops.plan_rename("Work", "Jobs", moved)

# The classifiers of one plan, on one line.
def classify(+cs: List<&2, I.Cmd>) -> String:
  "loses=" ++ flag(Ops.loses_mail(cs))
    ++ " expunged=" ++ maybe_uids(Ops.expunged(cs))
    ++ " copied=" ++ maybe_uids(Ops.copied(cs))
    ++ " marked=" ++ maybe_uids(Ops.marked_deleted(cs))
    ++ " pinned=" ++ flag(Ops.pinned(cs))
    ++ " pinned_or_empty=" ++ flag(Ops.pinned_or_empty(cs))
    ++ " pin=[" ++ Ops.pin_line_or(cs, "<empty>") ++ "]"
    ++ " uidplus=" ++ flag(Ops.checks_uidplus(cs))
    ++ " uidplus_or_empty=" ++ flag(Ops.checks_uidplus_or_empty(cs))
    ++ " only_flags=" ++ flag(Ops.only_flag_stores(Ops.mail_changes(cs)))
    ++ " mail=[" ++ wire(Ops.mail_changes(cs)) ++ "]"
    ++ " folders=[" ++ wire(Ops.mailbox_changes(cs)) ++ "]"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join(op_lines(Ops.all_ops()), "\n"))
    IO.print(String.join(Ops.read_only_names(Ops.all_ops()), ","))
    IO.print(maybe_op(Ops.from_name("mail_get")))
    IO.print(maybe_op(Ops.from_name("mail_forward")))
    IO.print(maybe_op(Ops.from_name("mail_gets")))
    IO.print(maybe_op(Ops.from_name("")))
    IO.print(String.join(Ops.read_only_names([Ops.OSend{}, Ops.OGetNew{}, Ops.OSearch{}]), ","))
    IO.print("[" ++ String.join(Ops.read_only_names([]), ",") ++ "]")
    IO.print("reads")
    IO.print(wire(Ops.plan_probe()))
    IO.print(wire(Ops.plan_preflight("INBOX")))
    IO.print(wire(Ops.plan_folders()))
    IO.print(wire(Ops.plan_folder_scan()))
    IO.print(wire(Ops.plan_roles()))
    IO.print(wire(Ops.plan_search("INBOX", [I.KFrom{"ann"}, I.KUnseen{}])))
    IO.print(wire(Ops.plan_search("Sent Messages", [])))
    IO.print(U32.show(Ops.max_uid()))
    IO.print(wire(Ops.plan_new("INBOX", 0)))
    IO.print(wire(Ops.plan_new("INBOX", 41)))
    IO.print(wire(Ops.plan_new("INBOX", 4294967294)))
    IO.print(wire(Ops.plan_new("INBOX", Ops.max_uid())))
    IO.print(wire(Ops.plan_new_if(True{}, "INBOX", 3)))
    IO.print(wire(Ops.plan_new_if(False{}, "INBOX", 3)))
    IO.print(wire(Ops.plan_headers("INBOX", [1, 2, 3])))
    IO.print(wire(Ops.plan_get("INBOX", 7, 1000)))
    IO.print("changes")
    IO.print(wire(mark(True{})))
    IO.print(wire(mark(False{})))
    IO.print(wire(flag_plan(None{})))
    IO.print(wire(flag_plan(Some{I.ColRed{}})))
    IO.print(wire(flag_plan(Some{I.ColGreen{}})))
    IO.print(wire(flag_plan(Some{I.ColGrey{}})))
    IO.print(wire(Ops.plan_flag_bits("INBOX", [5, 6], I.Bits{True{}, False{}, True{}}, 9)))
    IO.print(wire(Ops.plan_unflag("INBOX", [5, 6], 9)))
    IO.print(wire(move(True{}, True{})))
    IO.print(wire(move(True{}, False{})))
    IO.print(wire(move(False{}, True{})))
    IO.print("[" ++ wire(move(False{}, False{})) ++ "]")
    IO.print(wire(Ops.plan_trash("INBOX", [1], "Deleted Messages", True{}, False{}, 42)))
    IO.print(wire(Ops.plan_trash("INBOX", [1], "Deleted Messages", False{}, True{}, 42)))
    IO.print(wire(Ops.plan_label("INBOX", [1], "Receipts", True{}, True{}, 42)))
    IO.print(wire(Ops.plan_label("INBOX", [1], "Receipts", False{}, True{}, 42)))
    IO.print(Ops.confirm_word())
    IO.print(wire(delete("permanently-delete", True{})))
    IO.print("[" ++ wire(delete("permanently-delete", False{})) ++ "]")
    IO.print("[" ++ wire(delete("permanently-delete ", True{})) ++ "]")
    IO.print("[" ++ wire(delete("yes", True{})) ++ "]")
    IO.print("[" ++ wire(delete("", True{})) ++ "]")
    IO.print("[" ++ wire(Ops.plan_delete_if(False{}, "INBOX", [8], True{}, 6)) ++ "]")
    IO.print(wire(Ops.plan_draft("Drafts", "Subject: hi\r\n\r\nbody")))
    IO.print("folders")
    IO.print(wire(Ops.plan_create("Work/2026")))
    IO.print(Ops.renamed_to("Work", "Jobs", "Work"))
    IO.print(Ops.renamed_to("Work", "Jobs", "Work/Old/2025"))
    IO.print(wire(rename([])))
    IO.print(wire(rename(["Work", "Work/Old"])))
    IO.print(wire(Ops.subscribe_moved("Work", "Jobs", ["Work/A"], [I.CLsub{}])))
    IO.print(wire(Ops.unsubscribe_old(["Work", "Work/A"])))
    IO.print("classifiers")
    IO.print(classify([]))
    IO.print(classify(Ops.plan_probe()))
    IO.print(classify(Ops.plan_get("INBOX", 7, 1000)))
    IO.print(classify(mark(True{})))
    IO.print(classify(flag_plan(Some{I.ColBlue{}})))
    IO.print(classify(Ops.plan_unflag("INBOX", [5], 9)))
    IO.print(classify(move(True{}, False{})))
    IO.print(classify(move(False{}, True{})))
    IO.print(classify(delete("permanently-delete", True{})))
    IO.print(classify(Ops.plan_draft("Drafts", "x")))
    IO.print(classify(Ops.plan_create("New")))
    IO.print(classify(rename(["Work"])))
    IO.print(classify([I.CExpunge{[1]}, I.CCopy{[1], "A"}]))
    IO.print(classify([I.CStore{[1], True{}, I.FDeleted{}}, I.CExpunge{[2]}]))
    IO.print(classify([I.CStore{[1], False{}, I.FDeleted{}}, I.CCopy{[3], "A"}]))
    IO.print(classify([I.CSelect{"X"}, I.CExpect{"* OK [UIDVALIDITYX 1]"}]))
    IO.print(classify([I.CCapability{}, I.CExpectWord{"MOVE"}, I.CSelect{"X"}, I.CExpect{"e"}]))
    IO.print(classify([I.CCapability{}, I.CExpectWord{"UIDPLUS"}]))
    IO.print(classify([I.CExamine{"X"}, I.CExpect{"* OK [UIDVALIDITY 1]"}]))
    IO.print("flag stores")
    IO.print(flag(Ops.only_flag_stores([])))
    IO.print(flag(Ops.only_flag_stores([I.CStore{[1], True{}, I.FColourBit2{}}])))
    IO.print(flag(Ops.only_flag_stores([I.CStore{[1], True{}, I.FSeen{}}])))
    IO.print(flag(Ops.only_flag_stores([I.CStore{[1], True{}, I.FAnswered{}}])))
    IO.print(flag(Ops.only_flag_stores([I.CStore{[1], True{}, I.FFlagged{}}, I.CMove{[1], "A"}])))
    IO.print("prefixes")
    IO.print(flag(Ops.has_prefix("", "")))
    IO.print(flag(Ops.has_prefix("", "abc")))
    IO.print(flag(Ops.has_prefix("ab", "abc")))
    IO.print(flag(Ops.has_prefix("abc", "abc")))
    IO.print(flag(Ops.has_prefix("abcd", "abc")))
    IO.print(flag(Ops.has_prefix("b", "abc")))
    IO.print(flag(Ops.has_prefix("A", "abc")))
    IO.print("peek")
    IO.print(flag(Ops.peek_safe("UID")))
    IO.print(flag(Ops.peek_safe("FLAGS")))
    IO.print(flag(Ops.peek_safe("INTERNALDATE")))
    IO.print(flag(Ops.peek_safe("RFC822.SIZE")))
    IO.print(flag(Ops.peek_safe("BODY.PEEK[]<0.10>")))
    IO.print(flag(Ops.peek_safe("BODY.PEEK[")))
    IO.print(flag(Ops.peek_safe("BODY[]")))
    IO.print(flag(Ops.peek_safe("BODY.PEEK")))
    IO.print(flag(Ops.peek_safe("RFC822")))
    IO.print(flag(Ops.peek_safe("RFC822.TEXT")))
    IO.print(flag(Ops.peek_safe("uid")))
    IO.print(flag(Ops.peek_safe("UID ")))
    IO.print(flag(Ops.peek_safe("")))

#|mail_probe ro=True destructive=False back=mail_probe
#|mail_list_folders ro=True destructive=False back=mail_list_folders
#|mail_search ro=True destructive=False back=mail_search
#|mail_get ro=True destructive=False back=mail_get
#|mail_get_new ro=True destructive=False back=mail_get_new
#|mail_mark_read ro=False destructive=False back=mail_mark_read
#|mail_mark_unread ro=False destructive=False back=mail_mark_unread
#|mail_flag ro=False destructive=False back=mail_flag
#|mail_unflag ro=False destructive=False back=mail_unflag
#|mail_move ro=False destructive=False back=mail_move
#|mail_label ro=False destructive=False back=mail_label
#|mail_trash ro=False destructive=False back=mail_trash
#|mail_delete ro=False destructive=True back=mail_delete
#|mail_create_folder ro=False destructive=False back=mail_create_folder
#|mail_rename_folder ro=False destructive=False back=mail_rename_folder
#|mail_save_draft ro=False destructive=False back=mail_save_draft
#|mail_send ro=False destructive=False back=mail_send
#|mail_reply ro=False destructive=False back=mail_reply
#|mail_forward ro=False destructive=False back=mail_forward
#|mail_probe,mail_list_folders,mail_search,mail_get,mail_get_new
#|mail_get
#|mail_forward
#|none
#|none
#|mail_get_new,mail_search
#|[]
#|reads
#|a1 CAPABILITY | a2 LIST "" "*"
#|a1 CAPABILITY | a2 LIST "" "*" | a3 EXAMINE "INBOX"
#|a1 CAPABILITY | a2 LIST "" "*"
#|a1 CAPABILITY | a2 LIST "" "*" | a3 LSUB "" "*"
#|a1 LIST "" "*" RETURN (SPECIAL-USE)
#|a1 EXAMINE "INBOX" | a2 UID SEARCH FROM "ann" UNSEEN
#|a1 EXAMINE "Sent Messages" | a2 UID SEARCH ALL
#|4294967295
#|a1 EXAMINE "INBOX" | a2 UID SEARCH UID 1:*
#|a1 EXAMINE "INBOX" | a2 UID SEARCH UID 42:*
#|a1 EXAMINE "INBOX" | a2 UID SEARCH UID 4294967295:*
#|a1 EXAMINE "INBOX"
#|a1 EXAMINE "INBOX"
#|a1 EXAMINE "INBOX" | a2 UID SEARCH UID 4:*
#|a1 EXAMINE "INBOX" | a2 UID FETCH 1,2,3 (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES)])
#|a1 EXAMINE "INBOX" | a2 UID FETCH 7 (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[]<0.1000>)
#|changes
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 77] | a2 UID SEARCH UID 3,4 | a3 UID STORE 3,4 +FLAGS.SILENT (\Seen)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 77] | a2 UID SEARCH UID 3,4 | a3 UID STORE 3,4 -FLAGS.SILENT (\Seen)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 9] | a2 UID SEARCH UID 5 | a3 UID STORE 5 +FLAGS.SILENT (\Flagged) | a4 UID FETCH 5 (UID FLAGS)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 9] | a2 UID SEARCH UID 5 | a3 UID STORE 5 +FLAGS.SILENT (\Flagged) | a4 UID STORE 5 -FLAGS.SILENT ($MailFlagBit0) | a5 UID STORE 5 -FLAGS.SILENT ($MailFlagBit1) | a6 UID STORE 5 -FLAGS.SILENT ($MailFlagBit2) | a7 UID FETCH 5 (UID FLAGS)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 9] | a2 UID SEARCH UID 5 | a3 UID STORE 5 +FLAGS.SILENT (\Flagged) | a4 UID STORE 5 +FLAGS.SILENT ($MailFlagBit0) | a5 UID STORE 5 +FLAGS.SILENT ($MailFlagBit1) | a6 UID STORE 5 -FLAGS.SILENT ($MailFlagBit2) | a7 UID FETCH 5 (UID FLAGS)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 9] | a2 UID SEARCH UID 5 | a3 UID STORE 5 +FLAGS.SILENT (\Flagged) | a4 UID STORE 5 -FLAGS.SILENT ($MailFlagBit0) | a5 UID STORE 5 +FLAGS.SILENT ($MailFlagBit1) | a6 UID STORE 5 +FLAGS.SILENT ($MailFlagBit2) | a7 UID FETCH 5 (UID FLAGS)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 9] | a2 UID SEARCH UID 5,6 | a3 UID STORE 5,6 +FLAGS.SILENT (\Flagged) | a4 UID STORE 5,6 +FLAGS.SILENT ($MailFlagBit0) | a5 UID STORE 5,6 -FLAGS.SILENT ($MailFlagBit1) | a6 UID STORE 5,6 +FLAGS.SILENT ($MailFlagBit2) | a7 UID FETCH 5,6 (UID FLAGS)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 9] | a2 UID SEARCH UID 5,6 | a3 UID STORE 5,6 -FLAGS.SILENT (\Flagged) | a4 UID STORE 5,6 -FLAGS.SILENT ($MailFlagBit0) | a5 UID STORE 5,6 -FLAGS.SILENT ($MailFlagBit1) | a6 UID STORE 5,6 -FLAGS.SILENT ($MailFlagBit2) | a7 UID FETCH 5,6 (UID FLAGS)
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a2 UID SEARCH UID 1,2 | a3 UID MOVE 1,2 "Archive"
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a2 UID SEARCH UID 1,2 | a3 UID MOVE 1,2 "Archive"
#|a1 CAPABILITY | =EXPECT-WORD UIDPLUS | a2 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a3 UID SEARCH UID 1,2 | a4 UID COPY 1,2 "Archive" | a5 UID STORE 1,2 +FLAGS.SILENT (\Deleted) | a6 UID EXPUNGE 1,2
#|[]
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a2 UID SEARCH UID 1 | a3 UID MOVE 1 "Deleted Messages"
#|a1 CAPABILITY | =EXPECT-WORD UIDPLUS | a2 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a3 UID SEARCH UID 1 | a4 UID COPY 1 "Deleted Messages" | a5 UID STORE 1 +FLAGS.SILENT (\Deleted) | a6 UID EXPUNGE 1
#|a1 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a2 UID SEARCH UID 1 | a3 UID MOVE 1 "Receipts"
#|a1 CAPABILITY | =EXPECT-WORD UIDPLUS | a2 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 42] | a3 UID SEARCH UID 1 | a4 UID COPY 1 "Receipts" | a5 UID STORE 1 +FLAGS.SILENT (\Deleted) | a6 UID EXPUNGE 1
#|permanently-delete
#|a1 CAPABILITY | =EXPECT-WORD UIDPLUS | a2 SELECT "INBOX" | =EXPECT * OK [UIDVALIDITY 6] | a3 UID SEARCH UID 8 | a4 UID STORE 8 +FLAGS.SILENT (\Deleted) | a5 UID EXPUNGE 8
#|[]
#|[]
#|[]
#|[]
#|[]
#|a1 APPEND "Drafts" (\Draft \Seen) {19} | Subject: hi |  | body
#|folders
#|a1 CAPABILITY | a2 CREATE "Work/2026" | a3 SUBSCRIBE "Work/2026"
#|Jobs
#|Jobs/Old/2025
#|a1 CAPABILITY | a2 RENAME "Work" "Jobs"
#|a1 CAPABILITY | a2 RENAME "Work" "Jobs" | a3 SUBSCRIBE "Jobs" | a4 SUBSCRIBE "Jobs/Old" | a5 UNSUBSCRIBE "Work" | a6 UNSUBSCRIBE "Work/Old"
#|a1 SUBSCRIBE "Jobs/A" | a2 LSUB "" "*"
#|a1 UNSUBSCRIBE "Work" | a2 UNSUBSCRIBE "Work/A"
#|classifiers
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=True pin=[<empty>] uidplus=False uidplus_or_empty=True only_flags=True mail=[] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=True pinned_or_empty=True pin=[* OK [UIDVALIDITY 77]] uidplus=False uidplus_or_empty=False only_flags=False mail=[a1 UID STORE 3,4 +FLAGS.SILENT (\Seen)] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=True pinned_or_empty=True pin=[* OK [UIDVALIDITY 9]] uidplus=False uidplus_or_empty=False only_flags=True mail=[a1 UID STORE 5 +FLAGS.SILENT (\Flagged) | a2 UID STORE 5 -FLAGS.SILENT ($MailFlagBit0) | a3 UID STORE 5 -FLAGS.SILENT ($MailFlagBit1) | a4 UID STORE 5 +FLAGS.SILENT ($MailFlagBit2)] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=True pinned_or_empty=True pin=[* OK [UIDVALIDITY 9]] uidplus=False uidplus_or_empty=False only_flags=True mail=[a1 UID STORE 5 -FLAGS.SILENT (\Flagged) | a2 UID STORE 5 -FLAGS.SILENT ($MailFlagBit0) | a3 UID STORE 5 -FLAGS.SILENT ($MailFlagBit1) | a4 UID STORE 5 -FLAGS.SILENT ($MailFlagBit2)] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=True pinned_or_empty=True pin=[* OK [UIDVALIDITY 42]] uidplus=False uidplus_or_empty=False only_flags=False mail=[a1 UID MOVE 1,2 "Archive"] folders=[]
#|loses=False expunged=[1,2] copied=[1,2] marked=[1,2] pinned=True pinned_or_empty=True pin=[* OK [UIDVALIDITY 42]] uidplus=True uidplus_or_empty=True only_flags=False mail=[a1 UID COPY 1,2 "Archive" | a2 UID STORE 1,2 +FLAGS.SILENT (\Deleted) | a3 UID EXPUNGE 1,2] folders=[]
#|loses=True expunged=[8] copied=none marked=[8] pinned=True pinned_or_empty=True pin=[* OK [UIDVALIDITY 6]] uidplus=True uidplus_or_empty=True only_flags=False mail=[a1 UID STORE 8 +FLAGS.SILENT (\Deleted) | a2 UID EXPUNGE 8] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=False mail=[a1 APPEND "Drafts" (\Draft \Seen) {1} | x] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[a1 CREATE "New" | a2 SUBSCRIBE "New"]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[a1 RENAME "Work" "Jobs" | a2 SUBSCRIBE "Jobs" | a3 UNSUBSCRIBE "Work"]
#|loses=True expunged=[1] copied=[1] marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=False mail=[a1 UID EXPUNGE 1 | a2 UID COPY 1 "A"] folders=[]
#|loses=True expunged=[2] copied=none marked=[1] pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=False mail=[a1 UID STORE 1 +FLAGS.SILENT (\Deleted) | a2 UID EXPUNGE 2] folders=[]
#|loses=False expunged=none copied=[3] marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=False mail=[a1 UID STORE 1 -FLAGS.SILENT (\Deleted) | a2 UID COPY 3 "A"] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[* OK [UIDVALIDITYX 1]] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[e] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=True uidplus_or_empty=True only_flags=True mail=[] folders=[]
#|loses=False expunged=none copied=none marked=none pinned=False pinned_or_empty=False pin=[] uidplus=False uidplus_or_empty=False only_flags=True mail=[] folders=[]
#|flag stores
#|True
#|True
#|False
#|False
#|False
#|prefixes
#|True
#|True
#|True
#|True
#|False
#|False
#|False
#|peek
#|True
#|True
#|True
#|True
#|True
#|True
#|False
#|False
#|False
#|False
#|False
#|False
#|False
