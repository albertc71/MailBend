---
phase: 4
title: "Phase 4: Flags and colours"
status: todo
priority: P2
effort: "0.5d"
dependencies: []
---

# Phase 4: Flags and colours

## Goal

Add `mail_flag` and `mail_unflag`: set or clear `\Flagged`, optionally with
an Apple Mail colour, and report the flags the server actually kept.

## Evidence

- Most common competitor gap: flag toggling in 8+ connectors
  (mcp-email-server, codefuturist, non-dirty, imap-mini, sweetrb, ...).
- `FFlagged` already exists but no tool sets it (`src/imap.bend:14`,
  rendered at `:353`).
- Apple flag colours use `$MailFlagBit0/1/2` as a 3-bit index, only
  meaningful while `\Flagged` is set; clients SHOULD clear the bits on unflag
  (draft-eggert-mailflagcolors-00, an expired individual draft, not an RFC;
  sweetrb/apple-mail-mcp writes the same bits over IMAP).
- Colour index = Bit0 x 1 + Bit1 x 2 + Bit2 x 4: red 0 (no bits), orange 1
  (Bit0), yellow 2 (Bit1), green 3 (Bit0 + Bit1), blue 4 (Bit2), purple 5
  (Bit0 + Bit2), grey 6 (Bit1 + Bit2). draft-eggert-mailflagcolors-00 lists
  green and grey with the same bits, an error in the draft. The green = 3
  value follows sweetrb/apple-mail-mcp's `imapClient.ts`, which says it was
  "Verified against live Mail.app state 2026-08-03: $MailFlagBit0 +
  $MailFlagBit1 -> 3 = green". That quote comes from a fetched summary of
  the file, so the live check still confirms it.
- Whether iCloud keeps arbitrary keywords (`\*` in PERMANENTFLAGS) is
  unverified; the result therefore reports the server's FLAGS after the store.

## Design

- `Flag` gains `FColourBit0{}`, `FColourBit1{}`, `FColourBit2{}` rendered as
  `$MailFlagBit0..2` (a closed set: no free-form keywords).
- `plan_flag(mbox, uids, on, colour, uidv)`: pinned guard, then
  `CStore{uids, on, FFlagged}` and one store per colour bit (set the bits of
  the index, clear the others); unflag clears `\Flagged` and all three bits;
  then `CFetch{uids, [IUid, IFlags]}` so the result shows what was kept.
- Laws: `flag_is_pinned`, `flag_never_deletes` (no `\Deleted`, no expunge),
  `flag_changes_only_flag_bits` (every store in `mail_changes` is on
  `FFlagged` or a colour bit), and the existing `fetch_items_never_set_seen`
  covers the trailing fetch.
- Schema: `colour` enum `red, orange, yellow, green, blue, purple, grey`,
  mapped to bits with the index table above (a pure function with a unit
  test per colour).

## Files

- Modify (plus the contract consumers listed in phase 3): `src/imap.bend`, `src/ops.bend`, `src/tools.bend`, `LAWS.bend`,
  `PROOF.bend`, `tools/gen-schema.py`, `src/schema.bend` (generated),
  `tests/fake_mail_server.py` (keywords, PERMANENTFLAGS option),
  `tests/test-e2e.py`, `tests/unit/imap.bend`.

## Steps

1. Flag variants, rendering, unit tests.
2. Plan, laws, proofs.
3. Tools, schema, read-only gating, result `{changed, missing, flags}`.
4. Fake server: store keywords; an option to drop keywords not in
   PERMANENTFLAGS, so the "server did not keep the colour" path is tested.
5. e2e: flag, flag with colour, unflag clears bits, colour dropped reported.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `python3 tests/test-e2e.py`.

## Risks

- Colour mapping and iCloud keyword support unverified: live check in
  phase 13; the tool still works for plain `\Flagged`.
