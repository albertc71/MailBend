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
touches the password and the mail servers; `mailbend-attach`, which holds no
credentials, is the only code that opens attachment files, writes downloaded
attachments or opens the send counter; `mailbend-typesafe`, which never holds
the password, is the only code that reads the TypeSafe key and reaches
TypeSafe.

```mermaid
flowchart TB
  agent["AI agent (MCP client)"]
  cli["CLI: scripts/mailbend call / tools"]
  env[["Environment or agent secrets<br/>MAILBEND_EMAIL, MAILBEND_APP_PASSWORD"]]

  subgraph core["Bend core process: never reads the password"]
    direction TB
    main["main.bend<br/>MCP JSON-RPC server and CLI<br/>8 MiB line cap, envelope check"]
    json["src/json.bend<br/>strict JSON parser"]
    tools["src/tools.bend<br/>22 tools: arguments, sessions, results<br/>MAILBEND_READ_ONLY gate"]
    ops["src/ops.bend<br/>plan_* command plans<br/>the only way to build IMAP commands"]
    laws["LAWS.bend + PROOF.bend<br/>69 laws proven over the plans, the envelope and Jev requests"]
    imap["src/imap.bend<br/>render script, parse transcript"]
    mime["src/mime.bend + src/codec.bend<br/>parse and compose MIME"]
    smtp["src/smtp.bend<br/>SMTP envelope, dot-stuffing"]
    jevb["src/jev.bend<br/>Jev facts, questions, requests, answers"]
  end

  subgraph helper["mailbend-tls (Rust, rustls): the only reader of the password"]
    direction TB
    validate["Validate the whole script<br/>before connecting"]
    tls["TLS 1.2+, chain and host name verified<br/>login; login replies not forwarded"]
    lock["Lock-step: one command at a time<br/>stop at the first NO/BAD or unmet =EXPECT"]
  end

  subgraph reader["mailbend-attach (Rust)"]
    attach["no credentials: re-executes with an empty environment<br/>no procfs or sysfs files<br/>openat2 beneath the directory<br/>no symlinks, no .. that leaves it<br/>regular file within the byte budget"]
    save["save: a new file in the download directory<br/>apart from the attachment directory,<br/>not where files may be run<br/>O_TMPFILE, then linkat: never replaces"]
  end

  subgraph typesafe["mailbend-typesafe (Rust): the only reader of the TypeSafe key"]
    ask["re-executes with an allow-listed environment<br/>(no mail password)<br/>one POST to the fixed endpoint, verified TLS<br/>key redacted from answers"]
  end

  imapsrv[("IMAP implicit TLS<br/>default imap.mail.me.com:993")]
  smtpsrv[("SMTP STARTTLS required<br/>default smtp.mail.me.com:587")]
  files[("MAILBEND_ATTACH_DIR<br/>attachments off without it")]
  sends[("MAILBEND_STATE_DIR/sends<br/>daily send count")]
  downloads[("MAILBEND_DOWNLOAD_DIR<br/>downloads off without it")]
  tsapi[("TypeSafe HTTPS<br/>api.typesafe.ai/v1/systemone")]
  tskey[["MAILBEND_TYPESAFE_KEY_FILE"]]

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
  tools -- "count: state dir, limit, day" --> attach
  attach --> sends
  tools -- "save: name, file bytes on stdin" --> save
  save --> downloads
  tools --> jevb
  tools -- "request JSON (built by jev.bend) on stdin" --> ask
  ask -- "answer JSON on stdout" --> tools
  ask <--> tsapi
  env -. "read by the helper only" .-> tls
  tskey -. "read by this helper only" .-> ask
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
| TLS chain and host name always verified | `native/mailbend-net/src/tls.rs` (rustls) | transport tests (bad CA, wrong host, expired, self-signed) |
| Only the helper reads the password; no output contains it | helper (login, login replies not forwarded) | transport cases 2 and 18, e2e output scan |
| Reads never change mail (`EXAMINE`, `BODY.PEEK`) | `src/ops.bend` read plans | laws in `LAWS.bend`, e2e server log |
| Move and trash never expunge before copying; the first `UID EXPUNGE` names the first `UID COPY`'s UIDs | `plan_move`, `plan_trash` | laws `move/trash_never_loses_mail`, `move/trash_expunges_only_copied` (labels: `label_is_move`) |
| Flagging changes exactly `\Flagged` and, for a colour, its three bits (a closed set, one pure colour-to-bits mapping), never `\Deleted` or an expunge; unflagging clears all of them; `colour_kept` is `true` only with every changed message's reported flags and PERMANENTFLAGS as evidence | `plan_flag`, `plan_unflag`, `colour_bits`, `colour_kvs` | laws `flag_never_deletes`, `flag_changes_only_flag_and_colour`, `flag_changes_exactly`, `unflag_clears_flag_and_colour`, unit test per colour, e2e kept / session-only / dropped / unverified cases |
| A label is a move, and creating or renaming a folder touches no message | `plan_label` is `plan_move`; `plan_create`, `plan_rename` | laws `label_is_move`, `label_creates_no_folder`, `create/rename_changes_exactly`, `create/rename_changes_no_mail`, `folder_plans_destroy_nothing` |
| Folder tools never touch INBOX, role folders or `To Delete`, nest under no missing parent, and fail closed when the delimiter is unknown; `inbox/` is written as the listed INBOX | `src/tools.bend` `*_problem`, `canonical_name` | e2e `folder_*` cases, both delimiters |
| A move cut off after its COPY may have run is `partial`, never an error implying nothing changed | `src/tools.bend` `interrupted`, `Out.Partial` | e2e interrupted-label cases, MCP `isError` case |
| A flag change stopped once a store was acknowledged or sent unanswered is `partial`, listing the acknowledged and possibly-run changes; one whose search found no UID, or that stopped before any store, is a plain error | `src/tools.bend` `flag_cut`, `store_changes` | e2e refused, cut-off, absent-UID, unflag-cleanup and read-back cases |
| A helper that never started changed nothing; one that failed after starting, or was killed by a signal, may have (one classifier for flag changes, COPY-based moves and folder changes) | `src/tools.bend` `proc_of` (`ProcRefused` for the path refusal and spawn errnos), `helper_lost` | e2e relative, missing and killed helper cases |
| Delete needs `permanently-delete` and UIDPLUS; the first `UID EXPUNGE` names the first `\Deleted` store's UIDs | `plan_delete` | laws `delete_needs_confirmation`, `delete_checks_uidplus`, `delete_expunges_only_marked`, `delete_expunges_given_uids` |
| Stale UIDs never touch other messages | `=EXPECT` of the caller's UIDVALIDITY after `SELECT` in every change plan | laws `*_is_pinned`, `*_pins_callers_uidvalidity`, e2e stale-UIDVALIDITY cases |
| No plain `EXPUNGE` | plans use `UID EXPUNGE` only | law `expunge_renders_uid_expunge`, e2e server log |
| Read-only mode refuses and hides every tool that changes mail; drafts-only mode refuses every send; `mail_classify` is refused and hidden unless `MAILBEND_TYPESAFE` is on; unclear switch values fail | `src/tools.bend` (`config`, `gated`, `offered_tools`), `Ops.listed` | laws `read_only_tools_are_exactly_seven`, `tools_listed_per_config`, e2e (all 15 mutating tools, switch values, tool lists with Jev off and on) |
| The TypeSafe key never shares a process with the mail password: it is read only from `MAILBEND_TYPESAFE_KEY_FILE` by `mailbend-typesafe`, which re-executes with an allow-listed environment; `MAILBEND_TYPESAFE_API_KEY` set fails every tool; the key is redacted from answers | `native/mailbend-typesafe` (`environment`, `settings`, `api`), `mailbend-io` `secret`, `config` in `src/tools.bend`, `mailbend-tls` refusal | Rust tests (allow-list, redaction, exit codes), e2e (`/proc/<pid>/environ` of the helper, key in the environment, echoed key, output scan) |
| Jev gets header facts and attachment names, and message text only with `MAILBEND_TYPESAFE_CONTENT=body` and `MAILBEND_TYPESAFE_ZERO_RETENTION=1`; `mail_classify` changes nothing and creates no folder | `src/jev.bend` (`state_of`), `plan_classify` (`EXAMINE`, `BODY.PEEK`, `BODYSTRUCTURE`) | laws `headers_state_has_no_body`, `classify_writes_nothing`, `fetch_items_never_set_seen`; unit tests; e2e recorded requests, server log and state |
| A missing or malformed Jev answer reads as the cautious one; a refused request is split once, any other failure stops the call | `src/jev.bend` (bands, picks), `ask_batch` in `src/tools.bend` | law `missing_answer_is_cautious`, unit tests, e2e against `tests/fake_typesafe.py` (401, 422, 429, 529, timeout, malformed, split, later-batch failure) |
| With an allowlist, a message goes only when every envelope recipient is allowed; the envelope has no other source | `S.outbound` in `src/smtp.bend`, `send_with` in `src/tools.bend` | laws `allowlist_refuses_unlisted`, `no_allowlist_is_unchanged`, CI grep for other envelope callers, unit and e2e allowlist cases |
| The daily send limit is reserved before SMTP and fails closed; no tool reads or changes the count | `mailbend-attach count` (`flock`, openat2), `reserve` in `src/tools.bend` | Rust tests (two concurrent processes), e2e at, below and over the limit |
| A Sent copy is one `APPEND` to the resolved Sent folder, made only when a read-only search finds no copy; a failed copy does not fail the send | `plan_sent_copy`, `sent_copy` in `src/tools.bend` | law `sent_copy_only_appends`, e2e with and without server filing |
| Malformed send settings refuse every send, never read as off | `src/tools.bend` `sending_of` | unit and e2e cases |
| Attachments only from a dedicated `MAILBEND_ATTACH_DIR`, at most 32 and 25 MB | `mailbend-attach` (openat2, broad-directory and hard-link refusal, O_PATH type check), `src/tools.bend` budget | e2e (symlink, `..`, `/proc/self/environ`, `/`, home, `.ssh`, hard link, FIFO, count, budget) |
| Downloads are new files (mode 0600, never replacing one) only in a dedicated `MAILBEND_DOWNLOAD_DIR`, apart from `MAILBEND_ATTACH_DIR` and from directories whose files may be run; never in read-only mode | `mailbend-attach save` (`O_TMPFILE` + `linkat`, device and inode lineage, `PATH` entries), `local_name` in `src/mime.bend`, law `download_is_not_read_only` | Rust tests, e2e (every byte, existing file, names, overlap and alias, `~/.config`, `autostart`, `.ssh`, `PATH` and alias, killed helper, truncated fetch) |
| Message content cannot spoof a server reply | literals as raw bytes (helper and core) | transport and unit tests |
| Malformed MCP input is refused | `src/json.bend`, `main.bend` | unit tests, e2e MCP session |
| A thread holds only messages whose Message-ID, In-Reply-To or References name one of the IDs searched for, compared exactly after the substring `SEARCH HEADER`; never grouped by subject; at most two rounds | `src/thread.bend` (`is_linked`, `next_ids`, `thread_order`), `plan_thread_search`, `plan_thread_headers` | law `thread_plans_write_nothing`, unit tests (order, missing parents, cycles, shared IDs, long References), e2e case-only match, deleted reply, two-round bound, long References |
| A dry run (`dry_run: true`) runs only the read-only checks the tool makes (the flag tools make none), then shows the IMAP lines, the SMTP sender, recipients and `sent_copy` intent, or file it would use, with messages and files as `<N bytes>`; it reserves no send and does not check the daily limit, saves no file and is refused in read-only mode | `preview_or_run` in `src/tools.bend` (every tool that is not read-only), `I.preview` | law `append_preview_hides_message`, unit tests, e2e (every such tool: server state and log, download directory, send counter, `mailbend-attach` calls) |
| Folder roles resolve independently; uncertain targets never trigger guessed writes | `src/tools.bend` discovery and resolution, `src/ops.bend` discovery plans | local e2e partial-role, override, ambiguity and failed-discovery cases |

## Layers

```text
main.bend            CLI (call/tools/mcp) and the MCP stdio server (JSON-RPC lines)
src/tools.bend       the 22 tools: arguments, sessions, results
src/jev.bend         TypeSafe's Jev: message facts, questions, requests and typed answers
src/thread.bend      which messages form a thread, and their order and parents
src/ops.bend         operations and their IMAP command plans (the only way tools build commands)
src/imap.bend        command model, wire rendering, transcript parsing, modified UTF-7
src/mime.bend        message parsing (headers, RFC 2047/2231, multipart) and composition
src/smtp.bend        the SMTP envelope (dot-stuffing) and the recipient allowlist
src/codec.bend       UTF-8, base64, quoted-printable, charsets
src/json.bend        JSON values, parser and serializer
src/schema.bend      MCP tool schemas (generated by tools/gen-schema.py)
native/mailbend-tls/   verified TLS, login, lock-step command execution (Rust)
native/mailbend-attach/  safe attachment reads and downloads, the send counter (Rust, no credentials)
native/mailbend-typesafe/  the TypeSafe request, with the key from its file (Rust, no mail password)
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
| flag / unflag | then `UID STORE +FLAGS.SILENT (\Flagged)`; with a colour, one `UID STORE` per `$MailFlagBit0..2`, adding the bits of its index and removing the others (red has none); without one, no bit store. Unflag removes `\Flagged`, then all three bits. Then `UID FETCH (UID FLAGS)`: its own replies (the last with FLAGS per UID; none without a UID) are the reported flags, judged for a colour with SELECT's `PERMANENTFLAGS` (`colour_kept`, `colour_not_kept`) |
| move | then `UID MOVE`; else (after `CAPABILITY` + `=EXPECT-WORD UIDPLUS` ahead of the guard) `UID COPY` + `UID STORE +FLAGS.SILENT (\Deleted)` + `UID EXPUNGE`; else refused |
| trash | move to the resolved Trash folder using the per-role policy below |
| label | the move plan, into an existing folder that is none of the protected ones |
| create folder | `CAPABILITY`, `CREATE`, `SUBSCRIBE`, after a discovery session (`CAPABILITY`, `LIST`, `LSUB`) |
| rename folder | `CAPABILITY`, `RENAME`, a `SUBSCRIBE` of the new name of each moved folder that was subscribed, then an `UNSUBSCRIBE` of each old name |
| delete | confirmation word, then `CAPABILITY` + `=EXPECT-WORD UIDPLUS`, the guard, `\Deleted` + `UID EXPUNGE` of exactly those UIDs; else refused |
| save draft / reply-as-draft / forward-as-draft | `APPEND` to the resolved Drafts folder with `(\Draft \Seen)` |
| send / reply / forward | MIME composition + SMTP via STARTTLS |
| classify | `CAPABILITY` + `LIST` (the folders to choose among), then `EXAMINE` + `UID FETCH (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (...)] BODYSTRUCTURE)`, with `BODY.PEEK[]<0.max>` too in body mode; then requests to TypeSafe through `mailbend-typesafe` |

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
  holding `.ssh`, `.gnupg`, `.aws`, `.config` or `.git`, or that is or lies
  inside a directory so named, are refused, as are
  files with a second hard link, devices and FIFOs.
- `mail_get_attachment` reads the message as `mail_get` does and refuses one
  larger than 25 MB, by its reported size or because its body fills the
  25 MB fetch, rather than save part of it. `mailbend-attach save`
  writes into `MAILBEND_DOWNLOAD_DIR`, which it refuses on the same grounds
  as `MAILBEND_ATTACH_DIR`, when it is, contains or lies inside
  `MAILBEND_ATTACH_DIR`, or when its files may be run (see
  [native/README.md](../native/README.md#downloads)). `PATH` reaches it as
  an argument, because the helper drops its environment.
- A `mail_get_new` checkpoint is a UID with its UIDVALIDITY: `since_uid`
  without `uidvalidity` is refused.
- `mail_get_thread` searches the message's folder, INBOX and the resolved
  Sent folder (each once; Sent is left out when it does not resolve) for
  the IDs the thread names (`UID SEARCH HEADER ... UNDELETED`, one session
  for every folder), fetches the summaries of the new UIDs, and keeps a
  message only when its own ID, In-Reply-To or References name one of those
  IDs exactly. It runs two such rounds at most, 50 IDs each, and only the
  last 50 References of a message count, so a long header costs no more.
  An ID that is not plain ASCII or is longer than 998 bytes is not searched
  for, so that no server refuses a search. The read fails when a folder's
  UIDVALIDITY changes between its sessions. Messages are ordered by
  INTERNALDATE (set by the server) and then UID; a message's parent is the
  one its In-Reply-To names, else the last one its References names. A
  cycle of parents in broken headers is cut at its newest message, and a
  message whose Message-ID another message also has gets no parent.
- Replies read the first 256 KB of the original. The result reports
  `quoted_original_truncated`, `quoted_bytes` and `original_bytes`, and a
  larger original also gets a note in the quote that it may be incomplete,
  so a partial quote is never mistaken for the whole message.
- Saved drafts keep a `Bcc:` header (a mail client sends them later); sent
  mail never carries one, Bcc goes only into the SMTP envelope.
- Every tool call (MCP or CLI) is checked against the tool's input schema
  first: a value of the wrong type, an unknown argument name, an argument
  given more than once or a missing required argument is refused, never read
  as absent or defaulted (so `"as_draft": "true"` cannot fall back to
  sending, nor a reply go out with no body, and `"dry_run": false, "dry_run":
  true` cannot run for real while a client that keeps the last member reads
  a dry run).
- The MCP server accepts request lines up to 8 MiB and answers malformed
  JSON with `-32700`, a malformed JSON-RPC envelope with `-32600`, and
  tool `arguments` that are not an object with `-32602`.
- Search and new-mail fetch in a second session and require it to report
  the same UIDVALIDITY; reply and forward require the caller's
  `uidvalidity` to match the session that fetched the original.

## Safety laws

`LAWS.bend` states the invariants over the plans in `src/ops.bend` and the
SMTP envelope in `src/smtp.bend`; `PROOF.bend` proves them, and
`bend PROOF.bend` fails if any stops holding:

- `Read`/`Search` are read-only, `Delete` is not, `Trash` is not destructive;
- the probe, preflight, folder, roles, search, summary, read, new-mail and
  thread plans contain no command that can change a mailbox, for all
  arguments;
- rendered read scripts start with `EXAMINE`, and every fetch item renders as
  `BODY.PEEK[...]` or metadata;
- marking read/unread never marks `\Deleted` or expunges;
- flagging and unflagging never mark `\Deleted` or expunge, and every store
  they make is on `\Flagged` or a colour bit; flagging stores exactly
  `\Flagged` without a colour, and `\Flagged` then each bit as `colour_bits`
  gives it with one; unflagging clears `\Flagged`, then all three bits;
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
- with an allowlist, any one unlisted recipient, at any position, means no
  envelope at all (proven by induction over the recipients before it);
  without one, the envelope is the plain one;
- a Sent copy changes mail only by one `APPEND` of the message to Sent,
  seen, and changes no folder;
- mark, flag, move, trash and delete plans open with `SELECT` and the expectation
  of the caller's exact UIDVALIDITY (or are empty);
- delete and copy-based move plans confirm UIDPLUS in their own session
  before anything else;
- creating or renaming a folder changes folders and no message: `CREATE` then
  `SUBSCRIBE`, or `RENAME`, then a `SUBSCRIBE` of each
  moved folder's new name, then an `UNSUBSCRIBE` of each old one (each plan
  starts with `CAPABILITY`, which changes nothing), and nothing in them
  removes mail (no plan deletes a folder);
- a label is a move: `plan_label` is `plan_move`, so every move law covers it,
  and it changes no folder;
- a dry run shows an `APPEND` with the size of its message, never the
  message;
- exactly the seven read tools (the six reads and `mail_classify`) are
  read-only, and each combination of read-only, drafts-only and Jev lists
  exactly its tools;
- the classify plan contains no command that can change a mailbox;
- a headers-mode Jev request holds the UID, header fields and attachment
  names only, never message text;
- a missing Jev answer is the cautious one: an unknown band that counts as
  keep and as suspected injection, no suggested action, and no folder
  chosen.

The laws are about these pure plans, the envelope and their rendering. The native helpers,
TLS, MIME parsing, the agent's choices and the runtime configuration are
outside them and covered by the transport, unit and e2e tests. The
confirmation word is supplied by the agent, so it guards against mistakes,
not against a manipulated agent: it is not a person's approval.

Fetch items are a closed type with no non-PEEK body item, so a read cannot
set `\Seen` by construction; the e2e suite also checks the server log.

## Transport boundary

See [native/README.md](../native/README.md) for the helper's contract: the
TLS rules, script format, output encoding, limits and exit codes.

System DNS is the default. The cloud launcher opts into fresh
DNS-over-HTTPS per helper process (the helper's own client in
`native/mailbend-net/`), while rustls still verifies the original mail
hostname and owns mail TLS. Numeric
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
