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
    check_transcript(I.frame(transcript()))
    IO.print(Nat.show(List.length(&2, I.RLine, I.frame("a7 OK text {3}\r\nZ OK bye\r\n"))) ++ " " ++ Maybe.default(&2, String, I.imap_date("a\r\nb-02-01"), "bad") ++ " " ++ Maybe.default(&2, String, I.imap_date("{99}-02-01"), "bad"))

#|a1 CAPABILITY\r\na2 EXAMINE "Caf&AOk-"\r\na3 UID SEARCH CHARSET UTF-8 FROM {5}\r\njosé UNSEEN\r\na4 UID FETCH 5,7 (UID BODY.PEEK[]<0.1000>)\r\n
#|a1 UID STORE 3 +FLAGS.SILENT (\Seen)\r\na2 UID MOVE 3 "Deleted Messages"\r\na3 UID EXPUNGE 1,2\r\na4 APPEND "Drafts" (\Draft \Seen) {4}\r\nHi\r\n\r\na5 UID SEARCH SUBJECT "a\"b" UID 9:*\r\n
#|&ZeVnLA- &- Co 日本 & Co 日本 &2D3eAA-
#|1-Feb-2026 bad
#|a1 SELECT "INBOX"\r\n=EXPECT * OK [UIDVALIDITY 7]\r\na2 UID SEARCH UID 3,4\r\na3 UID STORE 3,4 +FLAGS.SILENT (\Seen)\r\n
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
