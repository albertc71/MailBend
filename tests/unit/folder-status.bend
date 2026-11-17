import Base
import ../../src/imap.bend as I
import ../../src/ops.bend as Ops
import ../../src/folder-status.bend as F
import ../../src/policy.bend as Policy

def name(s: String) -> String:
  Maybe.default(&2, String, F.canonical_name(s), "invalid")

def name_cases(ss: List<&2, String>) -> String:
  match ss:
    case Nil{}:
      ""
    case s <> t:
      name(s) ++ ";" ++ name_cases(t)

def modseq(q: F.Modseq) -> String:
  match q:
    case F.Unsupported{}:
      "unsupported"
    case F.NotPersistent{}:
      "not_persistent"
    case F.Highest{s}:
      s

def count(c: F.Count) -> String:
  match c:
    case F.Unknown{why}:
      F.unknown_name(why)
    case F.Known{m, u, n, v, q}:
      U32.show(m) ++ "," ++ U32.show(u) ++ "," ++ U32.show(n) ++ "," ++ U32.show(v) ++ "," ++ modseq(q)

def status(reply: String, use_modseq: Bool) -> String:
  +rs = F.records(I.frame(reply), use_modseq)
  count(F.evidence_count(True{}, F.assigned(rs, [I.Folder{"INBOX", "/", []}]), rs, "INBOX"))

def discovered(reply: String) -> String:
  Bool.show(Maybe.is_some(&2, F.Discovery, F.discovery(I.frame(
    "* CAPABILITY IMAP4rev1\r\na1 OK done\r\n" ++ reply ++ "a2 OK done\r\n"))))

def capability(reply: String) -> String:
  Bool.show(Maybe.is_some(&2, List<&2, String>, F.caps(I.frame(reply ++ "a1 OK done\r\n"))))

def entries(es: List<&2, F.Entry>) -> String:
  match es:
    case Nil{}:
      ""
    case F.Entry{I.Folder{name, _, _}, c} <> t:
      name ++ ":" ++ count(c) ++ ";" ++ entries(t)

def overview_evidence(result: F.Overview) -> String:
  match result:
    case F.Overview{es, _, reason}:
      F.reason_name(reason) ++ " " ++ entries(es)

def lost_evidence() -> String:
  overview_evidence(F.count_result(Policy.ProcOk{6,
    "* CAPABILITY IMAP4rev1\r\na1 OK done\r\n* STATUS A (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\na2 OK done\r\n", ""},
    [I.Folder{"A", "/", []}, I.Folder{"B", "/", []}], False{}, False{}))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(name_cases(["INBOX", "inbox", "&-", "&ZeVnLA-", "&2D3eAA-", "NIL"]))
    IO.print(name_cases(["", "&", "&abc", "&A-", "&AA-", "&2AA-", "&3AA-", "&!!!!-", "&AEk-NBOX", "&AAo-", "&AH8-"]))
    IO.print(discovered("* LIST (\\Noselect) NIL \"Parent\"\r\n"))
    IO.print(discovered("* LIST (Noselect) \"/\" \"INBOX\"\r\n"))
    IO.print(discovered("* LIST () {1}\r\n/ \"INBOX\"\r\n"))
    IO.print(discovered("*LIST () \"/\" \"INBOX\"\r\n"))
    IO.print(discovered("*\tLIST () \"/\" \"INBOX\"\r\n"))
    IO.print(discovered("* LIST () \"/\" {5}\r\nINBOX\r\n"))
    IO.print(discovered("* LIST () \"/\" \"INBOX\"\r\n* LIST () \"/\" \"inbox\"\r\n"))
    IO.print(capability("* CAPABILITY \r\n"))
    IO.print(capability("* CAPABILITY IMAP4rev1\r\n*\tCAPABILITY CONDSTORE\r\n"))
    IO.print(status("* STATUS INBOX (MESSAGES 000 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\n", False{}))
    IO.print(status("* STATUS {5}\r\nINBOX (MESSAGES 4294967295 UNSEEN 4294967295 UIDNEXT 4294967295 UIDVALIDITY 4294967295 HIGHESTMODSEQ 9223372036854775807)\r\n", True{}))
    IO.print(status("* STATUS INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7 HIGHESTMODSEQ 000)\r\n", True{}))
    IO.print(status("* STATUS INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7 HIGHESTMODSEQ 9223372036854775808)\r\n", True{}))
    IO.print(status("* STATUS INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7) trailing\r\n", False{}))
    IO.print(status("* STATUS INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7\r\n", False{}))
    IO.print(status("* STATUS \"INBOX\" (MESSAGES \"0\" UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\n", False{}))
    IO.print(status("", False{}))
    IO.print("wrong-name " ++ status("* STATUS \"Other\" (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\n", False{}))
    IO.print(status("* 1 FETCH (BODY[] {62}\r\n* STATUS INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\n)\r\n", False{}))
    IO.print(U32.show(I.tag_count(Ops.plan_folder_status(["A", "INBOX"], False{}, True{}))))
    IO.print(Bool.show(I.any_writes(Ops.plan_folder_status(["A", "INBOX"], True{}, True{}))))
    IO.print("lost " ++ lost_evidence())

#|INBOX;INBOX;&;日本;😀;NIL;
#|invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;
#|True
#|False
#|False
#|False
#|False
#|True
#|False
#|False
#|False
#|0,0,1,7,unsupported
#|4294967295,4294967295,4294967295,4294967295,9223372036854775807
#|0,0,1,7,not_persistent
#|invalid_response
#|invalid_response
#|invalid_response
#|invalid_response
#|not_returned
#|wrong-name invalid_response
#|not_returned
#|3
#|False
#|lost helper_failure A:helper_failure;B:helper_failure;
