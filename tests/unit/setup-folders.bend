# Local suggestions preserve discovery precedence and exclude unsafe overrides.

import Base
import ../../src/diagnostics.bend as D
import ../../src/policy.bend as T
import ../../src/imap.bend as I
import ../../src/json.bend as J

def show(+fs: List<&2, I.Folder>) -> String:
  J.show(J.arr(D.suggestion(T.role(fs, "\\Archive", "Archive", "Archive"),
    "archive", "MAILBEND_ARCHIVE_FOLDER", fs, "\\Archive", "Archive", "Archive")))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(show([I.Folder{"Archive", "/", []}]))
    IO.print(show([]))
    IO.print(show([I.Folder{"Archive A", "/", ["\\Archive"]},
      I.Folder{"Archive B", "/", ["\\Archive"]}, I.Folder{"Archive", "/", []}]))
    IO.print(show([I.Folder{"Hidden", "/", ["\\Archive", "\\Noselect"]},
      I.Folder{"Archive", "/", []}]))
    IO.print(show([I.Folder{"Archive", "/", ["\\Sent"]}]))
    IO.print(show([I.Folder{"To Delete", "/", ["\\Archive"]},
      I.Folder{"Safe \"quoted\" archive", "/", ["\\Archive"]}]))
    IO.print(J.show(J.arr(D.folder_suggestions(Fail{"private failure"}))))
    IO.print(J.show(J.arr(D.suggestion(None{}, "trash", "MAILBEND_TRASH_FOLDER",
      [I.Folder{"Trash", "/", []}, I.Folder{"Deleted Messages", "/", []}],
      "\\Trash", "Trash", "Deleted Messages"))))
    IO.print(J.show(J.arr(D.suggestion(Some{"Private resolved"}, "archive",
      "MAILBEND_ARCHIVE_FOLDER", [I.Folder{"Private candidate", "/", ["\\Archive"]}],
      "\\Archive", "Archive", "Archive"))))

#|[]
#|[{"role":"archive","variable":"MAILBEND_ARCHIVE_FOLDER","candidates":[],"status":"suggestions_only"}]
#|[{"role":"archive","variable":"MAILBEND_ARCHIVE_FOLDER","candidates":["Archive A","Archive B"],"status":"suggestions_only"}]
#|[{"role":"archive","variable":"MAILBEND_ARCHIVE_FOLDER","candidates":[],"status":"suggestions_only"}]
#|[{"role":"archive","variable":"MAILBEND_ARCHIVE_FOLDER","candidates":[],"status":"suggestions_only"}]
#|[{"role":"archive","variable":"MAILBEND_ARCHIVE_FOLDER","candidates":["Safe \"quoted\" archive"],"status":"suggestions_only"}]
#|[]
#|[{"role":"trash","variable":"MAILBEND_TRASH_FOLDER","candidates":["Trash","Deleted Messages"],"status":"suggestions_only"}]
#|[]
