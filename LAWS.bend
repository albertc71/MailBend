import Base
import ./src/imap.bend as I
import ./src/ops.bend as Ops

# MailBend's safety laws. Each is a claim about the pure command plans in
# src/ops.bend, which are the only way the tools build IMAP commands.
# PROOF.bend proves every law; `bend PROOF.bend` is the gate.

# Reading is read-only, and permanent deletion is not.
law read_is_read_only:
  {Ops.is_read_only(Ops.OGet{}) == True{} : Bool}

law search_is_read_only:
  {Ops.is_read_only(Ops.OSearch{}) == True{} : Bool}

law delete_is_not_read_only:
  {Ops.is_read_only(Ops.ODelete{}) == False{} : Bool}

law trash_is_not_destructive:
  {Ops.is_destructive(Ops.OTrash{}) == False{} : Bool}

# Read plans open mailboxes with EXAMINE, fetch with BODY.PEEK and never
# change anything: for every mailbox, UID, size, key list and checkpoint.
law probe_writes_nothing:
  {I.any_writes(Ops.plan_probe()) == False{} : Bool}

law folders_write_nothing:
  {I.any_writes(Ops.plan_folders()) == False{} : Bool}

law search_writes_nothing:
  for mbox: String
  for keys: List<&2, I.Key>
  {I.any_writes(Ops.plan_search(mbox, keys)) == False{} : Bool}

law get_writes_nothing:
  for mbox: String
  for uid: U32
  for max: U32
  {I.any_writes(Ops.plan_get(mbox, uid, max)) == False{} : Bool}

law headers_write_nothing:
  for mbox: String
  for uids: List<&2, U32>
  {I.any_writes(Ops.plan_headers(mbox, uids)) == False{} : Bool}

law preflight_writes_nothing:
  for mbox: String
  {I.any_writes(Ops.plan_preflight(mbox)) == False{} : Bool}

# What reaches the wire: read plans open the folder with EXAMINE, and every
# fetch item renders as BODY.PEEK or metadata, so no read can set \Seen.
law examine_renders_examine:
  for mbox: String
  {Ops.has_prefix("EXAMINE ", I.cmd_str(I.CExamine{mbox})) == True{} : Bool}

law search_script_examines:
  for mbox: String
  for keys: List<&2, I.Key>
  {Ops.has_prefix("a1 EXAMINE ", I.script(Ops.plan_search(mbox, keys))) == True{} : Bool}

law get_script_examines:
  for mbox: String
  for uid: U32
  for max: U32
  {Ops.has_prefix("a1 EXAMINE ", I.script(Ops.plan_get(mbox, uid, max))) == True{} : Bool}

law fetch_items_never_set_seen:
  for item: I.Item
  {Ops.peek_safe(I.item_str(item)) == True{} : Bool}

law get_new_writes_nothing:
  for mbox: String
  for since: U32
  {I.any_writes(Ops.plan_new(mbox, since)) == False{} : Bool}

# Marking read/unread only touches \Seen: it never marks \Deleted or expunges.
law mark_never_deletes:
  for mbox: String
  for uids: List<&2, U32>
  for seen: Bool
  for uidv: U32
  {Bool.or(I.any_marks_deleted(Ops.plan_mark(mbox, uids, seen, uidv)), I.any_expunges(Ops.plan_mark(mbox, uids, seen, uidv))) == False{} : Bool}

# Moving and trashing never lose mail: whatever server capabilities, no
# message is expunged before it has been copied.
law move_never_loses_mail:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.loses_mail(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) == False{} : Bool}

law trash_never_loses_mail:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.loses_mail(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) == False{} : Bool}

# Unless the confirmation is exactly "permanently-delete", deletion does
# nothing at all.
law delete_needs_confirmation:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for wrong: {String.eq(confirm, Ops.confirm_word()) == False{} : Bool}
  for uidplus: Bool
  for uidv: U32
  {Ops.plan_delete(mbox, uids, confirm, uidplus, uidv) == [] : List<&2, I.Cmd>}

# Every change to existing messages is pinned to the folder's UIDVALIDITY in
# the same session (SELECT, then the expectation the helper enforces), so
# UIDs read before the folder was recreated can never touch other messages.
law mark_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for seen: Bool
  for uidv: U32
  {Ops.pinned(Ops.plan_mark(mbox, uids, seen, uidv)) == True{} : Bool}

law move_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pinned_or_empty(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) == True{} : Bool}

law trash_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pinned_or_empty(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) == True{} : Bool}

law delete_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.pinned_or_empty(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) == True{} : Bool}

# Saving a draft only appends; it never removes anything.
law draft_never_removes:
  for drafts: String
  for msg: String
  {Bool.or(I.any_expunges(Ops.plan_draft(drafts, msg)), I.any_marks_deleted(Ops.plan_draft(drafts, msg))) == False{} : Bool}

# Plans that expunge confirm UIDPLUS in their own session before marking
# anything \Deleted, so a session without it never leaves marked messages.
law delete_checks_uidplus:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.checks_uidplus_or_empty(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) == True{} : Bool}

law copy_move_checks_uidplus:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for uidv: U32
  {Ops.checks_uidplus(Ops.plan_move(mbox, uids, dest, False{}, True{}, uidv)) == True{} : Bool}
