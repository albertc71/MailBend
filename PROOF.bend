# MailBend: the proofs of LAWS.bend, in its order and under its section
# names. Most laws hold by computation ({==}): a plan's structure decides
# its classifiers whatever the mailbox names, UIDs or keys. Where a plan
# branches on a Bool or a fetch item, the proof matches that parameter so
# each branch computes. A plan that branches on a computed value gets a
# lemma taking that value as a parameter, named after its law: `.if` for a
# computed Bool, `.put` for computed colour bits. Lemma parameters that
# only appear in the goal are erased.

import Base
import ./LAWS.bend as Laws
import ./src/json.bend as J
import ./src/imap.bend as I
import ./src/jev.bend as Jev
import ./src/secrets.bend as Secrets
import ./src/ops.bend as Ops
import ./src/smtp.bend as S

# Tool classes
# ------------

def Laws.read_is_read_only():
  {==}

def Laws.search_is_read_only():
  {==}

def Laws.delete_is_not_read_only():
  {==}

def Laws.download_is_not_read_only():
  {==}

def Laws.trash_is_not_destructive():
  {==}

def Laws.read_only_tools_are_exactly_seven():
  {==}

def Laws.tools_listed_per_config(drafts):
  match drafts:
    case True{}:
      ({==}, {==}, {==}, {==}, {==}, {==})
    case False{}:
      ({==}, {==}, {==}, {==}, {==}, {==})

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
  -> {I.any_writes(Ops.plan_new.if(at_end, mbox, since)) == False{} : Bool}:
  match at_end:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.get_new_writes_nothing(mbox, since):
  get_new_writes_nothing.if(U32.is_eq(since, Ops.max_uid()), mbox, since)

# The thread plans are lists over folders and keys, so their law rests on
# lemmas by induction over those lists: the searches add no write to what
# follows them, so neither plan writes anything.

def thread_searches_add_no_write(keys: List<&2, I.Key>, -rest: List<&2, I.Cmd>)
  -> {I.any_writes(Ops.thread_searches(keys, rest)) == I.any_writes(rest) : Bool}:
  match keys:
    case Nil{}:
      {==}
    case k <> t:
      thread_searches_add_no_write(t, rest)

def thread_search_writes_nothing(folders: List<&2, String>, +keys: List<&2, I.Key>)
  -> {I.any_writes(Ops.plan_thread_search(folders, keys)) == False{} : Bool}:
  match folders:
    case Nil{}:
      {==}
    case mbox <> t:
      Equal.trans(Bool,
        I.any_writes(Ops.thread_searches(keys, Ops.plan_thread_search(t, keys))),
        I.any_writes(Ops.plan_thread_search(t, keys)),
        False{},
        thread_searches_add_no_write(keys, Ops.plan_thread_search(t, keys)),
        thread_search_writes_nothing(t, keys))

def thread_headers_write_nothing(found: List<&2, Ops.FolderUids>)
  -> {I.any_writes(Ops.plan_thread_headers(found)) == False{} : Bool}:
  match found:
    case Nil{}:
      {==}
    case Ops.FolderUids{mbox, uids} <> t:
      thread_headers_write_nothing(t)

def Laws.thread_plans_write_nothing(folders, keys, found):
  %Equal.sym(Bool, I.any_writes(Ops.plan_thread_search(folders, keys)), False{},
    thread_search_writes_nothing(folders, keys)) :
    {Bool.or(_, I.any_writes(Ops.plan_thread_headers(found))) == False{} : Bool}
  thread_headers_write_nothing(found)

def Laws.sent_search_writes_nothing(sent, addrs):
  thread_search_writes_nothing([sent], Ops.sent_keys(addrs))

def Laws.reread_flags_writes_nothing(mbox, uids):
  {==}

def Laws.classify_writes_nothing(mbox, uids, body, max):
  match body:
    case True{}:
      {==}
    case False{}:
      {==}

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
    case I.IStructure{}:
      {==}
    case I.IFull{max}:
      {==}

# Marking and flagging
# --------------------

# A flag law with a colour goes through a .put lemma that matches the
# colour's bits, I.colour_bits(c), as a parameter: plan_flag_bits builds
# one store from each bit.

def Laws.mark_never_deletes(mbox, uids, seen, uidv):
  match seen:
    case True{}:
      {==}
    case False{}:
      {==}

def flag_never_deletes.put(
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
      (flag_never_deletes.put(mbox, uids, I.colour_bits(c), uidv), {==})

def flag_changes_only_flag_and_colour.put(
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
      (flag_changes_only_flag_and_colour.put(mbox, uids, I.colour_bits(c), uidv), {==})

# e names the bits: rewrite them to that literal, then compute
def flag_changes_exactly.put(
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
   e => flag_changes_exactly.put(mbox, uids, I.colour_bits(colour), b0, b1, b2, uidv, e))

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
  -> {Ops.expunged(Ops.plan_delete.if(confirm, mbox, uids, uidplus, uidv)) ==
       Ops.marked_deleted(Ops.plan_delete.if(confirm, mbox, uids, uidplus, uidv))
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
    {Ops.plan_delete.if(_, mbox, uids, uidplus, uidv) == [] : List<&2, I.Cmd>}
  {==}

def delete_checks_uidplus.if(
  confirm: Bool, -mbox: String, -uids: List<&2, U32>, uidplus: Bool, -uidv: U32)
  -> {Ops.checks_uidplus_or_empty(Ops.plan_delete.if(confirm, mbox, uids, uidplus, uidv)) ==
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
  -> {Ops.pinned_or_empty(Ops.plan_delete.if(confirm, mbox, uids, uidplus, uidv)) ==
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
         Ops.plan_delete.if(confirm, mbox, uids, uidplus, uidv), I.uidv_line(uidv)) ==
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

# Sending
# -------

# outbound branches on S.all_allowed, which walks the recipients: a lemma
# shows by induction over the recipients before the unlisted one that it is
# False there (and True for every recipient without an allowlist), and the
# law rewrites the verdict to that.

def and_false(b: Bool) -> {Bool.and(b, False{}) == False{} : Bool}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def all_allowed_refuses(
  +allow: List<&2, String>, before: List<&2, String>, -rcpt: String,
  -after: List<&2, String>, unlisted: {S.allowed(allow, rcpt) == False{} : Bool})
  -> {S.all_allowed(allow, List.append(&2, String, before, Con{rcpt, after})) ==
       False{} : Bool}:
  match before:
    case Nil{}:
      %Equal.sym(Bool, S.allowed(allow, rcpt), False{}, unlisted) :
        {Bool.and(_, S.all_allowed(allow, after)) == False{} : Bool}
      {==}
    case b <> bs:
      %Equal.sym(Bool,
        S.all_allowed(allow, List.append(&2, String, bs, Con{rcpt, after})), False{},
        all_allowed_refuses(allow, bs, rcpt, after, unlisted)) :
        {Bool.and(S.allowed(allow, b), _) == False{} : Bool}
      and_false(S.allowed(allow, b))

def all_allowed_without_allowlist(rcpts: List<&2, String>)
  -> {S.all_allowed([], rcpts) == True{} : Bool}:
  match rcpts:
    case Nil{}:
      {==}
    case rcpt <> rest:
      %Equal.sym(Bool, S.all_allowed([], rest), True{}, all_allowed_without_allowlist(rest)) :
        {_ == True{} : Bool}
      {==}

def Laws.allowlist_refuses_unlisted(allow, before, rcpt, after, from, msg, unlisted):
  +a = allow
  +bs = before
  +r = rcpt
  +rs = after
  %Equal.sym(Bool, S.all_allowed(a, List.append(&2, String, bs, Con{r, rs})), False{},
    all_allowed_refuses(a, bs, r, rs, unlisted)) :
    {S.outbound.if(_, List.append(&2, String, bs, Con{r, rs}), from, msg) ==
      None{} : Maybe<&2, String>}
  {==}

def Laws.no_allowlist_is_unchanged(rcpts, from, msg):
  +rs = rcpts
  %Equal.sym(Bool, S.all_allowed([], rs), True{}, all_allowed_without_allowlist(rs)) :
    {S.outbound.if(_, rs, from, msg) == Some{S.envelope(from, rs, msg)}
      : Maybe<&2, String>}
  {==}

def Laws.sent_copy_only_appends(sent, msg):
  ({==}, {==})

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

# Triage
# ------

# A triage plan is the move plans of its moves, or none when the plan's
# own check of the moves fails: each law goes through a .if lemma that
# takes that check's verdict, `ok`, and (where the law needs what the check
# found) `e`, the verdict's equation. The laws state their promises on their
# own, so a lemma derives each from the check, part by part. The move plans
# are a list over the moves, so the lemmas about them go by induction over
# it, using a fact about one plan_move at each step. A failed premise
# True == False is refuted through a motive that sends True to Unit and
# False to Empty.

def bool_motive(b: Bool) -> Type:
  match b:
    case True{}:
      Unit
    case False{}:
      Empty

def true_is_not_false(e: {True{} == False{} : Bool}) -> Empty:
  %e : bool_motive(_)
  Unit{}

def and_left(a: Bool, -b: Bool, e: {Bool.and(a, b) == True{} : Bool}) -> {a == True{} : Bool}:
  match a:
    case True{}:
      {==}
    case False{}:
      Empty.absurd({False{} == True{} : Bool},
        true_is_not_false(Equal.sym(Bool, False{}, True{}, e)))

def and_right(a: Bool, -b: Bool, e: {Bool.and(a, b) == True{} : Bool}) -> {b == True{} : Bool}:
  match a:
    case True{}:
      e
    case False{}:
      Empty.absurd({b == True{} : Bool}, true_is_not_false(Equal.sym(Bool, False{}, True{}, e)))

def or_false_left(a: Bool, -b: Bool, e: {Bool.or(a, b) == False{} : Bool}) -> {a == False{} : Bool}:
  match a:
    case True{}:
      Empty.absurd({True{} == False{} : Bool}, true_is_not_false(e))
    case False{}:
      {==}

def or_false_right(a: Bool, -b: Bool, e: {Bool.or(a, b) == False{} : Bool})
  -> {b == False{} : Bool}:
  match a:
    case True{}:
      Empty.absurd({b == False{} : Bool}, true_is_not_false(e))
    case False{}:
      e

def not_true(b: Bool, e: {Bool.not(b) == True{} : Bool}) -> {b == False{} : Bool}:
  match b:
    case True{}:
      Empty.absurd({True{} == False{} : Bool},
        true_is_not_false(Equal.sym(Bool, False{}, True{}, e)))
    case False{}:
      {==}

# The guard's verdict on the moves.
def triage_ok(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  +ms: List<&2, Ops.FolderUids>
) -> Bool:
  Ops.dests_ok(mbox, cats, reserved, ms) && Bool.not(Ops.repeats(Ops.uids_per_move(ms)))

# The folders the moves go into, in order.
def move_dests(ms: List<&2, Ops.FolderUids>) -> List<&2, String>:
  match ms:
    case Nil{}:
      []
    case Ops.FolderUids{dest, uids} <> t:
      dest <> move_dests(t)

# With MOVE, or by copy with UIDPLUS, the plans move or copy into the
# moves' folders, in order; with neither there are no plans to do so.
def dests_by_move(-mbox: String, ms: List<&2, Ops.FolderUids>, -uidplus: Bool, -uidv: U32)
  -> {Ops.plans_dests(Ops.move_plans(mbox, ms, True{}, uidplus, uidv)) == move_dests(ms)
       : List<&2, String>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      %dests_by_move(mbox, t, uidplus, uidv) :
        {Con{dest, Ops.plans_dests(Ops.move_plans(mbox, t, True{}, uidplus, uidv))} ==
          Con{dest, _} : List<&2, String>}
      {==}

def dests_by_copy(-mbox: String, ms: List<&2, Ops.FolderUids>, -uidv: U32)
  -> {Ops.plans_dests(Ops.move_plans(mbox, ms, False{}, True{}, uidv)) == move_dests(ms)
       : List<&2, String>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      %dests_by_copy(mbox, t, uidv) :
        {Con{dest, Ops.plans_dests(Ops.move_plans(mbox, t, False{}, True{}, uidv))} ==
          Con{dest, _} : List<&2, String>}
      {==}

def dests_by_none(-mbox: String, ms: List<&2, Ops.FolderUids>, -uidv: U32)
  -> {Ops.plans_dests(Ops.move_plans(mbox, ms, False{}, False{}, uidv)) == []
       : List<&2, String>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      dests_by_none(mbox, t, uidv)

# The parts of the check of one destination.
def unreserved(+reserved: List<&2, String>, +dest: String) -> Bool:
  Bool.not(Ops.named_in("INBOX" <> reserved, dest))

def offered(+cats: List<&2, String>, +dest: String) -> Bool:
  String.eq(dest, Ops.review_folder()) || List.contains(~String, ~String.eq, cats, dest)

def dest_not_source(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>, +dest: String,
  e: {Ops.triage_dest(mbox, cats, reserved, dest) == True{} : Bool})
  -> {Bool.not(I.same_name(dest, mbox)) == True{} : Bool}:
  and_left(Bool.not(I.same_name(dest, mbox)),
    Bool.and(unreserved(reserved, dest), offered(cats, dest)), e)

def dest_unreserved(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>, +dest: String,
  e: {Ops.triage_dest(mbox, cats, reserved, dest) == True{} : Bool})
  -> {unreserved(reserved, dest) == True{} : Bool}:
  and_left(unreserved(reserved, dest), offered(cats, dest),
    and_right(Bool.not(I.same_name(dest, mbox)),
      Bool.and(unreserved(reserved, dest), offered(cats, dest)), e))

def dest_offered(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>, +dest: String,
  e: {Ops.triage_dest(mbox, cats, reserved, dest) == True{} : Bool})
  -> {offered(cats, dest) == True{} : Bool}:
  and_right(unreserved(reserved, dest), offered(cats, dest),
    and_right(Bool.not(I.same_name(dest, mbox)),
      Bool.and(unreserved(reserved, dest), offered(cats, dest)), e))

# The laws compare names on their own; these tie them to the check's.
def contains_named(names: List<&2, String>, +d: String)
  -> {Ops.named_in(names, d) == List.contains(~String, ~Ops.lower_eq, names, d) : Bool}:
  match names:
    case Nil{}:
      {==}
    case n <> t:
      %contains_named(t, d) :
        {Ops.named_in(n <> t, d) == Bool.or(Ops.lower_eq(n, d), _) : Bool}
      {==}

def not_same_not_eq(+a: String, +b: String, e: {Bool.not(I.same_name(a, b)) == True{} : Bool})
  -> {Bool.not(String.eq(a, b)) == True{} : Bool}:
  %Equal.sym(Bool, String.eq(a, b), False{}, or_false_left(String.eq(a, b),
    String.eq(String.to_upper(a), "INBOX") && String.eq(String.to_upper(b), "INBOX"),
    not_true(I.same_name(a, b), e))) :
    {Bool.not(_) == True{} : Bool}
  {==}

# Each part, for every move the check passed.
def offered_moves(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  ms: List<&2, Ops.FolderUids>,
  +e: {Ops.dests_ok(mbox, cats, reserved, ms) == True{} : Bool})
  -> {Ops.all_offered(cats, move_dests(ms)) == True{} : Bool}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{+dest, uids} <> +t:
      %Equal.sym(Bool, offered(cats, dest), True{},
        dest_offered(mbox, cats, reserved, dest,
          and_left(Ops.triage_dest(mbox, cats, reserved, dest),
            Ops.dests_ok(mbox, cats, reserved, t), e))) :
        {Bool.and(_, Ops.all_offered(cats, move_dests(t))) == True{} : Bool}
      offered_moves(mbox, cats, reserved, t,
        and_right(Ops.triage_dest(mbox, cats, reserved, dest),
          Ops.dests_ok(mbox, cats, reserved, t), e))

def unreserved_moves(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  ms: List<&2, Ops.FolderUids>,
  +e: {Ops.dests_ok(mbox, cats, reserved, ms) == True{} : Bool})
  -> {Ops.none_named("INBOX" <> reserved, move_dests(ms)) == True{} : Bool}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{+dest, uids} <> +t:
      %contains_named("INBOX" <> reserved, dest) :
        {Bool.and(Bool.not(_), Ops.none_named("INBOX" <> reserved, move_dests(t))) == True{}
          : Bool}
      %Equal.sym(Bool, unreserved(reserved, dest), True{},
        dest_unreserved(mbox, cats, reserved, dest,
          and_left(Ops.triage_dest(mbox, cats, reserved, dest),
            Ops.dests_ok(mbox, cats, reserved, t), e))) :
        {Bool.and(_, Ops.none_named("INBOX" <> reserved, move_dests(t))) == True{} : Bool}
      unreserved_moves(mbox, cats, reserved, t,
        and_right(Ops.triage_dest(mbox, cats, reserved, dest),
          Ops.dests_ok(mbox, cats, reserved, t), e))

def not_source_moves(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  ms: List<&2, Ops.FolderUids>,
  +e: {Ops.dests_ok(mbox, cats, reserved, ms) == True{} : Bool})
  -> {Ops.none_same(mbox, move_dests(ms)) == True{} : Bool}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{+dest, uids} <> +t:
      %Equal.sym(Bool, Bool.not(String.eq(dest, mbox)), True{},
        not_same_not_eq(dest, mbox, dest_not_source(mbox, cats, reserved, dest,
          and_left(Ops.triage_dest(mbox, cats, reserved, dest),
            Ops.dests_ok(mbox, cats, reserved, t), e)))) :
        {Bool.and(_, Ops.none_same(mbox, move_dests(t))) == True{} : Bool}
      not_source_moves(mbox, cats, reserved, t,
        and_right(Ops.triage_dest(mbox, cats, reserved, dest),
          Ops.dests_ok(mbox, cats, reserved, t), e))

# What triage_moves_only_to_known_folders says of the folders `ds`.
def known(+mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  +ds: List<&2, String>) -> Type:
  ({Ops.all_offered(cats, ds) == True{} : Bool} &
   {Ops.none_named("INBOX" <> reserved, ds) == True{} : Bool} &
   {Ops.none_same(mbox, ds) == True{} : Bool})

def known_dests(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  +ms: List<&2, Ops.FolderUids>,
  +e: {Ops.dests_ok(mbox, cats, reserved, ms) == True{} : Bool})
  -> known(mbox, cats, reserved, move_dests(ms)):
  (offered_moves(mbox, cats, reserved, ms, e), unreserved_moves(mbox, cats, reserved, ms, e),
   not_source_moves(mbox, cats, reserved, ms, e))

def known_plans(
  +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  +ms: List<&2, Ops.FolderUids>, move: Bool, uidplus: Bool, +uidv: U32,
  e: {Ops.dests_ok(mbox, cats, reserved, ms) == True{} : Bool})
  -> known(mbox, cats, reserved, Ops.plans_dests(Ops.move_plans(mbox, ms, move, uidplus, uidv))):
  match move:
    case True{}:
      %Equal.sym(List<&2, String>,
        Ops.plans_dests(Ops.move_plans(mbox, ms, True{}, uidplus, uidv)), move_dests(ms),
        dests_by_move(mbox, ms, uidplus, uidv)) :
        known(mbox, cats, reserved, _)
      known_dests(mbox, cats, reserved, ms, e)
    case False{}:
      match uidplus:
        case True{}:
          %Equal.sym(List<&2, String>,
            Ops.plans_dests(Ops.move_plans(mbox, ms, False{}, True{}, uidv)), move_dests(ms),
            dests_by_copy(mbox, ms, uidv)) :
            known(mbox, cats, reserved, _)
          known_dests(mbox, cats, reserved, ms, e)
        case False{}:
          %Equal.sym(List<&2, String>,
            Ops.plans_dests(Ops.move_plans(mbox, ms, False{}, False{}, uidv)), [],
            dests_by_none(mbox, ms, uidv)) :
            known(mbox, cats, reserved, _)
          ({==}, {==}, {==})

def triage_moves_only_to_known_folders.if(
  ok: Bool, +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  +ms: List<&2, Ops.FolderUids>, move: Bool, uidplus: Bool, uidv: U32,
  e: {triage_ok(mbox, cats, reserved, ms) == ok : Bool})
  -> known(mbox, cats, reserved,
       Ops.plans_dests(Ops.plan_triage.if(ok, mbox, ms, move, uidplus, uidv))):
  match ok:
    case True{}:
      known_plans(mbox, cats, reserved, ms, move, uidplus, uidv,
        and_left(Ops.dests_ok(mbox, cats, reserved, ms),
          Bool.not(Ops.repeats(Ops.uids_per_move(ms))), e))
    case False{}:
      ({==}, {==}, {==})

def Laws.triage_moves_only_to_known_folders(mbox, cats, reserved, ms, move, uidplus, uidv):
  +m = mbox
  +cs = cats
  +rs = reserved
  +xs = ms
  triage_moves_only_to_known_folders.if(triage_ok(m, cs, rs, xs), m, cs, rs, xs, move, uidplus,
    uidv, {==})

def move_plans_change_no_mailbox(
  +mbox: String, ms: List<&2, Ops.FolderUids>, +move: Bool, +uidplus: Bool, +uidv: U32)
  -> {Ops.plans_mailbox_changes(Ops.move_plans(mbox, ms, move, uidplus, uidv)) == []
       : List<&2, I.Cmd>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      %Equal.sym(List<&2, I.Cmd>,
        Ops.mailbox_changes(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)), [],
        Laws.label_creates_no_folder(mbox, uids, dest, move, uidplus, uidv)) :
        {List.append(&2, I.Cmd, _,
          Ops.plans_mailbox_changes(Ops.move_plans(mbox, t, move, uidplus, uidv))) == []
          : List<&2, I.Cmd>}
      move_plans_change_no_mailbox(mbox, t, move, uidplus, uidv)

def triage_creates_no_mailbox.if(
  ok: Bool, mbox: String, ms: List<&2, Ops.FolderUids>, move: Bool, uidplus: Bool, uidv: U32)
  -> {Ops.plans_mailbox_changes(Ops.plan_triage.if(ok, mbox, ms, move, uidplus, uidv)) == []
       : List<&2, I.Cmd>}:
  match ok:
    case True{}:
      move_plans_change_no_mailbox(mbox, ms, move, uidplus, uidv)
    case False{}:
      {==}

def Laws.triage_creates_no_mailbox(mbox, cats, reserved, ms, move, uidplus, uidv):
  +m = mbox
  +xs = ms
  triage_creates_no_mailbox.if(triage_ok(m, cats, reserved, xs), m, xs, move, uidplus, uidv)

# With MOVE, or by copy with UIDPLUS, the plans move exactly the UIDs of the
# moves, in order; with neither there are no plans to move anything.
def moved_by_move(
  -mbox: String, ms: List<&2, Ops.FolderUids>, -uidplus: Bool, -uidv: U32)
  -> {Ops.plans_moved_uids(Ops.move_plans(mbox, ms, True{}, uidplus, uidv)) ==
       Ops.uids_per_move(ms) : List<&2, List<&2, U32>>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      %moved_by_move(mbox, t, uidplus, uidv) :
        {Con{uids, Ops.plans_moved_uids(Ops.move_plans(mbox, t, True{}, uidplus, uidv))} ==
          Con{uids, _} : List<&2, List<&2, U32>>}
      {==}

def moved_by_copy(-mbox: String, ms: List<&2, Ops.FolderUids>, -uidv: U32)
  -> {Ops.plans_moved_uids(Ops.move_plans(mbox, ms, False{}, True{}, uidv)) ==
       Ops.uids_per_move(ms) : List<&2, List<&2, U32>>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      %moved_by_copy(mbox, t, uidv) :
        {Con{uids, Ops.plans_moved_uids(Ops.move_plans(mbox, t, False{}, True{}, uidv))} ==
          Con{uids, _} : List<&2, List<&2, U32>>}
      {==}

def moved_by_none(-mbox: String, ms: List<&2, Ops.FolderUids>, -uidv: U32)
  -> {Ops.plans_moved_uids(Ops.move_plans(mbox, ms, False{}, False{}, uidv)) == []
       : List<&2, List<&2, U32>>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      moved_by_none(mbox, t, uidv)

# UIDs the check found unrepeated are distinct, UID by UID.
def distinct_if_unrepeated(xs: List<&2, U32>, +e: {Ops.repeated(xs) == False{} : Bool})
  -> {Ops.distinct(xs) == True{} : Bool}:
  match xs:
    case Nil{}:
      {==}
    case +x <> +t:
      %Equal.sym(Bool, List.contains(~U32, ~U32.is_eq, t, x), False{},
        or_false_left(List.contains(~U32, ~U32.is_eq, t, x), Ops.repeated(t), e)) :
        {Bool.and(Bool.not(_), Ops.distinct(t)) == True{} : Bool}
      distinct_if_unrepeated(t,
        or_false_right(List.contains(~U32, ~U32.is_eq, t, x), Ops.repeated(t), e))

def moves_are_distinct(
  -mbox: String, +ms: List<&2, Ops.FolderUids>, move: Bool, uidplus: Bool, -uidv: U32,
  r: {Ops.repeats(Ops.uids_per_move(ms)) == False{} : Bool})
  -> {Ops.distinct(List.concat(&2, U32,
       Ops.plans_moved_uids(Ops.move_plans(mbox, ms, move, uidplus, uidv)))) == True{} : Bool}:
  match move:
    case True{}:
      %Equal.sym(List<&2, List<&2, U32>>,
        Ops.plans_moved_uids(Ops.move_plans(mbox, ms, True{}, uidplus, uidv)),
        Ops.uids_per_move(ms), moved_by_move(mbox, ms, uidplus, uidv)) :
        {Ops.distinct(List.concat(&2, U32, _)) == True{} : Bool}
      distinct_if_unrepeated(List.concat(&2, U32, Ops.uids_per_move(ms)), r)
    case False{}:
      match uidplus:
        case True{}:
          %Equal.sym(List<&2, List<&2, U32>>,
            Ops.plans_moved_uids(Ops.move_plans(mbox, ms, False{}, True{}, uidv)),
            Ops.uids_per_move(ms), moved_by_copy(mbox, ms, uidv)) :
            {Ops.distinct(List.concat(&2, U32, _)) == True{} : Bool}
          distinct_if_unrepeated(List.concat(&2, U32, Ops.uids_per_move(ms)), r)
        case False{}:
          %Equal.sym(List<&2, List<&2, U32>>,
            Ops.plans_moved_uids(Ops.move_plans(mbox, ms, False{}, False{}, uidv)), [],
            moved_by_none(mbox, ms, uidv)) :
            {Ops.distinct(List.concat(&2, U32, _)) == True{} : Bool}
          {==}

def triage_one_move_per_message.if(
  ok: Bool, +mbox: String, +cats: List<&2, String>, +reserved: List<&2, String>,
  +ms: List<&2, Ops.FolderUids>, move: Bool, uidplus: Bool, uidv: U32,
  e: {triage_ok(mbox, cats, reserved, ms) == ok : Bool})
  -> {Ops.distinct(List.concat(&2, U32,
       Ops.plans_moved_uids(Ops.plan_triage.if(ok, mbox, ms, move, uidplus, uidv)))) ==
       True{} : Bool}:
  match ok:
    case True{}:
      +unique = Bool.not(Ops.repeats(Ops.uids_per_move(ms)))
      moves_are_distinct(mbox, ms, move, uidplus, uidv,
        not_true(Ops.repeats(Ops.uids_per_move(ms)),
          and_right(Ops.dests_ok(mbox, cats, reserved, ms), unique, e)))
    case False{}:
      {==}

def Laws.triage_one_move_per_message(mbox, cats, reserved, ms, move, uidplus, uidv):
  +m = mbox
  +cs = cats
  +rs = reserved
  +xs = ms
  triage_one_move_per_message.if(triage_ok(m, cs, rs, xs), m, cs, rs, xs, move, uidplus, uidv,
    {==})

# one move plan's UID EXPUNGEs and UID COPYs, by computation
def move_expunges_copied(
  -mbox: String, -uids: List<&2, U32>, -dest: String, move: Bool, uidplus: Bool, -uidv: U32)
  -> {Ops.expunged_uids(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)) ==
       Ops.copied_uids(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv))
       : List<&2, List<&2, U32>>}:
  match move:
    case True{}:
      {==}
    case False{}:
      match uidplus:
        case True{}:
          {==}
        case False{}:
          {==}

def move_plans_expunge_copied(
  -mbox: String, ms: List<&2, Ops.FolderUids>, +move: Bool, +uidplus: Bool, -uidv: U32)
  -> {Ops.plans_expunged(Ops.move_plans(mbox, ms, move, uidplus, uidv)) ==
       Ops.plans_copied(Ops.move_plans(mbox, ms, move, uidplus, uidv))
       : List<&2, List<&2, List<&2, U32>>>}:
  match ms:
    case Nil{}:
      {==}
    case Ops.FolderUids{dest, uids} <> t:
      %move_expunges_copied(mbox, uids, dest, move, uidplus, uidv) :
        {Con{Ops.expunged_uids(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)),
            Ops.plans_expunged(Ops.move_plans(mbox, t, move, uidplus, uidv))} ==
          Con{_, Ops.plans_copied(Ops.move_plans(mbox, t, move, uidplus, uidv))}
          : List<&2, List<&2, List<&2, U32>>>}
      %move_plans_expunge_copied(mbox, t, move, uidplus, uidv) :
        {Con{Ops.expunged_uids(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)),
            Ops.plans_expunged(Ops.move_plans(mbox, t, move, uidplus, uidv))} ==
          Con{Ops.expunged_uids(Ops.plan_move(mbox, uids, dest, move, uidplus, uidv)), _}
          : List<&2, List<&2, List<&2, U32>>>}
      {==}

def triage_expunges_only_moved.if(
  ok: Bool, -mbox: String, ms: List<&2, Ops.FolderUids>, move: Bool, uidplus: Bool, -uidv: U32)
  -> {Ops.plans_expunged(Ops.plan_triage.if(ok, mbox, ms, move, uidplus, uidv)) ==
       Ops.plans_copied(Ops.plan_triage.if(ok, mbox, ms, move, uidplus, uidv))
       : List<&2, List<&2, List<&2, U32>>>}:
  match ok:
    case True{}:
      move_plans_expunge_copied(mbox, ms, move, uidplus, uidv)
    case False{}:
      {==}

def Laws.triage_expunges_only_moved(mbox, cats, reserved, ms, move, uidplus, uidv):
  +m = mbox
  +xs = ms
  triage_expunges_only_moved.if(triage_ok(m, cats, reserved, xs), m, xs, move, uidplus, uidv)

# filing a message that is not safe to delete, case by case over its verdict
def unsafe_filing_matches_table(
  v: Jev.Verdict, unsafe: {Jev.is_safe(v) == False{} : Bool}, -folder: String)
  -> ({Jev.filing(v, Jev.Filed{folder}) == Ops.ToFolder{folder} : Ops.Action} &
      {Jev.filing(v, Jev.Proposed{folder}) == Ops.Stay{} : Ops.Action} &
      {Jev.filing(v, Jev.NeedsNew{}) == Ops.Stay{} : Ops.Action} &
      {Jev.filing(v, Jev.Uncategorised{}) == Ops.Stay{} : Ops.Action}):
  match v:
    case Jev.SafeToDelete{}:
      Empty.absurd(
        ({Jev.filing(Jev.SafeToDelete{}, Jev.Filed{folder}) == Ops.ToFolder{folder}
            : Ops.Action} &
         {Jev.filing(Jev.SafeToDelete{}, Jev.Proposed{folder}) == Ops.Stay{} : Ops.Action} &
         {Jev.filing(Jev.SafeToDelete{}, Jev.NeedsNew{}) == Ops.Stay{} : Ops.Action} &
         {Jev.filing(Jev.SafeToDelete{}, Jev.Uncategorised{}) == Ops.Stay{} : Ops.Action}),
        true_is_not_false(unsafe))
    case Jev.Keep{}:
      ({==}, {==}, {==}, {==})
    case Jev.Review{}:
      ({==}, {==}, {==}, {==})
    case Jev.Unanswered{}:
      ({==}, {==}, {==}, {==})

def Laws.filing_matches_table(cat, v, unsafe, folder):
  ({==}, unsafe_filing_matches_table(v, unsafe, folder))

# A message that stays is in no plan: it has no move, and no moves pass the
# check, which leaves no plan.
def stays_unplanned(
  -mbox: String, -cats: List<&2, String>, -reserved: List<&2, String>, -uid: U32, -move: Bool,
  -uidplus: Bool, -uidv: U32)
  -> {Ops.plan_triage(mbox, cats, reserved,
       Ops.triage_moves(mbox, [Ops.Placement{uid, Ops.Stay{}}]), move, uidplus, uidv) == []
       : List<&2, List<&2, I.Cmd>>}:
  {==}

# A message whose action `act` is Stay is in no plan.
def stay_unplanned(
  -mbox: String, -cats: List<&2, String>, -reserved: List<&2, String>, -uid: U32,
  -act: Ops.Action, e: {act == Ops.Stay{} : Ops.Action}, -move: Bool, -uidplus: Bool,
  -uidv: U32)
  -> {Ops.plan_triage(mbox, cats, reserved,
       Ops.triage_moves(mbox, [Ops.Placement{uid, act}]), move, uidplus, uidv) == []
       : List<&2, List<&2, I.Cmd>>}:
  %Equal.sym(Ops.Action, act, Ops.Stay{}, e) :
    {Ops.plan_triage(mbox, cats, reserved, Ops.triage_moves(mbox, [Ops.Placement{uid, _}]),
      move, uidplus, uidv) == [] : List<&2, List<&2, I.Cmd>>}
  stays_unplanned(mbox, cats, reserved, uid, move, uidplus, uidv)

# A category below High confidence, or none, files nothing: case by case
# over the verdict, then the confidence.
def unsure_files_nothing(
  v: Jev.Verdict, unsafe: {Jev.is_safe(v) == False{} : Bool}, -cat: Jev.Category,
  e: {Jev.filed(cat) == Ops.Stay{} : Ops.Action})
  -> {Jev.filing(v, cat) == Ops.Stay{} : Ops.Action}:
  match v:
    case Jev.SafeToDelete{}:
      Empty.absurd({Ops.ToReview{} == Ops.Stay{} : Ops.Action}, true_is_not_false(unsafe))
    case Jev.Keep{}:
      e
    case Jev.Review{}:
      e
    case Jev.Unanswered{}:
      e

def unsure_is_unfiled(
  -key: String, conf: Jev.Band, unsure: {Jev.is_high(conf) == False{} : Bool},
  -candidates: List<&2, String>, -none: String)
  -> {Jev.filed(Jev.category_of(Jev.Picked{key, conf}, candidates, none)) == Ops.Stay{}
       : Ops.Action}:
  match conf:
    case Jev.Low{}:
      {==}
    case Jev.Mid{}:
      {==}
    case Jev.High{}:
      Empty.absurd(
        {Jev.filed(Jev.category_of(Jev.Picked{key, Jev.High{}}, candidates, none)) == Ops.Stay{}
          : Ops.Action},
        true_is_not_false(unsure))
    case Jev.Missing{}:
      {==}

# With every answer missing, a code veto keeps the message and otherwise it
# is Unanswered; either way it has no category, so it stays.
def missing_stays(
  -c: Jev.Content, -whole: Jev.Completeness, vetoes: List<&2, String>, -uid: U32,
  -keys: List<&2, String>, -candidates: List<&2, String>, -none: String)
  -> {Jev.filing(Jev.verdict(c, whole, vetoes, Jev.answers_for(J.JNull{}, uid, keys)),
       Jev.category_of(Jev.answers_category(Jev.answers_for(J.JNull{}, uid, keys)),
         candidates, none)) == Ops.Stay{} : Ops.Action}:
  match vetoes:
    case Nil{}:
      {==}
    case h <> t:
      {==}

def Laws.uncertain_changes_nothing(
  v, unsafe, key, conf, unsure, candidates, none, c, whole, vetoes, uid, keys, mbox, cats,
  reserved, move, uidplus, uidv):
  +u = uid
  +a = v
  +no = unsafe
  (stay_unplanned(mbox, cats, reserved, u,
     Jev.filing(a, Jev.category_of(Jev.Picked{key, conf}, candidates, none)),
     unsure_files_nothing(a, no, Jev.category_of(Jev.Picked{key, conf}, candidates, none),
       unsure_is_unfiled(key, conf, unsure, candidates, none)), move, uidplus, uidv),
   stay_unplanned(mbox, cats, reserved, u,
     Jev.filing(a, Jev.category_of(Jev.NoPick{}, candidates, none)),
     unsure_files_nothing(a, no, Jev.category_of(Jev.NoPick{}, candidates, none), {==}),
     move, uidplus, uidv),
   stay_unplanned(mbox, cats, reserved, u,
     Jev.filing(Jev.verdict(c, whole, vetoes, Jev.answers_for(J.JNull{}, u, keys)),
       Jev.category_of(Jev.answers_category(Jev.answers_for(J.JNull{}, u, keys)),
         candidates, none)),
     missing_stays(c, whole, vetoes, u, keys, candidates, none), move, uidplus, uidv))

# Dry runs
# --------

def Laws.append_preview_hides_message(mbox, flags, msg, n):
  {==}

# Jev
# ---

def Laws.headers_state_has_no_body(uid, fields, flags, date, size, atts, body, text):
  {==}

def Laws.missing_answer_is_cautious(key, candidates, none):
  ({==}, {==}, {==}, {==}, {==}, {==})

# Gates
# -----

# The gates branch only on their own parameters, so each law computes;
# failure_blocks_outbound matches the scan, which outbound_checked reads
# first.

def Laws.send_veto_only_subtracts(allow, rcpts, from, msg, reasons):
  ({==}, {==}, {==})

def Laws.delete_veto_only_subtracts(plan, reasons):
  ({==}, {==}, {==})

def Laws.failure_blocks_outbound(scan, allow, rcpts, from, msg, reason, plan):
  match scan:
    case Secrets.Found{part}:
      ({==}, {==})
    case Secrets.Incomplete{why}:
      ({==}, {==})
    case Secrets.Clean{}:
      ({==}, {==})

def Laws.secret_scan_blocks(part, reason, gate, allow, rcpts, from, msg):
  ({==}, {==})

def Laws.outgoing_headers_state_has_no_body(fields, attachments, about, vetoes, text):
  {==}
