# MailBend: the proofs of LAWS.bend, in its order and under its section
# names. Most laws hold by computation ({==}): a plan's structure decides
# its classifiers whatever the mailbox names, UIDs or keys. Where a plan
# branches on a Bool or a fetch item, the proof matches that parameter so
# each branch computes. A plan that branches on a computed value gets a
# lemma taking that value as a parameter, named after its law: `.if` for a
# computed Bool, `.fin` for computed colour bits. Lemma parameters that
# only appear in the goal are erased.

import Base
import ./LAWS.bend as Laws
import ./src/imap.bend as I
import ./src/ops.bend as Ops

# Tool classes
# ------------

def Laws.read_is_read_only():
  {==}

def Laws.search_is_read_only():
  {==}

def Laws.delete_is_not_read_only():
  {==}

def Laws.trash_is_not_destructive():
  {==}

def Laws.read_only_tools_are_exactly_five():
  {==}

# Read plans
# ----------

def Laws.probe_writes_nothing():
  {==}

def Laws.folders_write_nothing():
  {==}

def Laws.roles_write_nothing():
  {==}

def Laws.folder_scan_writes_nothing():
  {==}

def Laws.search_writes_nothing(mbox, keys):
  {==}

def Laws.get_writes_nothing(mbox, uid, max):
  {==}

def Laws.headers_write_nothing(mbox, uids):
  {==}

def Laws.preflight_writes_nothing(mbox):
  {==}

# plan_new branches on whether the checkpoint is the largest UID: both the
# EXAMINE-only plan there and the search plan elsewhere write nothing
def get_new_writes_nothing.if(at_end: Bool, -mbox: String, -since: U32)
  -> {I.any_writes(Ops.plan_new_if(at_end, mbox, since)) == False{} : Bool}:
  match at_end:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.get_new_writes_nothing(mbox, since):
  get_new_writes_nothing.if(U32.is_eq(since, Ops.max_uid()), mbox, since)

# Read rendering
# --------------

def Laws.examine_renders_examine(mbox):
  {==}

def Laws.search_script_examines(mbox, keys):
  {==}

def Laws.get_script_examines(mbox, uid, max):
  {==}

# each fetch item renders to a fixed prefix
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

# Marking and flagging
# --------------------

# A flag law with a colour goes through a .fin lemma that matches the
# colour's bits, I.colour_bits(c), as a parameter: plan_flag_bits builds
# one store from each bit.

def Laws.mark_never_deletes(mbox, uids, seen, uidv):
  match seen:
    case True{}:
      {==}
    case False{}:
      {==}

def flag_never_deletes.fin(
  -mbox: String, -uids: List<&2, U32>, bits: I.Bits, -uidv: U32)
  -> {Bool.or(
       I.any_marks_deleted(Ops.plan_flag_bits(mbox, uids, bits, uidv)),
       I.any_expunges(Ops.plan_flag_bits(mbox, uids, bits, uidv))) == False{} : Bool}:
  match bits:
    case I.Bits{b0, b1, b2}:
      {==}

def Laws.flag_never_deletes(mbox, uids, colour, uidv):
  match colour:
    case None{}:
      ({==}, {==})
    case Some{c}:
      (flag_never_deletes.fin(mbox, uids, I.colour_bits(c), uidv), {==})

def flag_changes_only_flag_and_colour.fin(
  -mbox: String, -uids: List<&2, U32>, bits: I.Bits, -uidv: U32)
  -> {Ops.only_flag_stores(Ops.mail_changes(Ops.plan_flag_bits(mbox, uids, bits, uidv))) ==
       True{} : Bool}:
  match bits:
    case I.Bits{b0, b1, b2}:
      {==}

def Laws.flag_changes_only_flag_and_colour(mbox, uids, colour, uidv):
  match colour:
    case None{}:
      ({==}, {==})
    case Some{c}:
      (flag_changes_only_flag_and_colour.fin(mbox, uids, I.colour_bits(c), uidv), {==})

# e names the bits: rewrite them to that literal, then compute
def flag_changes_exactly.fin(
  -mbox: String, -uids: List<&2, U32>, bits: I.Bits,
  -b0: Bool, -b1: Bool, -b2: Bool, -uidv: U32,
  e: {bits == I.Bits{b0, b1, b2} : I.Bits})
  -> {Ops.mail_changes(Ops.plan_flag_bits(mbox, uids, bits, uidv)) == [
       I.CStore{uids, True{}, I.FFlagged{}},
       I.CStore{uids, b0, I.FColourBit0{}},
       I.CStore{uids, b1, I.FColourBit1{}},
       I.CStore{uids, b2, I.FColourBit2{}}
     ] : List<&2, I.Cmd>}:
  %Equal.sym(I.Bits, bits, I.Bits{b0, b1, b2}, e) :
    {Ops.mail_changes(Ops.plan_flag_bits(mbox, uids, _, uidv)) == [
      I.CStore{uids, True{}, I.FFlagged{}},
      I.CStore{uids, b0, I.FColourBit0{}},
      I.CStore{uids, b1, I.FColourBit1{}},
      I.CStore{uids, b2, I.FColourBit2{}}
    ] : List<&2, I.Cmd>}
  {==}

def Laws.flag_changes_exactly(mbox, uids, colour, b0, b1, b2, uidv):
  ({==},
   e => flag_changes_exactly.fin(mbox, uids, I.colour_bits(colour), b0, b1, b2, uidv, e))

def Laws.unflag_clears_flag_and_colour(mbox, uids, uidv):
  {==}

# Moving, trashing and deleting
# -----------------------------

# A move or trash plan branches on MOVE, then on UIDPLUS: the proofs match
# both. A delete plan branches on whether the confirmation matches, so each
# of its laws goes through a .if lemma that takes that verdict.

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

def Laws.move_expunges_only_copied(mbox, uids, dest, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.trash_expunges_only_copied(mbox, uids, trash, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def delete_expunges_only_marked.if(
  confirm: Bool, -mbox: String, -uids: List<&2, U32>, uidplus: Bool, -uidv: U32)
  -> {Ops.expunged(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) ==
       Ops.marked_deleted(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv))
       : Maybe<&2, List<&2, U32>>}:
  match confirm:
    case True{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}
    case False{}:
      {==}

def Laws.delete_expunges_only_marked(mbox, uids, confirm, uidplus, uidv):
  delete_expunges_only_marked.if(
    String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

def Laws.delete_expunges_given_uids(mbox, uids, uidv):
  {==}

def Laws.move_changes_exactly(mbox, uids, dest, uidplus, uidv):
  {==}

def Laws.copy_move_changes_exactly(mbox, uids, dest, uidv):
  {==}

def Laws.trash_changes_exactly(mbox, uids, trash, uidplus, uidv):
  {==}

def Laws.copy_trash_changes_exactly(mbox, uids, trash, uidv):
  {==}

def Laws.delete_changes_exactly(mbox, uids, uidv):
  {==}

def Laws.expunge_renders_uid_expunge(uids):
  {==}

# the premise `wrong` rewrites the confirmation's verdict to False{}
def Laws.delete_needs_confirmation(mbox, uids, confirm, wrong, uidplus, uidv):
  %Equal.sym(Bool, String.eq(confirm, Ops.confirm_word()), False{}, wrong) :
    {Ops.plan_delete_if(_, mbox, uids, uidplus, uidv) == [] : List<&2, I.Cmd>}
  {==}

def delete_checks_uidplus.if(
  confirm: Bool, -mbox: String, -uids: List<&2, U32>, uidplus: Bool, -uidv: U32)
  -> {Ops.checks_uidplus_or_empty(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) ==
       True{} : Bool}:
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
  delete_checks_uidplus.if(
    String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

def Laws.copy_move_checks_uidplus(mbox, uids, dest, uidv):
  {==}

# UIDVALIDITY pinning
# -------------------

def Laws.mark_is_pinned(mbox, uids, seen, uidv):
  {==}

def Laws.flag_is_pinned(mbox, uids, colour, uidv):
  match colour:
    case None{}:
      ({==}, {==})
    case Some{c}:
      ({==}, {==})

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

def delete_is_pinned.if(
  confirm: Bool, -mbox: String, -uids: List<&2, U32>, uidplus: Bool, -uidv: U32)
  -> {Ops.pinned_or_empty(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) ==
       True{} : Bool}:
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
  delete_is_pinned.if(
    String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

def Laws.mark_pins_callers_uidvalidity(mbox, uids, seen, uidv):
  {==}

def Laws.flag_pins_callers_uidvalidity(mbox, uids, colour, uidv):
  match colour:
    case None{}:
      ({==}, {==})
    case Some{c}:
      ({==}, {==})

def Laws.move_pins_callers_uidvalidity(mbox, uids, dest, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def Laws.trash_pins_callers_uidvalidity(mbox, uids, trash, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def delete_pins_callers_uidvalidity.if(
  confirm: Bool, -mbox: String, -uids: List<&2, U32>, uidplus: Bool, -uidv: U32)
  -> {Ops.pin_line_or(
         Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv), I.uidv_line(uidv)) ==
       I.uidv_line(uidv) : String}:
  match confirm:
    case True{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}
    case False{}:
      {==}

def Laws.delete_pins_callers_uidvalidity(mbox, uids, confirm, uidplus, uidv):
  delete_pins_callers_uidvalidity.if(
    String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

# Drafts
# ------

def Laws.draft_never_removes(drafts, msg):
  {==}

# Folders
# -------

# A rename plan's subscriptions run over the moved folders, so its laws
# rest on lemmas about subscribe_moved and unsubscribe_old, each by
# induction over that list: they change only folders, change no mail and
# expunge nothing. A law proof that hands `moved` to two lemmas binds a
# reusable copy, `+m = moved`, since the law's own parameter is affine.

def unsubscribe_old_changes_only_folders(moved: List<&2, String>)
  -> {Ops.unsubscribe_old(moved) == Ops.mailbox_changes(Ops.unsubscribe_old(moved))
       : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case name <> t:
      %unsubscribe_old_changes_only_folders(t) :
        {Con{I.CUnsubscribe{name}, Ops.unsubscribe_old(t)} ==
          Con{I.CUnsubscribe{name}, _} : List<&2, I.Cmd>}
      {==}

def subscribe_moved_changes_only_folders(
  -from: String, -to: String, moved: List<&2, String>, -rest: List<&2, I.Cmd>)
  -> {Ops.subscribe_moved(from, to, moved, Ops.mailbox_changes(rest)) ==
       Ops.mailbox_changes(Ops.subscribe_moved(from, to, moved, rest)) : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case name <> t:
      %subscribe_moved_changes_only_folders(from, to, t, rest) :
        {Con{I.CSubscribe{Ops.renamed_to(from, to, name)},
            Ops.subscribe_moved(from, to, t, Ops.mailbox_changes(rest))} ==
          Con{I.CSubscribe{Ops.renamed_to(from, to, name)}, _} : List<&2, I.Cmd>}
      {==}

def unsubscribe_old_changes_no_mail(moved: List<&2, String>)
  -> {Ops.mail_changes(Ops.unsubscribe_old(moved)) == [] : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case name <> t:
      %unsubscribe_old_changes_no_mail(t) :
        {Ops.mail_changes(Ops.unsubscribe_old(t)) == _ : List<&2, I.Cmd>}
      {==}

def subscribe_moved_changes_no_mail(
  -from: String, -to: String, moved: List<&2, String>, -rest: List<&2, I.Cmd>)
  -> {Ops.mail_changes(Ops.subscribe_moved(from, to, moved, rest)) ==
       Ops.mail_changes(rest) : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case name <> t:
      %subscribe_moved_changes_no_mail(from, to, t, rest) :
        {Ops.mail_changes(Ops.subscribe_moved(from, to, t, rest)) == _ : List<&2, I.Cmd>}
      {==}

def unsubscribe_old_expunges_nothing(moved: List<&2, String>)
  -> {I.any_expunges(Ops.unsubscribe_old(moved)) == False{} : Bool}:
  match moved:
    case Nil{}:
      {==}
    case name <> t:
      %unsubscribe_old_expunges_nothing(t) :
        {I.any_expunges(Ops.unsubscribe_old(t)) == _ : Bool}
      {==}

def subscribe_moved_expunges_nothing(
  -from: String, -to: String, moved: List<&2, String>, -rest: List<&2, I.Cmd>)
  -> {I.any_expunges(Ops.subscribe_moved(from, to, moved, rest)) ==
       I.any_expunges(rest) : Bool}:
  match moved:
    case Nil{}:
      {==}
    case name <> t:
      %subscribe_moved_expunges_nothing(from, to, t, rest) :
        {I.any_expunges(Ops.subscribe_moved(from, to, t, rest)) == _ : Bool}
      {==}

def Laws.create_changes_exactly(mbox):
  {==}

def Laws.create_changes_no_mail(mbox):
  {==}

# the subscriptions are folder changes: rewrite mailbox_changes away from
# subscribe_moved, then from unsubscribe_old
def Laws.rename_changes_exactly(from, to, moved):
  +m = moved
  %subscribe_moved_changes_only_folders(from, to, m, Ops.unsubscribe_old(m)) :
    {Con{I.CRename{from, to}, _} ==
      Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, m, Ops.unsubscribe_old(m))}
      : List<&2, I.Cmd>}
  %unsubscribe_old_changes_only_folders(m) :
    {Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, m, _)} ==
      Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, m, Ops.unsubscribe_old(m))}
      : List<&2, I.Cmd>}
  {==}

def Laws.rename_subscribes_each_moved_folder(from, to, name, moved, rest):
  {==}

def Laws.rename_unsubscribes_each_moved_folder(name, moved):
  {==}

def Laws.rename_subscribes_before_unsubscribing(from, to, moved):
  {==}

# no mail through the subscriptions, then none through the unsubscriptions
def Laws.rename_changes_no_mail(from, to, moved):
  +m = moved
  Equal.trans(List<&2, I.Cmd>,
    Ops.mail_changes(Ops.subscribe_moved(from, to, m, Ops.unsubscribe_old(m))),
    Ops.mail_changes(Ops.unsubscribe_old(m)),
    [],
    subscribe_moved_changes_no_mail(from, to, m, Ops.unsubscribe_old(m)),
    unsubscribe_old_changes_no_mail(m))

# CREATE expunges nothing by computation; a rename's expunges are its
# subscriptions', then its unsubscriptions'
def Laws.folder_plans_destroy_nothing(mbox, from, to, moved):
  +m = moved
  Equal.trans(Bool,
    I.any_expunges(Ops.subscribe_moved(from, to, m, Ops.unsubscribe_old(m))),
    I.any_expunges(Ops.unsubscribe_old(m)),
    False{},
    subscribe_moved_expunges_nothing(from, to, m, Ops.unsubscribe_old(m)),
    unsubscribe_old_expunges_nothing(m))

# Labels
# ------

def Laws.label_is_move(mbox, uids, label, move, uidplus, uidv):
  {==}

def Laws.label_creates_no_folder(mbox, uids, label, move, uidplus, uidv):
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}
