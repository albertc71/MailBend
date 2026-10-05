---
phase: 10
title: "Phase 10: Jev triage and delete review"
status: todo
priority: P1
effort: "1.5d"
dependencies: [3, 8, 9]
---

# Phase 10: Jev triage and delete review

## Goal

Add `mail_triage`: move each message into its label (category) folder
(inbox-zero style, no duplicate copies), or move safe-to-delete mail into
the protected "To Delete" review folder for the user's review. Jev never
deletes.

## Evidence

- User decisions: Jev never deletes; safe-to-delete is a move into "To
  Delete"; a label is a move into one folder, no duplicates; the category
  is that label folder; categories come from existing folders, with new ones
  proposed by the agent and chosen by Jev in a second call (phase 9).
- iCloud has no MOVE (`docs/CLOUD_AGENT.md:285`), so `plan_move` falls back
  to COPY, `\Deleted` store and UID EXPUNGE of exactly the copied UIDs
  (`src/ops.bend:179-197`; laws `copy_move_changes_exactly`,
  `move_expunges_only_copied`). A law "triage never expunges" would be false;
  the correct law ties triage to the proven move plan and the review folder.
- After a copy-fallback move the source UIDs are expunged, so each message
  may get exactly one move per triage call (red team).
- Red team: a caller-chosen review folder could be Trash, which iCloud
  purges, breaking "Jev never deletes"; role overrides are environment-only
  today (`src/tools.bend:390-402`).
- TypeSafe composite scoring is compensating; delete safety uses separate
  vetoes where any one keeps the message (`/patterns/composite-scoring.md`).

## Design

Review folder: the constant `To Delete`. It must already exist (created
with `mail_create_folder`); triage refuses otherwise. Phase 3 protects it:
no tool except `mail_triage` moves, copies or renames into or out of it, and
it can never be a role folder or INBOX.

Triage verdict (pure, `src/jev.bend`):

- Code vetoes first: `\Flagged`, `\Answered`, has attachments
  (BODYSTRUCTURE), younger than 30 days, sender the user has written to (one
  read-only search of Sent by `TO <addr>`).
- Jev vetoes (Noul, yes means keep): record, account security, personally
  written, open action or deadline, needed again; plus a disposability
  Score.
- `SafeToDelete` only when all code vetoes pass, every Jev veto is `Low`,
  disposability is `High` with high confidence, and content mode is `body`;
  `Keep` when any veto fires; `Review` otherwise.

`mail_triage(folder, uids, uidvalidity, dry_run?)`:

- Runs the phase 9 classification over the existing folders (one Jev
  request per batch).
- One move per message, decided in this order: `SafeToDelete` moves
  into `To Delete`; otherwise a category at or above the confidence floor
  moves into that existing label folder (phase 3 `plan_label`, a proven
  move); otherwise the message stays.
  Messages marked `needs_new_category` stay put and are returned so the
  agent can run the phase 9 candidate step, create the folder with
  `mail_create_folder`, and call triage again.
- Moves into the same destination are grouped into one `plan_move`.
- `dry_run` goes through phase 8's `preview_or_run`.
- Returns per message: destination (label folder, `To Delete` or none),
  verdict, and the `jev` object.

Laws:

- `triage_moves_only_to_known_folders`: for every verdict list and folder
  list, every move plan's destination is `To Delete` or a member of the
  discovered category folders passed in; never INBOX or a role folder.
- `triage_creates_no_mailbox`: `mailbox_changes` of every triage plan is
  empty (new categories exist only through `mail_create_folder`).
- `triage_one_move_per_message`: no UID appears in two move plans.
- `triage_expunges_only_moved`: any `destroys_mail` command in a triage plan
  sits inside a move plan whose expunge equals its copy.
- `uncertain_changes_nothing`: `Review` and `Missing` produce no plan.

The explicit-delete gate is phase 11's, not this verdict: triage asks "is
this proven disposable?", the delete gate asks "did any veto fire?".

## Files

- Modify: `src/jev.bend`, `src/ops.bend`, `src/tools.bend`, `LAWS.bend`,
  `PROOF.bend`, `tools/gen-schema.py`, `tests/unit/jev.bend`,
  `tests/fake_typesafe.py` (scripted answers per message),
  `tests/test-e2e.py`.

## Steps

1. Verdict function with exhaustive unit tests over bands.
2. Triage plans and laws.
3. `mail_triage` with `dry_run`; schema; MCP annotations.
4. e2e on a server without MOVE (copy fallback) and with MOVE: each message
   ends up in exactly one folder (no duplicate copies), safe message moved
   to review, vetoed
   message untouched, missing review folder refused, headers mode never
   moves, `mail_move` and `mail_rename_folder` into `To Delete` refused.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `python3 tests/test-e2e.py`.

## Risks

- Calibration: cautious thresholds; the user's review of "To Delete" is the
  feedback loop.
