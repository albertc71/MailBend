---
phase: 7
title: "Phase 7: Threads"
status: todo
priority: P2
effort: "1d"
dependencies: [3]
---

# Phase 7: Threads

## Goal

Add `mail_get_thread`: given a message, return the conversation it belongs
to (headers, dates, folders, UIDs) in order, read-only.

## Evidence

- Thread retrieval is in 8 competitors (codefuturist, Nylas list_threads,
  himalaya-mcp, anishhs, Fastmail JMAP, JulienRabault, ...).
- MailBend already parses `References` and `In-Reply-To` for replies
  (`src/tools.bend:1485-1486`) but has no thread tool.
- Phase 3 adds `KHeader` and `KUndeleted`, which threads reuse.
- Bend constraints: no mutual recursion and defs before use (AGENTS.md
  "When using Bend"), so threading is written as list folds, not a recursive
  tree walk.

## Design

- Start: fetch headers of the UID (`plan_headers`).
- Search (one read-only session) the source folder and the resolved Sent
  folder for messages whose Message-ID is in the start's References or
  In-Reply-To, and messages whose References or In-Reply-To contain the
  start's Message-ID (`KHeader`, plus `KUndeleted`).
- At most two rounds of expansion, then fetch headers of the found UIDs.
- Pure `thread_order(msgs)` in a new `src/thread.bend`: parent by
  In-Reply-To, else the last References entry present; order by date,
  then UID; no subject-based grouping (deterministic, no guesses).
- Laws: `thread_plans_write_nothing` for every folder list and key list.
- Unit tests for ordering, missing parents, cycles in broken headers
  (cut at the first repeat).

## Files

- Create: `src/thread.bend`, `tests/unit/thread.bend`.
- Modify: `src/ops.bend`, `src/tools.bend`, `LAWS.bend`, `PROOF.bend`,
  `tools/gen-schema.py`, `tests/run-unit.sh`, `tests/test-e2e.py`,
  `tests/fixtures/mailbox.json` (a three-message thread across INBOX and Sent).

## Steps

1. `thread.bend` with unit tests.
2. Plans, laws, tool, schema; read-only list update.
3. e2e on the fixture thread.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `python3 tests/test-e2e.py`.

## Risks

- iCloud HEADER search semantics unverified (phase 13 live check).
- HEADER search is a substring match; candidates are confirmed by comparing
  fetched Message-ID, References and In-Reply-To values exactly.
