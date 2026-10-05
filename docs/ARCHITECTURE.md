# Architecture

## Why IMAP + SMTP

MailBend uses password-authenticated IMAP for mailboxes and SMTP for delivery.
iCloud Mail is the default and live-tested profile:

- IMAP: `imap.mail.me.com:993`, implicit TLS
- SMTP: `smtp.mail.me.com:587`, STARTTLS
- login: the iCloud address and an Apple app-specific password

Other compatible providers use the same architecture with configured IMAP
and SMTP hosts and ports. IMAP requires implicit TLS and SMTP requires
STARTTLS; OAuth and implicit SMTPS are unsupported. Other providers have not
been live-tested here. The draft-folder repair has local fake-server coverage
and passed a live iCloud retest; see [cloud validation](CLOUD_AGENT.md).

## Diagrams

### Components and trust boundaries

The Bend core decides everything (which commands run, how they are
rendered, what the replies mean). `mailbend-tls` is the only code that
touches the password and the network; `mailbend-attach`, which holds no
credentials, is the only code that opens attachment files.

```mermaid
flowchart TB
  agent["AI agent (MCP client)"]
  cli["CLI: scripts/mailbend call / tools"]
  env[["Environment or agent secrets<br/>MAILBEND_EMAIL, MAILBEND_APP_PASSWORD"]]

  subgraph core["Bend core process: never reads the password"]
    direction TB
    main["main.bend<br/>MCP JSON-RPC server and CLI<br/>8 MiB line cap, envelope check"]
    json["src/json.bend<br/>strict JSON parser"]
    tools["src/tools.bend<br/>14 tools: arguments, sessions, results<br/>MAILBEND_READ_ONLY gate"]
    ops["src/ops.bend<br/>plan_* command plans<br/>the only way to build IMAP commands"]
    laws["LAWS.bend + PROOF.bend<br/>27 laws proven over the plans"]
    imap["src/imap.bend<br/>render script, parse transcript"]
    mime["src/mime.bend + src/codec.bend<br/>parse and compose MIME"]
    smtp["src/smtp.bend<br/>SMTP envelope, dot-stuffing"]
  end

  subgraph helper["mailbend-tls (C, OpenSSL): the only reader of the password"]
    direction TB
    validate["Validate the whole script<br/>before connecting"]
    tls["TLS 1.2+, chain and host name verified<br/>login; login replies not forwarded"]
    lock["Lock-step: one command at a time<br/>stop at the first NO/BAD or unmet =EXPECT"]
  end

  subgraph reader["mailbend-attach (C)"]
    attach["no credentials: re-executes with an empty environment<br/>no procfs or sysfs files<br/>openat2 beneath the directory<br/>no symlinks, no .. that leaves it<br/>regular file within the byte budget"]
  end

  imapsrv[("IMAP implicit TLS<br/>default imap.mail.me.com:993")]
  smtpsrv[("SMTP STARTTLS required<br/>default smtp.mail.me.com:587")]
  files[("MAILBEND_ATTACH_DIR<br/>attachments off without it")]

  agent -- "JSON-RPC lines on stdio" --> main
  cli --> main
  main --> json
  main --> tools
  tools --> ops
  laws -. "proves" .-> ops
  ops --> imap
  tools --> mime
  mime --> smtp
  imap -- "IMAP script on stdin" --> validate
  smtp -- "SMTP envelope on stdin" --> validate
  validate --> tls
  tls --> lock
  lock <--> imapsrv
  lock <--> smtpsrv
  lock -- "transcript on stdout" --> imap
  tools -- "dir, path, bytes left of 25 MB" --> attach
  attach --> files
  attach -- "file bytes on stdout" --> tools
  env -. "read by the helper only" .-> tls
```

The password is in the environment of both processes (the core starts the
helper, which inherits it), but only the helper reads it; see
[Credentials](#credentials).

### A read (mail_get)

```mermaid
sequenceDiagram
  autonumber
  participant A as Agent
  participant C as Bend core
  participant H as mailbend-tls
  participant S as IMAP server
  A->>C: tools/call mail_get with uid
  C->>C: plan_get gives EXAMINE and UID FETCH with BODY.PEEK
  C->>H: rendered script on stdin
  H->>S: TLS handshake, verify chain and host name
  H->>S: LOGIN (reply consumed, not forwarded)
  H->>S: EXAMINE folder (read-only, no flag changes)
  S-->>H: untagged replies, UIDVALIDITY
  H->>S: UID FETCH uid with FLAGS, sizes and BODY.PEEK[] up to max bytes
  S-->>H: message as a literal, read as raw bytes
  H->>S: LOGOUT
  H-->>C: transcript on stdout, exit 0
  C->>C: parse transcript, then MIME: headers, text, attachment list
  C-->>A: JSON result with uidvalidity
```

### A change (mail_trash)

Changes to existing messages are pinned to the caller's UIDVALIDITY inside
the changing session. Move, trash and delete first run a read-only preflight
for server capabilities and folders; the diagram shows trash with MOVE.

```mermaid
sequenceDiagram
  autonumber
  participant A as Agent
  participant C as Bend core
  participant H as mailbend-tls
  participant S as IMAP server
  A->>C: tools/call mail_trash with uids and uidvalidity
  C->>C: refuse if MAILBEND_READ_ONLY or uidvalidity missing
  C->>H: preflight: CAPABILITY, LIST, EXAMINE folder
  H->>S: login, then the commands one at a time
  S-->>H: capabilities, folders with special-use, UIDVALIDITY
  H-->>C: transcript
  opt SPECIAL-USE advertised after authentication
    C->>H: plan_roles: LIST RETURN (SPECIAL-USE)
    H->>S: login, then extended LIST
    S-->>H: folder attributes
    H-->>C: transcript
  end
  C->>C: merge folders, resolve Trash, check MOVE or UIDPLUS and UIDVALIDITY
  C->>H: plan_trash: SELECT, =EXPECT UIDVALIDITY, UID SEARCH, UID MOVE
  H->>S: SELECT folder
  S-->>H: OK [UIDVALIDITY v]
  alt the folder has another UIDVALIDITY
    H-->>C: exit 5 before any change
    C-->>A: error: the UIDs are stale
  else it matches
    H->>S: UID SEARCH UID uids (which exist)
    H->>S: UID MOVE uids Trash
    S-->>H: OK
    H-->>C: transcript
    C-->>A: result with changed and missing UIDs
  end
```

Without MOVE the plan copies, marks `\Deleted` and runs `UID EXPUNGE` of
exactly those UIDs, after `CAPABILITY` and `=EXPECT-WORD UIDPLUS` in the same
session; without UIDPLUS as well, there is no plan and nothing is sent.

### Where each safety rule is enforced

| Rule | Enforced in | Checked by |
| --- | --- | --- |
| TLS chain and host name always verified | `native/mailbend-tls.c` | transport tests (bad CA, wrong host, expired, self-signed) |
| Only the helper reads the password; no output contains it | helper (login, login replies not forwarded) | transport cases 2 and 18, e2e output scan |
| Reads never change mail (`EXAMINE`, `BODY.PEEK`) | `src/ops.bend` read plans | laws in `LAWS.bend`, e2e server log |
| Move and trash never expunge before copying; the first `UID EXPUNGE` names the first `UID COPY`'s UIDs | `plan_move`, `plan_trash` | laws `move/trash_never_loses_mail`, `move/trash_expunges_only_copied` |
| Delete needs `permanently-delete` and UIDPLUS; the first `UID EXPUNGE` names the first `\Deleted` store's UIDs | `plan_delete` | laws `delete_needs_confirmation`, `delete_checks_uidplus`, `delete_expunges_only_marked`, `delete_expunges_given_uids` |
| Stale UIDs never touch other messages | `=EXPECT` of the caller's UIDVALIDITY after `SELECT` in every change plan | laws `*_is_pinned`, `*_pins_callers_uidvalidity`, e2e stale-UIDVALIDITY cases |
| No plain `EXPUNGE` | plans use `UID EXPUNGE` only | law `expunge_renders_uid_expunge`, e2e server log |
| Read-only mode refuses and hides every tool that changes mail; drafts-only mode refuses every send; unclear switch values fail | `src/tools.bend` (`mode`, `gated`, `offered_tools`) | law `read_only_tools_are_exactly_five`, e2e (all 9 mutating tools, switch values, tool lists) |
| Attachments only from a dedicated `MAILBEND_ATTACH_DIR`, at most 32 and 25 MB | `mailbend-attach` (openat2, broad-directory and hard-link refusal, O_PATH type check), `src/tools.bend` budget | e2e (symlink, `..`, `/proc/self/environ`, `/`, home, `.ssh`, hard link, FIFO, count, budget) |
| Message content cannot spoof a server reply | literals as raw bytes (helper and core) | transport and unit tests |
| Malformed MCP input is refused | `src/json.bend`, `main.bend` | unit tests, e2e MCP session |
| Folder roles resolve independently; uncertain targets never trigger guessed writes | `src/tools.bend` discovery and resolution, `src/ops.bend` discovery plans | local e2e partial-role, override, ambiguity and failed-discovery cases |

## Layers

```text
main.bend            CLI (call/tools/mcp) and the MCP stdio server (JSON-RPC lines)
src/tools.bend       the 14 tools: arguments, sessions, results
src/ops.bend         operations and their IMAP command plans (the only way tools build commands)
src/imap.bend        command model, wire rendering, transcript parsing, modified UTF-7
src/mime.bend        message parsing (headers, RFC 2047/2231, multipart) and composition
src/smtp.bend        the SMTP envelope (dot-stuffing)
src/codec.bend       UTF-8, base64, quoted-printable, charsets
src/json.bend        JSON values, parser and serializer
src/schema.bend      MCP tool schemas (generated by tools/gen-schema.py)
native/mailbend-tls.c  verified TLS, login, lock-step command execution
native/mailbend-attach.c  safe attachment reads (no credentials)
LAWS.bend / PROOF.bend safety laws and their proofs
```

A tool call builds a plan (a list of IMAP commands) in `ops.bend`, renders it
to a script, and runs it through `mailbend-tls`, which logs in, sends the
commands one at a time, stops at the first rejection, logs out, and returns
the transcript. The core parses the transcript into results. Tools that need
server facts first (capabilities, special folders, the original of a reply)
run a short discovery session before the action session.

## Credentials

The core never reads `MAILBEND_APP_PASSWORD`; only the helper does. The
helper wipes its copies after login and does not forward the server's
login replies, so no transcript, tool result or log can contain the
password. An environment variable is still inherited by the core and
readable by any process of the same user; with `MAILBEND_PASSWORD_FILE`
(absolute, a regular file owned by the user, mode 600, no symlink in any
path component) the
helper reads the password from that file instead, and it is in no
environment. Setting both is refused.

## Semantics

| Operation | Protocol |
| --- | --- |
| probe / list folders | `CAPABILITY` (after login) + `LIST "" "*"`; when SPECIAL-USE is advertised, a second discovery session requests `LIST "" "*" RETURN (SPECIAL-USE)`, even if ordinary LIST already marks some roles |
| search | `EXAMINE` + `UID SEARCH` (`CHARSET UTF-8` with literals for non-ASCII) |
| message summaries | `EXAMINE` + `UID FETCH (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (...)])` |
| read | `EXAMINE` + `UID FETCH (... BODY.PEEK[]<0.max>)` |
| new mail | `EXAMINE` + `UID SEARCH UID n+1:*`, filtered to UIDs > n |
| changes to existing messages | `SELECT`, `=EXPECT * OK [UIDVALIDITY v]` (checked by the helper), `UID SEARCH UID <uids>` (reports changed/missing) |
| mark read / unread | then `UID STORE +FLAGS.SILENT (\Seen)` / `-FLAGS.SILENT` |
| move | then `UID MOVE`; else (after `CAPABILITY` + `=EXPECT-WORD UIDPLUS` ahead of the guard) `UID COPY` + `UID STORE +FLAGS.SILENT (\Deleted)` + `UID EXPUNGE`; else refused |
| trash | move to the resolved Trash folder using the per-role policy below |
| delete | confirmation word, then `CAPABILITY` + `=EXPECT-WORD UIDPLUS`, the guard, `\Deleted` + `UID EXPUNGE` of exactly those UIDs; else refused |
| save draft / reply-as-draft / forward-as-draft | `APPEND` to the resolved Drafts folder with `(\Draft \Seen)` |
| send / reply / forward | MIME composition + SMTP via STARTTLS |

### Folder discovery and resolution

The Bend core merges ordinary and extended LIST entries by decoded mailbox
identity, preserving ordinary entries and their attributes. A failed extended
LIST remains an error; it never permits fallback to guessed folder names.
The TLS helper only executes the core's discovery plans.

Each role resolves independently: a nonempty `MAILBEND_<ROLE>_FOLDER` override,
then a unique selectable advertised SPECIAL-USE target, then a unique
selectable conventional-name target if that role is not advertised.

| Role | Override | Conventional names |
| --- | --- | --- |
| Drafts | `MAILBEND_DRAFTS_FOLDER` | `Drafts` |
| Trash | `MAILBEND_TRASH_FOLDER` | `Trash`, `Deleted Messages` |
| Sent | `MAILBEND_SENT_FOLDER` | `Sent`, `Sent Messages` |
| Junk | `MAILBEND_JUNK_FOLDER` | `Junk` |
| Archive | `MAILBEND_ARCHIVE_FOLDER` | `Archive` |

Overrides use the exact decoded LIST name, including namespace prefixes;
only `INBOX` compares case-insensitively. Invalid or unselectable overrides
fail visibly. Multiple advertised targets or conventional aliases are
unresolved. An advertised but unselectable target blocks fallback, and a
conventional candidate carrying a different recognized role is excluded.
There is no substring matching, namespace guessing or mailbox creation.

`mail_probe` reports resolved roles. `mail_list_folders` reports actual
advertised attributes and `special_use`; a role resolved by name or override
can still have `special_use: null` in that listing. Missing or ambiguous
Drafts or Trash blocks operations requiring that target. Resolving Sent does
not append sent mail there: SMTP delivery and provider filing are separate.

Local e2e tests exercise partial metadata, extended discovery, all three
draft paths, advertised-role precedence, localized/nested overrides and
refusal of ambiguous, missing, unselectable or failed-discovery targets.
These tests use the fake TLS server, not a live provider.

### Other protocol details

- Capabilities are read after authentication, never assumed. IDLE is
  reported by `mail_probe` for a future watcher.
- Folders are IMAP mailboxes; names travel in modified UTF-7 and are shown
  decoded.
- Messages are addressed by UID. `mail_get_new` checkpoints on
  `folder + UIDVALIDITY + UID`, never on read/unread state; when UIDVALIDITY
  changes it reports `uidvalidity_changed` and restarts at 0.
- Composed messages are 7-bit: RFC 2047 encoded words for headers,
  quoted-printable text, base64 attachments. For SMTP-sent messages, Bcc goes
  only into the envelope; saved drafts retain the header.
- A plain `EXPUNGE` is never sent: it would also remove messages another
  client marked `\Deleted`.
- Changes to existing messages require the folder's `uidvalidity` and are
  pinned to it in the changing session itself (`=EXPECT` after `SELECT`); move, trash and
  delete also run a read-only preflight (`CAPABILITY`, `LIST`, `EXAMINE`)
  for capabilities and folders.
- The core starts the helper only from an absolute `MAILBEND_TLS_HELPER`,
  never from a path relative to the working directory.
- Attachments come only from `MAILBEND_ATTACH_DIR` (at most 32, 25 MB in
  total, reading stops at the first failure), read by `mailbend-attach`
  (from an absolute `MAILBEND_ATTACH_HELPER`) with `openat2` beneath that
  directory (no symlinks,
  no `..` that leaves it; the directory itself is opened by its canonical path without
  following symlinks) and checked on the opened descriptor. The directory
  must be dedicated: `/`, the home directory or one containing it, and one
  holding `.ssh`, `.gnupg`, `.aws`, `.config` or `.git` are refused, as are
  files with a second hard link, devices and FIFOs.
- A `mail_get_new` checkpoint is a UID with its UIDVALIDITY: `since_uid`
  without `uidvalidity` is refused.
- Replies read the first 256 KB of the original. The result reports
  `quoted_original_truncated`, `quoted_bytes` and `original_bytes`, and a
  larger original also gets a note in the quote that it may be incomplete,
  so a partial quote is never mistaken for the whole message.
- Saved drafts keep a `Bcc:` header (a mail client sends them later); sent
  mail never carries one, Bcc goes only into the SMTP envelope.
- Every tool call (MCP or CLI) is checked against the tool's input schema
  first: a value of the wrong type, an unknown argument name or a missing
  required argument is refused, never read as absent or defaulted (so
  `"as_draft": "true"` cannot fall back to sending, nor a reply go out with
  no body).
- The MCP server accepts request lines up to 8 MiB and answers malformed
  JSON with `-32700`, a malformed JSON-RPC envelope with `-32600`, and
  tool `arguments` that are not an object with `-32602`.
- Search and new-mail fetch in a second session and require it to report
  the same UIDVALIDITY; reply and forward require the caller's
  `uidvalidity` to match the session that fetched the original.

## Safety laws

`LAWS.bend` states the invariants over the plans in `src/ops.bend`;
`PROOF.bend` proves them, and `bend PROOF.bend` fails if any stops holding:

- `Read`/`Search` are read-only, `Delete` is not, `Trash` is not destructive;
- the probe, preflight, folder, roles, search, summary, read and new-mail plans
  contain no command that can change a mailbox, for all arguments;
- rendered read scripts start with `EXAMINE`, and every fetch item renders as
  `BODY.PEEK[...]` or metadata;
- marking read/unread never marks `\Deleted` or expunges;
- move and trash never expunge before copying, for every capability set,
  and their first `UID EXPUNGE` names the same UIDs as their first
  `UID COPY`;
- every mail-changing command of move, trash and confirmed delete is pinned:
  one `UID MOVE`, or one `UID COPY`, one `\Deleted` store and one
  `UID EXPUNGE`, or (delete) one `\Deleted` store and one `UID EXPUNGE`, all
  of the caller's UIDs, with nothing after them;
- delete is the empty plan unless the confirmation is exactly
  `permanently-delete` (the tool passes the caller's string straight in); its
  first `UID EXPUNGE` names the same UIDs as its first `\Deleted` store,
  which with the confirmation and UIDPLUS are the caller's UIDs;
- `CExpunge` renders as `UID EXPUNGE`;
- saving a draft never removes anything;
- mark, move, trash and delete plans open with `SELECT` and the expectation
  of the caller's exact UIDVALIDITY (or are empty);
- delete and copy-based move plans confirm UIDPLUS in their own session
  before anything else;
- exactly the five read tools are read-only.

The laws are about these pure plans and their rendering. The native helpers,
TLS, MIME parsing, the agent's choices and the runtime configuration are
outside them and covered by the transport, unit and e2e tests. The
confirmation word is supplied by the agent, so it guards against mistakes,
not against a manipulated agent: it is not a person's approval.

Fetch items are a closed type with no non-PEEK body item, so a read cannot
set `\Seen` by construction; the e2e suite also checks the server log.

## Transport boundary

See [native/README.md](../native/README.md) for the helper's contract: the
TLS rules, script format, output encoding, limits and exit codes.

The helper uses libcurl only for DNS and TCP connection setup, in connect-only
mode; it sends no mail commands through libcurl. System DNS is the default.
The cloud launcher opts into fresh DNS-over-HTTPS per helper process, while
OpenSSL still verifies the original mail hostname and owns mail TLS. Numeric
connection overrides likewise never change SNI or the certificate identity.
No DNS result is stored on disk or in the long-running Bend MCP core. See the
[cloud recovery guide](CLOUD_AGENT.md) for resolver configuration and rebuilds.

## Bend notes

Bend 2 is total by default: no mutual recursion, recursion must
shrink an argument, and `match` only inspects parameters. Parsers are
therefore char-by-char state machines (structural on the input) feeding
explicit stacks. The MCP read loop and its supporting loop helpers use
`@unsafe`, as in Bend's own server demos, because the client determines the
session length. Running `bend main.bend`
checks and compiles on every start (~9 s); `scripts/install.sh` compiles a
native binary once (~1 min) that starts in milliseconds.
