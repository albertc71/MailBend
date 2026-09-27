# IMAP command rendering and transcript parsing on a synthetic transcript.
import Base
import ../../src/imap.bend as I

def vis(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ vis(t)
    case SCon{'\n', t}:
      "\\n" ++ vis(t)
    case SCon{c, t}:
      SCon{c, vis(t)}

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

def show_folders(fs: List<&2, I.Folder>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{I.Folder{n, d, a}, t}:
      n ++ "|" ++ d ++ "|" ++ String.join(a, ",") ++ ";" ++ show_folders(t)

def show_msgs(ms: List<&2, I.Msg>) -> String:
  match ms:
    case Nil{}:
      ""
    case Con{I.Msg{u, f, d, s, h, b}, t}:
      U32.show(u) ++ " " ++ String.join(f, ",") ++ " " ++ d ++ " " ++ U32.show(s) ++ " [" ++ vis(b) ++ "];" ++ show_msgs(t)

def show_nums(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      U32.show(x) ++ " " ++ show_nums(t)

def check(+ls: List<&2, I.RLine>) -> IO(Unit):
  do IO<Unit>:
    IO.print(Nat.show(List.length(&2, I.RLine, ls)))
    IO.print(String.join(I.caps(ls), " "))
    IO.print(Bool.show(I.has_cap(I.caps(ls), "IDLE")))
    IO.print(show_folders(I.folders(ls)))
    IO.print(Maybe.default(&2, String, I.special(I.folders(ls), "\\Trash"), "-"))
    IO.print(U32.show(Maybe.default(&2, U32, I.ok_code(ls, "UIDVALIDITY"), 0)) ++ " " ++ U32.show(Maybe.default(&2, U32, I.exists(ls), 0)))
    IO.print(show_nums(I.search_uids(ls)))
    IO.print(show_msgs(I.fetched(ls)))
    IO.print(I.status(ls, 5) ++ " " ++ I.status(ls, 6) ++ " [" ++ I.status(ls, 7) ++ "]")
    IO.print(I.first_failure(ls))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(vis(I.script([I.CCapability{}, I.CExamine{"Café"}, I.CSearch{[I.KFrom{"josé"}, I.KUnseen{}]}, I.CFetch{[5, 7], [I.IUid{}, I.IFull{1000}]}])))
    IO.print(vis(I.script([I.CStore{[3], True{}, I.FSeen{}}, I.CMove{[3], "Deleted Messages"}, I.CExpunge{[1, 2]}, I.CAppend{"Drafts", [I.FDraft{}, I.FSeen{}], "Hi\r\n"}, I.CSearch{[I.KSubject{"a\"b"}, I.KUidFrom{9}]}])))
    IO.print(I.mutf7_encode("日本 & Co") ++ " " ++ I.mutf7_decode(I.mutf7_encode("日本 & Co")) ++ " " ++ I.mutf7_decode("&ZeVnLA-") ++ " " ++ I.mutf7_encode("😀"))
    IO.print(Maybe.default(&2, String, I.imap_date("2026-02-01"), "bad") ++ " " ++ Maybe.default(&2, String, I.imap_date("2026-13-01"), "bad"))
    check(I.frame(transcript()))

#|a1 CAPABILITY\r\na2 EXAMINE "Caf&AOk-"\r\na3 UID SEARCH CHARSET UTF-8 FROM {5}\r\njosé UNSEEN\r\na4 UID FETCH 5,7 (UID BODY.PEEK[]<0.1000>)\r\n
#|a1 UID STORE 3 +FLAGS.SILENT (\Seen)\r\na2 UID MOVE 3 "Deleted Messages"\r\na3 UID EXPUNGE 1,2\r\na4 APPEND "Drafts" (\Draft \Seen) {4}\r\nHi\r\n\r\na5 UID SEARCH SUBJECT "a\"b" UID 9:*\r\n
#|&ZeVnLA- &- Co 日本 & Co 日本 &2D3eAA-
#|1-Feb-2026 bad
#|19
#|IMAP4REV1 MOVE UIDPLUS IDLE
#|True
#|INBOX|/|\HasNoChildren;Deleted Messages|/|\HasNoChildren,\Trash;Work|/|\HasChildren;日本|/|\HasNoChildren;
#|Deleted Messages
#|1700000001 3
#|2 5 7 
#|5 \Seen,\Flagged 26-Sep-2026 10:00:00 +0000 42 [a5 OK spoof\r\n* BYE x\r\n];
#|OK NO []
#|a6 NO [TRYCREATE] no such mailbox
