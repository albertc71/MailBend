# MailBend core implementation (handoff milestones 1-6, 8)

Status: implemented; live iCloud run pending (needs the user's credentials
and an environment with outbound IMAP/SMTP).

## Outcome
A working prototype: Bend 2 core, verified TLS helper, 14 MCP/CLI tools,
proven safety laws, one-command install, verified end to end against a local
TLS IMAP/SMTP server.

## Constraints
The security rules in HANDOFF.md: verified TLS only, credentials from the
environment and never in outputs, reads never mutate, destructive actions
explicit, small native boundary.

## Non-goals (this change)
Live iCloud test (the build sandbox has no outbound IMAP/SMTP and no
credentials), the monitoring watcher (milestone 7), marketplace packaging.

## Acceptance
- [x] tree builds on Bend 2.0.29; `bend PROOF.bend` prints "All terms check."
- [x] helper builds warning-free (gcc, clang) and verifies chain + host name
- [x] unit tests: JSON, codecs, IMAP rendering/parsing, MIME
- [x] transport tests: TLS failures, lock-step stop, literal framing, SMTP STARTTLS
- [x] e2e: every tool via CLI and MCP stdio against the fake server; reads never add \Seen (84 checks)
- [x] security review findings fixed (attachment allowlist, helper literal guard, UIDVALIDITY checks, rendered-command laws)
- [x] `scripts/install.sh` builds everything; README has install/configure/test steps
- [ ] live iCloud run (docs/CLOUD_AGENT.md section 5)

## Phases
1. Build fixes and module layout (constructor namespaces, LAWS/PROOF split).
2. `native/mailbend-tls.c` (replaces the `openssl s_client` scripts).
3. Bend modules: json, codec, imap, mime, smtp, ops (plans), tools, main (MCP).
4. Laws and proofs over the command plans.
5. Tests: unit, transport (fake TLS server), e2e.
6. Install script, launcher, docs.

## Decisions
- Transport: one short-lived helper process per IMAP/SMTP session via
  `Process.run`; no ABI coupling to Bend's C runtime, no daemon.
- The helper authenticates, so the password never enters the Bend core.
- Tools build IMAP commands only through `src/ops.bend` plans, so the laws
  cover what actually runs.
- No plain EXPUNGE ever: move falls back to COPY + UID EXPUNGE only with
  UIDPLUS; delete requires UIDPLUS and `confirm = "permanently-delete"`.
- `MAILBEND_READ_ONLY=1` for safe first runs against a real mailbox.
- Attachments only from `MAILBEND_ATTACH_DIR` (resolved with realpath,
  regular files): the core's environment holds the app password, so an
  unrestricted path could mail out /proc/self/environ.
