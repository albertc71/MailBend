# MailBend prototype entry point.
#
# The first milestone deliberately keeps network/TLS outside this file until
# the Linux native boundary is wired and tested. This lets the command model
# remain pure Bend and makes destructive operations auditable.

type MailOp:
  ListFolders
  Search
  Read
  MarkRead
  MarkUnread
  Move
  Trash
  Delete
  SaveDraft
  Send

def MailOp/is_read_only(op):
  match op:
    ListFolders: return True
    Search:      return True
    Read:        return True
    MarkRead:    return False
    MarkUnread:  return False
    Move:        return False
    Trash:       return False
    Delete:      return False
    SaveDraft:   return False
    Send:        return False

def MailOp/name(op):
  match op:
    ListFolders: return "list-folders"
    Search:      return "search"
    Read:        return "read"
    MarkRead:    return "mark-read"
    MarkUnread:  return "mark-unread"
    Move:        return "move"
    Trash:       return "trash"
    Delete:      return "delete"
    SaveDraft:   return "save-draft"
    Send:        return "send"

def main:
  ops = [ListFolders, Search, Read, MarkRead, MarkUnread, Move, Trash, Delete, SaveDraft, Send]
  return ops
