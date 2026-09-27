import Base

type MailOp is Data:
  ListFolders{}
  Search{}
  Read{}
  MarkRead{}
  MarkUnread{}
  Move{}
  Trash{}
  Delete{}
  SaveDraft{}
  Send{}

def MailOp.is_read_only(op: MailOp) -> Bool:
  match op:
    case ListFolders{}: True
    case Search{}: True
    case Read{}: True
    case _: False

def require_env(name: String) -> IO(String):
  IO.try(String, IO.get_env(name))

def main() -> IO(Unit):
  do IO<Unit>:
    email : String <- require_env("MAILBEND_EMAIL")
    IO.print("MailBend configuration OK for " ++ email)
    IO.print("Credentials are loaded only by the transport process.")
