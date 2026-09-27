import Base
import ./imap.bend as I

# MailBend's operations and the IMAP command plans behind them. Tools build
# IMAP commands only through the plan_* defs here, so the laws in LAWS.bend
# (proven in PROOF.bend) are facts about the commands that actually run.

type Op is Data:
  OProbe{}
  OListFolders{}
  OSearch{}
  OGet{}
  OGetNew{}
  OMarkRead{}
  OMarkUnread{}
  OMove{}
  OTrash{}
  ODelete{}
  OSaveDraft{}
  OSend{}
  OReply{}
  OForward{}

# Read-only operations never change the mailbox or send mail.
def is_read_only(+op: Op) -> Bool:
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
    case _:
      False{}

# Destructive operations can lose mail: only permanent deletion.
def is_destructive(+op: Op) -> Bool:
  match op:
    case ODelete{}:
      True{}
    case _:
      False{}

def name(+op: Op) -> String:
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
    case OMarkRead{}:
      "mail_mark_read"
    case OMarkUnread{}:
      "mail_mark_unread"
    case OMove{}:
      "mail_move"
    case OTrash{}:
      "mail_trash"
    case ODelete{}:
      "mail_delete"
    case OSaveDraft{}:
      "mail_save_draft"
    case OSend{}:
      "mail_send"
    case OReply{}:
      "mail_reply"
    case OForward{}:
      "mail_forward"

def all_ops() -> List<&2, Op>:
  [OProbe{}, OListFolders{}, OSearch{}, OGet{}, OGetNew{}, OMarkRead{}, OMarkUnread{}, OMove{}, OTrash{}, ODelete{}, OSaveDraft{}, OSend{}, OReply{}, OForward{}]

def find_op(+ops: List<&2, Op>, +n: String) -> Maybe<&2, Op>:
  match ops:
    case Nil{}:
      None{}
    case Con{+op, t}:
      Bool.pick(Maybe<&2, Op>, String.eq(name(op), n), Some{op}, find_op(t, n))

def from_name(+n: String) -> Maybe<&2, Op>:
  find_op(all_ops(), n)

# ---- plans for reads: EXAMINE (read-only) and PEEK fetches only -----------------

def plan_probe() -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}]

# Before a change: capabilities, folders, and the folder's UIDVALIDITY
# (EXAMINE, read-only).
def plan_preflight(+mbox: String) -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}, I.CExamine{mbox}]

def plan_folders() -> List<&2, I.Cmd>:
  [I.CCapability{}, I.CList{}]

# A server may advertise SPECIAL-USE yet mark folders only when LIST asks
# for them (RFC 6154 RETURN option); tools use this plan then.
def plan_roles() -> List<&2, I.Cmd>:
  [I.CListRoles{}]

def plan_search(+mbox: String, +keys: List<&2, I.Key>) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CSearch{keys}]

def max_uid() -> U32:
  4294967295

# No UID follows the largest one, so a checkpoint there only examines the
# folder (for its UIDVALIDITY): since + 1 would wrap to the invalid UID 0.
def plan_new_if(+at_end: Bool, +mbox: String, +since: U32) -> List<&2, I.Cmd>:
  match at_end:
    case True{}:
      [I.CExamine{mbox}]
    case False{}:
      [I.CExamine{mbox}, I.CSearch{[I.KUidFrom{(since + 1 : U32)}]}]

def plan_new(+mbox: String, +since: U32) -> List<&2, I.Cmd>:
  plan_new_if(U32.is_eq(since, max_uid()), mbox, since)

def plan_headers(+mbox: String, +uids: List<&2, U32>) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CFetch{uids, [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IHeaders{}]}]

def plan_get(+mbox: String, +uid: U32, +max: U32) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CFetch{[uid], [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IFull{max}]}]

# ---- plans for changes ------------------------------------------------------------

# Every change to existing messages opens with the same guard, in the same
# session as the change: SELECT, then an expectation that the folder still
# has the caller's UIDVALIDITY (the helper stops the run otherwise, so stale
# UIDs never touch other messages), then a read-only UID SEARCH that reports
# which of the UIDs exist.
def plan_mark(+mbox: String, +uids: List<&2, U32>, +seen: Bool, +uidv: U32) -> List<&2, I.Cmd>:
  [I.CSelect{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{[I.KUids{uids}]}, I.CStore{uids, seen, I.FSeen{}}]

# Moves with UID MOVE when the server has it. Otherwise copies, then marks
# and expunges exactly those UIDs, which needs UIDPLUS (a plain EXPUNGE
# could remove other messages marked \Deleted); the session itself confirms
# UIDPLUS before anything is marked. With neither, no plan.
def plan_move(+mbox: String, +uids: List<&2, U32>, +dest: String, +move: Bool, +uidplus: Bool, +uidv: U32) -> List<&2, I.Cmd>:
  match move:
    case True{}:
      [I.CSelect{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{[I.KUids{uids}]}, I.CMove{uids, dest}]
    case False{}:
      match uidplus:
        case True{}:
          [I.CCapability{}, I.CExpectWord{"UIDPLUS"}, I.CSelect{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{[I.KUids{uids}]}, I.CCopy{uids, dest}, I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]
        case False{}:
          []

# Trash is a move into the Trash mailbox; it never deletes on its own.
def plan_trash(+mbox: String, +uids: List<&2, U32>, +trash: String, +move: Bool, +uidplus: Bool, +uidv: U32) -> List<&2, I.Cmd>:
  plan_move(mbox, uids, trash, move, uidplus, uidv)

def confirm_word() -> String:
  "permanently-delete"

def plan_delete_if(+confirm: Bool, +mbox: String, +uids: List<&2, U32>, +uidplus: Bool, +uidv: U32) -> List<&2, I.Cmd>:
  match confirm:
    case True{}:
      match uidplus:
        case True{}:
          [I.CCapability{}, I.CExpectWord{"UIDPLUS"}, I.CSelect{mbox}, I.CExpect{I.uidv_line(uidv)}, I.CSearch{[I.KUids{uids}]}, I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]
        case False{}:
          []
    case False{}:
      []

# Permanent deletion needs the caller's confirmation, exactly the word
# "permanently-delete", and UIDPLUS (to expunge only these UIDs), confirmed
# again in the deleting session before anything is marked. Without both
# there is no plan.
def plan_delete(+mbox: String, +uids: List<&2, U32>, +confirm: String, +uidplus: Bool, +uidv: U32) -> List<&2, I.Cmd>:
  plan_delete_if(String.eq(confirm, confirm_word()), mbox, uids, uidplus, uidv)

def plan_draft(+drafts: String, +msg: String) -> List<&2, I.Cmd>:
  [I.CAppend{drafts, [I.FDraft{}, I.FSeen{}], msg}]

# Whether a plan expunges before it has copied the messages anywhere, i.e.
# whether it can lose mail.
def loses_mail(+cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{c, t}:
      match c:
        case I.CCopy{u, d}:
          False{}
        case I.CExpunge{u}:
          True{}
        case _:
          loses_mail(t)

# Whether `s` starts with `p`. Unlike String.starts_with it looks at `p`
# first, so it decides as soon as a known prefix is matched even when the
# rest of `s` is unknown (which is what the laws about rendering need).
def has_prefix(+p: String, +s: String) -> Bool:
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
# pure metadata (non-PEEK BODY[...] or RFC822/RFC822.TEXT would set \Seen).
def peek_safe(+s: String) -> Bool:
  has_prefix("BODY.PEEK[", s) || String.eq(s, "UID") || String.eq(s, "FLAGS") || String.eq(s, "INTERNALDATE") || String.eq(s, "RFC822.SIZE")

# Whether a plan opens with the UIDVALIDITY guard: SELECT, then an
# expectation of the folder's UIDVALIDITY reply.
def pinned(+cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Con{I.CSelect{m}, Con{I.CExpect{e}, t}}:
      has_prefix("* OK [UIDVALIDITY ", e)
    case Con{I.CCapability{}, Con{I.CExpectWord{w}, t}}:
      pinned(t)
    case _:
      False{}

# Whether a plan confirms UIDPLUS in its own session before anything else:
# CAPABILITY, then the expectation of the word UIDPLUS.
def checks_uidplus(+cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Con{I.CCapability{}, Con{I.CExpectWord{w}, t}}:
      String.eq(w, "UIDPLUS")
    case _:
      False{}

def checks_uidplus_or_empty(+cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{h, t}:
      checks_uidplus(cs)

# Pinned, or no plan at all (a refused operation sends nothing).
def pinned_or_empty(+cs: List<&2, I.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{h, t}:
      pinned(cs)
