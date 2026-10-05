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

Add `mail_triage`: apply Jev's labels and move safe-to-delete mail into the
protected "To Delete" review folder for the user's review. Jev never deletes.

## Evidence

- User decisions: Jev never deletes; safe-to-delete is a move into "To
  Delete"; labels are copies.
- iCloud has no MOVE (`docs/CLOUD_AGENT.md:285`), so `plan_move` falls back
  to COPY, `\Deleted` store and UID EXPUNGE of exactly the copied UIDs
  (`src/ops.bend:179-197`; laws `copy_move_changes_exactly`,
  `move_expunges_only_copied`). A law "triage never expunges" would be false;
  the correct law ties triage to the proven move plan and the review folder.
- After a copy-fallback move the source UIDs are expunged, so a label copy
  run afterwards would name UIDs that no longer exist (red team).
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

`mail_triage(folder, uids, uidvalidity, labels?, dry_run?)`:

- All label copies first (phase 3 `plan_label`, de-duplicated), labels
  reported from the server's COPYUID response; then `SafeToDelete`
  messages move into `To Delete` with `plan_move`.
- `dry_run` goes through phase 8's `preview_or_run`.
- Returns per message: labels applied, moved, verdict, and the `jev` object.

Laws:

- `triage_moves_only_to_review`: for every verdict list, every move plan in
  triage has destination `To Delete`.
- `triage_labels_only_copy`: every label plan's `mail_changes` is one CCopy
  and its `mailbox_changes` is empty.
- `triage_expunges_only_moved`: any `destroys_mail` command in a triage plan
  sits inside a move plan whose expunge equals its copy.
- `triage_labels_before_moves`: in the triage command sequence, no COPY to a
  label folder follows the first move.
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
4. e2e on a server without MOVE (copy fallback) and with MOVE: labels
   copied once and before moves, safe message moved to review, vetoed
   message untouched, missing review folder refused, headers mode never
   moves, `mail_move` and `mail_rename_folder` into `To Delete` refused.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `python3 tests/test-e2e.py`.

## Risks

- Calibration: cautious thresholds; the user's review of "To Delete" is the
  feedback loop.
