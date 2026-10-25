# Role-folder resolution: proofs about Tools.resolved_role in src/tools.bend,
# the def that picks each role's folder (Drafts, Trash, Sent, Junk, Archive)
# from the folders the server listed. Every law holds for every folder list,
# override, role attribute and pair of conventional names, wherever the
# folders stand in the list.

import Base
import ../../src/imap.bend as I
import ../../src/tools.bend as Tools

# Notation
# --------

# Whether any folder of `fs` advertises `attr`, as role resolution reads it.
def advertises(fs: List<&2, I.Folder>, +attr: String) -> Bool:
  match fs:
    case Nil{}:
      False{}
    case I.Folder{name, delim, attrs} <> t:
      I.has_attr(attrs, attr) || advertises(t, attr)

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
  {Tools.resolved_role(fs, override, attr, a, b) == Tools.named_folder(fs, override)
    : Maybe<&2, String>}

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
  {Tools.resolved_role(
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
  for unselectable: {Tools.selectable(at) == False{} : Bool}
  {Tools.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
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
  for sel: {Tools.selectable(at) == True{} : Bool}
  for none_before: {advertises(before, attr) == False{} : Bool}
  for none_after: {advertises(after, attr) == False{} : Bool}
  {Tools.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
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
  for sel1: {Tools.selectable(at1) == True{} : Bool}
  for norole1: {Tools.recognized_role(at1) == False{} : Bool}
  for named2: {(I.same_name(n2, a) || I.same_name(n2, b)) == True{} : Bool}
  for sel2: {Tools.selectable(at2) == True{} : Bool}
  for norole2: {Tools.recognized_role(at2) == False{} : Bool}
  {Tools.resolved_role(
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
  for other: {Tools.recognized_role(at) == True{} : Bool}
  {Tools.resolved_role(List.append(&2, I.Folder, before, I.Folder{n, d, at} <> after),
     "", attr, a, b) ==
    Tools.resolved_role(List.append(&2, I.Folder, before, after), "", attr, a, b)
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
  {Tools.resolved_folders(fs, drafts, trash, sent, junk, archive) ==
    Tools.Folders{
      fs,
      Tools.resolved_role(fs, drafts, "\\Drafts", "Drafts", "Drafts"),
      Tools.resolved_role(fs, trash, "\\Trash", "Trash", "Deleted Messages"),
      Tools.resolved_role(fs, sent, "\\Sent", "Sent", "Sent Messages"),
      Tools.resolved_role(fs, junk, "\\Junk", "Junk", "Junk"),
      Tools.resolved_role(fs, archive, "\\Archive", "Archive", "Archive")
    } : Tools.Folders}

# Examples
# --------

# One instance of each law, on folders like iCloud's, where Trash is
# "Deleted Messages" advertising \Trash. They come before the proofs so
# that, when a change breaks a law, the first failure Bend prints is the
# folder the code now picks here, not a step inside a proof.

def trash_role(fs: List<&2, I.Folder>, override: String) -> Maybe<&2, String>:
  Tools.resolved_role(fs, override, "\\Trash", "Trash", "Deleted Messages")

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
  -> {trash_role(icloud_folders(), "Trash") == Some{"Trash"} : Maybe<&2, String>}:
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

def two_conventional_example()
  -> {trash_role([I.Folder{"Trash", "/", []}, I.Folder{"Deleted Messages", "/", []}], "") ==
       None{} : Maybe<&2, String>}:
  {==}

def other_role_example()
  -> {trash_role([I.Folder{"Trash", "/", ["\\Junk"]}], "") == None{} : Maybe<&2, String>}:
  {==}

def each_role_example()
  -> {Tools.resolved_folders(icloud_folders(), "", "", "", "", "") ==
       Tools.Folders{
         icloud_folders(),
         Some{"Drafts"},
         Some{"Deleted Messages"},
         Some{"Sent Messages"},
         Some{"Junk"},
         Some{"Archive"}
       } : Tools.Folders}:
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

# Tools.role_candidates keeps, in order, the folders that may take the role
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
  -> {Tools.role_candidates(List.append(&2, I.Folder, xs, ys), attr, a, b, adv) ==
       List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
         Tools.role_candidates(ys, attr, a, b, adv)) : List<&2, I.Folder>}:
  match xs:
    case Nil{}:
      {==}
    case I.Folder{n, d, at} <> t:
      +ts = t
      %Equal.sym(List<&2, I.Folder>,
        Tools.role_candidates(List.append(&2, I.Folder, ts, ys), attr, a, b, adv),
        List.append(&2, I.Folder, Tools.role_candidates(ts, attr, a, b, adv),
          Tools.role_candidates(ys, attr, a, b, adv)),
        candidates_append(ts, ys, attr, a, b, adv)) :
        {List.filter.put(I.Folder, I.Folder{n, d, at}, _,
            Tools.role_match(adv, n, at, attr, a, b)) ==
          List.append(&2, I.Folder,
            List.filter.put(I.Folder, I.Folder{n, d, at},
              Tools.role_candidates(ts, attr, a, b, adv),
              Tools.role_match(adv, n, at, attr, a, b)),
            Tools.role_candidates(ys, attr, a, b, adv)) : List<&2, I.Folder>}
      put_append(n, d, at, Tools.role_candidates(ts, attr, a, b, adv),
        Tools.role_candidates(ys, attr, a, b, adv), Tools.role_match(adv, n, at, attr, a, b))

def candidates_keep(
  -n: String, -d: String, -at: List<&2, String>, -t: List<&2, I.Folder>, -attr: String,
  -a: String, -b: String, -adv: Bool,
  e: {Tools.role_match(adv, n, at, attr, a, b) == True{} : Bool})
  -> {Tools.role_candidates(I.Folder{n, d, at} <> t, attr, a, b, adv) ==
       I.Folder{n, d, at} <> Tools.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}:
  %Equal.sym(Bool, Tools.role_match(adv, n, at, attr, a, b), True{}, e) :
    {List.filter.put(I.Folder, I.Folder{n, d, at}, Tools.role_candidates(t, attr, a, b, adv), _) ==
      I.Folder{n, d, at} <> Tools.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}
  {==}

def candidates_drop(
  -n: String, -d: String, -at: List<&2, String>, -t: List<&2, I.Folder>, -attr: String,
  -a: String, -b: String, -adv: Bool,
  e: {Tools.role_match(adv, n, at, attr, a, b) == False{} : Bool})
  -> {Tools.role_candidates(I.Folder{n, d, at} <> t, attr, a, b, adv) ==
       Tools.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}:
  %Equal.sym(Bool, Tools.role_match(adv, n, at, attr, a, b), False{}, e) :
    {List.filter.put(I.Folder, I.Folder{n, d, at}, Tools.role_candidates(t, attr, a, b, adv), _) ==
      Tools.role_candidates(t, attr, a, b, adv) : List<&2, I.Folder>}
  {==}

# No folder advertising the role leaves no advertised candidate.
def no_advertised_candidates(
  fs: List<&2, I.Folder>, +attr: String, -a: String, -b: String,
  none: {advertises(fs, attr) == False{} : Bool})
  -> {Tools.role_candidates(fs, attr, a, b, True{}) == [] : List<&2, I.Folder>}:
  match fs:
    case Nil{}:
      {==}
    case I.Folder{n, d, +at} <> t:
      +ts = t
      +e = none
      Equal.trans(List<&2, I.Folder>,
        Tools.role_candidates(I.Folder{n, d, at} <> ts, attr, a, b, True{}),
        Tools.role_candidates(ts, attr, a, b, True{}),
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
  e: {Tools.role_match(adv, n, at, attr, a, b) == True{} : Bool})
  -> {Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
        attr, a, b, adv) ==
       List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
         I.Folder{n, d, at} <> Tools.role_candidates(ys, attr, a, b, adv))
       : List<&2, I.Folder>}:
  Equal.trans(List<&2, I.Folder>,
    Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
      attr, a, b, adv),
    List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
      Tools.role_candidates(I.Folder{n, d, at} <> ys, attr, a, b, adv)),
    List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
      I.Folder{n, d, at} <> Tools.role_candidates(ys, attr, a, b, adv)),
    candidates_append(xs, I.Folder{n, d, at} <> ys, attr, a, b, adv),
    Equal.cong(List<&2, I.Folder>, List<&2, I.Folder>,
      zs => List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv), zs),
      Tools.role_candidates(I.Folder{n, d, at} <> ys, attr, a, b, adv),
      I.Folder{n, d, at} <> Tools.role_candidates(ys, attr, a, b, adv),
      candidates_keep(n, d, at, ys, attr, a, b, adv, e)))

def candidates_around_two(
  +xs: List<&2, I.Folder>, +n1: String, +d1: String, +at1: List<&2, String>,
  +ys: List<&2, I.Folder>, +n2: String, +d2: String, +at2: List<&2, String>,
  +zs: List<&2, I.Folder>, +attr: String, +a: String, +b: String, +adv: Bool,
  e1: {Tools.role_match(adv, n1, at1, attr, a, b) == True{} : Bool},
  e2: {Tools.role_match(adv, n2, at2, attr, a, b) == True{} : Bool})
  -> {Tools.role_candidates(
        List.append(&2, I.Folder, xs,
          I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs)),
        attr, a, b, adv) ==
       List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
         I.Folder{n1, d1, at1} <>
           List.append(&2, I.Folder, Tools.role_candidates(ys, attr, a, b, adv),
             I.Folder{n2, d2, at2} <> Tools.role_candidates(zs, attr, a, b, adv)))
       : List<&2, I.Folder>}:
  %candidates_around(ys, n2, d2, at2, zs, attr, a, b, adv, e2) :
    {Tools.role_candidates(
       List.append(&2, I.Folder, xs,
         I.Folder{n1, d1, at1} <> List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs)),
       attr, a, b, adv) ==
      List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
        I.Folder{n1, d1, at1} <> _) : List<&2, I.Folder>}
  candidates_around(xs, n1, d1, at1,
    List.append(&2, I.Folder, ys, I.Folder{n2, d2, at2} <> zs), attr, a, b, adv, e1)

def candidates_without(
  +xs: List<&2, I.Folder>, +n: String, +d: String, +at: List<&2, String>,
  +ys: List<&2, I.Folder>, +attr: String, +a: String, +b: String, +adv: Bool,
  e: {Tools.role_match(adv, n, at, attr, a, b) == False{} : Bool})
  -> {Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
        attr, a, b, adv) ==
       Tools.role_candidates(List.append(&2, I.Folder, xs, ys), attr, a, b, adv)
       : List<&2, I.Folder>}:
  %Equal.sym(List<&2, I.Folder>,
    Tools.role_candidates(List.append(&2, I.Folder, xs, ys), attr, a, b, adv),
    List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv),
      Tools.role_candidates(ys, attr, a, b, adv)),
    candidates_append(xs, ys, attr, a, b, adv)) :
    {Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
       attr, a, b, adv) == _ : List<&2, I.Folder>}
  %candidates_drop(n, d, at, ys, attr, a, b, adv, e) :
    {Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys),
       attr, a, b, adv) ==
      List.append(&2, I.Folder, Tools.role_candidates(xs, attr, a, b, adv), _)
      : List<&2, I.Folder>}
  candidates_append(xs, I.Folder{n, d, at} <> ys, attr, a, b, adv)

# Uniqueness
# ----------

# Tools.unique_folder names a folder only for a single candidate that can
# be selected: never for two, wherever they stand, nor for an unselectable
# one.

def unique_of_two(
  xs: List<&2, I.Folder>, -n1: String, -d1: String, -at1: List<&2, String>,
  ys: List<&2, I.Folder>, -n2: String, -d2: String, -at2: List<&2, String>,
  -zs: List<&2, I.Folder>)
  -> {Tools.unique_folder(
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
  ys: List<&2, I.Folder>, unselectable: {Tools.selectable(at) == False{} : Bool})
  -> {Tools.unique_folder(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys)) ==
       None{} : Maybe<&2, String>}:
  match xs ys:
    case Nil{} Nil{}:
      %Equal.sym(Bool, Tools.selectable(at), False{}, unselectable) :
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

# Tools.role_fallback takes the advertised candidates when there are any,
# and reads the folder list only when there are none.

def fallback_advertised(
  xs: List<&2, I.Folder>, -n: String, -d: String, -at: List<&2, String>,
  -ys: List<&2, I.Folder>, -fs: List<&2, I.Folder>, -attr: String, -a: String, -b: String)
  -> {Tools.role_fallback(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys), fs, attr, a, b)
       == Tools.unique_folder(List.append(&2, I.Folder, xs, I.Folder{n, d, at} <> ys))
       : Maybe<&2, String>}:
  match xs:
    case Nil{}:
      {==}
    case I.Folder{xn, xd, xa} <> xt:
      {==}

def fallback_same(
  marked: List<&2, I.Folder>, -fs: List<&2, I.Folder>, -gs: List<&2, I.Folder>, -attr: String,
  -a: String, -b: String,
  same: {Tools.role_candidates(fs, attr, a, b, False{}) ==
    Tools.role_candidates(gs, attr, a, b, False{}) : List<&2, I.Folder>})
  -> {Tools.role_fallback(marked, fs, attr, a, b) == Tools.role_fallback(marked, gs, attr, a, b)
       : Maybe<&2, String>}:
  match marked:
    case Nil{}:
      %same : {Tools.unique_folder(Tools.role_candidates(fs, attr, a, b, False{})) ==
        Tools.unique_folder(_) : Maybe<&2, String>}
      {==}
    case h <> t:
      {==}

# Matches
# -------

def conventional_match(
  -n: String, at: List<&2, String>, -attr: String, -a: String, -b: String,
  named: {(I.same_name(n, a) || I.same_name(n, b)) == True{} : Bool},
  sel: {Tools.selectable(at) == True{} : Bool},
  norole: {Tools.recognized_role(at) == False{} : Bool})
  -> {Tools.role_match(False{}, n, at, attr, a, b) == True{} : Bool}:
  %Equal.sym(Bool, I.same_name(n, a) || I.same_name(n, b), True{}, named) :
    {(_ && Tools.selectable(at)) && Bool.not(Tools.recognized_role(at)) == True{} : Bool}
  %Equal.sym(Bool, Tools.selectable(at), True{}, sel) :
    {_ && Bool.not(Tools.recognized_role(at)) == True{} : Bool}
  %Equal.sym(Bool, Tools.recognized_role(at), False{}, norole) :
    {Bool.not(_) == True{} : Bool}
  {==}

def other_role_no_match(
  +n: String, +at: List<&2, String>, -attr: String, +a: String, +b: String,
  other: {Tools.recognized_role(at) == True{} : Bool})
  -> {Tools.role_match(False{}, n, at, attr, a, b) == False{} : Bool}:
  %Equal.sym(Bool, Tools.recognized_role(at), True{}, other) :
    {((I.same_name(n, a) || I.same_name(n, b)) && Tools.selectable(at)) && Bool.not(_) ==
      False{} : Bool}
  and_false((I.same_name(n, a) || I.same_name(n, b)) && Tools.selectable(at))

# Law proofs
# ----------

# With an empty override, Tools.resolved_role is Tools.role_fallback over
# the advertised candidates. Each proof rewrites those candidates through
# the lemmas above, then lets the fallback and uniqueness lemmas decide.

def override_decides_the_role(fs, override, attr, a, b, set):
  +o = override
  %Equal.sym(Bool, String.is_empty(o), False{}, set) :
    {Tools.resolved_role.if(_, fs, o, attr, a, b) == Tools.named_folder(fs, o)
      : Maybe<&2, String>}
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
    Tools.role_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, True{}),
    List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
      I.Folder{m1, e1, t1} <>
        List.append(&2, I.Folder, Tools.role_candidates(ys, r, x, y, True{}),
          I.Folder{m2, e2, t2} <> Tools.role_candidates(zs, r, x, y, True{}))),
    candidates_around_two(xs, m1, e1, t1, ys, m2, e2, t2, zs, r, x, y, True{}, adv1, adv2)) :
    {Tools.role_fallback(_,
       List.append(&2, I.Folder, xs,
         I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
       r, x, y) == None{} : Maybe<&2, String>}
  Equal.trans(Maybe<&2, String>,
    Tools.role_fallback(
      List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
        I.Folder{m1, e1, t1} <>
          List.append(&2, I.Folder, Tools.role_candidates(ys, r, x, y, True{}),
            I.Folder{m2, e2, t2} <> Tools.role_candidates(zs, r, x, y, True{}))),
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y),
    Tools.unique_folder(
      List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
        I.Folder{m1, e1, t1} <>
          List.append(&2, I.Folder, Tools.role_candidates(ys, r, x, y, True{}),
            I.Folder{m2, e2, t2} <> Tools.role_candidates(zs, r, x, y, True{})))),
    None{},
    fallback_advertised(Tools.role_candidates(xs, r, x, y, True{}), m1, e1, t1,
      List.append(&2, I.Folder, Tools.role_candidates(ys, r, x, y, True{}),
        I.Folder{m2, e2, t2} <> Tools.role_candidates(zs, r, x, y, True{})),
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y),
    unique_of_two(Tools.role_candidates(xs, r, x, y, True{}), m1, e1, t1,
      Tools.role_candidates(ys, r, x, y, True{}), m2, e2, t2,
      Tools.role_candidates(zs, r, x, y, True{})))

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
    Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y, True{}),
    List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
      I.Folder{m, e, t} <> Tools.role_candidates(zs, r, x, y, True{})),
    candidates_around(xs, m, e, t, zs, r, x, y, True{}, adv)) :
    {Tools.role_fallback(_, List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      None{} : Maybe<&2, String>}
  Equal.trans(Maybe<&2, String>,
    Tools.role_fallback(
      List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
        I.Folder{m, e, t} <> Tools.role_candidates(zs, r, x, y, True{})),
      List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y),
    Tools.unique_folder(
      List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
        I.Folder{m, e, t} <> Tools.role_candidates(zs, r, x, y, True{}))),
    None{},
    fallback_advertised(Tools.role_candidates(xs, r, x, y, True{}), m, e, t,
      Tools.role_candidates(zs, r, x, y, True{}),
      List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y),
    unique_unselectable(Tools.role_candidates(xs, r, x, y, True{}), m, e, t,
      Tools.role_candidates(zs, r, x, y, True{}), unselectable))

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
    Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y, True{}),
    List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, True{}),
      I.Folder{m, e, t} <> Tools.role_candidates(zs, r, x, y, True{})),
    candidates_around(xs, m, e, t, zs, r, x, y, True{}, adv)) :
    {Tools.role_fallback(_, List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Tools.role_candidates(xs, r, x, y, True{}), [],
    no_advertised_candidates(xs, r, x, y, none_before)) :
    {Tools.role_fallback(
       List.append(&2, I.Folder, _,
         I.Folder{m, e, t} <> Tools.role_candidates(zs, r, x, y, True{})),
       List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      Some{m} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>, Tools.role_candidates(zs, r, x, y, True{}), [],
    no_advertised_candidates(zs, r, x, y, none_after)) :
    {Tools.unique_folder(I.Folder{m, e, t} <> _) == Some{m} : Maybe<&2, String>}
  %Equal.sym(Bool, Tools.selectable(t), True{}, sel) :
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
    Tools.role_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, True{}),
    [],
    no_advertised_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, none)) :
    {Tools.role_fallback(_,
       List.append(&2, I.Folder, xs,
         I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
       r, x, y) == None{} : Maybe<&2, String>}
  %Equal.sym(List<&2, I.Folder>,
    Tools.role_candidates(
      List.append(&2, I.Folder, xs,
        I.Folder{m1, e1, t1} <> List.append(&2, I.Folder, ys, I.Folder{m2, e2, t2} <> zs)),
      r, x, y, False{}),
    List.append(&2, I.Folder, Tools.role_candidates(xs, r, x, y, False{}),
      I.Folder{m1, e1, t1} <>
        List.append(&2, I.Folder, Tools.role_candidates(ys, r, x, y, False{}),
          I.Folder{m2, e2, t2} <> Tools.role_candidates(zs, r, x, y, False{}))),
    candidates_around_two(xs, m1, e1, t1, ys, m2, e2, t2, zs, r, x, y, False{},
      conventional_match(m1, t1, r, x, y, named1, sel1, norole1),
      conventional_match(m2, t2, r, x, y, named2, sel2, norole2))) :
    {Tools.unique_folder(_) == None{} : Maybe<&2, String>}
  unique_of_two(Tools.role_candidates(xs, r, x, y, False{}), m1, e1, t1,
    Tools.role_candidates(ys, r, x, y, False{}), m2, e2, t2,
    Tools.role_candidates(zs, r, x, y, False{}))

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
    Tools.role_candidates(List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y, True{}),
    Tools.role_candidates(List.append(&2, I.Folder, xs, zs), r, x, y, True{}),
    candidates_without(xs, m, e, t, zs, r, x, y, True{}, not_adv)) :
    {Tools.role_fallback(_, List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), r, x, y) ==
      Tools.role_fallback(Tools.role_candidates(List.append(&2, I.Folder, xs, zs), r, x, y, True{}),
        List.append(&2, I.Folder, xs, zs), r, x, y) : Maybe<&2, String>}
  fallback_same(Tools.role_candidates(List.append(&2, I.Folder, xs, zs), r, x, y, True{}),
    List.append(&2, I.Folder, xs, I.Folder{m, e, t} <> zs), List.append(&2, I.Folder, xs, zs),
    r, x, y,
    candidates_without(xs, m, e, t, zs, r, x, y, False{},
      other_role_no_match(m, t, r, x, y, other)))

def each_role_has_its_own_attribute_and_names(fs, drafts, trash, sent, junk, archive):
  {==}
