import Base
import ./LAWS.bend as Laws
import ./src/imap.bend as I
import ./src/ops.bend as Ops

# Proofs of LAWS.bend. Most laws hold by computation: the plans are fixed
# command lists, so the classifiers reduce to False{} whatever the mailbox
# names, UIDs or keys. The capability laws split on the Bool arguments.

def Laws.read_is_read_only():
  {==}

def Laws.search_is_read_only():
  {==}

def Laws.delete_is_not_read_only():
  {==}

def Laws.trash_is_not_destructive():
  {==}

def Laws.probe_writes_nothing():
  {==}

def Laws.folders_write_nothing():
  {==}

def Laws.search_writes_nothing(mbox, keys):
  {==}

def Laws.get_writes_nothing(mbox, uid, max):
  {==}

def Laws.headers_write_nothing(mbox, uids):
  {==}

def Laws.get_new_writes_nothing(mbox, since):
  {==}

def Laws.mark_never_deletes(mbox, uids, seen):
  match seen:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.move_never_loses_mail(mbox, uids, dest, move, uidplus):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.trash_never_loses_mail(mbox, uids, trash, move, uidplus):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.delete_needs_confirmation(mbox, uids, uidplus):
  {==}

def Laws.draft_never_removes(drafts, msg):
  {==}
