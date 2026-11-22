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

def discovery_text(found: Result<&2, &2, String, F.Discovery>) -> String:
  match found:
    case Done{_}:
      "True"
    case Fail{m}:
      m

def discovery(reply: String) -> String:
  discovery_text(F.discovery(I.frame("* CAPABILITY IMAP4rev1\r\na1 OK done\r\n" ++ reply ++ "a2 OK done\r\n")))

def discovered(reply: String) -> String:
  Bool.show(String.eq(discovery(reply), "True"))

# Discovery of one LIST row per entry: INBOX with each extended-data suffix.
def ext_rows(ss: List<&2, String>) -> String:
  match ss:
    case Nil{}:
      ""
    case s <> t:
      discovered("* LIST () \"/\" INBOX " ++ s ++ "\r\n") ++ ";" ++ ext_rows(t)

# Discovery of one LIST row per entry: each wire mailbox name.
def name_rows(ss: List<&2, String>) -> String:
  match ss:
    case Nil{}:
      ""
    case s <> t:
      discovered("* LIST () \"/\" " ++ s ++ "\r\n") ++ ";" ++ name_rows(t)

# Discovery of each whole LIST line.
def line_rows(ss: List<&2, String>) -> String:
  match ss:
    case Nil{}:
      ""
    case s <> t:
      discovered(s ++ "\r\n") ++ ";" ++ line_rows(t)

# INBOX's count from each STATUS line, which starts after "* STATUS ".
def status_rows(ss: List<&2, String>) -> String:
  match ss:
    case Nil{}:
      ""
    case s <> t:
      status("* STATUS " ++ s ++ "\r\n", False{}) ++ ";" ++ status_rows(t)

# INBOX's count from a STATUS reply with each HIGHESTMODSEQ spelling.
def modseq_rows(ss: List<&2, String>) -> String:
  match ss:
    case Nil{}:
      ""
    case s <> t:
      status("* STATUS INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7 HIGHESTMODSEQ " ++ s ++ ")\r\n",
        True{}) ++ ";" ++ modseq_rows(t)

def list_rows(n: Nat, +i: U32) -> String:
  match n:
    case 0n:
      ""
    case 1n+p:
      "* LIST () \"/\" \"F" ++ U32.show(i) ++ "\"\r\n" ++ list_rows(p, (i + 1 : U32))

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

def fast_extended_evidence() -> String:
  overview_evidence(F.count_result(Policy.ProcOk{0,
    "* CAPABILITY IMAP4rev1 LIST-STATUS\r\na1 OK done\r\n* LIST () \"/\" \"INBOX\" (\"CHILDINFO\" (\"SUBSCRIBED\"))\r\n* STATUS \"INBOX\" (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\na2 OK done\r\n", ""},
    [I.Folder{"INBOX", "/", []}], True{}, False{}))

# A LIST-STATUS reply whose INBOX row carries the attributes `wire`, after
# discovery listed them as `attrs`.
def fast_flags(wire: String, attrs: List<&2, String>) -> String:
  overview_evidence(F.count_result(Policy.ProcOk{0,
    "* CAPABILITY IMAP4rev1 LIST-STATUS\r\na1 OK done\r\n* LIST (" ++ wire ++ ") \"/\" \"INBOX\"\r\n* STATUS \"INBOX\" (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)\r\na2 OK done\r\n", ""},
    [I.Folder{"INBOX", "/", attrs}], True{}, False{}))

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
    IO.print(discovered("* LIST () \"/\" Reports[2026]\r\n"))
    IO.print(discovered("* LIST () \"/\" INBOX ()\r\n"))
    IO.print(discovered("* LIST () \"/\" INBOX (\"CHILDINFO\" (\"SUBSCRIBED\") X-NEW 7 OLDNAME (\"Old\"))\r\n"))
    IO.print(discovered("* LIST () \"/\" INBOX (CHILDINFO)\r\n"))
    IO.print(discovered("* LIST () \"/\" INBOX () ()\r\n"))
    IO.print(ext_rows(["(EX 1:*)", "(X 1:*)", "(X *:3)", "(X *)", "(X 1:*,5,7:9)", "(X-RANGE 1:*,5)",
      "(EX (\"a\tb\"))", "(EX 0)", "(EX 4294967295)"]))
    IO.print(ext_rows(["(EX 0:2)", "(EX 01:2)", "(EX 4294967296)", "(X-RANGE 0:2)", "(X-DATA 4294967296)"]))
    IO.print(ext_rows(["(\"\" 1)", "(\"two words\" 3)", "(\"\\\"\" (value))"]))
    IO.print(ext_rows(["(EX 1 )", "(EX  1)", "() "]))
    IO.print(ext_rows(["(X 1:2:3)", "(X *5)", "(X 1,)", "(X ,1)", "(X :1)", "(X \"quoted\")", "(X atom)",
      "(X NIL)"]))
    IO.print(name_rows(["X%", "X{Y", "X\\Y", "X*", "\"A\tB\""]))
    IO.print(ext_rows(["(X+Y 1)", "(1X 1)", "(123 1)", "(X! 1)", "(X# 1)", "(X' 1)",
      "(vendor.example-COUNT+FLAGS 2)", "(\"X+TEST\" 7)", "(EX ({3}\r\nabc))"]))
    IO.print(ext_rows(["(X* 1)", "(X] 1)", "(\"X%\" 1)", "(\"X(\" 1)"]))
    IO.print(ext_rows(["( EX 1)", "( )", "( R 42)", "( X 1)", "(X ( a))", "(EX ({3}\r\na\u{0}b))"]))
    IO.print(line_rows(["* LIST ( \\Noselect) \"/\" INBOX", "* LIST  () \"/\" INBOX"]))
    IO.print(status_rows(["INBOX ( MESSAGES 17 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)",
      " INBOX (MESSAGES 17 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 7)",
      "INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 031 UIDVALIDITY 09)",
      "INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 031 UIDVALIDITY 7)",
      "INBOX (MESSAGES 0 UNSEEN 0 UIDNEXT 1 UIDVALIDITY 09)",
      "INBOX (MESSAGES 017 UNSEEN 00 UIDNEXT 18 UIDVALIDITY 7)"]))
    IO.print(modseq_rows(["0", "00", "001"]))
    IO.print(line_rows(["* LIST (\\Marked \\Unmarked) \"/\" INBOX", "* LIST (\\Noselect \\Marked) \"/\" INBOX",
      "* LIST (\\noselect \\UNMARKED) \"/\" INBOX", "* LIST (\\HasChildren \\HasNoChildren) \"/\" INBOX",
      "* LIST (\\hasnochildren \\HASCHILDREN) \"/\" INBOX", "* LIST (\\Marked \\Marked) \"/\" INBOX"]))
    IO.print(line_rows(["* LIST (\\Noselect \\HasChildren) \"/\" INBOX", "* LIST (\\Marked \\HasNoChildren) \"/\" INBOX",
      "* LIST (\\Noinferiors \\Unmarked) \"/\" INBOX", "* LIST (\\X-One \\X-Two) \"/\" INBOX"]))
    IO.print("flags " ++ fast_flags("\\Marked \\Unmarked", ["\\Marked", "\\Unmarked"]))
    IO.print("flags " ++ fast_flags("\\HasChildren \\HasNoChildren", ["\\HasChildren", "\\HasNoChildren"]))
    IO.print("flags " ++ fast_flags("\\Marked \\HasNoChildren", ["\\Marked", "\\HasNoChildren"]))
    IO.print(ext_rows(["(\"vendor.Acme Mail-SIZE\" 2)", "(\"vendor.A-B C-D\" 2)", "(\"vendor.-X\" 2)",
      "(vendor.A/B-X 2)", "(vendor. 2)", "(\"VENDOR.\" 2)"]))
    IO.print(ext_rows(["(\"vendor.Acme Mail\" 2)", "(\"vendor.A*B-X\" 2)", "(\"vendor.Acme Mail-X Y\" 2)"]))
    IO.print(ext_rows(["(vendor.A\\B-X 2)", "({12}\r\nvendor.A\u{0}B-X 2)", "(\"vendor.Acme Mail-SIZE\" 2)",
      "({21}\r\nvendor.Acme Mail-SIZE 2)"]))
    IO.print(discovery(list_rows(100n, 1)))
    IO.print(discovery(list_rows(101n, 1)))
    IO.print(discovery("* LIST (Noselect) \"/\" \"INBOX\"\r\n"))
    IO.print(capability("* CAPABILITY \r\n"))
    IO.print(capability("* CAPABILITY IMAP4rev1\r\n*\tCAPABILITY CONDSTORE\r\n"))
    IO.print(capability("* CAPABILITY IMAP4rev1 X[TEST}\r\n"))
    IO.print(capability("* CAPABILITY IMAP4rev1 X]TEST\r\n"))
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
    IO.print("extended " ++ fast_extended_evidence())

#|INBOX;INBOX;&;日本;😀;NIL;
#|invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;invalid;
#|True
#|False
#|False
#|False
#|False
#|True
#|False
#|True
#|True
#|True
#|False
#|False
#|True;True;True;True;True;True;True;True;True;
#|False;False;False;False;False;
#|False;False;False;
#|False;False;False;
#|False;False;False;False;False;False;False;False;
#|False;False;False;False;False;
#|True;True;True;True;True;True;True;True;True;
#|False;False;False;False;
#|False;False;False;False;False;False;
#|False;False;
#|invalid_response;invalid_response;invalid_response;invalid_response;invalid_response;17,0,18,7,unsupported;
#|0,0,1,7,not_persistent;invalid_response;0,0,1,7,1;
#|False;False;False;False;False;False;
#|True;True;True;True;
#|flags scope_changed INBOX:scope_changed;
#|flags scope_changed INBOX:scope_changed;
#|flags  INBOX:0,0,1,7,unsupported;
#|True;True;True;True;True;True;
#|False;False;False;
#|False;False;True;True;
#|True
#|folder overview admits at most 100 folders
#|folder overview requires complete, valid capability and folder discovery
#|False
#|False
#|True
#|False
#|0,0,1,7,unsupported
#|4294967295,4294967295,4294967295,4294967295,9223372036854775807
#|invalid_response
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
#|extended  INBOX:0,0,1,7,unsupported;
