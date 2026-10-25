---
name: role-folder-proofs
description: Recheck MailBend's role-folder proofs when a change touches how the Drafts, Trash, Sent, Junk or Archive folder is chosen from the server's folder list (resolved_role and its helpers in src/tools.bend, I.has_attr or I.same_name in src/imap.bend), the role overrides or conventional names, or tests/formal/role-folders.bend itself.
---

# Role-folder resolution proofs

**Property.** For every folder list the server can return, `Tools.resolved_role` names a role folder only by the documented precedence (an override, else the one selectable folder advertising the role, else the one selectable folder with a conventional name), and never guesses when that tier is ambiguous or unselectable.

**Harm it prevents.** A guessed Trash, Drafts or Sent folder sends `mail_trash`, draft saves and Sent copies into a folder the user never meant: on iCloud, Trash is `Deleted Messages` advertising `\Trash`, and a user folder named `Trash` must not take its place.

The proofs are about the real Bend code, not a model: `tests/formal/role-folders.bend` imports `src/tools.bend` and proves seven laws about it with Bend's checker. `bend PROOF.bend --verdict` imports that file, so CI also rechecks the proofs with Bend's proven kernel.

## The laws

Each holds for every folder list (any length, the folders anywhere in it), every override string, every role attribute and every pair of conventional names, so it covers all five roles.

| Law | In plain words | Example that shows it |
| --- | --- | --- |
| `override_decides_the_role` | With an override set, only the override decides; no advertised role or name can take the role instead. | `override_example` |
| `two_advertised_folders_take_no_role` | Two folders advertising the role: no folder takes it. | `two_advertised_example` |
| `sole_advertised_folder_takes_the_role` | The one selectable folder advertising the role takes it, whatever the other folders are named. | `sole_advertised_example` |
| `unselectable_advertised_folder_takes_no_role` | A folder advertising the role that cannot be selected (`\Noselect`, `\NonExistent`): no folder takes it, with no fallback to a conventional name. | `unselectable_advertised_example` |
| `two_conventional_folders_take_no_role` | No folder advertises the role, and two selectable folders with no role of their own have a conventional name: no folder takes it. | `two_conventional_example` |
| `other_role_folder_never_takes_the_role` | A folder advertising another role (say `Trash` with `\Junk`) never takes this one by name; adding it anywhere changes nothing. | `other_role_example` |
| `each_role_has_its_own_attribute_and_names` | `resolved_folders` resolves Drafts by `\Drafts`/`Drafts`, Trash by `\Trash`/`Trash`/`Deleted Messages`, Sent by `\Sent`/`Sent`/`Sent Messages`, Junk by `\Junk`/`Junk` and Archive by `\Archive`/`Archive`, each with its own override. | `each_role_example` |

These are the promises in README.md's "Configure" section (the precedence paragraph and the override table) and AGENTS.md's role-folder rule. The examples are concrete instances on iCloud-like folders, placed before the proofs, so that when a law breaks, the first failure Bend prints names the folder the code now picks.

## Does my change touch it?

Coverage record. The proofs cover these defs in `src/tools.bend`, under "Special-use attributes" and "Role resolution": `RoleAttr`, `role_attrs`, `role_in`, `recognized_role`, `selectable`, `role_match`, `role_candidates`, `unique_folder`, `role_fallback`, `role`, `override_candidates`, `named_folder`, `resolved_role.if`, `resolved_role`, `drafts_name` through `archive_name`, and `resolved_folders`. The laws treat `I.has_attr` and `I.same_name` (`src/imap.bend`) as given: they hold whatever those return, and only the examples depend on their case rules.

Last confirmed at commit `ae13d95e71555b83e807eb5502d4d4e3375d40c4`, where the proofs describe the covered code. To see whether anything moved since:

```sh
git diff ae13d95e71555b83e807eb5502d4d4e3375d40c4 -- src/tools.bend src/imap.bend tests/formal/role-folders.bend tests/formal/check-role-folders.py
```

Run the checks below if that diff touches a covered def, `I.has_attr`, `I.same_name` or `I.Folder`, or if your change alters which folder any role resolves to. A change elsewhere in those files (another tool, say) needs no recheck, though the checks are cheap enough to run anyway.

## Run it

Bend and Lean come from the repo's pinned installers. Install them once if `bend` is missing, then put both on `PATH`:

```sh
sh scripts/install-bend.sh && sh scripts/install-lean.sh   # only if bend or lean is missing
export PATH="$HOME/.bend/bin:$HOME/.elan/bin:$PATH" BEND_NO_TELEMETRY=1
```

From the repository root:

```sh
bend tests/formal/role-folders.bend --check-only   # about 10 s; the loop while editing
python3 tests/formal/check-role-folders.py         # about 35 s; proofs, then 8 broken variants must fail
bend PROOF.bend --verdict                          # about 1.5 min; every proof, rechecked by the kernel
```

A pass prints `ALL PROOFS CHECK`. The mutation check prints one `PASS rejected <name>: <example> gives <wrong folder>, not <right folder>` line per broken variant and ends with `PASS checkout unchanged`. It copies `src/` into a temporary directory and never edits the checkout. All three run in CI (`.github/workflows/ci.yml`) and are listed in CONTRIBUTING.md.

## Reading a failure

Bend stops at the first failing def and prints `expected` (what the code computes) and `observed` (what the def claims), then `Location: <def>`.

- **An example fails** (`Location: <name>_example`): the code now resolves that folder list differently. The `expected` line is the folder the code picks, so read it as the counterexample. For instance, if `two_advertised_example` expects `Some{"Deleted Messages"}`, the code would put trash into one of two `\Trash` folders. Compare against README.md's precedence. Unless the change was meant to alter the precedence, this is a real bug in the product code: fix the code, never the example or the law.
- **Only a proof fails** (a lemma such as `candidates_append`, or a law's own def): if every example still passes, the behaviour probably held and the proof no longer follows the code's shape, because a helper was renamed, a condition reordered, or `&&` regrouped. Before deciding, write the law's statement out for the new code and look for an input that breaks it. Add that input as an example if you find one. Otherwise update the lemma to the new shape.
- **The mutation check stops with `mutation target not found once`**: the text of a covered def changed, so a mutation in `MUTATIONS` in `tests/formal/check-role-folders.py` no longer applies. Point it at the same behaviour in the new code, then rerun to see that variant rejected again.
- **`unknown name` or import errors**: a covered def was renamed or moved. Update the names in `tests/formal/role-folders.bend` (it imports `../../src/tools.bend as Tools` and `../../src/imap.bend as I`).

## Changing the verification on purpose

- **Precedence change** (a new tier, a new conventional name, a different ambiguity rule): the laws are the owner's promises. Change README.md's precedence and table, the affected law, its example and the proof together, and explain the changed law in the pull request (AGENTS.md: laws are the owner's). Never weaken a law, or delete an example, just to get a pass.
- **A new role** (a sixth role folder): add it to `each_role_has_its_own_attribute_and_names` and `each_role_example`. The other laws are generic over the attribute and names, so they already cover it.
- **Refactor with the same behaviour**: keep the laws and examples as they are, and repair the lemmas.
- Every law must still be able to fail. After a change, `python3 tests/formal/check-role-folders.py` must report every mutation rejected. When you add a law, add a mutation that breaks it and an example that catches it first.

Bend's own rules apply to the proof file: `bend guide` explains them, and the lemma style follows PROOF.bend. Rewriting with `%e : P` turns the `_` in `P` from the right side of `e` into its left. A Bool premise is used through `Equal.sym` and a rewrite. A computed Bool that blocks reduction goes through a lemma that matches it as a parameter.

## Scope

Verified, for every input: the precedence of one role's resolution (`resolved_role`) and the per-role attributes and names (`resolved_folders`). There are no size bounds. The assumptions are that Bend's checker and its Lean-proven kernel are sound, and that the compiled core runs the same Bend source.

Not covered by these proofs, and left to the end-to-end tests in `tests/test-e2e.py`:
- folder discovery: `plan_roles`, `merge_folders`, and `roles_of` refusing to guess after a failed extended LIST;
- override validation: `invalid_override`, `validate_overrides`;
- what each tool does with a resolved or missing role (refusing a trash with no Trash folder, the reserved names that folder tools protect);
- the case rules of `I.has_attr` and `I.same_name`;
- whether a sole conventional-name match is chosen (only the refusals at that tier are proven).

## Keeping it in step

When the diff above touches covered code, rerun all three checks. If a def's meaning changed, review its law against README.md. Move the commit in "Does my change touch it?" forward to the new commit only after you have confirmed that the laws, examples and mutation targets describe the code at that commit and every check passes. Use `/maintain-formal-verification-skill` to bring this skill back in line after changes that did not recheck it.
