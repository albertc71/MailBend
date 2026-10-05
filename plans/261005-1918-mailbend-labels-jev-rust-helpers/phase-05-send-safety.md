---
phase: 5
title: "Phase 5: Send safety"
status: todo
priority: P1
effort: "2d"
dependencies: [1, 3]
---

# Phase 5: Send safety

## Goal

Three controls for outgoing mail: an optional Sent copy after delivery, a
recipient allowlist proven by a law, and an optional daily send limit kept
in a local counter the agent cannot change.

## Evidence

- `docs/CLOUD_AGENT.md:315-317`: "SMTP delivery does not guarantee a Sent
  copy, and MailBend does not append one automatically."
- epinethrone/icloud-mcp states iCloud does not file SMTP-sent mail itself;
  **unverified** for this account, so the copy is opt-in and de-duplicated.
- README "Not yet": "A recipient allowlist for sending."
- Recipients actually sent to are `specs(all_rcpts(w))`, built in IO next to
  `S.envelope` (`src/tools.bend:1257-1260`, `:1325-1333`); reply-all adds
  the original To and Cc (`:1481`). `S.envelope` returns a `String`
  (`src/smtp.bend:31-34`); there is no `Envelope` type.
- `addr_ok` accepts any printable character except `<>",;\` and requires one
  `@` (`src/mime.bend:563-564`, `:592-594`), so `a%evil.com@allowed.com` is
  a valid address today (source-route style).
- Red team: a send count read from Sent can be lowered by the same agent
  (`mail_trash`/`mail_move` work on any folder, `src/ops.bend:179-201`,
  `src/tools.bend:918-920`), failed Sent copies undercount, and concurrent
  processes race. User decision: a local counter file.
- Bend's existing proofs are computation and case splits (73 `{==}` in
  `PROOF.bend`, one rewrite at `:116`), but the guide shows induction by a
  recursive call (`~/.bend/guide/GUIDE.md:279-299,336-337`).
- AGENTS.md: do not weaken a law to make code pass.

## Design

Switches (parsed once into the configuration record from phase 9's design,
fail closed):

- `MAILBEND_SAVE_SENT` (bool, default off).
- `MAILBEND_ALLOWED_RECIPIENTS`: comma-separated exact addresses and
  `@domain` entries (exact domain, no subdomains); unset or empty means no
  allowlist; a malformed entry is a configuration error.
- `MAILBEND_MAX_SENDS_PER_DAY`: positive integer; unset means no limit.
- `MAILBEND_STATE_DIR`: where the counter lives; default
  `$XDG_STATE_HOME/mailbend`, else `~/.local/state/mailbend`.

Allowlist (pure, `src/smtp.bend`):

- `outbound(allow, rcpts, from, msg) -> Maybe<String>`: the envelope string
  `S.envelope` would produce, or None when any recipient is not allowed.
  With an allowlist set, local parts containing `%`, `!` or `:` are
  refused. The send path calls only `outbound`; `smtp_run` receives its
  result (a grep in CI checks `S.envelope` has no other caller).
- Laws: `allowlist_refuses_unlisted` (for every allowlist, recipient list
  and position, an unlisted recipient gives None; proven by induction over
  the list) and `no_allowlist_is_unchanged` (empty allowlist gives today's
  envelope). Step 1 prototypes the induction proof; if it does not go
  through, stop and ask the user. The law is never restated more weakly.

Sent copy: after SMTP success, a read-only search of the resolved Sent
folder (HEADER Message-ID candidates, then exact comparison of the fetched
Message-ID) and `plan_sent_copy(sent, msg) = [CAppend{sent, [FSeen], msg}]`
only if absent; law `sent_copy_only_appends`. Bcc kept as in drafts
(commit 49a53fe). Failure is reported as `sent_copy: "failed: ..."` next to
the successful send. Unresolved Sent role: no copy, said so. No new header
is added to any message.

Daily limit (`mailbend-attach count`, Rust, credential-free):

- `mailbend-attach count <state-dir> <limit> <utc-date>` (4 arguments; the
  helper picks the mode by argument count, phase 1): opens
  `<state-dir>/sends` beneath the directory (created 0700 by the helper if
  missing, same symlink rules as attachments), takes an exclusive `flock`,
  counts lines for the date, and if the count is below `limit` appends one
  line and prints `ok <n>`; otherwise prints `full <n>` and appends nothing.
  The helper only compares the number Bend supplies (like `=EXPECT`); Bend
  decides to refuse.
- The reservation happens before SMTP, so failed or timed-out sends still
  count (fails closed). An unreadable counter refuses the send.
- No tool reads or writes the counter, so the agent cannot change it.

Applies to `mail_send`, `mail_reply`, `mail_forward`; never to drafts.

## Files

- Modify: `src/smtp.bend`, `src/tools.bend`, `src/ops.bend`, `LAWS.bend`,
  `PROOF.bend`, `native/mailbend-attach/src/*.rs` (count mode),
  `tests/fake_mail_server.py` (optional auto-filing of sent mail),
  `tests/test-e2e.py`, `.env.example`.

## Steps

1. Prototype `allowlist_refuses_unlisted` with its induction proof.
2. Switch parsing with fail-closed unit tests.
3. `outbound` and the send-path wiring; laws.
4. Sent copy with de-duplication; e2e with fake auto-filing on and off.
5. Counter mode in Rust with unit tests (concurrent reservations from two
   processes never exceed the limit); e2e at, below and over the limit,
   unreadable state dir refused, drafts unaffected.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `cargo test --locked`;
  `python3 tests/test-e2e.py`.

## Risks

- If iCloud files sent mail asynchronously, de-duplication may miss it: the
  live check (phase 13) decides the recommended `MAILBEND_SAVE_SENT`.
- The counter is MailBend's first persistent state; README documents its
  location and that deleting it resets the count (a local user action, not
  an agent action).
