# IMAP command rendering and transcript parsing on a synthetic transcript.
import Base
import ../../src/imap.bend as I

def show_line_endings(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ show_line_endings(t)
    case SCon{'\n', t}:
      "\\n" ++ show_line_endings(t)
    case SCon{c, t}:
      SCon{c, show_line_endings(t)}

def transcript() -> String:
  String.concat([
    "* OK [CAPABILITY IMAP4rev1] ready\r\n",
    "L OK logged in\r\n",
    "* CAPABILITY IMAP4rev1 MOVE UIDPLUS idle\r\n",
    "a1 OK done\r\n",
    "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n",
    "* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Messages\"\r\n",
    "* LIST (\\HasChildren) \"/\" Work\r\n",
    "* LIST (\\HasNoChildren) \"/\" \"&ZeVnLA-\"\r\n",
    "a2 OK list done\r\n",
    "* 3 EXISTS\r\n",
    "* OK [UIDVALIDITY 1700000001] ok\r\n",
    "* OK [UIDNEXT 9] next\r\n",
    "a3 OK [READ-ONLY] examined\r\n",
    "* SEARCH 2 5 7\r\n",
    "a4 OK search\r\n",
    "* 1 FETCH (UID 5 FLAGS (\\Seen \\Flagged) INTERNALDATE \"26-Sep-2026 10:00:00 +0000\" RFC822.SIZE 42 BODY[]<0> {22}\r\n",
    "a5 OK spoof\r\n* BYE x\r\n",
    ")\r\n",
    "a5 OK fetched\r\n",
    "a6 NO [TRYCREATE] no such mailbox\r\n",
    "Z OK bye\r\n"])

def show_folders(folders: List<&2, I.Folder>) -> String:
  match folders:
    case Nil{}:
      ""
    case Con{I.Folder{name, delimiter, attrs}, rest}:
      name ++ "|" ++ delimiter ++ "|" ++ String.join(attrs, ",") ++ ";" ++ show_folders(rest)

def show_messages(messages: List<&2, I.Msg>) -> String:
  match messages:
    case Nil{}:
      ""
    case Con{I.Msg{uid, flags, date, size, headers, body}, rest}:
      U32.show(uid) ++ " " ++ String.join(flags, ",") ++ " " ++ date ++ " " ++ U32.show(size) ++ " [" ++ show_line_endings(body) ++ "];" ++ show_messages(rest)

def show_uids(uids: List<&2, U32>) -> String:
  match uids:
    case Nil{}:
      ""
    case Con{uid, rest}:
      U32.show(uid) ++ " " ++ show_uids(rest)

# The number of tagged commands and the tag of the first COPY.
def show_tags(+cs: List<&2, I.Cmd>) -> String:
  U32.show(I.tag_count(cs)) ++ " " ++ U32.show(I.copy_tag(cs, 1))

# Bit0 Bit1 Bit2 as 0/1.
def show_bits(b: I.Bits) -> String:
  I.Bits{b0, b1, b2} = b
  Bool.pick(String, b0, "1", "0") ++ Bool.pick(String, b1, "1", "0") ++
    Bool.pick(String, b2, "1", "0")

def named_or_bad(m: Maybe<&2, I.Colour>) -> String:
  match m:
    case Some{c}:
      I.colour_name(c)
    case None{}:
      "bad"

# Each colour as name=bits/name found again from the name; "bad" is a name
# that is not a colour.
def show_colours(cs: List<&2, I.Colour>) -> String:
  match cs:
    case Nil{}:
      ""
    case Con{+c, rest}:
      +n = I.colour_name(c)
      n ++ "=" ++ show_bits(I.colour_bits(c)) ++ "/" ++
        named_or_bad(I.colour_from_name(n)) ++ " " ++ show_colours(rest)

def show_permanent(m: Maybe<&2, List<&2, String>>) -> String:
  match m:
    case Some{fs}:
      String.join(fs, ",")
    case None{}:
      "none"

# A flag change's session: SELECT, a STORE answered with a FETCH, then the
# trailing FETCH with a sequence-number-only update, the real one, and an
# update without FLAGS.
def flag_transcript() -> String:
  String.concat([
    "* OK [CAPABILITY IMAP4rev1] ready\r\n",
    "* FLAGS (\\Flagged \\Seen)\r\n",
    "* OK [PERMANENTFLAGS (\\Seen \\Flagged \\*)] ok\r\n",
    "a1 OK [READ-WRITE] selected\r\n",
    "* 1 FETCH (UID 3 FLAGS (\\Seen))\r\n",
    "a2 OK stored\r\n",
    "* 1 FETCH (FLAGS (\\Flagged))\r\n",
    "* 1 FETCH (UID 3 FLAGS (\\Flagged $MailFlagBit2))\r\n",
    "* 1 FETCH (UID 3 MODSEQ (7))\r\n",
    "a3 OK fetched\r\n",
    "* BYE bye\r\n",
    "Z OK bye\r\n"])

# Reply counts of commands 1, 3 and a never-answered 4 (the BYE); the flags
# each FETCH with FLAGS in command 3's replies carries; PERMANENTFLAGS from
# command 1's replies and from command 2's (none).
def check_flag_replies(+lines: List<&2, I.RLine>) -> IO(Unit):
  do IO<Unit>:
    IO.print(Nat.show(List.length(&2, I.RLine, I.replies(lines, 1))) ++ " " ++
      Nat.show(List.length(&2, I.RLine, I.replies(lines, 3))) ++ " " ++
      Nat.show(List.length(&2, I.RLine, I.replies(lines, 4))))
    IO.print(show_messages(I.flag_fetches(I.replies(lines, 3))))
    IO.print(show_permanent(I.permanent_flags(I.replies(lines, 1))) ++ " " ++
      show_permanent(I.permanent_flags(I.replies(lines, 2))))

def check_transcript(+lines: List<&2, I.RLine>) -> IO(Unit):
  do IO<Unit>:
    IO.print(Nat.show(List.length(&2, I.RLine, lines)))
    IO.print(String.join(I.caps(lines), " "))
    IO.print(Bool.show(I.has_cap(I.caps(lines), "IDLE")))
    IO.print(show_folders(I.folders(lines)))
    IO.print(Maybe.default(&2, String, I.special(I.folders(lines), "\\Trash"), "-"))
    IO.print(Maybe.default(&2, String, I.named(I.folders(lines), "inbox"), "-") ++ " " ++ Maybe.default(&2, String, I.named(I.folders(lines), "deleted messages"), "-") ++ " " ++ Maybe.default(&2, String, I.named(I.folders(lines), "Work"), "-"))
    IO.print(U32.show(Maybe.default(&2, U32, I.ok_code(lines, "UIDVALIDITY"), 0)) ++ " " ++ U32.show(Maybe.default(&2, U32, I.exists(lines), 0)))
    IO.print(show_uids(I.search_uids(lines)))
    IO.print(show_messages(I.fetched(lines)))
    IO.print(I.status(lines, 5) ++ " " ++ I.status(lines, 6) ++ " [" ++ I.status(lines, 7) ++ "]")
    IO.print(I.first_failure(lines))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_line_endings(I.script([I.CCapability{}, I.CExamine{"Café"}, I.CSearch{[I.KFrom{"josé"}, I.KUnseen{}]}, I.CFetch{[5, 7], [I.IUid{}, I.IFull{1000}]}])))
    IO.print(show_line_endings(I.script([I.CStore{[3], True{}, I.FSeen{}}, I.CMove{[3], "Deleted Messages"}, I.CExpunge{[1, 2]}, I.CAppend{"Drafts", [I.FDraft{}, I.FSeen{}], "Hi\r\n"}, I.CSearch{[I.KSubject{"a\"b"}, I.KUidFrom{9}]}])))
    IO.print(I.mutf7_encode("日本 & Co") ++ " " ++ I.mutf7_decode(I.mutf7_encode("日本 & Co")) ++ " " ++ I.mutf7_decode("&ZeVnLA-") ++ " " ++ I.mutf7_encode("😀"))
    IO.print(Maybe.default(&2, String, I.imap_date("2026-02-01"), "bad") ++ " " ++ Maybe.default(&2, String, I.imap_date("2026-13-01"), "bad"))
    IO.print(show_line_endings(I.script([I.CSelect{"INBOX"}, I.CExpect{I.uidv_line(7)}, I.CSearch{[I.KUids{[3, 4]}]}, I.CStore{[3, 4], True{}, I.FSeen{}}])))
    IO.print(show_line_endings(I.script([I.CCreate{"Reçus 日本"}, I.CRename{"Work", "Projects & Co"}, I.CSubscribe{"Projects & Co"}, I.CUnsubscribe{"Work"}, I.CSearch{[I.KHeader{"Message-ID", "<a@b>"}, I.KUndeleted{}]}])))
    IO.print(show_tags([I.CCapability{}, I.CExpectWord{"UIDPLUS"}, I.CSelect{"INBOX"}, I.CExpect{I.uidv_line(7)}, I.CSearch{[I.KUids{[3]}]}, I.CCopy{[3], "Work"}, I.CStore{[3], True{}, I.FDeleted{}}, I.CExpunge{[3]}]) ++ " " ++ show_tags([I.CExamine{"INBOX"}, I.CSearch{[I.KAll{}]}]))
    IO.print(show_line_endings(I.script([
      I.CStore{[3], True{}, I.FFlagged{}},
      I.CStore{[3], True{}, I.FColourBit0{}},
      I.CStore{[3], False{}, I.FColourBit1{}},
      I.CStore{[3], False{}, I.FColourBit2{}},
      I.CFetch{[3], [I.IUid{}, I.IFlags{}]}
    ])))
    IO.print(show_colours(I.colours()) ++ named_or_bad(I.colour_from_name("pink")) ++ " " ++
      String.join(I.colour_names(), ","))
    check_flag_replies(I.frame(flag_transcript()))
    check_transcript(I.frame(transcript()))
    IO.print(Nat.show(List.length(&2, I.RLine, I.frame("a7 OK text {3}\r\nZ OK bye\r\n"))) ++ " " ++ Maybe.default(&2, String, I.imap_date("a\r\nb-02-01"), "bad") ++ " " ++ Maybe.default(&2, String, I.imap_date("{99}-02-01"), "bad"))

#|a1 CAPABILITY\r\na2 EXAMINE "Caf&AOk-"\r\na3 UID SEARCH CHARSET UTF-8 FROM {5}\r\njosé UNSEEN\r\na4 UID FETCH 5,7 (UID BODY.PEEK[]<0.1000>)\r\n
#|a1 UID STORE 3 +FLAGS.SILENT (\Seen)\r\na2 UID MOVE 3 "Deleted Messages"\r\na3 UID EXPUNGE 1,2\r\na4 APPEND "Drafts" (\Draft \Seen) {4}\r\nHi\r\n\r\na5 UID SEARCH SUBJECT "a\"b" UID 9:*\r\n
#|&ZeVnLA- &- Co 日本 & Co 日本 &2D3eAA-
#|1-Feb-2026 bad
#|a1 SELECT "INBOX"\r\n=EXPECT * OK [UIDVALIDITY 7]\r\na2 UID SEARCH UID 3,4\r\na3 UID STORE 3,4 +FLAGS.SILENT (\Seen)\r\n
#|a1 CREATE "Re&AOc-us &ZeVnLA-"\r\na2 RENAME "Work" "Projects &- Co"\r\na3 SUBSCRIBE "Projects &- Co"\r\na4 UNSUBSCRIBE "Work"\r\na5 UID SEARCH HEADER "Message-ID" "<a@b>" UNDELETED\r\n
#|6 4 2 0
#|a1 UID STORE 3 +FLAGS.SILENT (\Flagged)\r\na2 UID STORE 3 +FLAGS.SILENT ($MailFlagBit0)\r\na3 UID STORE 3 -FLAGS.SILENT ($MailFlagBit1)\r\na4 UID STORE 3 -FLAGS.SILENT ($MailFlagBit2)\r\na5 UID FETCH 3 (UID FLAGS)\r\n
#|red=000/red orange=100/orange yellow=010/yellow green=110/green blue=001/blue purple=101/purple grey=011/grey bad red,orange,yellow,green,blue,purple,grey
#|3 3 1
#|0 \Flagged  0 [];3 \Flagged,$MailFlagBit2  0 [];
#|\Seen,\Flagged,\* none
#|19
#|IMAP4REV1 MOVE UIDPLUS IDLE
#|True
#|INBOX|/|\HasNoChildren;Deleted Messages|/|\HasNoChildren,\Trash;Work|/|\HasChildren;日本|/|\HasNoChildren;
#|Deleted Messages
#|INBOX - Work
#|1700000001 3
#|2 5 7 
#|5 \Seen,\Flagged 26-Sep-2026 10:00:00 +0000 42 [a5 OK spoof\r\n* BYE x\r\n];
#|OK NO []
#|a6 NO [TRYCREATE] no such mailbox
#|2 bad bad
