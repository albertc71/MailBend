# IMAP command rendering and transcript parsing on a synthetic transcript.
import Base
import ../../src/codec.bend as C
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

# Effects
# -------

def effect_name(e: I.Effect) -> String:
  match e:
    case I.ENone{}:
      "none"
    case I.ESelect{}:
      "select"
    case I.EMail{}:
      "mail"
    case I.ECopy{}:
      "copy"
    case I.EExpunge{}:
      "expunge"
    case I.EFolder{}:
      "folder"

def bit(b: Bool) -> String:
  Bool.pick(String, b, "1", "0")

# One of every command, plus the STOREs that do and do not mark \Deleted.
def every_cmd() -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}, I.CListRoles{}, I.CLsub{}, I.CExamine{"A"},
    I.CSelect{"A"}, I.CSearch{[]}, I.CFetch{[1], [I.IUid{}]},
    I.CStore{[1], True{}, I.FDeleted{}}, I.CStore{[1], False{}, I.FDeleted{}},
    I.CStore{[1], True{}, I.FSeen{}}, I.CCopy{[1], "B"}, I.CMove{[1], "B"},
    I.CExpunge{[1]}, I.CCreate{"A"}, I.CRename{"A", "B"}, I.CSubscribe{"A"},
    I.CUnsubscribe{"A"}, I.CAppend{"A", [], "m"}, I.CExpect{"e"},
    I.CExpectWord{"W"}]

# Per command: its effect, then writes, changes_mail, changes_mailbox,
# destroys_mail, copies_mail, expunges, marks_deleted and is_expect as 0/1.
def show_effects(cs: List<&2, I.Cmd>) -> String:
  match cs:
    case Nil{}:
      ""
    case Con{+c, rest}:
      +e = I.effect(c)
      effect_name(e) ++ ":" ++ bit(I.writes(e)) ++ bit(I.changes_mail(e)) ++
        bit(I.changes_mailbox(e)) ++ bit(I.destroys_mail(e)) ++
        bit(I.copies_mail(e)) ++ bit(I.expunges(c)) ++ bit(I.marks_deleted(c)) ++
        bit(I.is_expect(c)) ++ ";" ++ show_effects(rest)

# any_writes, any_expunges and any_marks_deleted as 0/1.
def show_any(+cs: List<&2, I.Cmd>) -> String:
  bit(I.any_writes(cs)) ++ bit(I.any_expunges(cs)) ++ bit(I.any_marks_deleted(cs))

def check_effects() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_effects(every_cmd()))
    IO.print(show_any([]) ++ " " ++
      show_any([I.CExamine{"A"}, I.CSearch{[]}, I.CExpect{"e"}]) ++ " " ++
      show_any([I.CExamine{"A"}, I.CCreate{"B"}]) ++ " " ++
      show_any([I.CStore{[1], True{}, I.FDeleted{}}, I.CExpunge{[1]}]) ++ " " ++
      show_any(every_cmd()))

# Rendering
# ---------

def show_items(xs: List<&2, I.Item>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{i, rest}:
      I.item_str(i) ++ ";" ++ show_items(rest)

def every_flag() -> List<&2, I.Flag>:
  [I.FSeen{}, I.FDeleted{}, I.FDraft{}, I.FFlagged{}, I.FAnswered{},
    I.FColourBit0{}, I.FColourBit1{}, I.FColourBit2{}]

def show_flag_names(fs: List<&2, I.Flag>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{f, rest}:
      I.flag_name(f) ++ ";" ++ show_flag_names(rest)

def check_rendering() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_line_endings(I.script([I.CList{}, I.CListRoles{}, I.CLsub{},
      I.CExpectWord{"MOVE"}, I.CCopy{[1, 2, 3], "Work"},
      I.CSearch{[I.KAll{}, I.KTo{"a b"}, I.KCc{"c"}, I.KBody{"d\\e"}, I.KText{"t"},
        I.KSince{"1-Feb-2026"}, I.KBefore{"2-Feb-2026"}, I.KSeen{}, I.KFlagged{},
        I.KUnflagged{}]},
      I.CSearch{[]}, I.CSearch{[I.KHeader{"X-Tag", "Ünï"}]},
      I.CFetch{[], [I.IFlags{}]}, I.CAppend{"Sent", [], ""}])))
    IO.print(show_items([I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{},
      I.IHeaders{}, I.IFull{0}]))
    IO.print(show_flag_names(every_flag()))
    IO.print(I.cmd_str(I.CExpect{"* OK [UIDVALIDITY 7]"}) ++ "|" ++
      I.cmd_str(I.CExpectWord{"UIDPLUS"}) ++ "|" ++ I.cmd_str(I.CExamine{"Café"}))
    IO.print(show_tags([]) ++ " " ++ show_tags([I.CExpect{"e"}, I.CCopy{[1], "B"}]) ++
      " " ++ U32.show(I.unsubscribe_count([I.CUnsubscribe{"A"}, I.CSubscribe{"B"},
        I.CUnsubscribe{"C"}])) ++ " " ++ U32.show(I.unsubscribe_count([])))

# Mailbox names and dates
# -----------------------

def show_dates(isos: List<&2, String>) -> String:
  match isos:
    case Nil{}:
      ""
    case Con{iso, rest}:
      Maybe.default(&2, String, I.imap_date(iso), "bad") ++ ";" ++ show_dates(rest)

def check_names_and_dates() -> IO(Unit):
  do IO<Unit>:
    IO.print(I.mutf7_encode("&") ++ " " ++ I.mutf7_encode("~ a") ++ " " ++
      I.mutf7_encode("a日b&") ++ " " ++ I.mutf7_encode("\t") ++ " [" ++
      I.mutf7_encode("") ++ "]")
    IO.print(I.mutf7_decode("&-") ++ "|" ++ I.mutf7_decode("a&ZeV") ++ "|" ++
      I.mutf7_decode("&2D3eAA-") ++ "|" ++ I.mutf7_decode("&2D0-") ++ "|" ++
      I.mutf7_decode("&3gA-") ++ "|" ++ I.mutf7_decode("&2D0AQQ-") ++ "|" ++
      I.mutf7_decode("&AE-") ++ "|" ++ I.mutf7_decode("Inbox-") ++ "|" ++
      I.mutf7_decode(I.mutf7_encode("😀 x")))
    IO.print(show_dates(["2026-2-1", "2026-12-31", "2026-02-09", "2026-00-10",
      "2026-13-10", "2026-01-00", "2026-01-32", "26-01-01", "20x6-01-01",
      "2026-01", "2026-01-01-01", "", "2026-01-1x", "02026-1-1"]))

# Framing
# -------

def show_char(+c: Char) -> String:
  Bool.pick(String, Char.is_eq(c, C.chr(57344)), "<L>",
    show_line_endings(SCon{c, SNil{}}))

def show_text(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      show_char(c) ++ show_text(t)

# Each line as text{count:literal|literal};
def show_rlines(lines: List<&2, I.RLine>) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{I.RLine{text, +lits}, rest}:
      show_text(text) ++ "{" ++ Nat.show(List.length(&2, String, lits)) ++ ":" ++
        show_text(String.join(lits, "|")) ++ "};" ++ show_rlines(rest)

def check_framing() -> IO(Unit):
  do IO<Unit>:
    IO.print(show_rlines(I.frame("* X {3}\r\nabc\r\n* Y {0}\r\n Z\r\n")))
    IO.print(show_rlines(I.frame("* A {}\r\n* B {1a}\r\n* C {a1}\r\n* D 12}\r\n")))
    IO.print(show_rlines(I.frame("a1 OK {3}\r\nabc\r\nx* {2}\r\nab\r\n")))
    IO.print(show_rlines(I.frame("* E {02}\r\nab {1}\r\n\n)\r\n* F\nG\r\n* tail")))
    IO.print(show_rlines(I.frame("* G {2}\r\na")) ++ "|" ++ show_rlines(I.frame("")))

# Responses
# ---------

def show_message(m: I.Msg) -> String:
  I.Msg{uid, flags, date, size, headers, body} = m
  U32.show(uid) ++ "|" ++ String.join(flags, ",") ++ "|" ++ date ++ "|" ++
    U32.show(size) ++ "|" ++ show_text(headers) ++ "|" ++ show_text(body)

def show_full_messages(ms: List<&2, I.Msg>) -> String:
  match ms:
    case Nil{}:
      ""
    case Con{m, rest}:
      show_message(m) ++ ";" ++ show_full_messages(rest)

def response_transcript() -> String:
  String.concat([
    "* capability imap4rev1 Move\r\n",
    "* list (\\Noselect) NIL \"Top\"\r\n",
    "* LIST () \"/\" {4}\r\nWork\r\n",
    "* LIST (\\Junk) \".\" \"Inbox\"\r\n",
    "* LIST (bad\r\n",
    "* LSUB () \"/\" \"Sub \\\"q\\\"\"\r\n",
    "* 4 exists\r\n",
    "* OK [UIDVALIDITY abc] x\r\n",
    "* OK [UIDNEXT 12] x\r\n",
    "* search 1 x 3\r\n",
    "* SEARCH\r\n",
    "* 2 fetch (uid 9 flags () internaldate NIL rfc822.size x ",
    "BODY[HEADER.FIELDS (FROM)] \"From: \\\"q\\\"\" BODY[] NIL)\r\n",
    "* 3 FETCH (UID 4 FLAGS (\\Seen [x] a[b c]d) RFC822.SIZE 7 BODY[] {2}\r\nhi",
    " BODY[HEADER] {3}\r\nh:v)\r\n",
    "* 5 FETCH (UID 6 FLAGS (\\Seen\r\n",
    "* 6 FETCH x\r\n",
    "a1 ok done\r\n",
    "a2 bad [PARSE] what\r\n",
    "a3 NO\r\n"])

def check_responses(+lines: List<&2, I.RLine>) -> IO(Unit):
  do IO<Unit>:
    IO.print(String.join(I.caps(lines), " ") ++ " " ++
      Bool.show(I.has_cap(I.caps(lines), "MOVE")) ++ " " ++
      Bool.show(I.has_cap(I.caps(lines), "move")))
    IO.print(show_folders(I.folders(lines)) ++ " " ++ show_folders(I.subscribed(lines)))
    IO.print(Maybe.default(&2, String, I.special(I.folders(lines), "\\junk"), "-") ++
      " " ++ Maybe.default(&2, String, I.special(I.folders(lines), "\\Trash"), "-") ++
      " " ++ Maybe.default(&2, String, I.named(I.folders(lines), "INBOX"), "-") ++
      " " ++ Maybe.default(&2, String, I.named(I.folders(lines), "work"), "-") ++
      " " ++ Bool.show(I.has_attr(["\\Trash"], "\\TRASH")) ++
      " " ++ Bool.show(I.same_name("inbox", "INBOX")) ++
      " " ++ Bool.show(I.same_name("Trash", "trash")))
    IO.print(U32.show(Maybe.default(&2, U32, I.ok_code(lines, "UIDVALIDITY"), 0)) ++
      " " ++ U32.show(Maybe.default(&2, U32, I.ok_code(lines, "UIDNEXT"), 0)) ++
      " " ++ U32.show(Maybe.default(&2, U32, I.ok_code(lines, "HIGHESTMODSEQ"), 0)) ++
      " " ++ U32.show(Maybe.default(&2, U32, I.exists(lines), 0)) ++
      " " ++ show_uids(I.search_uids(lines)) ++ ".")
    IO.print(show_full_messages(I.fetched(lines)))
    IO.print(show_full_messages(I.flag_fetches(lines)))
    IO.print(I.status(lines, 1) ++ " " ++ I.status(lines, 2) ++ " " ++
      I.status(lines, 3) ++ " [" ++ I.status_text(lines, 2) ++ "] [" ++
      I.status_text(lines, 3) ++ "] [" ++ I.status_text(lines, 9) ++ "] " ++
      Bool.show(I.refused(lines, 1)) ++ " " ++ Bool.show(I.refused(lines, 2)) ++
      " " ++ Bool.show(I.refused(lines, 3)) ++ " " ++ Bool.show(I.refused(lines, 9)))
    IO.print(I.first_failure(lines) ++ "|" ++ I.first_failure([]) ++ "|" ++
      I.resp_code("[TRYCREATE] x") ++ "|" ++ I.resp_code("[A B") ++ "|" ++
      I.resp_code("x [A]"))
    IO.print(Nat.show(List.length(&2, I.RLine, I.replies(lines, 1))) ++ " " ++
      Nat.show(List.length(&2, I.RLine, I.replies(lines, 2))) ++ " " ++
      Nat.show(List.length(&2, I.RLine, I.replies(lines, 9))) ++ " " ++
      "[" ++ show_permanent(I.permanent_flags(I.frame(
        "* OK [PERMANENTFLAGS ()] x\r\n* OK [PERMANENTFLAGS (\\Seen)] y\r\n"))) ++ "]")

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
    check_effects()
    check_rendering()
    check_names_and_dates()
    check_framing()
    check_responses(I.frame(response_transcript()))

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
#|none:00000000;none:00000000;none:00000000;none:00000000;none:00000000;select:10000000;none:00000000;none:00000000;mail:11000010;mail:11000000;mail:11000000;copy:11001000;mail:11000000;expunge:11010100;folder:10100000;folder:10100000;folder:10100000;folder:10100000;mail:11000000;none:00000001;none:00000001;
#|000 000 100 111 111
#|a1 LIST "" "*"\r\na2 LIST "" "*" RETURN (SPECIAL-USE)\r\na3 LSUB "" "*"\r\n=EXPECT-WORD MOVE\r\na4 UID COPY 1,2,3 "Work"\r\na5 UID SEARCH ALL TO "a b" CC "c" BODY "d\\e" TEXT "t" SINCE 1-Feb-2026 BEFORE 2-Feb-2026 SEEN FLAGGED UNFLAGGED\r\na6 UID SEARCH ALL\r\na7 UID SEARCH CHARSET UTF-8 HEADER "X-Tag" {5}\r\nÜnï\r\na8 UID FETCH  (FLAGS)\r\na9 APPEND "Sent" () {0}\r\n\r\n
#|UID;FLAGS;INTERNALDATE;RFC822.SIZE;BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES)];BODY.PEEK[]<0.0>;
#|\Seen;\Deleted;\Draft;\Flagged;\Answered;$MailFlagBit0;$MailFlagBit1;$MailFlagBit2;
#|* OK [UIDVALIDITY 7]|UIDPLUS|EXAMINE "Caf&AOk-"
#|0 0 1 1 2 0
#|&- ~ a a&ZeU-b&- &AAk- []
#|&|a|😀|�|�|�A||Inbox-|😀 x
#|1-Feb-2026;31-Dec-2026;9-Feb-2026;bad;bad;bad;bad;bad;bad;bad;bad;bad;bad;bad;
#|* X <L>{1:abc};* Y <L> Z{1:};
#|* A {}{0:};* B {1a}{0:};* C {a1}{0:};* D 12}{0:};
#|a1 OK {3}{0:};abc{0:};x* {2}{0:};ab{0:};
#|* E <L> <L>){2:ab|\n};* F{0:};G{0:};* tail{0:};
#|* G <L>{0:};|
#|IMAP4REV1 MOVE True False
#|Top||\Noselect;Work|/|;Inbox|.|\Junk; Sub "q"|/|;
#|Inbox - Inbox - True True False
#|0 12 0 4 1 3 .
#|9|||0|From: "q"|;4|\Seen,[x],a[b c]d||7|h:v|hi;6|\Seen||0||;
#|9|||0|From: "q"|;4|\Seen,[x],a[b c]d||7|h:v|hi;6|\Seen||0||;
#|OK BAD NO [[PARSE] what] [] [] False True True False
#|a2 bad [PARSE] what||TRYCREATE|A B|
#|15 0 0 []
