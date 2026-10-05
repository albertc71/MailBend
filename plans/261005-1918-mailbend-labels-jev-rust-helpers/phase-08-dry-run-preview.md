---
phase: 8
title: "Phase 8: Dry-run preview"
status: todo
priority: P2
effort: "0.5d"
dependencies: [3, 4, 5, 6]
---

# Phase 8: Dry-run preview

## Goal

Every tool that changes or sends mail accepts `dry_run: true` and returns
the exact commands it would run, without running them.

## Evidence

- Command plans are data rendered by `I.script` (`src/imap.bend:539`), so
  the preview is the same text the helper would receive.
- JulienRabault/icloud-mcp offers dry-run moves; two-phase send approval is
  in 5 competitors (Nylas `confirm_send_*`, himalaya-mcp `confirm=true`, ...).

## Design

- `dry_run` runs the read-only preflight (roles, capabilities, UIDVALIDITY),
  then returns `{dry_run: true, imap: [lines], smtp: {from, rcpt}}` instead
  of calling the helper for the change. The send counter (phase 5) is not
  reserved. Phase 11 adds the Jev verdict to this output.
- APPEND literals and SMTP bodies are summarised as `<N bytes>`, never
  echoed in full.
- One helper `preview_or_run(plan, dry)` in `src/tools.bend` used by every
  mutating tool from phases 3-6; phase 10 uses it for `mail_triage`, and
  phase 11 adds an e2e that enumerates every non-read-only tool.
- Still refused under `MAILBEND_READ_ONLY` (refusal stays simple and
  fail-closed).

## Files

- Modify: `src/tools.bend`, `tools/gen-schema.py`, `tests/test-e2e.py`,
  `README.md`.

Dry runs must leave local state alone too: the download directory
(`mail_get_attachment`, phase 6) and the send counter (phase 5) never appear
in the mail server's log, so the e2e also snapshots both before and after
each dry run, and a helper-call recorder (a wrapper set as
`MAILBEND_ATTACH_HELPER` in the test) asserts that no `save` or `count`
call happens.

## Steps

1. `preview_or_run` and the summary renderer, with unit tests.
2. Thread it through every mutating tool; schema property on each.
3. e2e: for every mutating tool, `dry_run` leaves the fake server's mailbox
   state and command log unchanged except for read-only commands.

## Verification

- `python3 tests/test-e2e.py` (asserts no STORE/COPY/MOVE/EXPUNGE/APPEND/
  CREATE/RENAME/SMTP DATA in the log, no new file in the download
  directory, an unchanged send counter and no `save`/`count` helper call
  during dry runs of send, reply, forward and attachment download, with Jev
  off and on).
