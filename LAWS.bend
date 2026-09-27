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
  {Bool.or(I.any_marks_deleted(Ops.plan_mark(mbox, uids, seen)), I.any_expunges(Ops.plan_mark(mbox, uids, seen))) == False{} : Bool}

# Moving and trashing never lose mail: whatever server capabilities, no
# message is expunged before it has been copied.
law move_never_loses_mail:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  {Ops.loses_mail(Ops.plan_move(mbox, uids, dest, move, uidplus)) == False{} : Bool}

law trash_never_loses_mail:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  {Ops.loses_mail(Ops.plan_trash(mbox, uids, trash, move, uidplus)) == False{} : Bool}

# Unless the confirmation is exactly "permanently-delete", deletion does
# nothing at all.
law delete_needs_confirmation:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for wrong: {String.eq(confirm, Ops.confirm_word()) == False{} : Bool}
  for uidplus: Bool
  {Ops.plan_delete(mbox, uids, confirm, uidplus) == [] : List<&2, I.Cmd>}

# Saving a draft only appends; it never removes anything.
law draft_never_removes:
  for drafts: String
  for msg: String
  {Bool.or(I.any_expunges(Ops.plan_draft(drafts, msg)), I.any_marks_deleted(Ops.plan_draft(drafts, msg))) == False{} : Bool}
