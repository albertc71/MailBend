# Role-folder resolution: proofs about Policy.resolved_role in src/policy.bend,
# the def that picks each role's folder (Drafts, Trash, Sent, Junk, Archive)
# from the folders the server listed. Every law holds for every folder list,
# override, role attribute and pair of conventional names, wherever the
# folders stand in the list.

import Base
import ../../src/imap.bend as I
import ../../src/policy.bend as Policy

# Notation
# --------

# Whether any folder of `fs` advertises `attr`, as role resolution reads it.
def advertises(fs: List<&2, I.Folder>, +attr: String) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case I.Folder{name, delim, attrs} <> t:
      I.has_attr(attrs, attr) || advertises(t, attr)

# Whether any folder of `fs` is named `want`, as an override is matched.
def lists_name(fs: List<&2, I.Folder>, +want: String) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case I.Folder{name, delim, attrs} <> t:
      I.same_name(name, want) || lists_name(t, want)

# Whether `at` holds any of `attrs`, as a folder's attributes are read.
def advertises_any(attrs: List<&2, String>, +at: List<&2, String>) -> Bool:
  match attrs:
    case Nil{}:
      False{}
    case attr <> t:
      I.has_attr(at, attr) || advertises_any(t, at)

# Laws
# ----

# The precedence is: an override, else the one folder advertising the
# role, else the one folder with a conventional name. Resolution never
# guesses: where the deciding tier has two candidates, or its one candidate
# cannot be selected, no folder takes the role.

# LAW: with an override set, the override alone decides the role: neither
# an advertised role nor a conventional name can take it instead
law override_decides_the_role:
  for fs: List<&2, I.Folder>
  for override: String
  for attr: String
  for a: String
  for b: String
  for set: {String.is_empty(override) == False{} : Bool}
  {Policy.resolved_role(fs, override, attr, a, b) == Policy.named_folder(fs, override)
    : Maybe<&2, String>}

# LAW: with an override set, the one selectable folder of that name takes
# the role, wherever it stands
law override_takes_its_listed_folder:
  for before: List<&2, I.Folder>
  for n: String
  for d: String
  for at: List<&2, String>
  for after: List<&2, I.Folder>
  for override: String
  for attr: String
  for a: String
  for b: String
  for set: {String.is_empty(override) == False{} : Bool}
  for named: {I.same_name(n, override) == True{} : Bool}
  for sel: {Policy.selectable(at) == True{} : Bool}
  for none_before: {lists_name(before, override) == False{} : Bool}
  for none_after: {lists_name(after, override) == False{} : Bool}
  {Policy.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
     override, attr, a, b) == Some{n} : Maybe<&2, String>}

# LAW: with an override set, two folders of that name: no folder takes the
# role
law override_naming_two_folders_takes_no_role:
  for before: List<&2, I.Folder>
  for n1: String
  for d1: String
  for at1: List<&2, String>
  for between: List<&2, I.Folder>
  for n2: String
  for d2: String
  for at2: List<&2, String>
  for after: List<&2, I.Folder>
  for override: String
  for attr: String
  for a: String
  for b: String
  for set: {String.is_empty(override) == False{} : Bool}
  for named1: {I.same_name(n1, override) == True{} : Bool}
  for named2: {I.same_name(n2, override) == True{} : Bool}
  {Policy.resolved_role(
     List.append(&2, I.Folder, before,
       I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, between, I.Folder{n2, d2, at2} <> after)),
     override, attr, a, b) == None{} : Maybe<&2, String>}

# LAW: with an override set, a folder of that name that cannot be selected:
# no folder takes the role
law override_naming_unselectable_folder_takes_no_role:
  for before: List<&2, I.Folder>
  for n: String
  for d: String
  for at: List<&2, String>
  for after: List<&2, I.Folder>
  for override: String
  for attr: String
  for a: String
  for b: String
  for set: {String.is_empty(override) == False{} : Bool}
  for named: {I.same_name(n, override) == True{} : Bool}
  for unselectable: {Policy.selectable(at) == False{} : Bool}
  {Policy.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
     override, attr, a, b) == None{} : Maybe<&2, String>}

# LAW: with an override set and no folder of that name, no folder takes the
# role: neither the name nor any other folder is used instead
law override_naming_no_folder_takes_no_role:
  for fs: List<&2, I.Folder>
  for override: String
  for attr: String
  for a: String
  for b: String
  for set: {String.is_empty(override) == False{} : Bool}
  for unlisted: {lists_name(fs, override) == False{} : Bool}
  {Policy.resolved_role(fs, override, attr, a, b) == None{} : Maybe<&2, String>}

# LAW: when two folders advertise the role, no folder takes it
law two_advertised_folders_take_no_role:
  for before: List<&2, I.Folder>
  for n1: String
  for d1: String
  for at1: List<&2, String>
  for between: List<&2, I.Folder>
  for n2: String
  for d2: String
  for at2: List<&2, String>
  for after: List<&2, I.Folder>
  for attr: String
  for a: String
  for b: String
  for adv1: {I.has_attr(at1, attr) == True{} : Bool}
  for adv2: {I.has_attr(at2, attr) == True{} : Bool}
  {Policy.resolved_role(
     List.append(&2, I.Folder, before,
       I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, between, I.Folder{n2, d2, at2} <> after)),
     "", attr, a, b) == None{} : Maybe<&2, String>}

# LAW: when a folder advertising the role cannot be selected, no folder
# takes it: resolution does not fall back to a conventional name
law unselectable_advertised_folder_takes_no_role:
  for before: List<&2, I.Folder>
  for n: String
  for d: String
  for at: List<&2, String>
  for after: List<&2, I.Folder>
  for attr: String
  for a: String
  for b: String
  for adv: {I.has_attr(at, attr) == True{} : Bool}
  for unselectable: {Policy.selectable(at) == False{} : Bool}
  {Policy.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
     "", attr, a, b) == None{} : Maybe<&2, String>}

# LAW: the one selectable folder advertising the role takes it, whatever
# the other folders are named
law sole_advertised_folder_takes_the_role:
  for before: List<&2, I.Folder>
  for n: String
  for d: String
  for at: List<&2, String>
  for after: List<&2, I.Folder>
  for attr: String
  for a: String
  for b: String
  for adv: {I.has_attr(at, attr) == True{} : Bool}
  for sel: {Policy.selectable(at) == True{} : Bool}
  for none_before: {advertises(before, attr) == False{} : Bool}
  for none_after: {advertises(after, attr) == False{} : Bool}
  {Policy.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
     "", attr, a, b) == Some{n} : Maybe<&2, String>}

# LAW: when no folder advertises the role and two selectable folders with
# no role of their own have a conventional name, no folder takes it
law two_conventional_folders_take_no_role:
  for before: List<&2, I.Folder>
  for n1: String
  for d1: String
  for at1: List<&2, String>
  for between: List<&2, I.Folder>
  for n2: String
  for d2: String
  for at2: List<&2, String>
  for after: List<&2, I.Folder>
  for attr: String
  for a: String
  for b: String
  for none: {advertises(
      List.append(&2, I.Folder, before,
        I.Folder{n1, d1, at1} <>
          List.append(&2, I.Folder, between, I.Folder{n2, d2, at2} <> after)),
      attr) == False{} : Bool}
  for named1: {(I.same_name(n1, a) || I.same_name(n1, b)) == True{} : Bool}
  for sel1: {Policy.selectable(at1) == True{} : Bool}
  for norole1: {Policy.recognized_role(at1) == False{} : Bool}
  for named2: {(I.same_name(n2, a) || I.same_name(n2, b)) == True{} : Bool}
  for sel2: {Policy.selectable(at2) == True{} : Bool}
  for norole2: {Policy.recognized_role(at2) == False{} : Bool}
  {Policy.resolved_role(
     List.append(&2, I.Folder, before,
       I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, between, I.Folder{n2, d2, at2} <> after)),
     "", attr, a, b) == None{} : Maybe<&2, String>}

# LAW: a folder that advertises another role never takes this one by its
# name: adding it anywhere in the list changes nothing
law other_role_folder_never_takes_the_role:
  for before: List<&2, I.Folder>
  for n: String
  for d: String
  for at: List<&2, String>
  for after: List<&2, I.Folder>
  for attr: String
  for a: String
  for b: String
  for not_adv: {I.has_attr(at, attr) == False{} : Bool}
  for other: {Policy.recognized_role(at) == True{} : Bool}
  {Policy.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
     "", attr, a, b) ==
    Policy.resolved_role(List.append(&2, I.Folder, before, after), "", attr, a, b)
    : Maybe<&2, String>}

# LAW: each role is resolved by its own attribute and conventional names:
# Drafts by \Drafts or "Drafts", Trash by \Trash, "Trash" or "Deleted
# Messages", Sent by \Sent, "Sent" or "Sent Messages", Junk by \Junk or
# "Junk", and Archive by \Archive or "Archive", each with its own override
law each_role_has_its_own_attribute_and_names:
  for fs: List<&2, I.Folder>
  for drafts: String
  for trash: String
  for sent: String
  for junk: String
  for archive: String
  {Policy.resolved_folders(fs, drafts, trash, sent, junk, archive) ==
    Policy.Folders{
      fs,
      Policy.resolved_role(fs, drafts, "\\Drafts", "Drafts", "Drafts"),
      Policy.resolved_role(fs, trash, "\\Trash", "Trash", "Deleted Messages"),
      Policy.resolved_role(fs, sent, "\\Sent", "Sent", "Sent Messages"),
      Policy.resolved_role(fs, junk, "\\Junk", "Junk", "Junk"),
      Policy.resolved_role(fs, archive, "\\Archive", "Archive", "Archive")
    } : Policy.Folders}

# The laws above read selectability and roles through Policy.selectable and
# Policy.recognized_role; these tie both to the attributes the server sent.

# LAW: a folder can be selected exactly when it advertises neither
# \Noselect nor \NonExistent
law selectable_is_neither_noselect_nor_nonexistent:
  for at: List<&2, String>
  {Policy.selectable(at) ==
    Bool.not(I.has_attr(at, "\\Noselect") || I.has_attr(at, "\\NonExistent")) : Bool}

# LAW: a folder has a role of its own exactly when it advertises one of
# \Drafts, \Sent, \Trash, \Junk, \Archive, \All or \Flagged
law recognized_roles_are_the_special_use_attributes:
  for at: List<&2, String>
  {Policy.recognized_role(at) ==
    advertises_any(
      ["\\Drafts", "\\Sent", "\\Trash", "\\Junk", "\\Archive", "\\All", "\\Flagged"], at)
    : Bool}

# Examples
# --------

# Instances of the laws on folders like iCloud's, where Trash is "Deleted
# Messages" advertising \Trash; every law a real folder list can show has
# one. They come before the proofs so that, when a change breaks a law, the
# first failure Bend prints is the folder the code now picks here, not a
# step inside a proof.

def trash_role(fs: List<&2, I.Folder>, override: String) -> Maybe<&2, String>:
  Policy.resolved_role(fs, override, "\\Trash", "Trash", "Deleted Messages")

def icloud_folders() -> List<&2, I.Folder>:
  [
    I.Folder{"INBOX", "/", []},
    I.Folder{"Drafts", "/", ["\\Drafts"]},
    I.Folder{"Sent Messages", "/", ["\\Sent"]},
    I.Folder{"Deleted Messages", "/", ["\\Trash"]},
    I.Folder{"Junk", "/", ["\\Junk"]},
    I.Folder{"Archive", "/", ["\\Archive"]},
    I.Folder{"Trash", "/", []}
  ]

def override_example()
  -> {trash_role(
        [I.Folder{"Deleted Messages", "/", ["\\Trash"]}, I.Folder{"Trash", "/", []},
          I.Folder{"Bin", "/", []}],
        "Bin") == Some{"Bin"} : Maybe<&2, String>}:
  {==}

def unlisted_override_example()
  -> {trash_role(icloud_folders(), "Bin") == None{} : Maybe<&2, String>}:
  {==}

def two_advertised_example()
  -> {trash_role(
        [I.Folder{"Deleted Messages", "/", ["\\Trash"]}, I.Folder{"Bin", "/", ["\\Trash"]}],
        "") == None{} : Maybe<&2, String>}:
  {==}

def sole_advertised_example()
  -> {trash_role(icloud_folders(), "") == Some{"Deleted Messages"} : Maybe<&2, String>}:
  {==}

def unselectable_advertised_example()
  -> {trash_role(
        [I.Folder{"Deleted Messages", "/", ["\\Trash", "\\Noselect"]}, I.Folder{"Trash", "/", []}],
        "") == None{} : Maybe<&2, String>}:
  {==}

def nonexistent_advertised_example()
  -> {trash_role(
        [I.Folder{"Deleted Messages", "/", ["\\Trash", "\\NonExistent"]},
          I.Folder{"Trash", "/", []}],
        "") == None{} : Maybe<&2, String>}:
  {==}

def two_conventional_example()
  -> {trash_role([I.Folder{"Trash", "/", []}, I.Folder{"Deleted Messages", "/", []}], "") ==
       None{} : Maybe<&2, String>}:
  {==}

def other_role_example()
  -> {trash_role([I.Folder{"Trash", "/", ["\\Junk"]}], "") == None{} : Maybe<&2, String>}:
  {==}

def all_mail_folder_example()
  -> {trash_role([I.Folder{"Trash", "/", ["\\All"]}], "") == None{} : Maybe<&2, String>}:
  {==}

def each_role_example()
  -> {Policy.resolved_folders(icloud_folders(), "", "", "", "", "") ==
       Policy.Folders{
         icloud_folders(),
         Some{"Drafts"},
         Some{"Deleted Messages"},
         Some{"Sent Messages"},
         Some{"Junk"},
         Some{"Archive"}
       } : Policy.Folders}:
  {==}

# Proofs
# ======

# Booleans
# --------

# A failed premise True == False is refuted through a motive that sends
# True to Unit and False to Empty.

def bool_motive(b: Bool) -> Type:
  match b:
    case True{}:
      Unit
    case False{}:
      Empty

def true_is_not_false(e: {True{} == False{} : Bool}) -> Empty:
  %e : bool_motive(_)
  Unit{}

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

def and_false(b: Bool) -> {Bool.and(b, False{}) == False{} : Bool}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}


# Candidates
# ----------

# Policy.role_candidates keeps, in order, the folders that may take the role
# at one tier: with `adv`, those advertising its attribute; without, those
# with a conventional name, selectable and advertising no role. It filters
# a list, so it splits over an append, keeps a folder whose match holds and
# drops one whose match fails.

def put_append(
  -n: String, -d: String, -at: List<&2, String>, -r: List<&2, I.Folder>,
  -s: List<&2, I.Folder>, keep: Bool)
  -> {List.filter.put(I.Folder, I.Folder{n, d, at}, List.append(&2, I.Folder, r, s), keep) ==
       List.append(&2, I.Folder, List.filter.put(I.Folder, I.Folder{n, d, at}, r, keep), s)
       : List<&2, I.Folder>}:
  match keep:
    case True{}:
      {==}
    case False{}:
      {==}

def candidates_append(
  xs: List<&2, I.Folder>, +ys: List<&2, I.Folder>, +attr: String, +a: String, +b: String,
  +adv: Bool)
  -> {Policy.role_candidates(List.append(&2, I.Folder, xs, ys), attr, a, b, adv) ==
       List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
         Policy.role_candidates(ys, attr, a, b, adv)) : List<&2, I.Folder>}:
  match xs:
    case Nil{}:
      {==}
    case I.Folder{n, d, at} <> t:
      +ts = t
      %Equal.sym(List<&2, I.Folder>,
        Policy.role_candidates(List.append(&2, I.Folder, ts, ys), attr, a, b, adv),
        List.append(&2, I.Folder, Policy.role_candidates(ts, attr, a, b, adv),
          Policy.role_candidates(ys, attr, a, b, adv)),
        candidates_append(ts, ys, attr, a, b, adv)) :
        {List.filter.put(I.Folder, I.Folder{n, d, at}, _,
            Policy.role_match(adv, n, at, attr, a, b)) ==
          List.append(&2, I.Folder,
            List.filter.put(I.Folder, I.Folder{n, d, at},
              Policy.role_candidates(ts, attr, a, b, adv),
              Policy.role_match(adv, n, at, attr, a, b)),
            Policy.role_candidates(ys, attr, a, b, adv)) : List<&2, I.Folder>}
      put_append(n, d, at, Policy.role_candidates(ts, attr, a, b, adv),
        Policy.role_candidates(ys, attr, a, b, adv), Policy.role_match(adv, n, at, attr, a, b))

def candidates_keep(
  -n: String, -d: String, -at: List<&2, String>, -t: List<&2, I.Folder>, -attr: String,
  -a: String, -b: String, -adv: Bool,
  e: {Policy.role_match(adv, n, at, attr, a, b) == True{} : Bool})
  -> {Policy.role_candidates(I.Folder{n, d, at} <> t, attr, a, b, adv) ==
       I.Folder{n, d, at} <> Policy.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}:
  %Equal.sym(Bool, Policy.role_match(adv, n, at, attr, a, b), True{}, e) :
    {List.filter.put(I.Folder, I.Folder{n, d, at}, Policy.role_candidates(t, attr, a, b, adv), _) ==
      I.Folder{n, d, at} <> Policy.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}
  {==}

def candidates_drop(
  -n: String, -d: String, -at: List<&2, String>, -t: List<&2, I.Folder>, -attr: String,
  -a: String, -b: String, -adv: Bool,
  e: {Policy.role_match(adv, n, at, attr, a, b) == False{} : Bool})
  -> {Policy.role_candidates(I.Folder{n, d, at} <> t, attr, a, b, adv) ==
       Policy.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}:
  %Equal.sym(Bool, Policy.role_match(adv, n, at, attr, a, b), False{}, e) :
    {List.filter.put(I.Folder, I.Folder{n, d, at}, Policy.role_candidates(t, attr, a, b, adv), _) ==
      Policy.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}
  {==}

# No folder advertising the role leaves no advertised candidate.
def no_advertised_candidates(
  fs: List<&2, I.Folder>, +attr: String, -a: String, -b: String,
  none: {advertises(fs, attr) == False{} : Bool})
  -> {Policy.role_candidates(fs, attr, a, b, True{}) == [] : List<&2, I.Folder>}:
  match fs:
    case Nil{}:
      {==}
    case I.Folder{n, d, +at} <> t:
      +ts = t
      +e = none
      Equal.trans(List<&2, I.Folder>,
        Policy.role_candidates(I.Folder{n, d, at} <> ts, attr, a, b, True{}),
        Policy.role_candidates(ts, attr, a, b, True{}),
        [],
        candidates_drop(n, d, at, ts, attr, a, b, True{},
          or_false_left(I.has_attr(at, attr), advertises(ts, attr), e)),
        no_advertised_candidates(ts, attr, a, b,
          or_false_right(I.has_attr(at, attr), advertises(ts, attr), e)))

# A folder whose match holds stays a candidate wherever it stands in the
# list; one whose match fails leaves the candidates as if it were absent.
def candidates_around(
  +xs: List<&2, I.Folder>, +n: String, +d: String, +at: List<&2, String>,
  +ys: List<&2, I.Folder>, +attr: String, +a: String, +b: String, +adv: Bool,
  e: {Policy.role_match(adv, n, at, attr, a, b) == True{} : Bool})
  -> {Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
        attr, a, b, adv) ==
       List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
         I.Folder{n, d, at} <> Policy.role_candidates(ys, attr, a, b, adv))
       : List<&2, I.Folder>}:
  Equal.trans(List<&2, I.Folder>,
    Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
      attr, a, b, adv),
    List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
      Policy.role_candidates(I.Folder{n, d, at} <> ys, attr, a, b, adv)),
    List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
      I.Folder{n, d, at} <> Policy.role_candidates(ys, attr, a, b, adv)),
    candidates_append(xs, I.Folder{n, d, at} <> ys, attr, a, b, adv),
    Equal.cong(List<&2, I.Folder>, List<&2, I.Folder>,
      zs => List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv), zs),
      Policy.role_candidates(I.Folder{n, d, at} <> ys, attr, a, b, adv),
      I.Folder{n, d, at} <> Policy.role_candidates(ys, attr, a, b, adv),
      candidates_keep(n, d, at, ys, attr, a, b, adv, e)))

def candidates_around_two(
  +xs: List<&2, I.Folder>, +n1: String, +d1: String, +at1: List<&2, String>,
  +ys: List<&2, I.Folder>, +n2: String, +d2: String, +at2: List<&2, String>,
  +zs: List<&2, I.Folder>, +attr: String, +a: String, +b: String, +adv: Bool,
  e1: {Policy.role_match(adv, n1, at1, attr, a, b) == True{} : Bool},
  e2: {Policy.role_match(adv, n2, at2, attr, a, b) == True{} : Bool})
  -> {Policy.role_candidates(
        List.append(&2, I.Folder, xs,
          I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs)),
        attr, a, b, adv) ==
       List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
         I.Folder{n1, d1, at1} <>
           List.append(&2, I.Folder, Policy.role_candidates(ys, attr, a, b, adv),
             I.Folder{n2, d2, at2} <> Policy.role_candidates(zs, attr, a, b, adv)))
       : List<&2, I.Folder>}:
  %candidates_around(ys, n2, d2, at2, zs, attr, a, b, adv, e2) :
    {Policy.role_candidates(
       List.append(&2, I.Folder, xs,
         I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs)),
       attr, a, b, adv) ==
      List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
        I.Folder{n1, d1, at1} <> _) : List<&2, I.Folder>}
  candidates_around(xs, n1, d1, at1,
    List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs), attr, a, b, adv, e1)

def candidates_without(
  +xs: List<&2, I.Folder>, +n: String, +d: String, +at: List<&2, String>,
  +ys: List<&2, I.Folder>, +attr: String, +a: String, +b: String, +adv: Bool,
  e: {Policy.role_match(adv, n, at, attr, a, b) == False{} : Bool})
  -> {Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
        attr, a, b, adv) ==
       Policy.role_candidates(List.append(&2, I.Folder, xs, ys), attr, a, b, adv)
       : List<&2, I.Folder>}:
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(List.append(&2, I.Folder, xs, ys), attr, a, b, adv),
    List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv),
      Policy.role_candidates(ys, attr, a, b, adv)),
    candidates_append(xs, ys, attr, a, b, adv)) :
    {Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
       attr, a, b, adv) == _ : List<&2, I.Folder>}
  %candidates_drop(n, d, at, ys, attr, a, b, adv, e) :
    {Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
       attr, a, b, adv) ==
      List.append(&2, I.Folder, Policy.role_candidates(xs, attr, a, b, adv), _)
      : List<&2, I.Folder>}
  candidates_append(xs, I.Folder{n, d, at} <> ys, attr, a, b, adv)

# Uniqueness
# ----------

# Policy.unique_folder names a folder only for a single candidate that can
# be selected: never for two, wherever they stand, nor for an unselectable
# one.

def unique_of_two(
  xs: List<&2, I.Folder>, -n1: String, -d1: String, -at1: List<&2, String>,
  ys: List<&2, I.Folder>, -n2: String, -d2: String, -at2: List<&2, String>,
  -zs: List<&2, I.Folder>)
  -> {Policy.unique_folder(
        List.append(&2, I.Folder, xs,
          I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs))) ==
       None{} : Maybe<&2, String>}:
  match xs ys:
    case Nil{} Nil{}:
      {==}
    case Nil{} I.Folder{yn, yd, ya} <> yt:
      {==}
    case I.Folder{xn, xd, xa} <> Nil{} _:
      {==}
    case I.Folder{xn, xd, xa} <> I.Folder{wn, wd, wa} <> wt _:
      {==}

def unique_unselectable(
  xs: List<&2, I.Folder>, -n: String, -d: String, -at: List<&2, String>,
  ys: List<&2, I.Folder>, unselectable: {Policy.selectable(at) == False{} : Bool})
  -> {Policy.unique_folder(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys)) ==
       None{} : Maybe<&2, String>}:
  match xs ys:
    case Nil{} Nil{}:
      %Equal.sym(Bool, Policy.selectable(at), False{}, unselectable) :
        {Bool.pick(Maybe<&2, String>, _, Some{n}, None{}) == None{} : Maybe<&2, String>}
      {==}
    case Nil{} I.Folder{yn, yd, ya} <> yt:
      {==}
    case I.Folder{xn, xd, xa} <> Nil{} _:
      {==}
    case I.Folder{xn, xd, xa} <> I.Folder{wn, wd, wa} <> wt _:
      {==}

# Fallback
# --------

# Policy.role_fallback takes the advertised candidates when there are any,
# and reads the folder list only when there are none.

def fallback_advertised(
  xs: List<&2, I.Folder>, -n: String, -d: String, -at: List<&2, String>,
  -ys: List<&2, I.Folder>, -fs: List<&2, I.Folder>, -attr: String, -a: String, -b: String)
  -> {Policy.role_fallback(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys), fs, attr, a, b)
       == Policy.unique_folder(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys))
       : Maybe<&2, String>}:
  match xs:
    case Nil{}:
      {==}
    case I.Folder{xn, xd, xa} <> xt:
      {==}

def fallback_same(
  marked: List<&2, I.Folder>, -fs: List<&2, I.Folder>, -gs: List<&2, I.Folder>, -attr: String,
  -a: String, -b: String,
  same: {Policy.role_candidates(fs, attr, a, b, False{}) ==
    Policy.role_candidates(gs, attr, a, b, False{}) : List<&2, I.Folder>})
  -> {Policy.role_fallback(marked, fs, attr, a, b) == Policy.role_fallback(marked, gs, attr, a, b)
       : Maybe<&2, String>}:
  match marked:
    case Nil{}:
      %same : {Policy.unique_folder(Policy.role_candidates(fs, attr, a, b, False{})) ==
        Policy.unique_folder(_) : Maybe<&2, String>}
      {==}
    case h <> t:
      {==}

# Matches
# -------

def conventional_match(
  -n: String, at: List<&2, String>, -attr: String, -a: String, -b: String,
  named: {(I.same_name(n, a) || I.same_name(n, b)) == True{} : Bool},
  sel: {Policy.selectable(at) == True{} : Bool},
  norole: {Policy.recognized_role(at) == False{} : Bool})
  -> {Policy.role_match(False{}, n, at, attr, a, b) == True{} : Bool}:
  %Equal.sym(Bool, I.same_name(n, a) || I.same_name(n, b), True{}, named) :
    {(_ && Policy.selectable(at)) && Bool.not(Policy.recognized_role(at)) == True{} : Bool}
  %Equal.sym(Bool, Policy.selectable(at), True{}, sel) :
    {_ && Bool.not(Policy.recognized_role(at)) == True{} : Bool}
  %Equal.sym(Bool, Policy.recognized_role(at), False{}, norole) :
    {Bool.not(_) == True{} : Bool}
  {==}

def other_role_no_match(
  +n: String, +at: List<&2, String>, -attr: String, +a: String, +b: String,
  other: {Policy.recognized_role(at) == True{} : Bool})
  -> {Policy.role_match(False{}, n, at, attr, a, b) == False{} : Bool}:
  %Equal.sym(Bool, Policy.recognized_role(at), True{}, other) :
    {((I.same_name(n, a) || I.same_name(n, b)) && Policy.selectable(at)) && Bool.not(_) ==
      False{} : Bool}
  and_false((I.same_name(n, a) || I.same_name(n, b)) && Policy.selectable(at))

# Override candidates
# -------------------

# Policy.override_candidates keeps, in order, the folders named like the
# override. Like the role candidates, it splits over an append, keeps a
# folder of that name and drops any other.

def override_candidates_append(xs: List<&2, I.Folder>, +ys: List<&2, I.Folder>, +want: String)
  -> {Policy.override_candidates(List.append(&2, I.Folder, xs, ys), want) ==
       List.append(&2, I.Folder, Policy.override_candidates(xs, want),
         Policy.override_candidates(ys, want)) : List<&2, I.Folder>}:
  match xs:
    case Nil{}:
      {==}
    case I.Folder{n, d, at} <> t:
      +ts = t
      %Equal.sym(List<&2, I.Folder>,
        Policy.override_candidates(List.append(&2, I.Folder, ts, ys), want),
        List.append(&2, I.Folder, Policy.override_candidates(ts, want),
          Policy.override_candidates(ys, want)),
        override_candidates_append(ts, ys, want)) :
        {List.filter.put(I.Folder, I.Folder{n, d, at}, _, I.same_name(n, want)) ==
          List.append(&2, I.Folder,
            List.filter.put(I.Folder, I.Folder{n, d, at}, Policy.override_candidates(ts, want),
              I.same_name(n, want)),
            Policy.override_candidates(ys, want)) : List<&2, I.Folder>}
      put_append(n, d, at, Policy.override_candidates(ts, want),
        Policy.override_candidates(ys, want), I.same_name(n, want))

def override_candidates_keep(
  -n: String, -d: String, -at: List<&2, String>, -t: List<&2, I.Folder>, -want: String,
  e: {I.same_name(n, want) == True{} : Bool})
  -> {Policy.override_candidates(I.Folder{n, d, at} <> t, want) ==
       I.Folder{n, d, at} <> Policy.override_candidates(t, want) : List<&2, I.Folder>}:
  %Equal.sym(Bool, I.same_name(n, want), True{}, e) :
    {List.filter.put(I.Folder, I.Folder{n, d, at}, Policy.override_candidates(t, want), _) ==
      I.Folder{n, d, at} <> Policy.override_candidates(t, want) : List<&2, I.Folder>}
  {==}

def override_candidates_drop(
  -n: String, -d: String, -at: List<&2, String>, -t: List<&2, I.Folder>, -want: String,
  e: {I.same_name(n, want) == False{} : Bool})
  -> {Policy.override_candidates(I.Folder{n, d, at} <> t, want) ==
       Policy.override_candidates(t, want) : List<&2, I.Folder>}:
  %Equal.sym(Bool, I.same_name(n, want), False{}, e) :
    {List.filter.put(I.Folder, I.Folder{n, d, at}, Policy.override_candidates(t, want), _) ==
      Policy.override_candidates(t, want) : List<&2, I.Folder>}
  {==}

# No folder of the override's name leaves no override candidate.
def no_override_candidates(
  fs: List<&2, I.Folder>, +want: String, unlisted: {lists_name(fs, want) == False{} : Bool})
  -> {Policy.override_candidates(fs, want) == [] : List<&2, I.Folder>}:
  match fs:
    case Nil{}:
      {==}
    case I.Folder{+n, d, +at} <> t:
      +ts = t
      +e = unlisted
      Equal.trans(List<&2, I.Folder>,
        Policy.override_candidates(I.Folder{n, d, at} <> ts, want),
        Policy.override_candidates(ts, want),
        [],
        override_candidates_drop(n, d, at, ts, want,
          or_false_left(I.same_name(n, want), lists_name(ts, want), e)),
        no_override_candidates(ts, want,
          or_false_right(I.same_name(n, want), lists_name(ts, want), e)))

def override_candidates_around(
  +xs: List<&2, I.Folder>, +n: String, +d: String, +at: List<&2, String>,
  +ys: List<&2, I.Folder>, +want: String, e: {I.same_name(n, want) == True{} : Bool})
  -> {Policy.override_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys), want) ==
       List.append(&2, I.Folder, Policy.override_candidates(xs, want),
         I.Folder{n, d, at} <> Policy.override_candidates(ys, want)) : List<&2, I.Folder>}:
  Equal.trans(List<&2, I.Folder>,
    Policy.override_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys), want),
    List.append(&2, I.Folder, Policy.override_candidates(xs, want),
      Policy.override_candidates(I.Folder{n, d, at} <> ys, want)),
    List.append(&2, I.Folder, Policy.override_candidates(xs, want),
      I.Folder{n, d, at} <> Policy.override_candidates(ys, want)),
    override_candidates_append(xs, I.Folder{n, d, at} <> ys, want),
    Equal.cong(List<&2, I.Folder>, List<&2, I.Folder>,
      zs => List.append(&2, I.Folder, Policy.override_candidates(xs, want), zs),
      Policy.override_candidates(I.Folder{n, d, at} <> ys, want),
      I.Folder{n, d, at} <> Policy.override_candidates(ys, want),
      override_candidates_keep(n, d, at, ys, want, e)))

def override_candidates_around_two(
  +xs: List<&2, I.Folder>, +n1: String, +d1: String, +at1: List<&2, String>,
  +ys: List<&2, I.Folder>, +n2: String, +d2: String, +at2: List<&2, String>,
  +zs: List<&2, I.Folder>, +want: String,
  e1: {I.same_name(n1, want) == True{} : Bool}, e2: {I.same_name(n2, want) == True{} : Bool})
  -> {Policy.override_candidates(
        List.append(&2, I.Folder, xs,
          I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs)),
        want) ==
       List.append(&2, I.Folder, Policy.override_candidates(xs, want),
         I.Folder{n1, d1, at1} <>
           List.append(&2, I.Folder, Policy.override_candidates(ys, want),
             I.Folder{n2, d2, at2} <> Policy.override_candidates(zs, want)))
       : List<&2, I.Folder>}:
  %override_candidates_around(ys, n2, d2, at2, zs, want, e2) :
    {Policy.override_candidates(
       List.append(&2, I.Folder, xs,
         I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs)),
       want) ==
      List.append(&2, I.Folder, Policy.override_candidates(xs, want),
        I.Folder{n1, d1, at1} <> _) : List<&2, I.Folder>}
  override_candidates_around(xs, n1, d1, at1,
    List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs), want, e1)

# Roles
# -----

# Policy.role_in walks the recognised attributes, so whether it finds a
# role is whether the folder holds any of them.

def role_attrs_any(roles: List<&2, Policy.RoleAttr>, +at: List<&2, String>) -> Bool:
  match roles:
    case Nil{}:
      False{}
    case Policy.RoleAttr{attr, name} <> t:
      I.has_attr(at, attr) || role_attrs_any(t, at)

def is_some_pick(c: Bool, -x: String, -m: Maybe<&2, String>)
  -> {Maybe.is_some(&2, String, Bool.pick(Maybe<&2, String>, c, Some{x}, m)) ==
       (c || Maybe.is_some(&2, String, m)) : Bool}:
  match c:
    case True{}:
      {==}
    case False{}:
      {==}

def role_in_finds_any(roles: List<&2, Policy.RoleAttr>, +at: List<&2, String>)
  -> {Maybe.is_some(&2, String, Policy.role_in(roles, at)) == role_attrs_any(roles, at) : Bool}:
  match roles:
    case Nil{}:
      {==}
    case Policy.RoleAttr{attr, name} <> t:
      +r = attr
      +ts = t
      Equal.trans(Bool,
        Maybe.is_some(&2, String,
          Bool.pick(Maybe<&2, String>, I.has_attr(at, r), Some{name}, Policy.role_in(ts, at))),
        I.has_attr(at, r) || Maybe.is_some(&2, String, Policy.role_in(ts, at)),
        I.has_attr(at, r) || role_attrs_any(ts, at),
        is_some_pick(I.has_attr(at, r), name, Policy.role_in(ts, at)),
        Equal.cong(Bool, Bool, v => I.has_attr(at, r) || v,
          Maybe.is_some(&2, String, Policy.role_in(ts, at)), role_attrs_any(ts, at),
          role_in_finds_any(ts, at)))

# Law proofs
# ----------

# With an empty override, Policy.resolved_role is Policy.role_fallback over
# the advertised candidates. Each proof rewrites those candidates through
# the lemmas above, then lets the fallback and uniqueness lemmas decide.

def override_decides_the_role(fs, override, attr, a, b, set):
  +o = override
  %Equal.sym(Bool, String.is_empty(o), False{}, set) :
    {Policy.resolved_role.if(_, fs, o, attr, a, b) == Policy.named_folder(fs, o)
      : Maybe<&2, String>}
  {==}

# With an override set, Policy.resolved_role is Policy.named_folder, the one
# selectable override candidate; each proof rewrites to it first.

def override_takes_its_listed_folder(
  before, n, d, at, after, override, attr, a, b, set, named, sel, none_before, none_after):
  +xs = before
  +zs = after
  +m = n
  +e = d
  +t = at
  +o = override
  %Equal.sym(Maybe<&2, String>,
    Policy.resolved_role(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o, attr, a, b),
    Policy.named_folder(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o),
    override_decides_the_role(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o,
      attr, a, b, set)) :
    {_ == Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>,
    Policy.override_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o),
    List.append(&2, I.Folder, Policy.override_candidates(xs, o),
      I.Folder{m, e, t} <> Policy.override_candidates(zs, o)),
    override_candidates_around(xs, m, e, t, zs, o, named)) :
    {Policy.unique_folder(_) == Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Policy.override_candidates(xs, o), [],
    no_override_candidates(xs, o, none_before)) :
    {Policy.unique_folder(
       List.append(&2, I.Folder, _, I.Folder{m, e, t} <> Policy.override_candidates(zs, o))) ==
      Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Policy.override_candidates(zs, o), [],
    no_override_candidates(zs, o, none_after)) :
    {Policy.unique_folder(I.Folder{m, e, t} <> _) == Some{m} : Maybe<&2, String>}
  %Equal.sym(Bool, Policy.selectable(t), True{}, sel) :
    {Bool.pick(Maybe<&2, String>, _, Some{m}, None{}) == Some{m} : Maybe<&2, String>}
  {==}

def override_naming_two_folders_takes_no_role(
  before, n1, d1, at1, between, n2, d2, at2, after, override, attr, a, b, set, named1, named2):
  +xs = before
  +ys = between
  +zs = after
  +m1 = n1
  +e1 = d1
  +t1 = at1
  +m2 = n2
  +e2 = d2
  +t2 = at2
  +o = override
  %Equal.sym(Maybe<&2, String>,
    Policy.resolved_role(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      o, attr, a, b),
    Policy.named_folder(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      o),
    override_decides_the_role(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      o, attr, a, b, set)) :
    {_ == None{} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>,
    Policy.override_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      o),
    List.append(&2, I.Folder, Policy.override_candidates(xs, o),
      I.Folder{m1, e1, t1} <>
        List.append(&2, I.Folder, Policy.override_candidates(ys, o),
          I.Folder{m2, e2, t2} <> Policy.override_candidates(zs, o))),
    override_candidates_around_two(xs, m1, e1, t1, ys, m2, e2, t2, zs, o, named1, named2)) :
    {Policy.unique_folder(_) == None{} : Maybe<&2, String>}
  unique_of_two(Policy.override_candidates(xs, o), m1, e1, t1,
    Policy.override_candidates(ys, o), m2, e2, t2, Policy.override_candidates(zs, o))

def override_naming_unselectable_folder_takes_no_role(
  before, n, d, at, after, override, attr, a, b, set, named, unselectable):
  +xs = before
  +zs = after
  +m = n
  +e = d
  +t = at
  +o = override
  %Equal.sym(Maybe<&2, String>,
    Policy.resolved_role(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o, attr, a, b),
    Policy.named_folder(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o),
    override_decides_the_role(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o,
      attr, a, b, set)) :
    {_ == None{} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>,
    Policy.override_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), o),
    List.append(&2, I.Folder, Policy.override_candidates(xs, o),
      I.Folder{m, e, t} <> Policy.override_candidates(zs, o)),
    override_candidates_around(xs, m, e, t, zs, o, named)) :
    {Policy.unique_folder(_) == None{} : Maybe<&2, String>}
  unique_unselectable(Policy.override_candidates(xs, o), m, e, t,
    Policy.override_candidates(zs, o), unselectable)

def override_naming_no_folder_takes_no_role(fs, override, attr, a, b, set, unlisted):
  +f = fs
  +o = override
  %Equal.sym(Maybe<&2, String>, Policy.resolved_role(f, o, attr, a, b), Policy.named_folder(f, o),
    override_decides_the_role(f, o, attr, a, b, set)) :
    {_ == None{} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Policy.override_candidates(f, o), [],
    no_override_candidates(f, o, unlisted)) :
    {Policy.unique_folder(_) == None{} : Maybe<&2, String>}
  {==}

def two_advertised_folders_take_no_role(
  before, n1, d1, at1, between, n2, d2, at2, after, attr, a, b, adv1, adv2):
  +xs = before
  +ys = between
  +zs = after
  +m1 = n1
  +e1 = d1
  +t1 = at1
  +m2 = n2
  +e2 = d2
  +t2 = at2
  +r = attr
  +x = a
  +y = b
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, True{}),
    List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
      I.Folder{m1, e1, t1} <>
        List.append(&2, I.Folder, Policy.role_candidates(ys, r, x, y, True{}),
          I.Folder{m2, e2, t2} <> Policy.role_candidates(zs, r, x, y, True{}))),
    candidates_around_two(xs, m1, e1, t1, ys, m2, e2, t2, zs, r, x, y, True{}, adv1, adv2)) :
    {Policy.role_fallback(_,
       List.append(&2, I.Folder, xs,
         I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
       r, x, y) == None{} : Maybe<&2, String>}
  Equal.trans(Maybe<&2, String>,
    Policy.role_fallback(
      List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
        I.Folder{m1, e1, t1} <>
          List.append(&2, I.Folder, Policy.role_candidates(ys, r, x, y, True{}),
            I.Folder{m2, e2, t2} <> Policy.role_candidates(zs, r, x, y, True{}))),
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y),
    Policy.unique_folder(
      List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
        I.Folder{m1, e1, t1} <>
          List.append(&2, I.Folder, Policy.role_candidates(ys, r, x, y, True{}),
            I.Folder{m2, e2, t2} <> Policy.role_candidates(zs, r, x, y, True{})))),
    None{},
    fallback_advertised(Policy.role_candidates(xs, r, x, y, True{}), m1, e1, t1,
      List.append(&2, I.Folder, Policy.role_candidates(ys, r, x, y, True{}),
        I.Folder{m2, e2, t2} <> Policy.role_candidates(zs, r, x, y, True{})),
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y),
    unique_of_two(Policy.role_candidates(xs, r, x, y, True{}), m1, e1, t1,
      Policy.role_candidates(ys, r, x, y, True{}), m2, e2, t2,
      Policy.role_candidates(zs, r, x, y, True{})))

def unselectable_advertised_folder_takes_no_role(
  before, n, d, at, after, attr, a, b, adv, unselectable):
  +xs = before
  +zs = after
  +m = n
  +e = d
  +t = at
  +r = attr
  +x = a
  +y = b
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y, True{}),
    List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
      I.Folder{m, e, t} <> Policy.role_candidates(zs, r, x, y, True{})),
    candidates_around(xs, m, e, t, zs, r, x, y, True{}, adv)) :
    {Policy.role_fallback(_, List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      None{} : Maybe<&2, String>}
  Equal.trans(Maybe<&2, String>,
    Policy.role_fallback(
      List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
        I.Folder{m, e, t} <> Policy.role_candidates(zs, r, x, y, True{})),
      List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y),
    Policy.unique_folder(
      List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
        I.Folder{m, e, t} <> Policy.role_candidates(zs, r, x, y, True{}))),
    None{},
    fallback_advertised(Policy.role_candidates(xs, r, x, y, True{}), m, e, t,
      Policy.role_candidates(zs, r, x, y, True{}),
      List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y),
    unique_unselectable(Policy.role_candidates(xs, r, x, y, True{}), m, e, t,
      Policy.role_candidates(zs, r, x, y, True{}), unselectable))

def sole_advertised_folder_takes_the_role(
  before, n, d, at, after, attr, a, b, adv, sel, none_before, none_after):
  +xs = before
  +zs = after
  +m = n
  +e = d
  +t = at
  +r = attr
  +x = a
  +y = b
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y, True{}),
    List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, True{}),
      I.Folder{m, e, t} <> Policy.role_candidates(zs, r, x, y, True{})),
    candidates_around(xs, m, e, t, zs, r, x, y, True{}, adv)) :
    {Policy.role_fallback(_, List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Policy.role_candidates(xs, r, x, y, True{}), [],
    no_advertised_candidates(xs, r, x, y, none_before)) :
    {Policy.role_fallback(
       List.append(&2, I.Folder, _,
         I.Folder{m, e, t} <> Policy.role_candidates(zs, r, x, y, True{})),
       List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Policy.role_candidates(zs, r, x, y, True{}), [],
    no_advertised_candidates(zs, r, x, y, none_after)) :
    {Policy.unique_folder(I.Folder{m, e, t} <> _) == Some{m} : Maybe<&2, String>}
  %Equal.sym(Bool, Policy.selectable(t), True{}, sel) :
    {Bool.pick(Maybe<&2, String>, _, Some{m}, None{}) == Some{m} : Maybe<&2, String>}
  {==}

def two_conventional_folders_take_no_role(
  before, n1, d1, at1, between, n2, d2, at2, after, attr, a, b, none,
  named1, sel1, norole1, named2, sel2, norole2):
  +xs = before
  +ys = between
  +zs = after
  +m1 = n1
  +e1 = d1
  +t1 = at1
  +m2 = n2
  +e2 = d2
  +t2 = at2
  +r = attr
  +x = a
  +y = b
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, True{}),
    [],
    no_advertised_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, none)) :
    {Policy.role_fallback(_,
       List.append(&2, I.Folder, xs,
         I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
       r, x, y) == None{} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, False{}),
    List.append(&2, I.Folder, Policy.role_candidates(xs, r, x, y, False{}),
      I.Folder{m1, e1, t1} <>
        List.append(&2, I.Folder, Policy.role_candidates(ys, r, x, y, False{}),
          I.Folder{m2, e2, t2} <> Policy.role_candidates(zs, r, x, y, False{}))),
    candidates_around_two(xs, m1, e1, t1, ys, m2, e2, t2, zs, r, x, y, False{},
      conventional_match(m1, t1, r, x, y, named1, sel1, norole1),
      conventional_match(m2, t2, r, x, y, named2, sel2, norole2))) :
    {Policy.unique_folder(_) == None{} : Maybe<&2, String>}
  unique_of_two(Policy.role_candidates(xs, r, x, y, False{}), m1, e1, t1,
    Policy.role_candidates(ys, r, x, y, False{}), m2, e2, t2,
    Policy.role_candidates(zs, r, x, y, False{}))

def other_role_folder_never_takes_the_role(before, n, d, at, after, attr, a, b, not_adv, other):
  +xs = before
  +zs = after
  +m = n
  +e = d
  +t = at
  +r = attr
  +x = a
  +y = b
  %Equal.sym(List<&2, I.Folder>,
    Policy.role_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y, True{}),
    Policy.role_candidates(List.append(&2, I.Folder, xs, zs), r, x, y, True{}),
    candidates_without(xs, m, e, t, zs, r, x, y, True{}, not_adv)) :
    {Policy.role_fallback(_, List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      Policy.role_fallback(Policy.role_candidates(List.append(&2, I.Folder, xs, zs), r, x, y, True{}),
        List.append(&2, I.Folder, xs, zs), r, x, y) : Maybe<&2, String>}
  fallback_same(Policy.role_candidates(List.append(&2, I.Folder, xs, zs), r, x, y, True{}),
    List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), List.append(&2, I.Folder, xs, zs),
    r, x, y,
    candidates_without(xs, m, e, t, zs, r, x, y, False{},
      other_role_no_match(m, t, r, x, y, other)))

def each_role_has_its_own_attribute_and_names(fs, drafts, trash, sent, junk, archive):
  {==}

def selectable_is_neither_noselect_nor_nonexistent(at):
  {==}

# Policy.recognized_role asks Policy.role_in over Policy.role_attrs, whose
# list computes to the attributes the law names.
def recognized_roles_are_the_special_use_attributes(at):
  +t = at
  Equal.trans(Bool,
    Policy.recognized_role(t),
    role_attrs_any(Policy.role_attrs(), t),
    advertises_any(
      ["\\Drafts", "\\Sent", "\\Trash", "\\Junk", "\\Archive", "\\All", "\\Flagged"], t),
    role_in_finds_any(Policy.role_attrs(), t),
    {==})
