---
phase: 13
title: "Phase 13: Release checks and PR"
status: todo
priority: P1
effort: "0.5d"
dependencies: [12]
---

# Phase 13: Release checks and PR

## Goal

Run every gate, open the PR, and hand the user a live iCloud checklist that
turns each "unverified" item into a recorded result.

## Evidence

- AGENTS.md "Checks before committing" lists `bend PROOF.bend`,
  `sh tests/run-unit.sh`, `bash tests/test-transport.sh`,
  `scripts/install.sh && python3 tests/test-e2e.py`.
- CI runs the same on `ubuntu-24.04` (`.github/workflows/ci.yml`).
- `.github/PULL_REQUEST_TEMPLATE.md` exists and sets the PR layout.
- User: "I'll run it after having a PR ready."

## Live iCloud checklist (added to `docs/CLOUD_AGENT.md`)

Each item records pass/fail and the observed value:

1. Rust `mailbend-tls`: `mail_probe` (IMAP TLS and login to
   `imap.mail.me.com:993`), a send to self (SMTP STARTTLS on 587), the same
   with `MAILBEND_DOH_URL` set, and with `MAILBEND_IMAP_CONNECT_IP`; IPv6 if
   the network has it.
2. Hierarchy delimiter from `mail_list_folders`.
3. `mail_create_folder` at top level and nested; visible on iCloud.com and
   Apple Mail; creation under INBOX accepted or refused.
4. `mail_rename_folder`; `mail_delete_folder` (with the confirmation word)
   of an empty folder: does iCloud accept DELETE of the examined mailbox?
5. `UID SEARCH HEADER Message-ID` finds a known message; whether searches
   return `\Deleted`-but-not-expunged messages (sweetrb PR #255 report).
6. `mail_label` moves a message into a label folder on iCloud (copy
   fallback, since iCloud has no MOVE): it appears once there, is gone from
   INBOX, and no duplicate remains; `mail_move` back to INBOX removes it.
7. `mail_flag` with each colour: shown colour in Apple Mail matches; whether
   iCloud keeps `$MailFlagBit*` (PERMANENTFLAGS `\*`).
8. Send to self: does iCloud file SMTP mail in Sent by itself? Decides the
   recommended `MAILBEND_SAVE_SENT` value.
9. `mail_get_attachment` round trip of a binary file.
10. `mail_get_thread` across INBOX and Sent.
11. With Jev on (headers mode): `mail_classify` on 20 messages; a blocked
    send to an obviously wrong recipient; a delete of junk proceeds; TypeSafe
    unreachable blocks a send and lets a search continue marked "unchecked";
    `mail_triage` moves only into `To Delete`.
12. The send limit: with `MAILBEND_MAX_SENDS_PER_DAY=2`, the third send is
    refused, and trashing the Sent copies does not reset it.

## Steps

1. Run every local gate: `bend PROOF.bend`, `sh tests/run-unit.sh`,
   `bash tests/test-transport.sh`, `python3 tests/test-cloud-network.py`,
   `scripts/install.sh && python3 tests/test-e2e.py`, `cargo fmt --check`,
   `cargo clippy --all-targets -- -D warnings`, `cargo test --locked`,
   `cargo deny check`, the fuzz smoke run, `sh scripts/scan-secrets.sh`.
2. Re-read the diff adversarially (verification can't be disabled, no
   secret in logs, laws not weakened: diff `LAWS.bend` and explain each
   change in the PR).
3. Commit in focused conventional commits (helpers, each feature, Jev,
   docs), push the branch, open one PR (user decision) using the repository
   template; the PR names the last commit that still has the C helpers and
   lists every new or changed law verbatim for the user's review (Bend
   convention: the human owns `LAWS.bend`, `~/.bend/guide/GUIDE.md:319-325`).
4. Subscribe to PR activity; fix CI until green.

## Verification

- CI green on the PR head; every law change explained in the PR body.
