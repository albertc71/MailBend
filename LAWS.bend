import Base

# MailBend safety laws. These are deliberately small and pure so that the
# mutation boundary stays reviewable as transport code grows.

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

law read_is_read_only:
  {MailOp.is_read_only(Read{}) == True : Bool}

def read_is_read_only:
  {==}

law delete_is_not_read_only:
  {MailOp.is_read_only(Delete{}) == False : Bool}

def delete_is_not_read_only:
  {==}
