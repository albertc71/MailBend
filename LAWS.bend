import Base
import ./src/imap.bend as I
import ./src/ops.bend as Ops

# MailBend's safety laws. Each is a claim about the pure command plans in
# src/ops.bend, which are the only way the tools build IMAP commands.
# PROOF.bend proves every law; `bend PROOF.bend` is the gate. The laws cover
# these plans and their rendering only, not the native helpers, TLS, MIME
# parsing, agent behaviour or the runtime configuration.

# Reading is read-only, and permanent deletion is not.
law read_is_read_only:
  {Ops.is_read_only(Ops.OGet{}) == True{} : Bool}

law search_is_read_only:
  {Ops.is_read_only(Ops.OSearch{}) == True{} : Bool}

law delete_is_not_read_only:
  {Ops.is_read_only(Ops.ODelete{}) == False{} : Bool}

law trash_is_not_destructive:
  {Ops.is_destructive(Ops.OTrash{}) == False{} : Bool}

# Exactly these five tools are read-only (MAILBEND_READ_ONLY allows and
# lists only them); every other tool can change mail or send it.
law read_only_tools_are_exactly_five:
  {Ops.read_only_names(Ops.all_ops()) == ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new"] : List<&2, String>}

# Read plans open mailboxes with EXAMINE, fetch with BODY.PEEK and never
# change anything: for every mailbox, UID, size, key list and checkpoint.
law probe_writes_nothing:
  {I.any_writes(Ops.plan_probe()) == False{} : Bool}

law folders_write_nothing:
  {I.any_writes(Ops.plan_folders()) == False{} : Bool}

law roles_write_nothing:
  {I.any_writes(Ops.plan_roles()) == False{} : Bool}

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

# A plan that expunges expunges exactly the UIDs it copied first (so a move
# without UID MOVE removes only what now exists at the destination), and
# permanent deletion expunges exactly the UIDs it marked \Deleted: the
# caller's UIDs when the confirmation is given.
law move_expunges_only_copied:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.expunged(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) == Ops.copied(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) : Maybe<&2, List<&2, U32>>}

law trash_expunges_only_copied:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.expunged(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) == Ops.copied(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) : Maybe<&2, List<&2, U32>>}

law delete_expunges_only_marked:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.expunged(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) == Ops.marked_deleted(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) : Maybe<&2, List<&2, U32>>}

law delete_expunges_given_uids:
  for mbox: String
  for uids: List<&2, U32>
  for uidv: U32
  {Ops.expunged(Ops.plan_delete(mbox, uids, Ops.confirm_word(), True{}, uidv)) == Some{uids} : Maybe<&2, List<&2, U32>>}

# Expunging always renders as UID EXPUNGE, never a plain EXPUNGE.
law expunge_renders_uid_expunge:
  for uids: List<&2, U32>
  {Ops.has_prefix("UID EXPUNGE ", I.cmd_str(I.CExpunge{uids})) == True{} : Bool}

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

# The guard expects the caller's exact UIDVALIDITY, not just any value.
law mark_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for seen: Bool
  for uidv: U32
  {Ops.pin_line_or(Ops.plan_mark(mbox, uids, seen, uidv), I.uidv_line(uidv)) == I.uidv_line(uidv) : String}

law move_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pin_line_or(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv), I.uidv_line(uidv)) == I.uidv_line(uidv) : String}

law trash_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pin_line_or(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv), I.uidv_line(uidv)) == I.uidv_line(uidv) : String}

law delete_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.pin_line_or(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv), I.uidv_line(uidv)) == I.uidv_line(uidv) : String}

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
