# Both implementations receive the same fixture. A successful reported method
# must agree with the resolver returning Some, in either direction. The output
# also pins the reported method, independently of whether resolution succeeds.
# These are concrete regression cases, not an unbounded equivalence proof.

import Base
import ../../src/provider-report.bend as R
import ../../src/policy.bend as Policy
import ../../src/imap.bend as I
import ../../src/json.bend as J

def check_method(label: String, +method: String, +resolved: Bool) -> IO(Unit):
  +reported = List.contains(~String, ~String.eq, ["override", "advertised", "name"], method)
  equivalent = (reported && resolved) || (Bool.not(reported) && Bool.not(resolved))
  IO.print(label ++ " " ++ method ++ " " ++ Bool.show(equivalent))

# Read the actual report field, so wiring drift in R.roles is tested too.
# A missing or non-string field must not silently become "unresolved".
def report_method(roles: J.Json, key: String) -> String:
  Maybe.default(&2, String, J.as_str(J.get(roles, key)), "invalid report field")

def trash(label: String, +fs: List<&2, I.Folder>, +override: String) -> IO(Unit):
  check_method(label, report_method(R.roles(fs, "", override, "", "", ""), "trash"),
    Maybe.is_some(&2, String, Policy.resolved_role(fs, override, "\\Trash",
      Policy.trash_name(), Policy.deleted_messages_name())))

def drafts(label: String, +fs: List<&2, I.Folder>, +override: String) -> IO(Unit):
  check_method(label, report_method(R.roles(fs, override, "", "", "", ""), "drafts"),
    Maybe.is_some(&2, String, Policy.resolved_role(fs, override, "\\Drafts",
      Policy.drafts_name(), Policy.drafts_name())))

def sent(label: String, +fs: List<&2, I.Folder>, +override: String) -> IO(Unit):
  check_method(label, report_method(R.roles(fs, "", "", override, "", ""), "sent"),
    Maybe.is_some(&2, String, Policy.resolved_role(fs, override, "\\Sent",
      Policy.sent_name(), Policy.sent_messages_name())))

def junk(label: String, +fs: List<&2, I.Folder>, +override: String) -> IO(Unit):
  check_method(label, report_method(R.roles(fs, "", "", "", override, ""), "junk"),
    Maybe.is_some(&2, String, Policy.resolved_role(fs, override, "\\Junk",
      Policy.junk_name(), Policy.junk_name())))

def archive(label: String, +fs: List<&2, I.Folder>, +override: String) -> IO(Unit):
  check_method(label, report_method(R.roles(fs, "", "", "", "", override), "archive"),
    Maybe.is_some(&2, String, Policy.resolved_role(fs, override, "\\Archive",
      Policy.archive_name(), Policy.archive_name())))

def inbox(label: String, +fs: List<&2, I.Folder>) -> IO(Unit):
  check_method(label, report_method(R.roles(fs, "", "", "", "", ""), "inbox"),
    Maybe.is_some(&2, String, Policy.named_folder(fs, "INBOX")))

def main() -> IO(Unit):
  do IO<Unit>:
    inbox("inbox uppercase", [I.Folder{"INBOX", "/", []}])
    inbox("inbox lowercase", [I.Folder{"inbox", "/", []}])
    inbox("inbox duplicate", [I.Folder{"INBOX", "/", []}, I.Folder{"INBOX", "/", []}])
    inbox("inbox mixed-case duplicate", [I.Folder{"INBOX", "/", []}, I.Folder{"inbox", "/", []}])
    inbox("inbox noselect", [I.Folder{"INBOX", "/", ["\\Noselect"]}])
    inbox("inbox nonexistent", [I.Folder{"INBOX", "/", ["\\NonExistent"]}])
    inbox("inbox empty listing", [])
    trash("override wins", [I.Folder{"Custom", "/", []},
      I.Folder{"Provider Trash", "/", ["\\Trash"]}, I.Folder{"Trash", "/", []}], "Custom")
    trash("override missing blocks fallback", [I.Folder{"Provider Trash", "/", ["\\Trash"]},
      I.Folder{"Trash", "/", []}], "Missing")
    trash("override duplicate", [I.Folder{"Custom", "/", []},
      I.Folder{"Custom", "/", []}, I.Folder{"Trash", "/", []}], "Custom")
    trash("override noselect", [I.Folder{"Custom", "/", ["\\Noselect"]},
      I.Folder{"Trash", "/", []}], "Custom")
    trash("override nonexistent", [I.Folder{"Custom", "/", ["\\NonExistent"]},
      I.Folder{"Trash", "/", []}], "Custom")
    trash("override other role", [I.Folder{"Custom", "/", ["\\Junk"]}], "Custom")
    trash("override remains case-sensitive", [I.Folder{"Trash", "/", []}], "trash")
    trash("advertised wins", [I.Folder{"Trash", "/", []},
      I.Folder{"Provider Trash", "/", ["\\Trash"]}], "")
    trash("advertised lowercase attribute", [I.Folder{"Provider Trash", "/", ["\\trash"]}], "")
    trash("advertised duplicate blocks fallback", [I.Folder{"A", "/", ["\\Trash"]},
      I.Folder{"Trash", "/", []}, I.Folder{"B", "/", ["\\Trash"]}], "")
    trash("advertised mixed selectability", [I.Folder{"A", "/", ["\\Trash"]},
      I.Folder{"B", "/", ["\\Trash", "\\Noselect"]}, I.Folder{"Trash", "/", []}], "")
    trash("advertised noselect blocks fallback", [I.Folder{"A", "/", ["\\Trash", "\\Noselect"]},
      I.Folder{"Trash", "/", []}], "")
    trash("advertised nonexistent blocks fallback", [I.Folder{"A", "/", ["\\Trash", "\\NonExistent"]},
      I.Folder{"Trash", "/", []}], "")
    trash("primary conventional name", [I.Folder{"Unrelated", "/", []}, I.Folder{"Trash", "/", []}], "")
    trash("alternate conventional name", [I.Folder{"Deleted Messages", "/", []}], "")
    trash("both conventional names", [I.Folder{"Trash", "/", []}, I.Folder{"Deleted Messages", "/", []}], "")
    trash("duplicate conventional name", [I.Folder{"Trash", "/", []}, I.Folder{"Trash", "/", []}], "")
    trash("conventional noselect", [I.Folder{"Trash", "/", ["\\Noselect"]}], "")
    trash("conventional nonexistent", [I.Folder{"Trash", "/", ["\\NonExistent"]}], "")
    trash("unselectable conventional ignored", [I.Folder{"Trash", "/", ["\\Noselect"]},
      I.Folder{"Deleted Messages", "/", []}], "")
    trash("other role blocks conventional name", [I.Folder{"Trash", "/", ["\\Junk"]}], "")
    trash("other role allows alternate name", [I.Folder{"Trash", "/", ["\\Junk"]},
      I.Folder{"Deleted Messages", "/", []}], "")
    trash("empty listing", [], "")
    trash("no matching role", [I.Folder{"Unrelated", "/", []}], "")
    drafts("drafts same conventional names", [I.Folder{"Drafts", "/", []}], "")
    sent("sent alternate name", [I.Folder{"Sent Messages", "/", []}], "")
    junk("junk advertised", [I.Folder{"Spam", "/", ["\\Junk"]}], "")
    archive("archive override", [I.Folder{"Saved", "/", []}], "Saved")
    drafts("drafts override", [I.Folder{"Saved", "/", []}], "Saved")
    drafts("drafts advertised", [I.Folder{"Provider Drafts", "/", ["\\Drafts"]}], "")
    drafts("drafts name ignores sent", [I.Folder{"Drafts", "/", []},
      I.Folder{"Sent", "/", []}], "")
    sent("sent override", [I.Folder{"Saved", "/", []}], "Saved")
    sent("sent advertised", [I.Folder{"Provider Sent", "/", ["\\Sent"]}], "")
    sent("sent alternate ignores junk", [I.Folder{"Sent Messages", "/", []},
      I.Folder{"Junk", "/", []}], "")
    junk("junk override", [I.Folder{"Saved", "/", []}], "Saved")
    junk("junk conventional name", [I.Folder{"Junk", "/", []}], "")
    junk("junk name ignores sent", [I.Folder{"Junk", "/", []},
      I.Folder{"Sent", "/", []}], "")
    archive("archive advertised", [I.Folder{"Provider Archive", "/", ["\\Archive"]}], "")
    archive("archive conventional name", [I.Folder{"Archive", "/", []}], "")
    archive("archive name ignores sent", [I.Folder{"Archive", "/", []},
      I.Folder{"Sent", "/", []}], "")

#|inbox uppercase name True
#|inbox lowercase name True
#|inbox duplicate ambiguous True
#|inbox mixed-case duplicate ambiguous True
#|inbox noselect unresolved True
#|inbox nonexistent unresolved True
#|inbox empty listing unresolved True
#|override wins override True
#|override missing blocks fallback unresolved True
#|override duplicate ambiguous True
#|override noselect unresolved True
#|override nonexistent unresolved True
#|override other role override True
#|override remains case-sensitive unresolved True
#|advertised wins advertised True
#|advertised lowercase attribute advertised True
#|advertised duplicate blocks fallback ambiguous True
#|advertised mixed selectability ambiguous True
#|advertised noselect blocks fallback unresolved True
#|advertised nonexistent blocks fallback unresolved True
#|primary conventional name name True
#|alternate conventional name name True
#|both conventional names ambiguous True
#|duplicate conventional name ambiguous True
#|conventional noselect unresolved True
#|conventional nonexistent unresolved True
#|unselectable conventional ignored name True
#|other role blocks conventional name unresolved True
#|other role allows alternate name name True
#|empty listing unresolved True
#|no matching role unresolved True
#|drafts same conventional names name True
#|sent alternate name name True
#|junk advertised advertised True
#|archive override override True
#|drafts override override True
#|drafts advertised advertised True
#|drafts name ignores sent name True
#|sent override override True
#|sent advertised advertised True
#|sent alternate ignores junk name True
#|junk override override True
#|junk conventional name name True
#|junk name ignores sent name True
#|archive advertised advertised True
#|archive conventional name name True
#|archive name ignores sent name True
