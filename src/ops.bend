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

def plan_folders() -> List<&2, I.Cmd>:
  [I.CList{}]

def plan_search(+mbox: String, +keys: List<&2, I.Key>) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CSearch{keys}]

def plan_new(+mbox: String, +since: U32) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CSearch{[I.KUidFrom{(since + 1 : U32)}]}]

def plan_headers(+mbox: String, +uids: List<&2, U32>) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CFetch{uids, [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IHeaders{}]}]

def plan_get(+mbox: String, +uid: U32, +max: U32) -> List<&2, I.Cmd>:
  [I.CExamine{mbox}, I.CFetch{[uid], [I.IUid{}, I.IFlags{}, I.IDate{}, I.ISize{}, I.IFull{max}]}]

# ---- plans for changes ------------------------------------------------------------

def plan_mark(+mbox: String, +uids: List<&2, U32>, +seen: Bool) -> List<&2, I.Cmd>:
  [I.CSelect{mbox}, I.CStore{uids, seen, I.FSeen{}}]

# Moves with UID MOVE when the server has it. Otherwise copies, then marks
# and expunges exactly those UIDs, which needs UIDPLUS (a plain EXPUNGE
# could remove other messages marked \Deleted). With neither, no plan.
def plan_move(+mbox: String, +uids: List<&2, U32>, +dest: String, +move: Bool, +uidplus: Bool) -> List<&2, I.Cmd>:
  match move:
    case True{}:
      [I.CSelect{mbox}, I.CMove{uids, dest}]
    case False{}:
      match uidplus:
        case True{}:
          [I.CSelect{mbox}, I.CCopy{uids, dest}, I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]
        case False{}:
          []

# Trash is a move into the Trash mailbox; it never deletes on its own.
def plan_trash(+mbox: String, +uids: List<&2, U32>, +trash: String, +move: Bool, +uidplus: Bool) -> List<&2, I.Cmd>:
  plan_move(mbox, uids, trash, move, uidplus)

# Permanent deletion needs the caller's explicit confirmation and UIDPLUS
# (to expunge only these UIDs). Without both there is no plan.
def plan_delete(+mbox: String, +uids: List<&2, U32>, +confirm: Bool, +uidplus: Bool) -> List<&2, I.Cmd>:
  match confirm:
    case True{}:
      match uidplus:
        case True{}:
          [I.CSelect{mbox}, I.CStore{uids, True{}, I.FDeleted{}}, I.CExpunge{uids}]
        case False{}:
          []
    case False{}:
      []

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
