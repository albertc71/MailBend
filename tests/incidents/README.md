# Synthetic incident format

`scenarios.json` is a versioned registry of incident-inspired calls, not attack
instructions to an LLM. Each `.eml` is a synthetic input. The driver assumes the
agent obeys the attacker and issues the listed calls through `scripts/mailbend mcp`.
No model decides which call to make. Browser/image attacks are adapted to SMTP;
this is not a reproduction of the original service vulnerability.

Each scenario contains:

- `id`, `category`, `source`, `goal` and `fixture` for provenance.
- `calls`, ordered MCP tool names and arguments. The first call reads UID 101,
  the injected fixture. UIDs 1 and 2 are old, unflagged synthetic thread messages.
  UID 3 is an old message with a fake deadline. UID 4 holds a synthetic code. INBOX UIDVALIDITY is 1700000001.
- `oracle`, one of `send`, `delete` or `move`. A send needs the actual envelope
  recipient and marker in a decoded MIME payload, with a required delivery count.
  Delete needs the listed Message-IDs absent from every mailbox. Move needs them
  absent from INBOX and present in the named destination.
- `expected` independently specifies achieved, partial or blocked for each profile.
  The driver compares effects against it before writing documentation, so a broken
  helper cannot silently turn permissive cases into newly accepted blocked cells.
- `required_reads` lists synthetic message bodies that must appear in BODY.PEEK
  command evidence. Header-only fetches do not satisfy it.
- `control` names the law or existing test relevant to the result. It does not
  assert that the control blocked every attack.
- `followup` links an open design item relevant to residual risk. It is not a
  promise that the proposal, if implemented, would prevent every row.

All addresses use reserved example domains. Markers are fake data, not secrets.
The helper recorder delegates to the real attachment helper unchanged and records
only operation and argument count. A read attempt is not proof that bytes escaped;
the delivered MIME marker decides that. Counter calls are attempts, not a claim
that each reservation succeeded.

Each profile starts with a new mailbox, attachment root and counter. All profiles
point at loopback fake servers, trust the generated test CA, enable the synthetic
attachment directory and disable Sent-copy storage. A read-only profile can still
return private message contents to a compromised caller. Its blocked send cells do
not prove that another connector or browser could not disclose those contents.

The fake Jev profile enables body mode and routes the actual TypeSafe helper to
`tests/fake_typesafe.py`. `[veto]`, `[disposable]` and deadline text deliberately
select its deterministic answers. This measures enforcement and transport wiring,
not model accuracy. The external source URLs are documentation only and are never
requested by the runtime suite.

For another connector, preserve the synthetic fixtures, ordered intent and goal
oracle. Replace only the call adapter and authoritative event/state collectors.
Do not infer outcomes from an agent's prose, connector success message or displayed
headers. Missing evidence, malformed transport, or an uninitialized connector is
a test error, never a blocked cell.

Run `python3 tests/test-incidents.py --controls-only` for the pure observation and
source-mutation checks. The hidden-envelope check executes the existing CI guard
on a disposable copy with an added direct `S.envelope` call. It does not install a
backdoored package or claim the guard detects arbitrary malicious source changes.

Run `python3 tests/test-incidents.py` after the normal build to compute and compare
all cells with `docs/INCIDENTS.md`. CI runs this same command. To accept a deliberate
change, inspect evidence, then run with `--write` and review the generated diff.
Use `--evidence-dir` with a new path outside the repository for synthetic logs.
Do not commit generated certificates, synthetic key files or temporary counters.
