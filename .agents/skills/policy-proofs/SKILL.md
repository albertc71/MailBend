---
name: policy-proofs
description: Recheck switch refusal, malformed Boolean configuration, command classifier, exact draft and role provenance laws when changing src/policy.bend, IMAP effects, plan_draft, their callers or proof imports.
---

# Policy and classifier proofs

The laws prevent a safety switch from silently allowing a forbidden call, a
mutating command from disappearing from the write classifiers, a draft from
performing another command, or role resolution from inventing a target folder.

## Coverage

`LAWS.bend` states these properties and `PROOF.bend` proves them for all inputs.

- Every mutating IMAP constructor has its specified effect, is writing, and
  makes `any_writes` true on its singleton plan, for every constructor argument.
  A separate law pins the empty case and checks every head and tail in a plan.
- `sends` classifies `mail_send` as sending, and Reply and Forward as sending
  unless the raw JSON `as_draft` field is true. It classifies other operations as
  not sending. Dispatch can still refuse a call.
- Read-only refuses non-read-only operations, drafts-only refuses sends, and
  Jev-off refuses operations that need Jev, for every JSON argument value.
- Any Boolean switch string outside empty, 0, 1, and case-insensitive false or
  true produces `FlagBad`. A bad flag in any of the five positions rejects
  `config_of`, regardless of the other settings or which error is reported first.
- `plan_draft` is exactly one APPEND of its message to its folder argument, with
  Draft and Seen flags. No command classifier is used to filter that equality.
- Every resolved role has a structural witness of an exact name and selectable
  folder in the original listing. Both override and discovery paths are covered
  for lists of any length. The existing role-folder skill covers precedence.
- `helper_lost(ProcRefused)` is false. This is not a claim that every refusal
  returns `Out.Err`. SMTP intentionally returns structured `Out.Partial` data
  with `smtp_outcome=not_sent` when its helper never started.

The laws do not prove environment IO, dispatch, native helpers, wire escaping,
provider behavior, human approval, or the truth of Jev's answers. The policy
module has no direct IO, but its dependencies include existing IO definitions.

## Run

Use the pinned Bend and Lean installers from CONTRIBUTING.md, then run:

```sh
bend PROOF.bend --verdict
bend src/tools.bend --verdict
python3 tests/formal/check-policy.py
python3 tests/formal/check-role-folders.py
```

Both verdict commands must print `ALL PROOFS CHECK`. The second retains the tool
layer's kernel coverage after the policy proof entry stops importing tools and
schema. It does not add behavioral laws to tool orchestration.

The policy checker follows local proof imports, forbids tools and schema in
that closure, and checks that policy has no direct IO. It copies production
source, extracts the universal policy law section without examples, and requires
each deliberate mutation to fail at its named law or structural proof helper.
Parser errors, affine-use errors, timeouts, and unrelated failures do not count.
It checks the original checkout and the restored copy too.

## Maintain

Do not weaken a law or accept an arbitrary nonzero exit to make a mutation pass.
If source text moves, update each exact-once mutation target and preserve the
behavior it breaks. If a definition moves, migrate its production callers,
proofs and mutation targets together. Keep the existing role precedence laws.
Read a failed theorem's expected and observed values before changing its proof.
Run the full contributor checks after changes to policy or its callers.

The runtime definitions were last compared with
`bbe96fe33e7660b980606ad470a02d25669ea284`, where the 68 moved definitions lived
in `src/tools.bend`. Their code is unchanged apart from namespace qualification.
Advance this reference only after confirming correspondence and rerunning the
checks above. Keep new policy laws inside the section markers that the mutation
checker extracts, or update the checker with the section move.

A TypeScript/BendTT mismatch is not a pass. Preserve the theorem and repair the
proof shape, or report the toolchain blocker. A reusable continuation can need a
direct result case split rather than an affine higher-order proof helper.
