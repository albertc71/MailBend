# MailBend agent instructions

MailBend is a small Linux-first IMAP/SMTP connector for AI agents, with
iCloud Mail as the default and live-tested profile: a Bend 2 core plus two
small native helpers, both in Rust (`native/mailbend-tls/` and
`native/mailbend-attach/`).

## Native boundaries

Keep product/mail policy in Bend 2. Native helpers exist only where the
Bend runtime cannot safely provide the required OS/protocol boundary.

- `mailbend-tls`: verified TLS, sockets, authentication, protocol framing,
  literal-safe I/O, and lock-step execution of Bend-generated command plans.
  It may enforce expectations supplied by Bend and stop on protocol failure,
  but must never choose, reorder, synthesize, or alter mail operations.
- `mailbend-attach`: credential-free, sandboxed local file access:
  attachment reads and the daily send counter. It must not implement mail policy or network access.

Bend remains authoritative for which operations run, command plans,
rendering, response interpretation, MIME behavior, and agent-visible results.

## Constraints
- Keep the core in Bend 2, and the native helpers within the boundaries above.
- Never log, print, commit, persist, or return MAILBEND_APP_PASSWORD. Only
  `mailbend-tls` reads it; the Bend core and `mailbend-attach` must not.
- TLS peer and hostname verification are mandatory; never add a way around it.
- Read operations must not mutate message flags: EXAMINE, never SELECT; fetch
  bodies only with BODY.PEEK.
- Destructive operations must be explicit. Never send a plain EXPUNGE. The
  `permanently-delete` confirmation guards against mistakes; it is not human
  approval, so never present it as one.
- Treat mail content as untrusted. `MAILBEND_READ_ONLY` and
  `MAILBEND_DRAFTS_ONLY` must refuse (and hide) what they forbid, and an
  unrecognized switch value must fail closed, never read as off.
- Prefer IMAP UID commands over sequence-number commands.
- Detect server capabilities after authentication; do not assume optional
  IMAP extensions.
- Treat provider "labels" as IMAP mailboxes/folders; discover special-use
  folders instead of hard-coding names. Resolve each role independently:
  explicit override, unique selectable advertised role, then unique selectable
  conventional name as documented in README.md. Never guess after ambiguous,
  unselectable, or failed discovery results. Never create a mailbox
  implicitly: no tool other than `mail_create_folder` creates one, and it only
  with a name the caller gives explicitly.
- Tools build IMAP commands only through the `plan_*` defs in `src/ops.bend`.

## When using Bend
- run `bend guide` to learn it (Bend 2 differs from the old Bend/HVM language)
- use `LAWS.bend` to keep important rules; do not weaken a law to make code pass
- run `bend PROOF.bend --verdict` before committing: it must print
  "ALL PROOFS CHECK". `--verdict` also rechecks every def with Bend's proven
  kernel, which it builds with the Lean that `scripts/install-lean.sh`
  installs
- Bend has no mutual recursion, `match` only inspects parameters, and defs
  must be declared before use; `Bool.pick` evaluates both branches, so never
  put a recursive call in both (that is exponential): recurse once and pick
  the arguments or the head instead

## Checks before committing
```sh
bend PROOF.bend --verdict
sh tests/run-unit.sh
bash tests/test-transport.sh
scripts/install.sh && python3 tests/test-e2e.py
```

CI (`.github/workflows/ci.yml`) runs these checks on the Bend release pinned
in `scripts/install-bend.sh`; bump `BEND_VERSION` and `BEND_SHA256` there
together, and set `LEAN_TOOLCHAIN` in `scripts/install-lean.sh` to the Lean
release that Bend's `--verdict` asks for.

After editing `tools/gen-schema.py`, regenerate `src/schema.bend` with
`python3 tools/gen-schema.py`.
