# Write and prove a MailBend law

Use this guide when you add or change a pure command plan. Keep the promise
in `LAWS.bend` and its proof in `PROOF.bend`, under matching section names.
Never weaken a law to make code pass. Explain each law change in the PR.

## Check the toolchain and the proof boundary

Use the Bend release pinned in [install-bend.sh](../scripts/install-bend.sh)
and the Lean release in [install-lean.sh](../scripts/install-lean.sh).
Run these commands from the repository root:

```sh
bend guide
sh scripts/install-lean.sh
bend PROOF.bend --verdict
python3 tests/formal/check-writing-laws.py
```

Require `ALL PROOFS CHECK`. Plain `bend PROOF.bend` checks the laws with
Bend's checker. `--verdict` also rechecks every definition outside Base with
the proven BendTT kernel. This does not prove that a law states the right
promise. The translation to BendTT is not itself proved.

The checker below extracts this page's marked Bend blocks in order into one
temporary module, then checks that module with `--verdict`. It also requires
a broken production search plan to fail. No snippet sends mail or runs a
native helper. Imports in the first block are relative to that module at
the temporary repository root.

Distinguish example checks from universal proofs in your PR. A concrete
example checks only its chosen inputs. A law with `for` parameters states a promise for
every value of those types, subject to any premises. Neither proves the
native helpers, TLS, runtime configuration, or the IO caller uses the plan.
Keep the relevant tests and source checks. See
[what the proofs cover](../README.md#what-the-proofs-cover).

## Start with an equality that computes

Copy the shape of [`search_writes_nothing`](../LAWS.bend) and its
[`Laws.search_writes_nothing` proof](../PROOF.bend#L69-L70).
The small example keeps the law and proof together. In the repository,
`PROOF.bend` imports `LAWS.bend as Laws`, so its proof name has that prefix.

```bend guide:computation
import Base
import ./src/imap.bend as I
import ./src/ops.bend as Ops

law search_writes_nothing:
  for mbox: String
  for keys: List<&2, I.Key>
  {I.any_writes(Ops.plan_search(mbox, keys)) == False{} : Bool}

def search_writes_nothing(mbox, keys):
  {==}
```

`{a == b : T}` is an equality type, not a Boolean comparison. `{==}` proves
it when both sides compute to the same term. Here the command constructors
determine their effects without inspecting `mbox` or `keys`. This is a
universal proof, not a test with one mailbox and an empty key list.

## Match a computed condition through a lemma

When reduction stops at a computed Boolean, pass that Boolean to a helper
and match its parameter. Follow
[`get_new_writes_nothing`](../LAWS.bend) and
[`get_new_writes_nothing.if`](../PROOF.bend#L122-L133).

```bend guide:computed-condition
law get_new_writes_nothing:
  for mbox: String
  for since: U32
  {I.any_writes(Ops.plan_new(mbox, since)) == False{} : Bool}

def get_new_writes_nothing.if(at_end: Bool, -mbox: String, -since: U32)
  -> {I.any_writes(Ops.plan_new.if(at_end, mbox, since)) == False{} : Bool}:
  match at_end:
    case True{}:
      {==}
    case False{}:
      {==}

def get_new_writes_nothing(mbox, since):
  get_new_writes_nothing.if(U32.is_eq(since, Ops.max_uid()), mbox, since)
```

Both branches must prove the same promise. Do not replace the caller's
computed condition with a convenient constant. `-mbox` and `-since` are
erased parameters used only in the proof's type.

## Induct over a list and join equalities

For an arbitrary list, prove the empty case and recurse on its tail.
These two lemmas support [`thread_plans_write_nothing`](../LAWS.bend).
They are copied from [the thread-search proofs](../PROOF.bend#L140-L161).

```bend guide:list-induction
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
```

`Equal.trans(T, a, b, c, ab, bc)` joins `a == b` and `b == c`.
The first lemma removes the current searches from the equality. The
recursive proof handles the remaining folders. The root law also needs
the headers-plan proof. These two lemmas alone do not prove that part.

## Reuse affine parameters explicitly

Bend parameters are affine by default. If a law parameter goes to two
lemmas, bind a reusable copy. In
[`rename_changes_no_mail`](../LAWS.bend), the proof in
[PROOF.bend](../PROOF.bend#L849-L857) binds `+m = moved` before passing `m` to
`subscribe_moved_changes_no_mail` and `unsubscribe_old_changes_no_mail`.
The list proof above uses `+keys` for the same reason.

Use `+` only when a value is used more than once on a path. Do not add it
to every parameter to silence an error. Distinguish reusable `+x` from
erased `-x`, which cannot supply a runtime value.

## Eliminate an impossible Boolean premise

For contradictory equalities, use the existing `bool_motive` and
`true_is_not_false` pattern from [PROOF.bend](../PROOF.bend#L899-L908).
Its `and_left` lemma helps prove the independent triage promises, including
[`triage_moves_only_to_known_folders`](../LAWS.bend).

```bend guide:contradiction
def bool_motive(b: Bool) -> Type:
  match b:
    case True{}:
      Unit
    case False{}:
      Empty

def true_is_not_false(e: {True{} == False{} : Bool}) -> Empty:
  %e : bool_motive(_)
  Unit{}
```

The motive maps `True` to `Unit` and `False` to `Empty`. Rewriting with
`e` makes the impossible branch require a `Unit`, which `Unit{}` supplies.
Use `Empty.absurd` to finish a goal after obtaining `Empty`. This does not
construct an unconditional proof of `False` or justify assuming a premise.

## Reject a seeded bug before trusting the promise

Run the snippet check again:

```sh
python3 tests/formal/check-writing-laws.py
```

After the kernel check, it copies the production sources and changes
`Ops.plan_search` from `I.CExamine{mbox}` to `I.CSelect{mbox}`. The unchanged
`search_writes_nothing` proof must fail with a Boolean equality mismatch.
A syntax error, missing import, timeout, or unrelated proof failure is not
evidence that the law caught this bug. The checker restores the temporary
source and requires the proofs to pass again. Your checkout is unchanged.

For each new plan, check these risks:

- State the promise independently of the plan's own guard. Do not prove
  only that a guard accepts its own output. Follow the triage laws and
  [their lemmas](../PROOF.bend#L1081-L1168) that derive each promise from
  the guard's verdict.
- Prefer exact plans when command order, caller mailbox, UID list, or
  UIDVALIDITY matters. See
  [`search_continuation_pins_identity`](../LAWS.bend). A predicate that
  accepts any `SELECT` does not establish the caller's mailbox identity.
- Check non-empty accepted cases as well as refused cases. A plan that
  always returns `[]` can satisfy a writes-nothing law while doing no work.
- Check the predicates themselves. If a mutating command is misclassified
  as `ENone`, a writes-nothing proof can pass for the wrong reason.
  [Issue #51](https://github.com/albertc71/MailBend/issues/51) tracks this gap.
- Require a seeded bug to fail the specific promise it breaks. Keep
  classifier, plan, and renderer mutations separate so you know which
  layer rejected each one. Passing one mutation is not complete coverage.
- For a law with premises, exhibit an accepted input that satisfies them.
  An impossible premise makes the implication true without covering any
  real operation. Keep negative examples for the refused branch too.

Existing focused mutation checks run without real mail:

```sh
python3 tests/formal/check-role-folders.py
python3 tests/formal/check-search-contract-mutations.py
```

[Issue #118](https://github.com/albertc71/MailBend/issues/118) tracks the
broader mutation suite. It is not a command available in this checkout.
When it lands, run its documented command and add your plan's mutant
there. Until then, keep a focused test like the checks above.

## Add the plan and its checks together

1. Add the `plan_*` definition in [src/ops.bend](../src/ops.bend).
   Keep mail policy in Bend and build tool commands through these plans.
2. Add a writes-nothing or exact-plan law in [LAWS.bend](../LAWS.bend).
   For a new command or renderer, add an exact rendering law too. Follow
   [`search_headers_render_exactly`](../LAWS.bend).
3. Prove the law in [PROOF.bend](../PROOF.bend), under the same section
   name as its declaration. Declare helpers before their callers.
4. Add the accepted and refused tests and a focused mutation test.
   Confirm that a named proof rejects the mutant for the intended reason.
5. Run `bend PROOF.bend --verdict` and every
   [contributor check](../CONTRIBUTING.md#checks) before committing.
6. Explain the promise, its quantifiers and premises, the rejected bug,
   and the boundary left to tests in the PR.

If a proof stalls, run `bend guide` and inspect the actual goal. Bend has
no mutual recursion, `match` inspects parameters, and definitions precede
use. `Bool.pick`, `&&`, and `||` evaluate both arguments. Recurse once and
choose arguments or the head, rather than placing recursion in both
branches. Use a matching helper when a branch must avoid costly work.

Run `python3 scripts/check-docs.py` after changing the linked law names.
That check catches stale citations, not false claims or invalid snippets.
The generated `docs/LAWS.md` catalogue belongs to
[issue #126](https://github.com/albertc71/MailBend/issues/126) and is not
present here. This guide covers proof technique, not the catalogue's list
of promises.
