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

def Laws.mark_never_deletes(mbox, uids, seen, uidv):
  match seen:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.move_never_loses_mail(mbox, uids, dest, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.trash_never_loses_mail(mbox, uids, trash, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.delete_needs_confirmation(mbox, uids, confirm, wrong, uidplus, uidv):
  %Equal.sym(Bool, String.eq(confirm, Ops.confirm_word()), False{}, wrong) : {Ops.plan_delete_if(_, mbox, uids, uidplus, uidv) == [] : List<&2, I.Cmd>}
  {==}

def Laws.mark_is_pinned(mbox, uids, seen, uidv):
  {==}

def Laws.move_is_pinned(mbox, uids, dest, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.trash_is_pinned(mbox, uids, trash, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

# For any confirmation outcome: the plan is pinned or empty.
def delete_if_pinned(confirm: Bool, mbox: String, uids: List<&2, U32>, uidplus: Bool, uidv: U32) -> {Ops.pinned_or_empty(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) == True{} : Bool}:
  match confirm:
    case True{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}
    case False{}:
      {==}

def Laws.delete_is_pinned(mbox, uids, confirm, uidplus, uidv):
  delete_if_pinned(String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

def Laws.draft_never_removes(drafts, msg):
  {==}

def delete_if_checks_uidplus(confirm: Bool, mbox: String, uids: List<&2, U32>, uidplus: Bool, uidv: U32) -> {Ops.checks_uidplus_or_empty(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) == True{} : Bool}:
  match confirm:
    case True{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}
    case False{}:
      {==}

def Laws.delete_checks_uidplus(mbox, uids, confirm, uidplus, uidv):
  delete_if_checks_uidplus(String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

def Laws.copy_move_checks_uidplus(mbox, uids, dest, uidv):
  {==}
