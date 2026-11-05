# Public report serialization has a finite vocabulary even for hostile server data.

import Base
import ../../src/provider-report.bend as R
import ../../src/json.bend as J
import ../../src/imap.bend as I

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(J.show(R.capabilities(["IMAP4REV1", "UIDPLUS", "MOVE", "CONDSTORE",
      "X-GM-EXT-1", "ACCOUNT@PRIVATE.EXAMPLE", "UIDPLUS", ""])))
    +fs : List<&2, I.Folder> = [I.Folder{"person@private.example", "/", ["\\Sent"]},
      I.Folder{"Trash", "/", []}, I.Folder{"Deleted Messages", "/", []},
      I.Folder{"Drafts", "/", []}, I.Folder{"Junk", "/", ["\\Noselect", "\\Junk"]}]
    IO.print(R.role_method(fs, "person@private.example", "\\Archive", "Archive", "Archive"))
    IO.print(R.role_method(fs, "", "\\Sent", "Sent", "Sent Messages"))
    IO.print(R.role_method(fs, "", "\\Drafts", "Drafts", "Drafts"))
    IO.print(R.role_method(fs, "", "\\Trash", "Trash", "Deleted Messages"))
    IO.print(R.role_method(fs, "", "\\Junk", "Junk", "Junk"))
    IO.print(R.role_method(fs, "", "\\Archive", "Archive", "Archive"))
    IO.print(J.show(R.smtp("smtp_auth PLAIN\nsmtp_auth XOAUTH2\nsmtp_auth_other 2\n" ++
      "smtp_auth person@private.example\nprivate server text\n")))
    IO.print(J.show(R.smtp("smtp_auth PLAIN\n")))
    IO.print(J.show(R.smtp("smtp_auth_other 1@example.com\n")))
    IO.print(J.show(R.smtp("smtp_auth_other 1\nsmtp_auth_other 2\n")))

#|{"tokens":["IMAP4REV1","UIDPLUS","MOVE","CONDSTORE","X-GM-EXT-1"],"unknown_count":1}
#|override
#|advertised
#|name
#|ambiguous
#|unresolved
#|unresolved
#|{"mechanisms":["PLAIN","XOAUTH2"],"unknown_count":2}
#|null
#|null
#|null
