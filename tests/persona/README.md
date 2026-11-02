# Synthetic persona task replays

This suite checks whether fixed tool-call sequences finish ordinary mail tasks
without collateral changes, and records what those sequences cost. It does not
run an agent or a model. A passing injection replay shows that the recorded safe
sequence leaves the mailbox safe. It does not measure prompt-injection resistance.

The corpus has 500 synthetic messages across INBOX, Archive, Sent Messages,
Travel, Receipts, and Work. Empty role folders complete the fake-server fixture.
All mail addresses use reserved `example.com`, `example.net`, or `example.org`
domains. The account password and reset token are fake. Dates use a fixed
`2026-10-01T12:00:00+00:00` clock, not the current date. The generator uses seed
133 by default and sets deterministic MIME boundaries.

The 25 tasks cover find, read, reply, organise, attention, and injection.
The corpus includes List-Id newsletters, travel confirmations, receipts, one-time
codes, an HTML-only reset link, a thread with a Sent reply, a calendar attachment,
a lookalike sender, and four untrusted instruction payloads. [NOTICE.md](NOTICE.md)
records the injection goals' attribution and license.

## Run the checks

Build MailBend with `scripts/install.sh`, then run:

```sh
python3 tests/test-persona.py
```

The suite starts the existing fake IMAP and SMTP server on loopback with local
TLS certificates. It uses modern MCP `2026-07-28` metadata on each request.
No external network endpoint, real mailbox, secret, TypeSafe service, tokenizer,
or model is used. Each task starts with a fresh 500-message state. Each recorded
call runs in a fresh MCP process, so the table measures this replay strategy,
not the minimum possible work of an agent or a persistent session.

The inherited environment is replaced with an allowlist. The fake-server ports
and CA are explicit. TypeSafe and automatic Sent copies are off. A compiled core
is required, so a missing build cannot silently fall back to the interpreter.

`tests/test-integrated-results.py` runs this suite after its combined read checks.
That existing CI entry point makes replay failures fail the checks job without
changing the workflow. The repository's 30-minute CI job timeout remains the
limit. Local completion is not proof that CI meets its time limit.

Useful commands:

```sh
# Check deterministic generation and fixture metadata without a build.
python3 tests/test-persona.py --unit

# Export the same corpus for another local fake-server or evaluation consumer.
python3 tools/generate-persona.py --output /tmp/persona.json --labels /tmp/labels.json

# Replay one task or save a measured table outside the repository.
python3 tests/test-persona.py --task read-html-reset
python3 tests/test-persona.py --report /tmp/persona-budgets.md
```

## Review or update expectations

`tasks.json` is the task specification. Each entry names its prompt, category,
expected response evidence, answer pattern, exact allowed mailbox effects,
expected SMTP deliveries, per-call permitted fetch identities and mutation
commands, and the issue expected to reduce its budget. The prompts are ordinary
mail requests. They do not grant authority outside this synthetic fixture.

`labels.json` pins the generated corpus's SHA-256, fixed clock, seed, and named
message identities. It is not a production mailbox export. The full corpus is
generated at runtime instead of storing hundreds of background messages in git.

`golden.json` pins complete modern MCP replies. Only the generated reply
Message-ID is replaced, and only on outbound `mail_reply` results after checking
its shape and its identity against the recorded SMTP delivery. The read results'
Message-IDs, dates, MIME content, mailbox identities, and flags are not normalized.
SMTP verification separately ignores only the newly generated Date and
Message-ID headers, checks their syntax, and compares the remaining headers,
recipients, and decoded body exactly.

To intentionally refresh the golden replies and budget caps after reviewing a
contract change, run:

```sh
python3 tests/test-persona.py --record --report tests/persona/BUDGETS.md
```

`--record` is never used in CI. It still checks task utility, security and exact
collateral effects before recording. Review every changed response and budget.
Do not refresh them just to hide a regression.

The pure `verify_task(task, before, after, log, answer)` function in
`tests/persona_replay.py` returns separate utility, security, and collateral
verdicts. `answer` contains text and the observed structured results. The replay
extracts its answer text from those results, rather than supplying a canned
answer that could pass without reading mail. All verdicts must pass.
The function reads no files, clock, model, or network. Unknown or missing evidence
fails closed. Exact state comparison includes every mailbox and message, flags,
raw MIME, INTERNALDATE, UIDNEXT, UIDVALIDITY, special-use roles, subscriptions,
account identity, and SMTP state.

Per-step log checks reject unrequested fetch identities, non-UID reads, BODY
fetches without PEEK, reads through SELECT, unexpected mutations, EXPUNGE, and
unrequested SMTP attempts. Reply envelopes must match exactly. The negative
controls inject omitted results, wrong answers, unrelated reads, changed flags,
mailbox identities, subscriptions, wrong moves, extra sends, wrong recipients,
changed reply bodies, an extra login, and an extra tool call. They must fail.
A full-suite run also executes an actual extra MCP read in a fresh task replay
and checks that the unchanged budget rejects the observed extra call.

## Read the budgets

[BUDGETS.md](BUDGETS.md) is generated from observed replies and server logs.
Calls count matched `tools/call` replies. IMAP logins count redacted LOGIN records
from the fake server. Result bytes count canonical UTF-8 JSON for the complete
MCP result envelope, including both text and structured content. Request bytes,
SMTP bytes, IMAP response bytes, framing, and discovery are not counted.

Estimated tokens are `ceil(result_bytes / 4)`. This is an explicit byte-based
estimate, not a tokenizer count, model cost, or efficiency claim. Each cap is a
checked upper bound. Each task names one of #61, #66, #70, or #72 as a possible
budget improvement, not as a claim that the issue was evaluated here.

The labelled corpus and pure verifiers are reusable inputs for
[#48](https://github.com/albertc71/MailBend/issues/48) and a future
[#139](https://github.com/albertc71/MailBend/issues/139) evaluation runner.
No such model evaluation has run as part of this suite. Real-server container
loading in #84 and compromised-agent configuration coverage in #130 remain
separate work.
