import Base
import ./LAWS.bend as Laws
import ./src/imap.bend as I
import ./src/ops.bend as Ops

# Proofs of LAWS.bend. Most laws hold by computation: command-plan structure
# determines the classifiers regardless of mailbox names, UIDs or keys.
# Case analysis exposes plans selected by fetch items and Bool arguments.

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

def Laws.probe_writes_nothing():
  {==}

def Laws.folders_write_nothing():
  {==}

def Laws.roles_write_nothing():
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

# Match the checkpoint comparison through a parameter: both the empty plan
# at the maximum UID and the search plan are read-only.
def new_if_writes_nothing(at_end: Bool, mbox: String, since: U32) -> {I.any_writes(Ops.plan_new_if(at_end, mbox, since)) == False{} : Bool}:
  match at_end:
    case True{}:
      {==}
    case False{}:
      {==}

def new_writes_nothing(mbox: String, +since: U32) -> {I.any_writes(Ops.plan_new(mbox, since)) == False{} : Bool}:
  new_if_writes_nothing(U32.is_eq(since, Ops.max_uid()), mbox, since)

def Laws.get_new_writes_nothing(mbox, since):
  new_writes_nothing(mbox, since)

def Laws.mark_never_deletes(mbox, uids, seen, uidv):
  match seen:
    case True{}:
      {==}
    case False{}:
      {==}

# A flag law with a colour goes through a lemma that matches the colour's
# bits as a parameter: plan_flag_bits builds the stores from them.
def flag_bits_never_deletes(
  -mbox: String,
  -uids: List<&2, U32>,
  bits: I.Bits,
  -uidv: U32
) -> {Bool.or(
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
      (flag_bits_never_deletes(mbox, uids, I.colour_bits(c), uidv), {==})

def flag_bits_change_only_flag_and_colour(
  -mbox: String,
  -uids: List<&2, U32>,
  bits: I.Bits,
  -uidv: U32
) -> {Ops.only_flag_stores(Ops.mail_changes(Ops.plan_flag_bits(mbox, uids, bits, uidv))) ==
    True{} : Bool}:
  match bits:
    case I.Bits{b0, b1, b2}:
      {==}

def Laws.flag_changes_only_flag_and_colour(mbox, uids, colour, uidv):
  match colour:
    case None{}:
      ({==}, {==})
    case Some{c}:
      (flag_bits_change_only_flag_and_colour(mbox, uids, I.colour_bits(c), uidv), {==})

# Rewrites the bits to the literal the law names, then computes.
def flag_bits_change_exactly(
  -mbox: String,
  -uids: List<&2, U32>,
  bits: I.Bits,
  -b0: Bool,
  -b1: Bool,
  -b2: Bool,
  -uidv: U32,
  e: {bits == I.Bits{b0, b1, b2} : I.Bits}
) -> {Ops.mail_changes(Ops.plan_flag_bits(mbox, uids, bits, uidv)) == [
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
  ({==}, e => flag_bits_change_exactly(mbox, uids, I.colour_bits(colour), b0, b1, b2, uidv, e))

def Laws.unflag_clears_flag_and_colour(mbox, uids, uidv):
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
  # Rewrite the confirmation comparison to False using the law's premise.
  %Equal.sym(Bool, String.eq(confirm, Ops.confirm_word()), False{}, wrong) : {Ops.plan_delete_if(_, mbox, uids, uidplus, uidv) == [] : List<&2, I.Cmd>}
  {==}

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

def delete_if_expunges_marked(confirm: Bool, mbox: String, uids: List<&2, U32>, uidplus: Bool, uidv: U32) -> {Ops.expunged(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) == Ops.marked_deleted(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv)) : Maybe<&2, List<&2, U32>>}:
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
  delete_if_expunges_marked(String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

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

def delete_if_pins_uidvalidity(confirm: Bool, mbox: String, uids: List<&2, U32>, uidplus: Bool, uidv: U32) -> {Ops.pin_line_or(Ops.plan_delete_if(confirm, mbox, uids, uidplus, uidv), I.uidv_line(uidv)) == I.uidv_line(uidv) : String}:
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
  delete_if_pins_uidvalidity(String.eq(confirm, Ops.confirm_word()), mbox, uids, uidplus, uidv)

def Laws.create_changes_exactly(mbox):
  {==}

def Laws.create_changes_no_mail(mbox):
  {==}

# The subscriptions of a rename, by induction over the moved folders.
def unsubscribe_old_changes_only_folders(moved: List<&2, String>) -> {Ops.unsubscribe_old(moved) == Ops.mailbox_changes(Ops.unsubscribe_old(moved)) : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case Con{name, t}:
      %unsubscribe_old_changes_only_folders(t) : {Con{I.CUnsubscribe{name}, Ops.unsubscribe_old(t)} == Con{I.CUnsubscribe{name}, _} : List<&2, I.Cmd>}
      {==}

def subscribe_moved_changes_only_folders(from: String, to: String, moved: List<&2, String>, rest: List<&2, I.Cmd>) -> {Ops.subscribe_moved(from, to, moved, Ops.mailbox_changes(rest)) == Ops.mailbox_changes(Ops.subscribe_moved(from, to, moved, rest)) : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case Con{name, t}:
      %subscribe_moved_changes_only_folders(from, to, t, rest) : {Con{I.CSubscribe{Ops.renamed_to(from, to, name)}, Ops.subscribe_moved(from, to, t, Ops.mailbox_changes(rest))} == Con{I.CSubscribe{Ops.renamed_to(from, to, name)}, _} : List<&2, I.Cmd>}
      {==}

def unsubscribe_old_changes_no_mail(moved: List<&2, String>) -> {Ops.mail_changes(Ops.unsubscribe_old(moved)) == [] : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case Con{name, t}:
      %unsubscribe_old_changes_no_mail(t) : {Ops.mail_changes(Ops.unsubscribe_old(t)) == _ : List<&2, I.Cmd>}
      {==}

def subscribe_moved_changes_no_mail(from: String, to: String, moved: List<&2, String>, rest: List<&2, I.Cmd>) -> {Ops.mail_changes(Ops.subscribe_moved(from, to, moved, rest)) == Ops.mail_changes(rest) : List<&2, I.Cmd>}:
  match moved:
    case Nil{}:
      {==}
    case Con{name, t}:
      %subscribe_moved_changes_no_mail(from, to, t, rest) : {Ops.mail_changes(Ops.subscribe_moved(from, to, t, rest)) == _ : List<&2, I.Cmd>}
      {==}

def unsubscribe_old_expunges_nothing(moved: List<&2, String>) -> {I.any_expunges(Ops.unsubscribe_old(moved)) == False{} : Bool}:
  match moved:
    case Nil{}:
      {==}
    case Con{name, t}:
      %unsubscribe_old_expunges_nothing(t) : {I.any_expunges(Ops.unsubscribe_old(t)) == _ : Bool}
      {==}

def subscribe_moved_expunges_nothing(from: String, to: String, moved: List<&2, String>, rest: List<&2, I.Cmd>) -> {I.any_expunges(Ops.subscribe_moved(from, to, moved, rest)) == I.any_expunges(rest) : Bool}:
  match moved:
    case Nil{}:
      {==}
    case Con{name, t}:
      %subscribe_moved_expunges_nothing(from, to, t, rest) : {I.any_expunges(Ops.subscribe_moved(from, to, t, rest)) == _ : Bool}
      {==}

def rename_changes_exactly(+from: String, +to: String, +moved: List<&2, String>) -> {Ops.mailbox_changes(Ops.plan_rename(from, to, moved)) == Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))} : List<&2, I.Cmd>}:
  %subscribe_moved_changes_only_folders(from, to, moved, Ops.unsubscribe_old(moved)) : {Con{I.CRename{from, to}, _} == Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))} : List<&2, I.Cmd>}
  %unsubscribe_old_changes_only_folders(moved) : {Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, moved, _)} == Con{I.CRename{from, to}, Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))} : List<&2, I.Cmd>}
  {==}

def Laws.rename_changes_exactly(from, to, moved):
  rename_changes_exactly(from, to, moved)

def Laws.rename_subscribes_each_moved_folder(from, to, name, moved, rest):
  {==}

def Laws.rename_unsubscribes_each_moved_folder(name, moved):
  {==}

def Laws.rename_subscribes_before_unsubscribing(from, to, moved):
  {==}

def rename_changes_no_mail(+from: String, +to: String, +moved: List<&2, String>) -> {Ops.mail_changes(Ops.plan_rename(from, to, moved)) == [] : List<&2, I.Cmd>}:
  Equal.trans(List<&2, I.Cmd>, Ops.mail_changes(Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))), Ops.mail_changes(Ops.unsubscribe_old(moved)), [], subscribe_moved_changes_no_mail(from, to, moved, Ops.unsubscribe_old(moved)), unsubscribe_old_changes_no_mail(moved))

def Laws.rename_changes_no_mail(from, to, moved):
  rename_changes_no_mail(from, to, moved)

def folder_plans_destroy_nothing(mbox: String, +from: String, +to: String, +moved: List<&2, String>) -> {Bool.or(I.any_expunges(Ops.plan_create(mbox)), I.any_expunges(Ops.plan_rename(from, to, moved))) == False{} : Bool}:
  Equal.trans(Bool, I.any_expunges(Ops.subscribe_moved(from, to, moved, Ops.unsubscribe_old(moved))), I.any_expunges(Ops.unsubscribe_old(moved)), False{}, subscribe_moved_expunges_nothing(from, to, moved, Ops.unsubscribe_old(moved)), unsubscribe_old_expunges_nothing(moved))

def Laws.folder_plans_destroy_nothing(mbox, from, to, moved):
  folder_plans_destroy_nothing(mbox, from, to, moved)

def Laws.folder_scan_writes_nothing():
  {==}

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
