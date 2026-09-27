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

def Laws.preflight_writes_nothing(mbox):
  {==}

def Laws.examine_renders_examine(mbox):
  {==}

def Laws.search_script_examines(mbox, keys):
  {==}

def Laws.get_script_examines(mbox, uid, max):
  {==}

def Laws.fetch_items_never_set_seen(item):
  match item:
    case I.IUid{}:
      {==}
    case I.IFlags{}:
      {==}
    case I.IDate{}:
      {==}
    case I.ISize{}:
      {==}
    case I.IHeaders{}:
      {==}
    case I.IFull{max}:
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

def Laws.delete_needs_confirmation(mbox, uids, confirm, wrong, uidplus):
  %Equal.sym(Bool, String.eq(confirm, Ops.confirm_word()), False{}, wrong) : {Ops.plan_delete_if(_, mbox, uids, uidplus) == [] : List<&2, I.Cmd>}
  {==}

def Laws.draft_never_removes(drafts, msg):
  {==}
