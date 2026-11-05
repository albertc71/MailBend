# Both implementations receive the same fixture. A successful reported method
# must agree with the resolver returning Some, in either direction. The output
# also pins the reported method, independently of whether resolution succeeds.
# These are concrete regression cases, not an unbounded equivalence proof.

import Base
import ../../src/provider-report.bend as R
import ../../src/policy.bend as Policy
import ../../src/imap.bend as I

def check(label: String, +fs: List<&2, I.Folder>, +override: String,
  +attr: String, +a: String, +b: String) -> IO(Unit):
  +method = R.role_method(fs, override, attr, a, b)
  +reported = List.contains(~String, ~String.eq, ["override", "advertised", "name"], method)
  +resolved = Maybe.is_some(&2, String, Policy.resolved_role(fs, override, attr, a, b))
  equivalent = (reported && resolved) || (Bool.not(reported) && Bool.not(resolved))
  IO.print(label ++ " " ++ method ++ " " ++ Bool.show(equivalent))

def trash(label: String, fs: List<&2, I.Folder>, override: String) -> IO(Unit):
  check(label, fs, override, "\\Trash", Policy.trash_name(), Policy.deleted_messages_name())

def main() -> IO(Unit):
  do IO<Unit>:
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
    trash("advertised wins", [I.Folder{"Trash", "/", []},
      I.Folder{"Provider Trash", "/", ["\\Trash"]}], "")
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
    check("drafts same conventional names", [I.Folder{"Drafts", "/", []}], "", "\\Drafts",
      Policy.drafts_name(), Policy.drafts_name())
    check("sent alternate name", [I.Folder{"Sent Messages", "/", []}], "", "\\Sent",
      Policy.sent_name(), Policy.sent_messages_name())
    check("junk advertised", [I.Folder{"Spam", "/", ["\\Junk"]}], "", "\\Junk",
      Policy.junk_name(), Policy.junk_name())
    check("archive override", [I.Folder{"Saved", "/", []}], "Saved", "\\Archive",
      Policy.archive_name(), Policy.archive_name())

#|override wins override True
#|override missing blocks fallback unresolved True
#|override duplicate ambiguous True
#|override noselect unresolved True
#|override nonexistent unresolved True
#|override other role override True
#|advertised wins advertised True
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
