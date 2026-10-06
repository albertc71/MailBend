# MailBend: the safety laws. Each is a claim about the pure command plans
# in src/ops.bend, which are the only way the tools build IMAP commands;
# about the SMTP envelope in src/smtp.bend, which is built only by
# S.outbound; about the tools each configuration lists; about what
# src/jev.bend sends to TypeSafe and how it reads a missing answer; or
# about Jev's gates, the pure functions through which alone the tools reach
# an SMTP envelope or a delete plan. PROOF.bend proves every law; `bend
# PROOF.bend` is the gate. The laws cover these values and their rendering
# only, not the native helpers, TLS, MIME parsing, agent behaviour, how the
# configuration is read, or the IO that calls the gates (the end-to-end
# tests and a CI check cover that).

import Base
import ./src/codec.bend as C
import ./src/json.bend as J
import ./src/imap.bend as I
import ./src/mime.bend as M
import ./src/jev.bend as Jev
import ./src/secrets.bend as Secrets
import ./src/ops.bend as Ops
import ./src/smtp.bend as S

# Tool classes
# ------------

# Reading is read-only, and permanent deletion is not. Exactly seven tools
# are read-only (MAILBEND_READ_ONLY allows and lists only them); every other
# tool can change mail, send it, or (mail_get_attachment) write a file.
# mail_classify only asks TypeSafe about messages; mail_triage asks it, then
# moves them. Both are listed only when MAILBEND_TYPESAFE is on.

# LAW: mail_get is read-only
law read_is_read_only:
  {Ops.is_read_only(Ops.OGet{}) == True{} : Bool}

# LAW: mail_search is read-only
law search_is_read_only:
  {Ops.is_read_only(Ops.OSearch{}) == True{} : Bool}

# LAW: mail_delete is not read-only
law delete_is_not_read_only:
  {Ops.is_read_only(Ops.ODelete{}) == False{} : Bool}

# LAW: mail_get_attachment is not read-only: it saves a file
law download_is_not_read_only:
  {Ops.is_read_only(Ops.OGetAttachment{}) == False{} : Bool}

# LAW: mail_trash is not destructive
law trash_is_not_destructive:
  {Ops.is_destructive(Ops.OTrash{}) == False{} : Bool}

# LAW: the read-only tools are exactly these seven, in this order
law read_only_tools_are_exactly_seven:
  {Ops.read_only_names(Ops.all_ops()) ==
    ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
      "mail_get_thread", "mail_classify"]
    : List<&2, String>}

# LAW: the tools each configuration lists: with Jev on, every tool; with it
# off, all but mail_classify and mail_triage; drafts-only mode hides
# mail_send; read-only mode lists only the read-only tools, whatever
# drafts-only says
law tools_listed_per_config:
  for drafts: Bool
  ({Ops.listed_names(Ops.all_ops(), False{}, False{}, True{}) ==
      ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
       "mail_get_thread", "mail_classify", "mail_triage", "mail_get_attachment",
       "mail_mark_read", "mail_mark_unread", "mail_flag", "mail_unflag", "mail_move",
       "mail_label", "mail_trash", "mail_delete", "mail_create_folder", "mail_rename_folder",
       "mail_save_draft", "mail_send", "mail_reply", "mail_forward"] : List<&2, String>} &
   {Ops.listed_names(Ops.all_ops(), False{}, False{}, False{}) ==
      ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
       "mail_get_thread", "mail_get_attachment", "mail_mark_read", "mail_mark_unread",
       "mail_flag", "mail_unflag", "mail_move", "mail_label", "mail_trash", "mail_delete",
       "mail_create_folder", "mail_rename_folder", "mail_save_draft", "mail_send",
       "mail_reply", "mail_forward"] : List<&2, String>} &
   {Ops.listed_names(Ops.all_ops(), False{}, True{}, True{}) ==
      ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
       "mail_get_thread", "mail_classify", "mail_triage", "mail_get_attachment",
       "mail_mark_read", "mail_mark_unread", "mail_flag", "mail_unflag", "mail_move",
       "mail_label", "mail_trash", "mail_delete", "mail_create_folder", "mail_rename_folder",
       "mail_save_draft", "mail_reply", "mail_forward"] : List<&2, String>} &
   {Ops.listed_names(Ops.all_ops(), False{}, True{}, False{}) ==
      ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
       "mail_get_thread", "mail_get_attachment", "mail_mark_read", "mail_mark_unread",
       "mail_flag", "mail_unflag", "mail_move", "mail_label", "mail_trash", "mail_delete",
       "mail_create_folder", "mail_rename_folder", "mail_save_draft", "mail_reply",
       "mail_forward"] : List<&2, String>} &
   {Ops.listed_names(Ops.all_ops(), True{}, drafts, True{}) ==
      ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
       "mail_get_thread", "mail_classify"] : List<&2, String>} &
   {Ops.listed_names(Ops.all_ops(), True{}, drafts, False{}) ==
      ["mail_probe", "mail_list_folders", "mail_search", "mail_get", "mail_get_new",
       "mail_get_thread"] : List<&2, String>})

# Read plans
# ----------

# Read plans open mailboxes with EXAMINE, fetch with BODY.PEEK and never
# change anything: for every mailbox, UID, size, key list and checkpoint.

# LAW: the probe plan writes nothing
law probe_writes_nothing:
  {I.any_writes(Ops.plan_probe()) == False{} : Bool}

# LAW: the folder-list plan writes nothing
law folders_write_nothing:
  {I.any_writes(Ops.plan_folders()) == False{} : Bool}

# LAW: the special-use role plan writes nothing
law roles_write_nothing:
  {I.any_writes(Ops.plan_roles()) == False{} : Bool}

# LAW: the scan before a folder change writes nothing
law folder_scan_writes_nothing:
  {I.any_writes(Ops.plan_folder_scan()) == False{} : Bool}

# LAW: for every mailbox and keys, the search plan writes nothing
law search_writes_nothing:
  for mbox: String
  for keys: List<&2, I.Key>
  {I.any_writes(Ops.plan_search(mbox, keys)) == False{} : Bool}

# LAW: for every mailbox, UID and size limit, the get plan writes nothing
law get_writes_nothing:
  for mbox: String
  for uid: U32
  for max: U32
  {I.any_writes(Ops.plan_get(mbox, uid, max)) == False{} : Bool}

# LAW: for every mailbox and UIDs, the headers plan writes nothing
law headers_write_nothing:
  for mbox: String
  for uids: List<&2, U32>
  {I.any_writes(Ops.plan_headers(mbox, uids)) == False{} : Bool}

# LAW: for every mailbox, the preflight before a change writes nothing
law preflight_writes_nothing:
  for mbox: String
  {I.any_writes(Ops.plan_preflight(mbox)) == False{} : Bool}

# LAW: for every mailbox and checkpoint, the get-new plan writes nothing,
# the largest UID included
law get_new_writes_nothing:
  for mbox: String
  for since: U32
  {I.any_writes(Ops.plan_new(mbox, since)) == False{} : Bool}

# LAW: for every folder list, key list and UIDs per folder, the plans that
# read a thread write nothing
law thread_plans_write_nothing:
  for folders: List<&2, String>
  for keys: List<&2, I.Key>
  for found: List<&2, Ops.FolderUids>
  {Bool.or(
    I.any_writes(Ops.plan_thread_search(folders, keys)),
    I.any_writes(Ops.plan_thread_headers(found))) == False{} : Bool}

# LAW: for every Sent folder and addresses, the search of Sent for mail to
# them writes nothing
law sent_search_writes_nothing:
  for sent: String
  for addrs: List<&2, String>
  {I.any_writes(Ops.plan_sent_search(sent, addrs)) == False{} : Bool}

# LAW: for every mailbox and UIDs, reading their flags again writes nothing
law reread_flags_writes_nothing:
  for mbox: String
  for uids: List<&2, U32>
  {I.any_writes(Ops.plan_reread_flags(mbox, uids)) == False{} : Bool}

# LAW: for every mailbox, UIDs, content and size limit, the classify plan
# writes nothing
law classify_writes_nothing:
  for mbox: String
  for uids: List<&2, U32>
  for body: Bool
  for max: U32
  {I.any_writes(Ops.plan_classify(mbox, uids, body, max)) == False{} : Bool}

# Read rendering
# --------------

# What reaches the wire: read plans open the folder with EXAMINE, and every
# fetch item renders as BODY.PEEK or metadata, so no read can set \Seen.

# LAW: an EXAMINE command renders as EXAMINE
law examine_renders_examine:
  for mbox: String
  {Ops.has_prefix("EXAMINE ", I.cmd_str(I.CExamine{mbox})) == True{} : Bool}

# LAW: the search script's first command is EXAMINE
law search_script_examines:
  for mbox: String
  for keys: List<&2, I.Key>
  {Ops.has_prefix("a1 EXAMINE ", I.script(Ops.plan_search(mbox, keys))) ==
    True{} : Bool}

# LAW: the get script's first command is EXAMINE
law get_script_examines:
  for mbox: String
  for uid: U32
  for max: U32
  {Ops.has_prefix("a1 EXAMINE ", I.script(Ops.plan_get(mbox, uid, max))) ==
    True{} : Bool}

# LAW: every fetch item renders as BODY.PEEK or metadata
law fetch_items_never_set_seen:
  for item: I.Item
  {Ops.peek_safe(I.item_str(item)) == True{} : Bool}

# Marking and flagging
# --------------------

# Marking read/unread only touches \Seen. Flagging and unflagging touch only
# \Flagged and the colour bits. Neither marks \Deleted or expunges. Each
# flag law states the flag plan (with or without a colour), then the unflag
# plan.

# LAW: marking never marks \Deleted and never expunges
law mark_never_deletes:
  for mbox: String
  for uids: List<&2, U32>
  for seen: Bool
  for uidv: U32
  {Bool.or(
    I.any_marks_deleted(Ops.plan_mark(mbox, uids, seen, uidv)),
    I.any_expunges(Ops.plan_mark(mbox, uids, seen, uidv))) == False{} : Bool}

# LAW: flagging and unflagging never mark \Deleted and never expunge
law flag_never_deletes:
  for mbox: String
  for uids: List<&2, U32>
  for colour: Maybe<&2, I.Colour>
  for uidv: U32
  ({Bool.or(
      I.any_marks_deleted(Ops.plan_flag(mbox, uids, colour, uidv)),
      I.any_expunges(Ops.plan_flag(mbox, uids, colour, uidv))) == False{} : Bool} &
   {Bool.or(
      I.any_marks_deleted(Ops.plan_unflag(mbox, uids, uidv)),
      I.any_expunges(Ops.plan_unflag(mbox, uids, uidv))) == False{} : Bool})

# LAW: every store that flagging and unflagging make is on \Flagged or a
# colour bit
law flag_changes_only_flag_and_colour:
  for mbox: String
  for uids: List<&2, U32>
  for colour: Maybe<&2, I.Colour>
  for uidv: U32
  ({Ops.only_flag_stores(Ops.mail_changes(Ops.plan_flag(mbox, uids, colour, uidv))) ==
      True{} : Bool} &
   {Ops.only_flag_stores(Ops.mail_changes(Ops.plan_unflag(mbox, uids, uidv))) ==
      True{} : Bool})

# LAW: flagging changes exactly what was asked, in order: without a colour,
# one store adding \Flagged (the colour bits stay as they are); with a
# colour, \Flagged, then each colour bit added or removed as colour_bits
# gives it
law flag_changes_exactly:
  for mbox: String
  for uids: List<&2, U32>
  for colour: I.Colour
  for b0: Bool
  for b1: Bool
  for b2: Bool
  for uidv: U32
  ({Ops.mail_changes(Ops.plan_flag(mbox, uids, None{}, uidv)) ==
      [I.CStore{uids, True{}, I.FFlagged{}}] : List<&2, I.Cmd>} &
   ({I.colour_bits(colour) == I.Bits{b0, b1, b2} : I.Bits} ->
    {Ops.mail_changes(Ops.plan_flag(mbox, uids, Some{colour}, uidv)) == [
      I.CStore{uids, True{}, I.FFlagged{}},
      I.CStore{uids, b0, I.FColourBit0{}},
      I.CStore{uids, b1, I.FColourBit1{}},
      I.CStore{uids, b2, I.FColourBit2{}}
    ] : List<&2, I.Cmd>}))

# LAW: unflagging removes \Flagged, then all three colour bits
law unflag_clears_flag_and_colour:
  for mbox: String
  for uids: List<&2, U32>
  for uidv: U32
  {Ops.mail_changes(Ops.plan_unflag(mbox, uids, uidv)) == [
    I.CStore{uids, False{}, I.FFlagged{}},
    I.CStore{uids, False{}, I.FColourBit0{}},
    I.CStore{uids, False{}, I.FColourBit1{}},
    I.CStore{uids, False{}, I.FColourBit2{}}
  ] : List<&2, I.Cmd>}

# Moving, trashing and deleting
# -----------------------------

# Moving and trashing never lose mail: whatever the server capabilities, no
# message is expunged before it has been copied.
#
# A move or trash plan's first UID EXPUNGE names the same UIDs as its first
# UID COPY, and a delete plan's first UID EXPUNGE names the same UIDs as its
# first \Deleted store; with the confirmation and UIDPLUS those are the
# caller's UIDs. Only the first matching commands are compared: on their own
# these laws do not bind move/trash's \Deleted store or any later command.
# The *_changes_exactly laws close that gap.
#
# Every command that changes mail, in order, is exactly this: UID MOVE of the
# caller's UIDs; or, without MOVE but with UIDPLUS, one UID COPY, one \Deleted
# store and one UID EXPUNGE, all of the caller's UIDs; or, for a confirmed
# delete with UIDPLUS, one \Deleted store and one UID EXPUNGE of them. So the
# \Deleted store names the copied UIDs, and no second or later COPY, STORE,
# MOVE, EXPUNGE or APPEND exists. (Without MOVE or UIDPLUS, or without the
# confirmation, the plan is empty; see the laws on those plans.)
#
# Plans that expunge confirm UIDPLUS in their own session before marking
# anything \Deleted, so a session without it never leaves marked messages.

# LAW: a move plan never expunges before it has copied
law move_never_loses_mail:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.loses_mail(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) ==
    False{} : Bool}

# LAW: a trash plan never expunges before it has copied
law trash_never_loses_mail:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.loses_mail(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) ==
    False{} : Bool}

# LAW: a move plan's first UID EXPUNGE names its first UID COPY's UIDs
law move_expunges_only_copied:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.expunged(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) ==
    Ops.copied(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv))
    : Maybe<&2, List<&2, U32>>}

# LAW: a trash plan's first UID EXPUNGE names its first UID COPY's UIDs
law trash_expunges_only_copied:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.expunged(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) ==
    Ops.copied(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv))
    : Maybe<&2, List<&2, U32>>}

# LAW: a delete plan's first UID EXPUNGE names its first \Deleted store's
# UIDs
law delete_expunges_only_marked:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.expunged(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) ==
    Ops.marked_deleted(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv))
    : Maybe<&2, List<&2, U32>>}

# LAW: a confirmed delete with UIDPLUS expunges exactly the caller's UIDs
law delete_expunges_given_uids:
  for mbox: String
  for uids: List<&2, U32>
  for uidv: U32
  {Ops.expunged(Ops.plan_delete(mbox, uids, Ops.confirm_word(), True{}, uidv)) ==
    Some{uids} : Maybe<&2, List<&2, U32>>}

# LAW: with MOVE, a move changes mail only by one UID MOVE
law move_changes_exactly:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for uidplus: Bool
  for uidv: U32
  {Ops.mail_changes(Ops.plan_move(mbox, uids, dest, True{}, uidplus, uidv)) ==
    [I.CMove{uids, dest}] : List<&2, I.Cmd>}

# LAW: without MOVE but with UIDPLUS, a move changes mail only by one UID
# COPY, one \Deleted store and one UID EXPUNGE, all of the caller's UIDs
law copy_move_changes_exactly:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for uidv: U32
  {Ops.mail_changes(Ops.plan_move(mbox, uids, dest, False{}, True{}, uidv)) ==
    [I.CCopy{uids, dest}, I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]
    : List<&2, I.Cmd>}

# LAW: with MOVE, trashing changes mail only by one UID MOVE
law trash_changes_exactly:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for uidplus: Bool
  for uidv: U32
  {Ops.mail_changes(Ops.plan_trash(mbox, uids, trash, True{}, uidplus, uidv)) ==
    [I.CMove{uids, trash}] : List<&2, I.Cmd>}

# LAW: without MOVE but with UIDPLUS, trashing changes mail only by one UID
# COPY, one \Deleted store and one UID EXPUNGE, all of the caller's UIDs
law copy_trash_changes_exactly:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for uidv: U32
  {Ops.mail_changes(Ops.plan_trash(mbox, uids, trash, False{}, True{}, uidv)) ==
    [I.CCopy{uids, trash}, I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]
    : List<&2, I.Cmd>}

# LAW: a confirmed delete with UIDPLUS changes mail only by one \Deleted
# store and one UID EXPUNGE, both of the caller's UIDs
law delete_changes_exactly:
  for mbox: String
  for uids: List<&2, U32>
  for uidv: U32
  {Ops.mail_changes(Ops.plan_delete(mbox, uids, Ops.confirm_word(), True{}, uidv)) ==
    [I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}] : List<&2, I.Cmd>}

# LAW: expunging always renders as UID EXPUNGE, never a plain EXPUNGE
law expunge_renders_uid_expunge:
  for uids: List<&2, U32>
  {Ops.has_prefix("UID EXPUNGE ", I.cmd_str(I.CExpunge{uids})) == True{} : Bool}

# LAW: unless the confirmation is exactly "permanently-delete", deletion
# does nothing at all
law delete_needs_confirmation:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for wrong: {String.eq(confirm, Ops.confirm_word()) == False{} : Bool}
  for uidplus: Bool
  for uidv: U32
  {Ops.plan_delete(mbox, uids, confirm, uidplus, uidv) == [] : List<&2, I.Cmd>}

# LAW: a delete plan, if any, confirms UIDPLUS in its own session first
law delete_checks_uidplus:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.checks_uidplus_or_empty(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) ==
    True{} : Bool}

# LAW: a move by copy confirms UIDPLUS in its own session first
law copy_move_checks_uidplus:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for uidv: U32
  {Ops.checks_uidplus(Ops.plan_move(mbox, uids, dest, False{}, True{}, uidv)) ==
    True{} : Bool}

# UIDVALIDITY pinning
# -------------------

# Every change to existing messages is pinned to the folder's UIDVALIDITY in
# the same session (SELECT, then the expectation the helper enforces), so
# UIDs read before the folder was recreated can never touch other messages.
# The guard expects the caller's exact UIDVALIDITY, not just any value.

# LAW: marking is pinned
law mark_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for seen: Bool
  for uidv: U32
  {Ops.pinned(Ops.plan_mark(mbox, uids, seen, uidv)) == True{} : Bool}

# LAW: flagging and unflagging are pinned
law flag_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for colour: Maybe<&2, I.Colour>
  for uidv: U32
  ({Ops.pinned(Ops.plan_flag(mbox, uids, colour, uidv)) == True{} : Bool} &
   {Ops.pinned(Ops.plan_unflag(mbox, uids, uidv)) == True{} : Bool})

# LAW: a move plan, if any, is pinned
law move_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pinned_or_empty(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) ==
    True{} : Bool}

# LAW: a trash plan, if any, is pinned
law trash_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pinned_or_empty(Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv)) ==
    True{} : Bool}

# LAW: a delete plan, if any, is pinned
law delete_is_pinned:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.pinned_or_empty(Ops.plan_delete(mbox, uids, confirm, uidplus, uidv)) ==
    True{} : Bool}

# LAW: marking expects the caller's UIDVALIDITY
law mark_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for seen: Bool
  for uidv: U32
  {Ops.pin_line_or(Ops.plan_mark(mbox, uids, seen, uidv), I.uidv_line(uidv)) ==
    I.uidv_line(uidv) : String}

# LAW: flagging and unflagging expect the caller's UIDVALIDITY
law flag_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for colour: Maybe<&2, I.Colour>
  for uidv: U32
  ({Ops.pin_line_or(Ops.plan_flag(mbox, uids, colour, uidv), I.uidv_line(uidv)) ==
      I.uidv_line(uidv) : String} &
   {Ops.pin_line_or(Ops.plan_unflag(mbox, uids, uidv), I.uidv_line(uidv)) ==
      I.uidv_line(uidv) : String})

# LAW: a move plan, if any, expects the caller's UIDVALIDITY
law move_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for dest: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pin_line_or(
    Ops.plan_move(mbox, uids, dest, move, uidplus, uidv), I.uidv_line(uidv)) ==
    I.uidv_line(uidv) : String}

# LAW: a trash plan, if any, expects the caller's UIDVALIDITY
law trash_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for trash: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.pin_line_or(
    Ops.plan_trash(mbox, uids, trash, move, uidplus, uidv), I.uidv_line(uidv)) ==
    I.uidv_line(uidv) : String}

# LAW: a delete plan, if any, expects the caller's UIDVALIDITY
law delete_pins_callers_uidvalidity:
  for mbox: String
  for uids: List<&2, U32>
  for confirm: String
  for uidplus: Bool
  for uidv: U32
  {Ops.pin_line_or(
    Ops.plan_delete(mbox, uids, confirm, uidplus, uidv), I.uidv_line(uidv)) ==
    I.uidv_line(uidv) : String}

# Drafts
# ------

# LAW: saving a draft only appends: it never expunges or marks \Deleted
law draft_never_removes:
  for drafts: String
  for msg: String
  {Bool.or(
    I.any_expunges(Ops.plan_draft(drafts, msg)),
    I.any_marks_deleted(Ops.plan_draft(drafts, msg))) == False{} : Bool}

# Sending
# -------

# The SMTP envelope is built only by S.outbound. With an allowlist, it is
# refused whenever any recipient is not allowed, wherever that recipient
# stands in the list; without one, it is the plain envelope. A Sent copy is
# one APPEND of the sent message, seen, to the Sent folder, and nothing else.

# LAW: for every allowlist, recipient list and position, an unlisted
# recipient means no envelope at all
law allowlist_refuses_unlisted:
  for allow: List<&2, String>
  for before: List<&2, String>
  for rcpt: String
  for after: List<&2, String>
  for from: String
  for msg: String
  for unlisted: {S.allowed(allow, rcpt) == False{} : Bool}
  {S.outbound(allow, List.append(&2, String, before, Con{rcpt, after}), from, msg) ==
    None{} : Maybe<&2, String>}

# LAW: without an allowlist, the envelope is the plain one for every
# recipient list
law no_allowlist_is_unchanged:
  for rcpts: List<&2, String>
  for from: String
  for msg: String
  {S.outbound([], rcpts, from, msg) == Some{S.envelope(from, rcpts, msg)}
    : Maybe<&2, String>}

# LAW: a Sent copy changes mail only by one APPEND of the message to Sent,
# marked seen, and changes no folder
law sent_copy_only_appends:
  for sent: String
  for msg: String
  ({Ops.mail_changes(Ops.plan_sent_copy(sent, msg)) ==
      [I.CAppend{sent, [I.FSeen{}], msg}] : List<&2, I.Cmd>} &
   {Ops.mailbox_changes(Ops.plan_sent_copy(sent, msg)) == [] : List<&2, I.Cmd>})

# Folders
# -------

# Folder plans change folders and nothing else: CREATE then SUBSCRIBE, or
# RENAME, then a SUBSCRIBE of each moved folder's new name, then an
# UNSUBSCRIBE of each old name; no message command, and never anything that
# removes mail. Each starts with CAPABILITY, which changes nothing. There is
# no plan, and no command, that deletes a folder.

# LAW: creating changes folders only by CREATE, then SUBSCRIBE, of the name
law create_changes_exactly:
  for mbox: String
  {Ops.mailbox_changes(Ops.plan_create(mbox)) ==
    [I.CCreate{mbox}, I.CSubscribe{mbox}] : List<&2, I.Cmd>}

# LAW: creating changes no mail
law create_changes_no_mail:
  for mbox: String
  {Ops.mail_changes(Ops.plan_create(mbox)) == [] : List<&2, I.Cmd>}

# LAW: renaming changes folders only by RENAME, then the subscriptions
law rename_changes_exactly:
  for from: String
  for to: String
  for moved: List<&2, String>
  {Ops.mailbox_changes(Ops.plan_rename(from, to, moved)) ==
    Con{I.CRename{from, to},
      Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))}
    : List<&2, I.Cmd>}

# LAW: each moved folder is subscribed under its new name, in order
law rename_subscribes_each_moved_folder:
  for from: String
  for to: String
  for name: String
  for moved: List<&2, String>
  for rest: List<&2, I.Cmd>
  {Ops.subscribe_moved(from, to, Con{name, moved}, rest) ==
    Con{I.CSubscribe{Ops.renamed_to(from, to, name)},
      Ops.subscribe_moved(from, to, moved, rest)}
    : List<&2, I.Cmd>}

# LAW: each moved folder's old name is unsubscribed, in order
law rename_unsubscribes_each_moved_folder:
  for name: String
  for moved: List<&2, String>
  {Ops.unsubscribe_old(Con{name, moved}) ==
    Con{I.CUnsubscribe{name}, Ops.unsubscribe_old(moved)} : List<&2, I.Cmd>}

# LAW: a rename plan is CAPABILITY, RENAME, every new subscription, then
# every old unsubscription
law rename_subscribes_before_unsubscribing:
  for from: String
  for to: String
  for moved: List<&2, String>
  {Ops.plan_rename(from, to, moved) ==
    Con{I.CCapability{}, Con{I.CRename{from, to},
      Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))}}
    : List<&2, I.Cmd>}

# LAW: renaming changes no mail
law rename_changes_no_mail:
  for from: String
  for to: String
  for moved: List<&2, String>
  {Ops.mail_changes(Ops.plan_rename(from, to, moved)) == [] : List<&2, I.Cmd>}

# LAW: neither creating nor renaming expunges
law folder_plans_destroy_nothing:
  for mbox: String
  for from: String
  for to: String
  for moved: List<&2, String>
  {Bool.or(
    I.any_expunges(Ops.plan_create(mbox)),
    I.any_expunges(Ops.plan_rename(from, to, moved))) == False{} : Bool}

# Labels
# ------

# A label is a move: the very same plan, so the move laws above (never loses
# mail, expunges only the copied UIDs, changes exactly those commands, pinned
# to the caller's UIDVALIDITY) cover labels, and labelling creates no folder.

# LAW: a label plan is the move plan into the label
law label_is_move:
  for mbox: String
  for uids: List<&2, U32>
  for label: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.plan_label(mbox, uids, label, move, uidplus, uidv) ==
    Ops.plan_move(mbox, uids, label, move, uidplus, uidv) : List<&2, I.Cmd>}

# LAW: labelling changes no folder
law label_creates_no_folder:
  for mbox: String
  for uids: List<&2, U32>
  for label: String
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.mailbox_changes(Ops.plan_label(mbox, uids, label, move, uidplus, uidv)) ==
    [] : List<&2, I.Cmd>}

# Triage
# ------

# mail_triage files each message by at most one move (Jev.filing): into the
# review folder "To Delete" when the delete review finds it safe to delete,
# or into the existing folder Jev chose for it with High confidence; any
# other message stays. The moves into one folder are one plan_move, in a
# session of its own, so the move laws above hold for each plan. These laws
# hold for every source folder, category list, reserved (role) folder list,
# list of moves, capabilities and UIDVALIDITY.

# LAW: every UID MOVE and UID COPY of a triage plan goes into the review
# folder or one of the categories passed in; never into INBOX or one of the
# reserved (role) folders passed in, in any case; and never into the
# source folder
law triage_moves_only_to_known_folders:
  for mbox: String
  for cats: List<&2, String>
  for reserved: List<&2, String>
  for ms: List<&2, Ops.FolderUids>
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  ({Ops.all_offered(cats,
      Ops.plans_dests(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv))) ==
      True{} : Bool} &
   {Ops.none_named("INBOX" <> reserved,
      Ops.plans_dests(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv))) ==
      True{} : Bool} &
   {Ops.none_same(mbox,
      Ops.plans_dests(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv))) ==
      True{} : Bool})

# LAW: triage changes no folder: a new category exists only through
# mail_create_folder
law triage_creates_no_mailbox:
  for mbox: String
  for cats: List<&2, String>
  for reserved: List<&2, String>
  for ms: List<&2, Ops.FolderUids>
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.plans_mailbox_changes(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv)) ==
    [] : List<&2, I.Cmd>}

# LAW: no UID is moved or copied twice, within one triage plan or across two
law triage_one_move_per_message:
  for mbox: String
  for cats: List<&2, String>
  for reserved: List<&2, String>
  for ms: List<&2, Ops.FolderUids>
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.distinct(List.concat(&2, U32,
    Ops.plans_moved_uids(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv)))) ==
    True{} : Bool}

# LAW: each triage plan expunges only what it copied: its UID EXPUNGEs name,
# in order, exactly the UIDs of its UID COPYs (a plan with UID MOVE has
# neither)
law triage_expunges_only_moved:
  for mbox: String
  for cats: List<&2, String>
  for reserved: List<&2, String>
  for ms: List<&2, Ops.FolderUids>
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  {Ops.plans_expunged(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv)) ==
    Ops.plans_copied(Ops.plan_triage(mbox, cats, reserved, ms, move, uidplus, uidv))
    : List<&2, List<&2, List<&2, U32>>>}

# LAW: filing follows its table for every verdict and category: a message
# safe to delete goes to review whatever its category; with any other
# verdict (Keep, Review, or Unanswered when the delete answers are missing),
# an existing folder chosen with High confidence files it, and a candidate,
# no fitting folder, a lower confidence or no category answer leaves it
law filing_matches_table:
  for cat: Jev.Category
  for v: Jev.Verdict
  for unsafe: {Jev.is_safe(v) == False{} : Bool}
  for folder: String
  ({Jev.filing(Jev.SafeToDelete{}, cat) == Jev.ToReview{} : Jev.Action} &
   {Jev.filing(v, Jev.Filed{folder}) == Jev.ToFolder{folder} : Jev.Action} &
   {Jev.filing(v, Jev.Proposed{folder}) == Jev.Stay{} : Jev.Action} &
   {Jev.filing(v, Jev.NeedsNew{}) == Jev.Stay{} : Jev.Action} &
   {Jev.filing(v, Jev.Uncategorised{}) == Jev.Stay{} : Jev.Action})

# LAW: a message that is not safe to delete, with a category answer below
# High confidence or none at all, is in no triage plan; nor is a message
# whose answers are all missing (an empty reply), whatever its content,
# completeness and code vetoes
law uncertain_changes_nothing:
  for v: Jev.Verdict
  for unsafe: {Jev.is_safe(v) == False{} : Bool}
  for key: String
  for conf: Jev.Band
  for unsure: {Jev.is_high(conf) == False{} : Bool}
  for candidates: List<&2, String>
  for none: String
  for c: Jev.Content
  for whole: Jev.Completeness
  for vetoes: List<&2, String>
  for uid: U32
  for keys: List<&2, String>
  for mbox: String
  for cats: List<&2, String>
  for reserved: List<&2, String>
  for move: Bool
  for uidplus: Bool
  for uidv: U32
  ({Ops.plan_triage(mbox, cats, reserved, Ops.triage_moves(mbox, [Ops.Placement{uid,
       Jev.filing(v, Jev.category_of(Jev.Picked{key, conf}, candidates, none))}]),
       move, uidplus, uidv) == [] : List<&2, List<&2, I.Cmd>>} &
   {Ops.plan_triage(mbox, cats, reserved, Ops.triage_moves(mbox, [Ops.Placement{uid,
       Jev.filing(v, Jev.category_of(Jev.NoPick{}, candidates, none))}]),
       move, uidplus, uidv) == [] : List<&2, List<&2, I.Cmd>>} &
   {Ops.plan_triage(mbox, cats, reserved, Ops.triage_moves(mbox, [Ops.Placement{uid,
       Jev.filing(Jev.verdict(c, whole, vetoes, Jev.answers_for(J.JNull{}, uid, keys)),
         Jev.category_of(Jev.answers_category(Jev.answers_for(J.JNull{}, uid, keys)),
           candidates, none))}]),
       move, uidplus, uidv) == [] : List<&2, List<&2, I.Cmd>>})

# Dry runs
# --------

# A dry run shows a plan as its script, one line per command, but no message
# it would append: an APPEND shows the size of the message instead.

# LAW: for every mailbox, flags, message and tag, a dry run shows an APPEND
# as its command with the size of its message, never the message
law append_preview_hides_message:
  for mbox: String
  for flags: List<&2, I.Flag>
  for msg: String
  for n: U32
  {I.preview.line(I.CAppend{mbox, flags, msg}, n) ==
    I.tag(n) ++ " " ++ I.append_head(mbox, flags) ++ C.size_note(C.utf8_len(msg)) : String}

# Jev
# ---

# In headers mode a message's state, what TypeSafe sees of it, is its UID,
# its fact fields and its attachment names: never its text, flags, date or
# size. A missing or malformed answer is read as the cautious one: keep the
# message, flag it as a suspected injection, suggest nothing, and file it
# nowhere.

# LAW: for every message and text, the headers-mode state is the header
# facts alone
law headers_state_has_no_body:
  for uid: U32
  for fields: List<&2, M.Hdr>
  for flags: List<&2, String>
  for date: String
  for size: U32
  for atts: Jev.Attachments
  for body: Jev.Completeness
  for text: String
  {Jev.state_of(Jev.Headers{}, Jev.Facts{uid, fields, flags, date, size, atts, body}, text) ==
    J.obj(J.kv("uid", J.num(uid)) <>
      List.append(&2, J.Json, Jev.field_kvs(fields),
        [J.kv("attachments", Jev.attachments_json(atts))]))
    : J.Json}

# LAW: a missing answer reads as Missing, which the injection screen flags
# (Jev.suspects), suggests nothing and files it nowhere, whatever the key,
# candidates and none key
law missing_answer_is_cautious:
  for key: String
  for candidates: List<&2, String>
  for none: String
  ({Jev.noul_band(J.JNull{}) == Jev.Missing{} : Jev.Band} &
   {Jev.suspects(Jev.Missing{}) == True{} : Bool} &
   {Jev.suggestion(Jev.NoPick{}) == "none" : String} &
   {Jev.suggestion(Jev.Picked{key, Jev.Missing{}}) == "none" : String} &
   {Jev.category_of(Jev.NoPick{}, candidates, none) == Jev.Uncategorised{} : Jev.Category} &
   {Jev.category_of(Jev.Picked{key, Jev.Missing{}}, candidates, none) == Jev.NeedsNew{}
     : Jev.Category})

# Gates
# -----

# With Jev on, a send passes a local secret scan and Jev's veto questions,
# and a permanent delete passes the delete vetoes. A gate can only take
# the action away: the send keeps exactly the allowlist's envelope and the
# delete exactly its plan, or gets none. A scan that found a secret or
# could not read the whole message, and a check Jev could not decide
# (TypeSafe failed, or an answer is missing), block it.

# LAW: for every allowlist, recipient list, sender and message, a send the
# secret scan found clean gets the allowlist's envelope unchanged when Jev
# is off or vetoed nothing, and no envelope when Jev vetoed it
law send_veto_only_subtracts:
  for allow: List<&2, String>
  for rcpts: List<&2, String>
  for from: String
  for msg: String
  for reasons: List<&2, String>
  ({Jev.outbound_checked(Secrets.Clean{}, allow, Jev.JevOff{}, rcpts, from, msg) ==
     S.outbound(allow, rcpts, from, msg) : Maybe<&2, String>} &
   {Jev.outbound_checked(Secrets.Clean{}, allow, Jev.Cleared{}, rcpts, from, msg) ==
     S.outbound(allow, rcpts, from, msg) : Maybe<&2, String>} &
   {Jev.outbound_checked(Secrets.Clean{}, allow, Jev.Vetoed{reasons}, rcpts, from, msg) ==
     None{} : Maybe<&2, String>})

# LAW: for every plan, a delete keeps its plan unchanged when Jev is off or
# vetoed nothing, and runs no command when Jev vetoed it
law delete_veto_only_subtracts:
  for plan: List<&2, I.Cmd>
  for reasons: List<&2, String>
  ({Jev.delete_checked(Jev.JevOff{}, plan) == plan : List<&2, I.Cmd>} &
   {Jev.delete_checked(Jev.Cleared{}, plan) == plan : List<&2, I.Cmd>} &
   {Jev.delete_checked(Jev.Vetoed{reasons}, plan) == [] : List<&2, I.Cmd>})

# LAW: when Jev could not decide, for every scan result, allowlist,
# recipient list, sender, message and plan, a send gets no envelope and a
# delete runs no command
law failure_blocks_outbound:
  for scan: Secrets.Scan
  for allow: List<&2, String>
  for rcpts: List<&2, String>
  for from: String
  for msg: String
  for reason: String
  for plan: List<&2, I.Cmd>
  ({Jev.outbound_checked(scan, allow, Jev.Failed{reason}, rcpts, from, msg) ==
     None{} : Maybe<&2, String>} &
   {Jev.delete_checked(Jev.Failed{reason}, plan) == [] : List<&2, I.Cmd>})

# LAW: a send in which the secret scan found a secret, or which it could
# not read in full, gets no envelope, whatever Jev decided and for every
# allowlist, recipient list, sender and message: only a clean scan can
# give one
law secret_scan_blocks:
  for part: String
  for reason: String
  for gate: Jev.Gate
  for allow: List<&2, String>
  for rcpts: List<&2, String>
  for from: String
  for msg: String
  ({Jev.outbound_checked(Secrets.Found{part}, allow, gate, rcpts, from, msg) ==
     None{} : Maybe<&2, String>} &
   {Jev.outbound_checked(Secrets.Incomplete{reason}, allow, gate, rcpts, from, msg) ==
     None{} : Maybe<&2, String>})

# LAW: in headers mode, the request about an outgoing message is the same
# whatever its text, for every header field, attachment name, original and
# list of veto questions: TypeSafe never sees the body
law outgoing_headers_state_has_no_body:
  for fields: List<&2, M.Hdr>
  for attachments: List<&2, String>
  for about: Jev.Context
  for vetoes: List<&2, Jev.Veto>
  for text: String
  {Jev.outgoing_request(Jev.Headers{}, Jev.Outgoing{fields, attachments, about}, vetoes, text) ==
    Jev.outgoing_request(Jev.Headers{}, Jev.Outgoing{fields, attachments, about}, vetoes, "")
    : String}
