# MailBend agent instructions

MailBend is a small Linux-first iCloud Mail connector (IMAP/SMTP) for AI
agents: a Bend 2 core plus two small native helpers (`native/mailbend-tls.c`,
`native/mailbend-attach.c`).

## Native boundaries

Keep product/mail policy in Bend 2. Native helpers exist only where the
Bend runtime cannot safely provide the required OS/protocol boundary.

- `mailbend-tls`: verified TLS, sockets, authentication, protocol framing,
  literal-safe I/O, and lock-step execution of Bend-generated command plans.
  It may enforce expectations supplied by Bend and stop on protocol failure,
  but must never choose, reorder, synthesize, or alter mail operations.
- `mailbend-attach`: credential-free, sandboxed attachment-file access.
  It must not implement mail policy or network access.

Bend remains authoritative for which operations run, command plans,
rendering, response interpretation, MIME behavior, and agent-visible results.

## Constraints
- Keep the core in Bend 2, and the native helpers within the boundaries above.
- Never log, print, commit, persist, or return MAILBEND_APP_PASSWORD. Only
  `mailbend-tls` reads it; the Bend core and `mailbend-attach` must not.
- TLS peer and hostname verification are mandatory; never add a way around it.
- Read operations must not mutate message flags: EXAMINE, never SELECT; fetch
  bodies only with BODY.PEEK.
- Destructive operations must be explicit. Never send a plain EXPUNGE.
- Prefer IMAP UID commands over sequence-number commands.
- Detect server capabilities after authentication; do not assume optional
  IMAP extensions.
- Treat iCloud "labels" as IMAP mailboxes/folders; discover special-use
  folders instead of hard-coding names.
- Tools build IMAP commands only through the `plan_*` defs in `src/ops.bend`.

## When using Bend
- run `bend guide` to learn it (Bend 2 differs from the old Bend/HVM language)
- use `LAWS.bend` to keep important rules; do not weaken a law to make code pass
- run `bend PROOF.bend` before committing: it must print "All terms check."
- Bend has no mutual recursion, `match` only inspects parameters, and defs
  must be declared before use; `Bool.pick` evaluates both branches, so never
  put a recursive call in both (that is exponential): recurse once and pick
  the arguments or the head instead

## Checks before committing
```sh
bend PROOF.bend
sh tests/run-unit.sh
bash tests/test-transport.sh
scripts/install.sh && python3 tests/test-e2e.py
```

After editing `tools/gen-schema.py`, regenerate `src/schema.bend` with
`python3 tools/gen-schema.py`.
