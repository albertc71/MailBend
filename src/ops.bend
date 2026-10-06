# MailBend's operations and the IMAP command plans behind them. Tools build
# IMAP commands only through the plan_* defs here, so the laws in LAWS.bend
# (proven in PROOF.bend) are facts about the commands that actually run.

import Base
import ./imap.bend as I

# Operations
# ----------

type Op is Data:
  OProbe{}
  OListFolders{}
  OSearch{}
  OGet{}
  OGetNew{}
  OGetThread{}
  OClassify{}
  OGetAttachment{}
  OMarkRead{}
  OMarkUnread{}
  OFlag{}
  OUnflag{}
  OMove{}
  OLabel{}
  OTrash{}
  ODelete{}
  OCreateFolder{}
  ORenameFolder{}
  OSaveDraft{}
  OSend{}
  OReply{}
  OForward{}

# Read-only operations never change the mailbox or send mail, and write
# nothing anywhere: mail_get_attachment reads like mail_get but saves a file,
# so it is not one. mail_classify only asks Jev about messages.
def is_read_only(op: Op) -> Bool:
  match op:
    case OProbe{}:
      True{}
    case OListFolders{}:
      True{}
    case OSearch{}:
      True{}
    case OGet{}:
      True{}
    case OGetNew{}:
      True{}
    case OGetThread{}:
      True{}
    case OClassify{}:
      True{}
    case _:
      False{}

# Destructive operations can lose mail: only permanent deletion.
def is_destructive(op: Op) -> Bool:
  match op:
    case ODelete{}:
      True{}
    case _:
      False{}

# The name of the tool that runs an operation.
def name(op: Op) -> String:
  match op:
    case OProbe{}:
      "mail_probe"
    case OListFolders{}:
      "mail_list_folders"
    case OSearch{}:
      "mail_search"
    case OGet{}:
      "mail_get"
    case OGetNew{}:
      "mail_get_new"
    case OGetThread{}:
      "mail_get_thread"
    case OClassify{}:
      "mail_classify"
    case OGetAttachment{}:
      "mail_get_attachment"
    case OMarkRead{}:
      "mail_mark_read"
    case OMarkUnread{}:
      "mail_mark_unread"
    case OFlag{}:
      "mail_flag"
    case OUnflag{}:
      "mail_unflag"
    case OMove{}:
      "mail_move"
    case OLabel{}:
      "mail_label"
    case OTrash{}:
      "mail_trash"
    case ODelete{}:
      "mail_delete"
    case OCreateFolder{}:
      "mail_create_folder"
    case ORenameFolder{}:
      "mail_rename_folder"
    case OSaveDraft{}:
      "mail_save_draft"
    case OSend{}:
      "mail_send"
    case OReply{}:
      "mail_reply"
    case OForward{}:
      "mail_forward"

# Every operation, in the order the tools are listed.
def all_ops() -> List<&2, Op>:
  [
    OProbe{},
    OListFolders{},
    OSearch{},
    OGet{},
    OGetNew{},
    OGetThread{},
    OClassify{},
    OGetAttachment{},
    OMarkRead{},
    OMarkUnread{},
    OFlag{},
    OUnflag{},
    OMove{},
    OLabel{},
    OTrash{},
    ODelete{},
    OCreateFolder{},
    ORenameFolder{},
    OSaveDraft{},
    OSend{},
    OReply{},
    OForward{}
  ]

# `op`'s name before `rest` when `keep` holds, else just `rest`.
def read_only_names.if(keep: Bool, op: Op, rest: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      name(op) <> rest
    case False{}:
      rest

# The names of the read-only operations among `ops`, in order.
def read_only_names(+ops: List<&2, Op>) -> List<&2, String>:
  match ops:
    case Nil{}:
      []
    case op <> t:
      read_only_names.if(is_read_only(op), op, read_only_names(t))

# Whether an operation consults TypeSafe's Jev, so it is listed and runs
# only when MAILBEND_TYPESAFE is on.
def needs_jev(op: Op) -> Bool:
  match op:
    case OClassify{}:
      True{}
    case _:
      False{}

# Whether an operation always sends mail (replies and forwards may not).
def is_send(op: Op) -> Bool:
  match op:
    case OSend{}:
      True{}
    case _:
      False{}

# Whether a configuration lists `op`: read-only mode lists only the
# read-only operations, drafts-only mode hides mail_send, and the Jev
# operations need Jev on.
def listed(+op: Op, ro: Bool, drafts: Bool, jev: Bool) -> Bool:
  Bool.not(ro && Bool.not(is_read_only(op))) && Bool.not(drafts && is_send(op)) &&
    (jev || Bool.not(needs_jev(op)))

def listed_names.if(keep: Bool, op: Op, rest: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      name(op) <> rest
    case False{}:
      rest

# The names of the operations among `ops` that a configuration lists, in
# order.
def listed_names(ops: List<&2, Op>, +ro: Bool, +drafts: Bool, +jev: Bool) -> List<&2, String>:
  match ops:
    case Nil{}:
      []
    case +op <> t:
      listed_names.if(listed(op, ro, drafts, jev), op, listed_names(t, ro, drafts, jev))

# The first operation among `ops` named `n`. The list is short, so the
# search simply walks all of it.
def find_op(ops: List<&2, Op>, +n: String) -> Maybe<&2, Op>:
  match ops:
    case Nil{}:
      None{}
    case +op <> t:
      Bool.pick(Maybe<&2, Op>, String.eq(name(op), n), Some{op}, find_op(t, n))

# The operation whose tool is named `n`, if any.
def from_name(n: String) -> Maybe<&2, Op>:
  find_op(all_ops(), n)

# Read plans
# ----------

# Reads open folders with EXAMINE (read-only) and fetch only with PEEK.

# Capabilities and folders.
def plan_probe() -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}]

# Before a change: capabilities, folders, and the folder's UIDVALIDITY
# (EXAMINE, read-only).
def plan_preflight(mbox: String) -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}, I.CExamine{mbox}]

# Capabilities and folders, for listing them.
def plan_folders() -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}]

# Before a folder change: capabilities, folders and which of them are
# subscribed (LSUB, read-only).
def plan_folder_scan() -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}, I.CLsub{}]

# When SPECIAL-USE is advertised, tools explicitly request its attributes
# with this plan, even if ordinary LIST already reports some roles. Providers
# may expose only part of their role information without RETURN (SPECIAL-USE).
def plan_roles() -> List<&2, I.Cmd>:
  [I.CListRoles{}]

# The UIDs in `mbox` that match every key.
def plan_search(mbox: String, keys: List<&2, I.Key>) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CSearch{keys}]

# The largest UID, 2^32 - 1.
def max_uid() -> U32:
  4294967295

# No UID follows the largest one, so a checkpoint there only examines the
# folder (for its UIDVALIDITY): since + 1 would wrap to the invalid UID 0.
def plan_new.if(at_end: Bool, mbox: String, since: U32) -> List<&2, I.Cmd>:
  match at_end:
    case True{}:
      [I.CExamine{mbox}]
    case False{}:
      [I.CExamine{mbox}, I.CSearch{[I.KUidFrom{(since + 1 : U32)}]}]

# The UIDs in `mbox` above the checkpoint `since`.
def plan_new(mbox: String, +since: U32) -> List<&2, I.Cmd>:
  plan_new.if(U32.is_eq(since, max_uid()), mbox, since)

# The summaries (flags, date, size, header fields) of `uids`.
def plan_headers(mbox: String, uids: List<&2, U32>) -> List<&2, I.Cmd>:
  [
    I.CExamine{mbox},
    I.CFetch{uids, [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IHeaders{}]}
  ]

# What mail_classify fetches of each message: its summary, its
# BODYSTRUCTURE (for the attachments) and, for `body`, the message itself
# cut at `max` bytes.
def classify_items(body: Bool, max: U32) -> List<&2, I.Item>:
  match body:
    case True{}:
      [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IHeaders{}, I.IStructure{}, I.IFull{max}]
    case False{}:
      [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IHeaders{}, I.IStructure{}]

# Classifying: capabilities and folders (the category options), then the
# messages of `mbox`, opened with EXAMINE.
def plan_classify(mbox: String, uids: List<&2, U32>, body: Bool, max: U32) -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}, I.CExamine{mbox}, I.CFetch{uids, classify_items(body, max)}]

# One message in full, its body cut at `max` bytes.
def plan_get(mbox: String, uid: U32, max: U32) -> List<&2, I.Cmd>:
  [
    I.CExamine{mbox},
    I.CFetch{[uid], [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IFull{max}]}
  ]

# A conversation is read in sessions of several folders each: one searches
# every folder for the thread's message IDs, the next fetches the summaries
# of what it found.

# One UID SEARCH per key, each for undeleted messages only, then `rest`.
def thread_searches(keys: List<&2, I.Key>, rest: List<&2, I.Cmd>) -> List<&2, I.Cmd>:
  match keys:
    case Nil{}:
      rest
    case k <> t:
      I.CSearch{[k, I.KUndeleted{}]} <> thread_searches(t, rest)

# Each folder opened with EXAMINE, then searched once per key.
def plan_thread_search(folders: List<&2, String>, +keys: List<&2, I.Key>) -> List<&2, I.Cmd>:
  match folders:
    case Nil{}:
      []
    case mbox <> t:
      I.CExamine{mbox} <> thread_searches(keys, plan_thread_search(t, keys))

# The UIDs to fetch in one folder.
type FolderUids is Data:
  FolderUids{mbox: String, uids: List<&2, U32>}

# The summaries of the UIDs in each folder, as plan_headers fetches them.
def plan_thread_headers(found: List<&2, FolderUids>) -> List<&2, I.Cmd>:
  match found:
    case Nil{}:
      []
    case FolderUids{mbox, uids} <> t:
      List.append(&2, I.Cmd, plan_headers(mbox, uids), plan_thread_headers(t))

# Change plans
# ------------

# Every change to existing messages opens with the same guard, in the same
# session as the change: SELECT, then an expectation that the folder still
# has the caller's UIDVALIDITY (the helper stops the run otherwise, so stale
# UIDs never touch other messages), then a read-only UID SEARCH that reports
# which of the UIDs exist. `changes` follow the guard.
def guarded(
  mbox: String, uids: List<&2, U32>, uidv: U32, changes: List<&2, I.Cmd>
) -> List<&2, I.Cmd>:
  List.append(&2, I.Cmd,
    [I.CSelect{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{[I.KUids{uids}]}],
    changes)

# Expunging exactly some UIDs needs UIDPLUS (a plain EXPUNGE could remove
# other messages marked \Deleted). With it, the plan first confirms UIDPLUS
# in its own session, before anything is marked; without it, there is no plan.
def with_uidplus(uidplus: Bool, plan: List<&2, I.Cmd>) -> List<&2, I.Cmd>:
  match uidplus:
    case True{}:
      I.CCapability{} <> (I.CExpectWord{"UIDPLUS"} <> plan)
    case False{}:
      []

# Marks `uids` \Deleted, then expunges exactly them with UID EXPUNGE.
def delete_uids(+uids: List<&2, U32>) -> List<&2, I.Cmd>:
  [I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]

# Marking read or unread: the guard, then one store of \Seen.
def plan_mark(
  mbox: String, +uids: List<&2, U32>, seen: Bool, uidv: U32
) -> List<&2, I.Cmd>:
  guarded(mbox, uids, uidv, [I.CStore{uids, seen, I.FSeen{}}])

# A flag change: the guard, its `stores`, then a UID FETCH of the flags,
# whose answer shows which flags the server kept.
def plan_flag_stores(
  mbox: String, +uids: List<&2, U32>, stores: List<&2, I.Cmd>, uidv: U32
) -> List<&2, I.Cmd>:
  guarded(mbox, uids, uidv,
    List.append(&2, I.Cmd, stores, [I.CFetch{uids, [I.IUid{}, I.IFlags{}]}]))

# One store per colour bit, setting or clearing it.
def colour_stores(+uids: List<&2, U32>, bits: I.Bits) -> List<&2, I.Cmd>:
  I.Bits{b0, b1, b2} = bits
  [
    I.CStore{uids, b0, I.FColourBit0{}},
    I.CStore{uids, b1, I.FColourBit1{}},
    I.CStore{uids, b2, I.FColourBit2{}}
  ]

# Flagging with a colour: \Flagged, then each of the colour's bits set or
# cleared, so a recolour leaves no stale bit.
def plan_flag_bits(
  mbox: String, +uids: List<&2, U32>, bits: I.Bits, uidv: U32
) -> List<&2, I.Cmd>:
  plan_flag_stores(mbox, uids,
    I.CStore{uids, True{}, I.FFlagged{}} <> colour_stores(uids, bits), uidv)

# Flagging without a colour stores only \Flagged, so the colour bits a
# message already has stay as they are.
def plan_flag(
  mbox: String, +uids: List<&2, U32>, colour: Maybe<&2, I.Colour>, uidv: U32
) -> List<&2, I.Cmd>:
  match colour:
    case None{}:
      plan_flag_stores(mbox, uids, [I.CStore{uids, True{}, I.FFlagged{}}], uidv)
    case Some{c}:
      plan_flag_bits(mbox, uids, I.colour_bits(c), uidv)

# Unflagging clears \Flagged, then all three colour bits.
def plan_unflag(
  mbox: String, +uids: List<&2, U32>, uidv: U32
) -> List<&2, I.Cmd>:
  plan_flag_stores(mbox, uids,
    I.CStore{uids, False{}, I.FFlagged{}}
      <> colour_stores(uids, I.Bits{False{}, False{}, False{}}),
    uidv)

# Moves with UID MOVE when the server has it. Otherwise copies, then marks
# and expunges exactly those UIDs, which needs UIDPLUS (see with_uidplus).
# With neither, no plan.
def plan_move(
  mbox: String,
  +uids: List<&2, U32>,
  dest: String,
  move: Bool,
  uidplus: Bool,
  uidv: U32
) -> List<&2, I.Cmd>:
  match move:
    case True{}:
      guarded(mbox, uids, uidv, [I.CMove{uids, dest}])
    case False{}:
      with_uidplus(uidplus,
        guarded(mbox, uids, uidv, I.CCopy{uids, dest} <> delete_uids(uids)))

# Trash is a move into the Trash mailbox; it never deletes on its own.
def plan_trash(
  mbox: String,
  uids: List<&2, U32>,
  trash: String,
  move: Bool,
  uidplus: Bool,
  uidv: U32
) -> List<&2, I.Cmd>:
  plan_move(mbox, uids, trash, move, uidplus, uidv)

# The word that confirms a permanent deletion.
def confirm_word() -> String:
  "permanently-delete"

# Permanent deletion of `uids` once `confirm` holds; without it, no plan.
def plan_delete.if(
  confirm: Bool,
  mbox: String,
  +uids: List<&2, U32>,
  uidplus: Bool,
  uidv: U32
) -> List<&2, I.Cmd>:
  match confirm:
    case True{}:
      with_uidplus(uidplus, guarded(mbox, uids, uidv, delete_uids(uids)))
    case False{}:
      []

# Permanent deletion needs the caller's confirmation, exactly the word
# "permanently-delete", and UIDPLUS (to expunge only these UIDs), confirmed
# again in the deleting session before anything is marked. Without both
# there is no plan.
def plan_delete(
  mbox: String,
  uids: List<&2, U32>,
  confirm: String,
  uidplus: Bool,
  uidv: U32
) -> List<&2, I.Cmd>:
  plan_delete.if(String.eq(confirm, confirm_word()), mbox, uids, uidplus, uidv)

# A label is an iCloud folder, so labelling is moving: every law about
# plan_move holds for it unchanged.
def plan_label(
  mbox: String,
  uids: List<&2, U32>,
  label: String,
  move: Bool,
  uidplus: Bool,
  uidv: U32
) -> List<&2, I.Cmd>:
  plan_move(mbox, uids, label, move, uidplus, uidv)

# Saving a draft appends `msg` to `drafts`, marked as a draft and seen.
def plan_draft(drafts: String, msg: String) -> List<&2, I.Cmd>:
  [I.CAppend{drafts, [I.FDraft{}, I.FSeen{}], msg}]

# The copy of a sent message appends `msg` to `sent`, marked seen. The tool
# appends it only after the read-only search plans found no copy there.
def plan_sent_copy(sent: String, msg: String) -> List<&2, I.Cmd>:
  [I.CAppend{sent, [I.FSeen{}], msg}]

# Folder plans
# ------------

# Folder plans touch no message. Each starts with CAPABILITY, which changes
# nothing: once it is answered, a session that dies before the change is
# answered may have made it, and one that dies earlier has not. There is no
# plan that deletes a folder: IMAP has no way to delete a folder only when it
# is empty, and iCloud deletes a folder's messages with it.

# A new folder is subscribed to straight away, so that clients which list
# only subscribed folders still show it.
def plan_create(+mbox: String) -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CCreate{mbox}, I.CSubscribe{mbox}]

# The name a folder of a renamed tree gets: `from` becomes `to`, and a folder
# inside `from` keeps its path below it.
def renamed_to(from: String, to: String, name: String) -> String:
  to ++ String.drop(name, String.length(from))

# SUBSCRIBE of the new name of each moved folder, then `rest`.
def subscribe_moved(
  +from: String, +to: String, moved: List<&2, String>, rest: List<&2, I.Cmd>
) -> List<&2, I.Cmd>:
  match moved:
    case Nil{}:
      rest
    case name <> t:
      I.CSubscribe{renamed_to(from, to, name)}
        <> subscribe_moved(from, to, t, rest)

# UNSUBSCRIBE of the old name of each moved folder.
def unsubscribe_old(moved: List<&2, String>) -> List<&2, I.Cmd>:
  match moved:
    case Nil{}:
      []
    case name <> t:
      I.CUnsubscribe{name} <> unsubscribe_old(t)

# RENAME leaves subscriptions alone (RFC 3501 6.3.5), so each folder that
# moved and was subscribed (`moved`: its old name, inside `from` or `from`
# itself) is subscribed under its new name, and only then are the old names
# dropped: a failure part-way leaves every folder subscribed under at least
# one name.
def plan_rename(
  +from: String, +to: String, +moved: List<&2, String>
) -> List<&2, I.Cmd>:
  subscriptions = subscribe_moved(from, to, moved, unsubscribe_old(moved))
  I.CCapability{} <> (I.CRename{from, to} <> subscriptions)

# Plan classifiers
# ----------------

# What the laws say about plans, as computations over their commands.

# Whether a plan expunges before it has copied anything: the first command
# that copies or destroys mail decides. On its own this says nothing about
# which UIDs were copied; `copied` and `expunged` below let the laws tie the
# expunged set to the copied (or marked) one.
def loses_mail(cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case c <> t:
      +e = I.effect(c)
      +destroys = I.destroys_mail(e)
      Bool.pick(Bool, I.copies_mail(e) || destroys, destroys, loses_mail(t))

# The UIDs of a plan's first UID EXPUNGE, if it has one.
def expunged(cs: List<&2, I.Cmd>) -> Maybe<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      None{}
    case I.CExpunge{u} <> _:
      Some{u}
    case _ <> t:
      expunged(t)

# The UIDs of a plan's first UID COPY, if it has one.
def copied(cs: List<&2, I.Cmd>) -> Maybe<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      None{}
    case I.CCopy{u, _} <> _:
      Some{u}
    case _ <> t:
      copied(t)

# The UIDs a plan first marks \Deleted, if any.
def marked_deleted(cs: List<&2, I.Cmd>) -> Maybe<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      None{}
    case I.CStore{u, True{}, I.FDeleted{}} <> _:
      Some{u}
    case _ <> t:
      marked_deleted(t)

# The commands of a plan that change mail (store, copy, move, expunge,
# append), in order. Unlike the first-match helpers above, it keeps every
# such command, so a law about it also binds any second or later one.
def mail_changes(cs: List<&2, I.Cmd>) -> List<&2, I.Cmd>:
  List.filter(~I.Cmd, ~(c => I.changes_mail(I.effect(c))), cs)

# The commands of a plan that change folders (create, rename, subscribe,
# unsubscribe), in order.
def mailbox_changes(cs: List<&2, I.Cmd>) -> List<&2, I.Cmd>:
  List.filter(~I.Cmd, ~(c => I.changes_mailbox(I.effect(c))), cs)

# Whether a flag is \Flagged or one of the colour bits.
def is_flag_or_colour(f: I.Flag) -> Bool:
  match f:
    case I.FFlagged{}:
      True{}
    case I.FColourBit0{}:
      True{}
    case I.FColourBit1{}:
      True{}
    case I.FColourBit2{}:
      True{}
    case _:
      False{}

# Whether every command is a store on \Flagged or a colour bit.
def only_flag_stores(cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case I.CStore{_, _, f} <> t:
      is_flag_or_colour(f) && only_flag_stores(t)
    case _:
      False{}

# Whether `s` starts with `p`. Unlike String.starts_with it looks at `p`
# first, so it decides as soon as a known prefix is matched even when the
# rest of `s` is unknown (which is what the laws about rendering need).
def has_prefix(p: String, s: String) -> Bool:
  match p:
    case SNil{}:
      True{}
    case SCon{c, pt}:
      match s:
        case SNil{}:
          False{}
        case SCon{d, st}:
          Char.is_eq(c, d) && has_prefix(pt, st)

# Whether a rendered fetch item leaves \Seen alone: a BODY.PEEK section or
# pure metadata, BODYSTRUCTURE included (non-PEEK BODY[...] or
# RFC822/RFC822.TEXT would set \Seen).
def peek_safe(+s: String) -> Bool:
  has_prefix("BODY.PEEK[", s) || String.eq(s, "UID") || String.eq(s, "FLAGS")
    || String.eq(s, "INTERNALDATE") || String.eq(s, "RFC822.SIZE")
    || String.eq(s, "BODYSTRUCTURE")

# Whether a plan opens with the UIDVALIDITY guard (after any UIDPLUS check):
# SELECT, then an expectation of the folder's UIDVALIDITY reply.
def pinned(cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case I.CSelect{_} <> I.CExpect{e} <> _:
      has_prefix("* OK [UIDVALIDITY ", e)
    case I.CCapability{} <> I.CExpectWord{_} <> t:
      pinned(t)
    case _:
      False{}

# The exact UIDVALIDITY line a plan's guard expects: `empty` for no plan at
# all, and "" for a plan that changes messages without the guard.
def pin_line_or(cs: List<&2, I.Cmd>, empty: String) -> String:
  match cs:
    case Nil{}:
      empty
    case I.CSelect{_} <> I.CExpect{e} <> _:
      e
    case I.CCapability{} <> I.CExpectWord{_} <> t:
      pin_line_or(t, "")
    case _:
      ""

# Whether a plan confirms UIDPLUS in its own session before anything else:
# CAPABILITY, then the expectation of the word UIDPLUS.
def checks_uidplus(cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case I.CCapability{} <> I.CExpectWord{w} <> _:
      String.eq(w, "UIDPLUS")
    case _:
      False{}

# Checks UIDPLUS, or no plan at all (a refused operation sends nothing).
def checks_uidplus_or_empty(cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case _ <> _:
      checks_uidplus(cs)

# Pinned, or no plan at all (a refused operation sends nothing).
def pinned_or_empty(cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case _ <> _:
      pinned(cs)
