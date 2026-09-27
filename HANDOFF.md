# MailBend Handoff

## Objective

Build **MailBend**, a small, lightweight, Linux-first iCloud Mail connector for AI agents, with **Bend 2** as the core language. The immediate target is installation and use from **Cursor Cloud Agent / Grok Bot**. Keep the mail layer reusable for other MCP-capable assistants.

Repository: `albertc71/MailBend` (private).

The intended primary development branch is **`main`**. The repository was initially created on `master`; `main` has since been created from that history. If GitHub still reports `master` as the default branch, change the repository default branch to `main` in GitHub settings when administrative access is available.

## Status (2026-09-27)

Milestones 1-6 and 8 are implemented and verified end to end against a local
TLS IMAP/SMTP server (`tests/fake_mail_server.py`): 90 e2e checks, 17
transport checks, 4 unit suites, 24 proven laws. See
`plans/260927-0319-mailbend-core-implementation/plan.md`.

- Bend 2.0.29 core in `main.bend` + `src/*.bend`; safety laws in `LAWS.bend`,
  proofs in `PROOF.bend` (`bend PROOF.bend` is the gate).
- `native/mailbend-tls.c`: the only native code (OpenSSL, verified TLS,
  login, lock-step command execution). The earlier `openssl s_client`
  scripts are gone.
- 14 tools over MCP stdio and a CLI (`scripts/mailbend`); install with
  `scripts/install.sh`.
- Tests: `tests/run-unit.sh`, `tests/test-transport.sh`, `tests/test-e2e.py`.
- A security review (plans/reports/code-reviewer-260927-0319-security-review.md)
  found an attachment-path exfiltration route and a helper literal bug; both
  are fixed (attachments only from `MAILBEND_ATTACH_DIR`). A Codex review on
  PR #1 led to UIDVALIDITY pinning inside the changing session, an absolute
  helper path, strict JSON, RFC 2231 filenames and header folding.

Not done yet:

1. **Live iCloud run** (milestone 2's live half and the "ready to use"
   checklist): the build sandbox had no outbound IMAP/SMTP and no credentials.
   Follow docs/CLOUD_AGENT.md section 5 in the target Cursor Cloud Agent.
   Record the authenticated CAPABILITY and the special-use folders.
2. **Milestone 7, monitoring**: `mail_get_new` provides the
   `UIDVALIDITY + UID` checkpoint; the watcher (IDLE/polling, filters,
   ledger) is not written.
3. Check whether iCloud files SMTP-sent mail in "Sent Messages" by itself;
   add an optional copy to Sent only if it does not.

## Why this exists

Apple does not provide a Gmail-style public REST API for iCloud Mail. The supported interoperability path is standard email protocols:

- IMAP over TLS: `imap.mail.me.com:993`
- SMTP with STARTTLS: `smtp.mail.me.com:587`
- authentication using the iCloud email address and an **Apple app-specific password**
- Apple account 2FA is required to create/use an app-specific password

Therefore MailBend should expose an agent-friendly interface over IMAP/SMTP rather than pretend an Apple Mail REST API exists.

Do **not** put an Apple app-specific password in prompts, source control, command-line arguments, logs, fixtures, or test output. Use Cloud Agent secrets/environment variables.

## Product direction

The name deliberately avoids `icloud` so the project can eventually support arbitrary IMAP/SMTP providers.

Potential future shape:

```text
MailBend
├── iCloud
├── generic IMAP/SMTP
├── Gmail via IMAP (optional)
├── Outlook via IMAP (optional)
└── MCP/agent adapters
```

For now, optimize for iCloud and prove the smallest useful implementation first.

## Desired functionality

The user requested:

1. compose/send email
2. delete email
3. read messages
4. mark read/unread
5. labels/folders
6. drafts
7. any other useful functionality supported by the underlying protocols once the prototype is proven

The intended initial tool surface is:

### Read-only

- `mail_probe`
- `mail_list_folders`
- `mail_search`
- `mail_get` / `mail_read`
- `mail_get_new`

### Mutating

- `mail_mark_read`
- `mail_mark_unread`
- `mail_move`
- `mail_trash`
- `mail_delete`
- `mail_save_draft`
- `mail_send`

Later:

- reply
- forward
- attachments
- create/delete folders
- monitoring/watchlists
- event-driven notifications where feasible

Keep mutation tools separate from reads so an agent cannot accidentally turn a read operation into a write.

## iCloud/IMAP semantics

Map operations approximately as follows:

| MailBend operation | IMAP/SMTP representation |
| --- | --- |
| list folders | IMAP `LIST` |
| search | `UID SEARCH` |
| read without changing unread state | `UID FETCH ... BODY.PEEK[]` |
| mark read | `UID STORE +FLAGS (\\Seen)` |
| mark unread | `UID STORE -FLAGS (\\Seen)` |
| label | IMAP mailbox/folder semantics |
| move | `UID MOVE`, or carefully implemented COPY + delete fallback |
| trash | move to the discovered Trash special-use mailbox |
| explicit permanent delete | `\\Deleted` + controlled expunge path |
| save draft | `APPEND` to discovered Drafts mailbox with `\\Draft` |
| compose/send | MIME construction + SMTP |
| attachments | MIME parts |

Do not hard-code English folder names such as `Trash` or `Drafts` if the server advertises special-use mailboxes. Discover them.

Use IMAP UIDs rather than sequence numbers.

For persistent monitoring/checkpointing, use:

```text
account + mailbox + UIDVALIDITY + UID
```

Do not use read/unread state as the processing checkpoint.

## Capability detection

Do not assume optional IMAP extensions.

After authentication, query server capabilities again. In particular, do not assume IMAP IDLE is or is not supported based on documentation or a pre-authentication greeting.

If authenticated `CAPABILITY` advertises IDLE, a future watcher may use it. Otherwise use polling with sensible backoff.

## Architecture

Target architecture:

```text
Cursor Cloud Agent / Grok Bot
            |
            | MCP / command adapter
            v
          Bend 2
     domain + mail policy
            |
            | minimal native/runtime boundary
            v
 verified TLS + IMAP/SMTP
            |
            v
        iCloud Mail
```

Important: Bend 2 currently has useful Linux IO facilities such as TCP/environment/files/foreign effects, but no complete TLS client in its standard library. Do not implement cryptography or certificate validation in Bend.

Use a **tiny, auditable native boundary** for TLS. OpenSSL or an equally mature system TLS implementation is appropriate on Linux.

The native boundary should contain transport/interoperability only. Mail policy, operation classification, protocol decisions, and safety rules belong in Bend wherever practical.

A pragmatic prototype may temporarily use a small standard-library runtime helper to prove connectivity, but the final design should preserve the Bend core and keep the helper narrow.

## TLS/security requirements

These are non-negotiable:

1. verify the certificate chain
2. verify the server hostname
3. never use an equivalent of `rejectUnauthorized=false`
4. secrets come from environment/secret storage
5. do not pass the Apple password as a command-line argument
6. do not print or log authentication material
7. use bounded reads/timeouts
8. read operations must not mutate message state
9. destructive operations must be explicit
10. start live testing with a test mailbox where possible

A previous review of an unrelated open-source iCloud MCP found TLS verification disabled in one implementation. MailBend must not copy that pattern.

## Environment

Expected variables:

```text
MAILBEND_EMAIL
MAILBEND_APP_PASSWORD
MAILBEND_IMAP_HOST=imap.mail.me.com
MAILBEND_IMAP_PORT=993
MAILBEND_SMTP_HOST=smtp.mail.me.com
MAILBEND_SMTP_PORT=587
```

Only the first two are secrets/identity inputs. Host/port overrides are mainly for testing.

## Cursor Cloud Agent / Grok Bot

The first deployment target is Linux in Cursor Cloud Agent / Grok Bot.

The desired UX is eventually:

1. clone/install MailBend
2. configure `MAILBEND_EMAIL` and `MAILBEND_APP_PASSWORD` using the platform's secure secret/environment mechanism
3. register the MailBend MCP server
4. restart/reload the agent if necessary
5. run `mail_probe`
6. expose mail tools to the agent

Do not assume that installing an MCP server in one Cursor environment automatically installs it in every Grok Bot/Cloud Agent environment. Test the exact target.

A remote authenticated HTTP MCP service is a possible future deployment model, especially for marketplace distribution. For this prototype, a lightweight local/stdin-stdout MCP process in the Cloud Agent is acceptable if supported by the target.

## Monitoring design

The original motivation included Gmail/Mailmate-style monitoring of selected iCloud mail.

Do not wake an LLM simply to discover that no mail arrived if a deterministic watcher can perform the check.

Preferred future design:

```text
IMAP watcher
   ↓
sender/subject/rule filter
   ↓
deduplicate using UIDVALIDITY + UID
   ↓
trigger agent only for relevant new mail
   ↓
summarize/notify
   ↓
record successful delivery
```

Opening a message on a phone must not cause the watcher to think it was already processed.

## Existing projects researched

Several prior projects were examined conceptually for lessons:

### Albretsen/MCPEmails

Useful reference for:

- multi-provider email MCP architecture
- remote HTTP access
- hosted/self-hosted patterns
- scoped permissions/API keys
- read/send/folder/delete permission separation

Its licensing and current implementation must be reviewed before copying code. Prefer learning from architecture rather than importing code blindly.

### JulienRabault/icloud-mcp

Useful iCloud-focused reference.

Notable examples included sender watching, daily digest, waiting-on-reply, and auto-file workflows. Its sender-watch example was useful conceptually but did not provide the persistent deduplication semantics MailBend needs.

### Wh1isper/mcp-email-server

Useful reference for generic IMAP/SMTP and multiple MCP transports.

### minagishl/icloud-mail-mcp

Useful TypeScript reference, but a reviewed version contained disabled TLS certificate verification. Do not copy that security behavior.

### Lawiak/icloud-mcp

Useful packaging/container/remote-machine reference.

### Pear MCP

Example of a hosted iCloud MCP-style integration. Product-specific Grok/Grok Bot compatibility should not be assumed from general MCP compatibility.

## Repository work already completed

The repository was created privately as:

```text
albertc71/MailBend
```

`main` was created from the original `master` history.

The first prototype commit added a Bend command model, `LAWS.bend`, docs and
`openssl s_client` shell scripts. Those scripts were replaced by
`native/mailbend-tls.c`; `docs/PROTOTYPE.md` became `docs/ARCHITECTURE.md`.
The non-mutating connectivity check is now the `mail_probe` tool (CAPABILITY
after login + LIST; it opens no mailbox).

## History

An earlier attempt from ChatGPT's GitHub connector to commit the runtime was
rejected by that connector's write guard. That was a limitation of that write
path, not a design requirement; the implementation was then done in a normal
development environment.

Do not weaken MailBend's security model to work around that connector restriction.

## Bend-specific direction

Use current **Bend 2** syntax/tooling, not assumptions from the older Bend/HVM language.

The repository includes a Bend command/safety model. Keep critical invariants mechanically visible where possible.

Examples of invariants worth retaining/testing:

- `Read` is classified as read-only
- `Delete` is never classified as read-only
- read paths use `BODY.PEEK`
- credentials never enter returned tool payloads
- no mutation occurs during probe/search/read
- permanent deletion cannot be reached accidentally from trash/read paths

## Next implementation steps

Continue without stopping at scaffolding.

### Milestone 1 — make the current tree build

1. install current Bend 2 on Linux
2. run/compile `main.bend`
3. run/check `LAWS.bend`
4. correct any syntax/API drift against the current Bend version
5. add repeatable build/smoke commands

### Milestone 2 — live transport proof

With secrets configured securely:

1. run the non-mutating IMAP probe
2. verify TLS chain + hostname validation
3. authenticate successfully
4. capture authenticated CAPABILITY output without secrets
5. list folders
6. identify special-use folders
7. logout cleanly

Never commit live credentials or mailbox content.

### Milestone 3 — safe reads

Implement in Bend plus the minimal transport boundary:

1. list folders
2. UID SEARCH
3. UID FETCH using BODY.PEEK
4. parse useful headers/body
5. prove reading does not add `\\Seen`
6. add tests with synthetic IMAP transcripts

### Milestone 4 — controlled mutations

Implement and test separately:

1. mark read
2. mark unread
3. move
4. trash
5. permanent delete
6. draft APPEND

Require explicit operation selection.

### Milestone 5 — SMTP

Implement:

1. MIME compose
2. send
3. reply
4. forward
5. attachments

Use STARTTLS with proper verification.

### Milestone 6 — MCP

Expose the proven operations through a small MCP server suitable for Cursor Cloud Agent.

Tool schemas should be narrow and explicit.

Read and write tools remain separate.

### Milestone 7 — monitoring

Add:

- persistent checkpoint state
- duplicate suppression
- sender/subject filters
- reconnect/backoff
- IDLE when authenticated capability supports it
- polling fallback
- successful-delivery ledger

### Milestone 8 — packaging

Make installation lightweight:

- Linux-first
- minimal dependencies
- one clear install command/script
- no daemon required for ordinary on-demand tools
- optional watcher service for monitoring
- Cloud Agent instructions
- MCP configuration example

Then consider marketplace packaging only after the private installation is proven.

## Definition of “ready to use”

Do not declare the prototype ready merely because code compiles.

For the first usable release, all of the following should be true:

- clean Linux install succeeds
- Bend core builds/runs
- TLS verification is enforced
- iCloud login succeeds using secrets
- folder listing works
- search works
- reading via UID works without changing unread state
- read/unread mutation works
- folder move works
- trash works
- permanent delete works only through its explicit tool
- draft creation works
- SMTP send works
- MCP tool discovery works from the target Cursor Cloud Agent
- MCP tool invocation works
- credentials never appear in repository/log/tool results
- README contains end-to-end install/configure/test instructions
- destructive behavior has tests or a documented safe test procedure

## Development philosophy

Keep MailBend **small**.

Do not build a mail database, web application, queue, OAuth service, or hosted control plane just to prove iCloud connectivity.

The prototype should be understandable enough that a reviewer can audit the path from an agent tool call to the corresponding IMAP/SMTP command.

Once that small version is proven, expand functionality based on actual protocol capabilities and Grok Bot/Cursor needs.
