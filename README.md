# MailBend

Lightweight, Linux-first IMAP/SMTP connector for AI agents, with iCloud Mail
as the default and live-tested profile. The core is
written in [Bend 2](https://github.com/bendlang/bend); a small C helper
does verified TLS. MailBend exposes mail as MCP tools (stdio) and as a CLI.

## What it can do

| Tool | What it does | Changes mail? |
| --- | --- | --- |
| `mail_probe` | Verified TLS login, server capabilities, special folders | no |
| `mail_list_folders` | Mailboxes/folders with advertised special-use attributes | no |
| `mail_search` | Search by from/to/cc/subject/body/text/dates/flags, newest first | no |
| `mail_get` | Read one message: headers, text, attachment list | no |
| `mail_get_new` | Messages after a `UIDVALIDITY + UID` checkpoint | no |
| `mail_get_thread` | The conversation of a message, oldest first, from its folder, INBOX and Sent: linked by Message-ID, In-Reply-To and References only (never by subject), each message with its folder, `uidvalidity` and `parent` | no |
| `mail_classify` | Ask TypeSafe's Jev, for up to 50 messages, which existing folder each belongs in and whether it needs a reply, an action or attention; only with `MAILBEND_TYPESAFE` on (see [TypeSafe's Jev](#typesafes-jev)) | no |
| `mail_triage` | File up to 50 messages with Jev: each moves at most once, into the existing folder Jev chose with high confidence, or into `To Delete` for you to review when the delete review finds it safe to delete; only with `MAILBEND_TYPESAFE` on (see [Triage](#triage-and-the-to-delete-folder)) | yes |
| `mail_get_attachment` | Save one attachment of a message as a new file in `MAILBEND_DOWNLOAD_DIR` (the message stays unread) | writes a file |
| `mail_mark_read` / `mail_mark_unread` | Add / remove `\Seen` | flags |
| `mail_flag` / `mail_unflag` | Add / remove `\Flagged`; `mail_flag` sets an Apple Mail `colour` (red, orange, yellow, green, blue, purple, grey) or, without one, keeps the current colour; `mail_unflag` clears the colour. The result lists the flags the server reported and, for a colour, `colour_kept` (`true`, `false` or `"unverified"`) | flags |
| `mail_move` | Move to another folder | yes |
| `mail_label` | Move into an existing label folder (a label is a folder; one copy, `uidvalidity` required) | yes |
| `mail_trash` | Move to the resolved Trash folder (recoverable) | yes |
| `mail_delete` | **Permanent** delete; needs `"confirm": "permanently-delete"` and the folder's `uidvalidity`; with Jev on, at most 50 UIDs, each checked by Jev first | yes |
| `mail_create_folder` | Create and subscribe to a folder: the only tool that creates a mailbox | yes |
| `mail_rename_folder` | Rename a folder with its subfolders; the subscriptions of the moved folders follow | yes |
| `mail_save_draft` | Compose into Drafts (with attachments) | yes |
| `mail_send` | Compose and send over SMTP (to/cc/bcc, attachments) | sends |
| `mail_reply` | Reply or reply-all, threaded; or save as draft (needs `uidvalidity`) | sends |
| `mail_forward` | Forward with the original attached; or save as draft (needs `uidvalidity`) | sends |

Read tools open folders with `EXAMINE` and fetch with `BODY.PEEK`, so reading
never marks mail as read. Tools that change messages take the `uidvalidity`
that came with the UIDs and report which UIDs were `changed` or `missing`. The safety rules are laws checked by the Bend
compiler (see [Safety](#safety)).

Every tool that changes or sends mail, or saves a file, also takes
`dry_run: true`. It then runs only the read-only checks the tool makes before
changing anything (such as folder discovery and the server's capabilities)
and returns what it would do instead of doing it: the IMAP commands as the TLS
helper would get them (`imap`), the SMTP sender and recipients (`smtp`), or
the file it would save (`file`). Messages and files show only their size, as
`<N bytes>`. A send's `smtp` also holds `sent_copy`, which says whether
`MAILBEND_SAVE_SENT` would save a Sent copy; it states the intent, and the
real send still skips the copy when the server has filed one itself. A dry
run is not a full pre-check:

- `mail_mark_read`, `mail_mark_unread`, `mail_flag` and `mail_unflag` make
  no connection on a dry run, so a stale UIDVALIDITY is caught only by the
  real run's check (the `=EXPECT` line in their preview);
- a dry-run send checks `MAILBEND_ALLOWED_RECIPIENTS` but not the daily send
  limit, and reserves no place in it;
- with Jev on, a dry-run send or delete passes the same gates (see
  [Jev's gates](#jevs-gates-on-sends-deletes-and-reads)) and shows their
  verdict.

Read-only mode refuses a dry run as it refuses the tool.

## Install (Linux)

Needs a C compiler, Rust 1.99+ (cargo and rustc), the system CA certificates,
and Bend 2 (clang 14+ to compile the core; without clang the core runs
through `bend` with a slower start).

```sh
sudo apt-get install -y build-essential clang ca-certificates curl
git clone https://github.com/albertc71/MailBend.git && cd MailBend
scripts/install.sh --install-bend --install-rust
```

`scripts/install.sh` builds `bin/mailbend-tls`, `bin/mailbend-attach` and
`bin/mailbend-typesafe`, checks the safety proofs with `bend PROOF.bend`,
and compiles the core to `bin/mailbend-core`. With
`--install-bend` and no `bend` on the `PATH`, it first runs
`scripts/install-bend.sh`, which installs the Bend release tested in CI to
`~/.bend` after checking the archive's sha256. That pinned release is Linux
x64 only; elsewhere, install Bend 2.0.35 yourself and run
`scripts/install.sh`. An already installed Bend is reused as is. Likewise,
`--install-rust` runs `scripts/install-rust.sh` (a sha256-checked `rustup-init`
that installs Rust 1.99 to `~/.cargo`) only when `cargo` does not provide
cargo and rustc 1.99+. Debian and Ubuntu do not package Rust 1.99, so use
rustup rather than a distribution `cargo`.

On a Grok Bot / Cursor cloud Linux computer, run `sh scripts/setup-cloud.sh`
for a complete Debian/Ubuntu install, then use `scripts/mailbend-cloud` for
CLI and MCP. That launcher enables fresh DNS-over-HTTPS to avoid cloud DNS
returning unreachable fake addresses such as `198.18.0.1`. After a computer
rebuild, rerun the same setup command from the saved clone; no `/etc/hosts`
pins are needed. See [cloud setup and recovery](docs/CLOUD_AGENT.md).

## Configure

For the default iCloud profile:

1. Turn on two-factor authentication for your Apple Account, then create an
   **app-specific password** at <https://account.apple.com> → Sign-In and
   Security → App-Specific Passwords.
2. Provide these as environment variables or agent secrets (never in files,
   prompts or command lines):

   ```sh
   export MAILBEND_EMAIL='you@icloud.com'
   export MAILBEND_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'
   ```

   Or keep the password out of every environment with
   `MAILBEND_PASSWORD_FILE`: the absolute path of a file you own with mode
   600, holding just the password, outside `MAILBEND_ATTACH_DIR`, given by
   a path with no symlink in any component (Linux 5.6+). Only
   `mailbend-tls` opens it; setting both variables is an error.

Optional variables are listed in [.env.example](.env.example): server
overrides, `MAILBEND_READ_ONLY=1` (refuse every tool that changes mail, and
list only the read tools), `MAILBEND_DRAFTS_ONLY=1` (allow changes but never
send: `mail_send` is refused and hidden, replies and forwards only as drafts,
so a person sends each message from Drafts), `MAILBEND_ATTACH_DIR` (the only
directory attachments may come from; attachments are off without it),
`MAILBEND_DOWNLOAD_DIR` (the only directory `mail_get_attachment` saves
in; downloads are off without it), `MAILBEND_TIMEOUT_MS`, and
`MAILBEND_TLS_HELPER` / `MAILBEND_ATTACH_HELPER`.
The two switches take `1`/`true` or `0`/`false`/empty; any other value is a
configuration error that fails every tool, rather than silently meaning off.

Sending (`mail_send`, and replies and forwards that are not drafts) has its
own optional settings. A malformed value refuses every send, never reads as
off, and leaves drafts and reads alone:

| Setting | Effect |
| --- | --- |
| `MAILBEND_ALLOWED_RECIPIENTS` | Comma-separated exact addresses and `@domain` entries (that domain only, not its subdomains), compared case-insensitively. A message with any other recipient (To, Cc, Bcc, or the original's To and Cc in a reply-all) is refused whole, and with an allowlist an address containing `%`, `!` or `:` is refused too. Unset or empty: no allowlist. |
| `MAILBEND_MAX_SENDS_PER_DAY` | A positive number of sends per UTC day. Each send is counted before it is handed to SMTP, so one that then fails or times out still counts, and a count that cannot be read or written refuses the send. Unset: no limit. |
| `MAILBEND_STATE_DIR` | An absolute path for the send count. Default: `$XDG_STATE_HOME/mailbend`, else `~/.local/state/mailbend`. |
| `MAILBEND_SAVE_SENT` | `1`/`true` appends each sent message (with its Bcc header, as a draft keeps it) to the resolved Sent folder, marked seen, unless the server already filed it there; the result reports `sent_copy`, and a failed copy does not fail the send. Default off. |

The count is `sends` in the state directory: one line per send, created
by `mailbend-attach` (directory mode 0700). No tool reads or changes it;
deleting it resets the count, which is a local user action, not one the
agent can take through MailBend.

### TypeSafe's Jev

`mail_classify` asks [TypeSafe](https://docs.typesafe.ai)'s Jev model about
messages, and `mail_triage` files them by its answers. Both are off, hidden
and refused unless you turn Jev on; `mail_classify` changes nothing: no
flag, no move, no folder. These settings are checked even when Jev is off,
and any bad value fails every tool:

| Setting | Effect |
| --- | --- |
| `MAILBEND_TYPESAFE` | `1`/`true` lists `mail_classify` and `mail_triage` (read-only mode still hides `mail_triage`); `0`/`false`/empty keeps them off. |
| `MAILBEND_TYPESAFE_KEY_FILE` | Required when on: the absolute path of a file you own with mode 600 holding only the TypeSafe key, with the same rules as `MAILBEND_PASSWORD_FILE`. Only `mailbend-typesafe` reads it. |
| `MAILBEND_TYPESAFE_CONTENT` | `headers` (the default) sends each message's UID, its decoded From, To, Cc, Subject, Date, List-Id, List-Unsubscribe, Auto-Submitted and Precedence headers, and its attachment names. `body` also sends up to 16 KB of its plain text. |
| `MAILBEND_TYPESAFE_ZERO_RETENTION` | `1`/`true` is your statement that the TypeSafe account has a zero-retention plan; `body` content is refused without it. MailBend cannot check this statement. |

Never put the key in `MAILBEND_TYPESAFE_API_KEY`: when that variable is set,
even empty, every tool fails with a configuration error, so the key never
reaches a process that holds the mail password.

For each message, `mail_classify` returns `category` (the existing folder Jev
chose among the selectable folders other than INBOX, the special folders and
`To Delete`, or `null`) and a `jev` object: `status` (`checked`, or
`unchecked` with `reasons` when the message's header facts alone exceed a
request), the pinned `model`, the `content` sent, and `signals` such as
`reply_needed`, `action_required`, `priority`, `suggested_action`, `keep`,
`disposable` and `suspected_injection`. A missing or malformed answer reads
as the cautious one. When no folder fits, `needs_new_category` is `true`:
call again with `candidates` (new folder names, checked as
`mail_create_folder` checks them) and a chosen one is returned as
`new_category`. It is never created; create it with `mail_create_folder`.
The result also lists `not_found` UIDs and, per request, its `messages`,
`bytes` and TypeSafe's `input_tokens`. A request TypeSafe refuses is split
once into halves; any other failure stops the call. The answers come from
untrusted mail content.

#### Triage and the To Delete folder

`mail_triage(folder, uids, uidvalidity, dry_run?)` reads the messages as
`mail_classify` does, asks Jev about every one of them before anything
moves, and then moves each message at most once, following one table
(`filing` in `src/jev.bend`):

| Delete review | Category answer | Action |
| --- | --- | --- |
| safe to delete | any | move into `To Delete` |
| keep, review, or unanswered | an existing folder with high confidence | move into that folder |
| keep, review, or unanswered | a candidate, no fitting folder, a lower confidence, or none | stay |

A message is safe to delete only when every check passes: content mode is
`body` and Jev saw the whole text (a `body_truncated` message never is);
the message is not flagged or answered, has no attachments (and they can be
told), and is at least 30 days old; it has one From field with one readable
address, and you have never written to that sender in To or Cc (two
read-only searches of the Sent folder per sender; Bcc is not searched);
every keep answer (record, account security, personally written, open
action, needed again) is low; and the disposability score is high with high
confidence. Such a message is asked about in a request of its own, and only
those answers can send it to `To Delete`; the others are asked in batches,
as `mail_classify` asks. Just before the moves, a short read-only session
reads the flags of the messages bound for `To Delete` again: one you
flagged or answered meanwhile is kept, and filed like any kept message.
Each message's result gives its `verdict` (`safe_to_delete`, `keep`,
`review` or `unanswered`), the code's `vetoes`, its `destination` (or
`null`) and the `jev` object; `moves` lists one move per destination folder.

Triage never deletes: `To Delete` is a folder for you to review, and
`mail_delete` remains the only way to remove mail permanently. Create it
once with `mail_create_folder`; triage never creates a folder. When a
message is safe to delete but `To Delete` is missing (or is a special
folder), the call is refused and moves nothing, but its error still lists
every message's verdict and proposed destination. If any TypeSafe request
fails, nothing moves. A move cut off part way fails the call with
`partial: true` and leaves the later moves unmade. Only `mail_triage` moves
mail into `To Delete` or a folder inside it. `mail_move` and `mail_label`
may move a message you keep out of it; `mail_trash` does not, and triage
never files mail out of it. No folder tool renames it or creates a folder
inside it, and no `MAILBEND_*_FOLDER` override may name it or a folder
inside it.

#### Jev's gates on sends, deletes and reads

With `MAILBEND_TYPESAFE` on, Jev can stop a send or a permanent delete, and
annotates what the agent reads. With it off, nothing below happens and no
tool's result changes. A gate can only take an action away, never change
it: a send that passes keeps exactly the envelope the allowlist gives, and
a delete exactly its plan.

- **Sends** (`mail_send`, `mail_reply`, `mail_forward`) first pass a local
  secret scan, in either content mode and without TypeSafe. It looks for a
  private-key block (PEM or PGP armour), a token with a well-known prefix
  (AWS, Google, GitHub, GitLab, Slack, Stripe, Anthropic, OpenAI, npm) and a
  line giving a password (`Password: ...`, with a digit in it, also when
  quoted with `>`). It reads, decoded from any transfer encoding:
  - the header fields (from, to and cc with their display names, bcc,
    subject, in-reply-to, references), the body and each attachment's name;
  - every text part of the attachments and of a forwarded original, and
    the header section of each attached or forwarded message
    (`message/rfc822` or `message/global`), opening them up to 3 levels
    deep and multipart nesting up to 8 levels;
  - last, every other part's bytes, whatever its type: a key file or a
    config file is caught, but this is best effort. Compressed formats (PDF
    streams, images, archives, office files) are not inspected, and these
    bytes share what is left of the text's 1 MB budget.

  A secret found blocks the send, and so does a scan that cannot read all
  the text: more than 1 MB of it, deeper nesting, more than 10,000 parts,
  or a text part it cannot decode, including one holding a NUL character
  (UTF-16 or UTF-32 text). Running out of budget on the other bytes does
  not. A block names the part by position (`attachment 1 > text/plain`),
  never by file name, and TypeSafe is not asked. The scan catches mistakes;
  it is not a boundary against an agent set on leaking.

  A clean message then goes to Jev, which is asked whether a recipient does
  not belong and whether it shares confidential information, plus, for
  reply-all, whether it should go only to the sender, and for a forward,
  whether the original asks not to be shared. Jev sees the header fields
  (from, to, cc, bcc, subject),
  attachment names and the original's header facts, and the body only in
  `body` mode. The result holds `secret_scan` (`clean`, `found` or
  `incomplete`) and a `jev` object whose `decision` is `proceeded` or
  `blocked`, with its `reasons`. A blocked send says so and suggests
  `mail_save_draft`, which is never gated.
- **`mail_delete`** asks Jev the delete review's keep questions (record,
  account security, personally written, open action, needed again) about
  every message first; any high answer blocks the whole delete. With Jev on
  it takes at most 50 UIDs and needs UIDPLUS, and it deletes only the
  messages Jev was asked about: a UID that did not exist then is reported
  in `missing`, even if a message took it meanwhile.
- **TypeSafe failing** (or an answer missing) blocks the send or delete,
  after two retries of an overloaded or timed-out TypeSafe.
- **Reads** (`mail_search`, `mail_get`, `mail_get_new` and
  `mail_get_thread`, marked `openWorldHint` for this reason) add a `jev`
  object to each message shown: `reply_needed`, `action_required`,
  `priority`, `category`, `suggested_action`, and `suspected_injection`
  only when Jev suspects one. The categories come from the folder list:
  `mail_get_thread` reuses the one it already read, and the others list the
  folders in one more read-only session (two when the server has
  SPECIAL-USE). A read asks TypeSafe once, without retries, so it waits at
  most one `MAILBEND_TIMEOUT_MS`. When TypeSafe fails, the read still
  returns its messages, each `jev` with `status: "unchecked"` and the
  reason.

The laws cover the pure gate functions (`Jev.outbound_checked` and
`Jev.delete_checked`, the only way the tools reach an SMTP envelope or a
delete plan) and the headers-mode request; the IO that calls them is
covered by the end-to-end tests and a CI check that no other code reaches
`S.outbound` or `smtp_run`, uses `plan_delete` without `delete_checked`, or
makes an expunge outside `src/ops.bend` and `src/imap.bend`.

Other providers require compatible password-authenticated IMAP over implicit
TLS and SMTP with STARTTLS. Set `MAILBEND_IMAP_HOST`, `MAILBEND_IMAP_PORT`,
`MAILBEND_SMTP_HOST` and `MAILBEND_SMTP_PORT` for that provider, and supply its
accepted password or app password. OAuth and implicit SMTPS are unsupported;
other providers have not been live-tested here.

Folder roles resolve independently, in this order: a nonempty explicit
override, a unique selectable mailbox advertising the role, then a unique
selectable conventional-name match when that role is not advertised. Partial
SPECIAL-USE metadata for one role does not disable fallback for another.

| Role override | Conventional fallback names |
| --- | --- |
| `MAILBEND_DRAFTS_FOLDER` | `Drafts` |
| `MAILBEND_TRASH_FOLDER` | `Trash`, `Deleted Messages` |
| `MAILBEND_SENT_FOLDER` | `Sent`, `Sent Messages` |
| `MAILBEND_JUNK_FOLDER` | `Junk` |
| `MAILBEND_ARCHIVE_FOLDER` | `Archive` |

Overrides must name one existing selectable mailbox using its exact decoded
LIST name, including any namespace prefix; only `INBOX` is case-insensitive.
Use them for localized or nested folders. Invalid overrides fail visibly.
Multiple role matches or multiple fallback aliases are ambiguous, and an
advertised but unselectable role blocks fallback. A fallback mailbox cannot
carry a different recognized role. Unresolved Drafts or Trash prevents writes
that require that role; MailBend never creates a mailbox implicitly or guesses
a path. Only `mail_create_folder` creates one, with the name the caller gives.

When the authenticated server advertises SPECIAL-USE, MailBend requests
`LIST RETURN (SPECIAL-USE)` and merges its metadata with ordinary LIST; a
failed discovery request remains an error. `mail_probe` reports resolved
roles. `mail_list_folders` retains actual advertised attributes and
`special_use`, so a folder resolved by override or name can still have
`special_use: null`.

## Use

Check the connection first:

```sh
scripts/mailbend call mail_probe
scripts/mailbend call mail_search '{"from": "apple", "limit": 5}'
scripts/mailbend call mail_get '{"uid": 1234}'
scripts/mailbend tools        # the tool list with JSON schemas
```

Register the MCP server (stdio) with your agent, using the absolute path:

```json
{
  "mcpServers": {
    "mailbend": {
      "command": "/absolute/path/to/MailBend/scripts/mailbend",
      "args": ["mcp"]
    }
  }
}
```

The server reads `MAILBEND_EMAIL` and `MAILBEND_APP_PASSWORD` (or
`MAILBEND_PASSWORD_FILE`) from its environment. Cursor Cloud Agent / Grok Bot setup, including secrets and
passing them through, is in [docs/CLOUD_AGENT.md](docs/CLOUD_AGENT.md).

## Safety

- **TLS is always verified**: certificate chain and host name, TLS 1.2+, with
  no option to turn verification off. SMTP requires STARTTLS.
- **Credentials stay in the helper.** Only `mailbend-tls` reads the password;
  it sends it only to the verified server and never prints it. The Bend core
  never reads it, so no tool result or log contains it. This is a code-level
  separation, not an OS boundary: `MAILBEND_APP_PASSWORD` is inherited by
  every MailBend process, and any process of the same user can read it.
  `MAILBEND_PASSWORD_FILE` keeps it out of the environment; the file is
  still readable by that user.
- **Mail is untrusted input, and the agent decides.** Anything that can call
  the tools can act on the account. A message read with `mail_get` can try
  to talk the agent into forwarding mail, sending files from
  `MAILBEND_ATTACH_DIR` or deleting messages. `confirm: "permanently-delete"`
  only stops a mistaken call; it is not a person's approval, because the
  agent supplies it. Read-only mode still shows mail to the agent. Use
  `MAILBEND_READ_ONLY=1` when writes are not needed and
  `MAILBEND_DRAFTS_ONLY=1` to keep a person in front of every send, and
  have your MCP client ask before it runs a tool that changes mail.
- **Sending can be fenced.** With `MAILBEND_ALLOWED_RECIPIENTS`, a message
  goes only when every envelope recipient is allowed: `LAWS.bend` states, and
  `PROOF.bend` proves, that the envelope is refused whenever any one
  recipient is not, wherever it stands in the list, and that without an
  allowlist the envelope is unchanged; the envelope has no other source.
  `MAILBEND_MAX_SENDS_PER_DAY` caps sends per UTC day in a local counter no
  tool can read or change. A Sent copy (`MAILBEND_SAVE_SENT`) is one
  `APPEND` to the Sent folder and nothing else (proven).
- **Reads cannot write.** `LAWS.bend` states, and `PROOF.bend` proves, that
  every read plan (probe, folders, search, get, new mail) contains no command
  that can change a mailbox, for every argument, and that what is rendered on
  the wire is `EXAMINE` and `BODY.PEEK`.
- **Nothing is lost by accident.** Move and trash never expunge before
  copying (proven for every server capability), and their first
  `UID EXPUNGE` names the same UIDs as their first `UID COPY` (proven).
  Permanent delete needs the exact confirmation word (proven: otherwise the
  plan is empty) and UIDPLUS; its first `UID EXPUNGE` names the same UIDs
  as its first `\Deleted` store, and with the confirmation those are the
  caller's UIDs (proven). Every command that changes mail is pinned too:
  move and trash do exactly one `UID MOVE`, or exactly one `UID COPY`, one
  `\Deleted` store and one `UID EXPUNGE`, and a confirmed delete exactly one
  `\Deleted` store and one `UID EXPUNGE`, all of the caller's UIDs, with no
  second or later change (proven). Expunging always renders as
  `UID EXPUNGE` (proven).
- **Stale UIDs never touch other messages.** Every change is pinned to the
  caller's UIDVALIDITY in the same IMAP session (proven for every plan): if
  the folder was recreated since the UIDs were read, the helper stops before
  any change. Reply and forward check it too before using the original, and
  expunging plans confirm UIDPLUS in their own session first.
- **Folder targets must be resolved.** Overrides, advertised roles and
  conventional names follow the per-role precedence above; ambiguous or
  unselectable targets never trigger a guessed mutation.
- **Labels are folders, and no tool deletes one.** On iCloud a label is a
  folder: `mail_label` is the proven move plan (so every move law holds for
  it), and moving the messages back to INBOX removes the label.
  `mail_create_folder` and `mail_rename_folder` only create, rename and
  (un)subscribe (proven: they change no message and expunge nothing). A
  rename subscribes the new name of each moved folder that was subscribed,
  then unsubscribes its old name; if only a subscription fails, the call
  succeeds with `subscribed: false` and a note not to retry. They refuse INBOX
  itself, the Drafts, Sent, Trash, Junk and Archive folders (by any usual name
  or configured override) and anything inside them, anything inside
  `To Delete` (which `mail_create_folder` may create once, at top level), and a
  rename that would move one of them with its parent. The parent of a new
  folder must already exist. IMAP has no way to delete a folder only when it
  is empty, and iCloud deletes a folder's messages with it, so delete folders
  in Apple Mail or iCloud.com.
- **Triage moves each message once, into a folder it may fill.**
  `mail_triage` files each message by at most one proven move, into
  `To Delete` or a category folder passed in, never into INBOX, a role
  folder or the folder it reads, and creates no folder (proven for every
  input).
- **An interrupted move says so.** A move (`mail_move`, `mail_trash`,
  `mail_label`) cut off when its COPY may have run fails with `partial: true`
  (the messages may be in both folders; `isError` over MCP, exit 1 on the
  CLI), never as an error that implies nothing changed. A refused or earlier
  failure is an ordinary error. A folder change cut off after CAPABILITY
  answered says the folder may have been created or renamed: list folders
  before retrying. A flag change (`mail_flag`, `mail_unflag`) that stops
  once a store was acknowledged or sent unanswered also fails with
  `partial: true`, listing the acknowledged changes and any that may have
  run unanswered; a retry is idempotent. One that stopped before any store
  could run, or whose search found none of the UIDs, is an ordinary error.
  A helper that never started (a relative `MAILBEND_TLS_HELPER`, or one that
  cannot be spawned) changed nothing, so it is an ordinary error; one that
  failed after starting or was killed by a signal may have, so these changes
  count it as cut off.
- **Attachments stay inside one directory.** Attachments are read only from
  `MAILBEND_ATTACH_DIR` (off without it), at most 32 and 25 MB in total, by
  `mailbend-attach`, a separate program with no credentials. It opens them
  beneath that directory with `openat2`, refusing any symlink or `..` that
  leaves it, and checks the opened file itself, so a prompt-injected message
  cannot make the agent mail out a file from outside that directory (such as
  `/proc/self/environ`), even by racing a path swap. Any file inside it can
  be sent, so use an empty, dedicated directory holding only files you are
  willing to mail. The reader refuses `/`, your home directory or any
  directory containing it, and a directory holding, or that is or lies
  inside, `.ssh`, `.gnupg`, `.aws`, `.config` or `.git`; it checks the file's type on an `O_PATH` descriptor
  first, so a device or FIFO is not opened, then reopens that probed inode
  for reading through `/proc/self/fd/<probe>` (not by walking the path
  again), so a file a concurrent local writer substitutes under the name is
  never opened. It refuses a file with a second hard link (whose other name
  may be elsewhere).
- **Downloads land only in one directory, as new files.**
  `mail_get_attachment` saves only in `MAILBEND_DOWNLOAD_DIR` (off without
  it, and refused in read-only mode), through the same credential-free
  `mailbend-attach`. The file name is the attachment's last path component
  without control or format characters (such as U+202E) and leading dots,
  so a message cannot name a path elsewhere or a hidden file. The file is
  written unnamed (`O_TMPFILE`) and named only once complete (`linkat`),
  which never replaces an existing file, so an interrupted save leaves
  nothing behind; it has mode 0600. Besides everything refused for
  `MAILBEND_ATTACH_DIR`, the helper refuses a download directory that is,
  contains or lies inside `MAILBEND_ATTACH_DIR` (so a saved file never
  becomes attachable), and one whose files may be run: anything under
  `~/.config`, `~/.local/bin` or `~/.local/share/applications`, any
  `autostart` or `systemd` directory, and any directory in `PATH`, compared
  by device and inode so a symlink alias is refused too. It also refuses
  when it cannot find your home directory to check. A saved file is
  still untrusted content: open it with care.
- **Jev sees only what you allow, and changes nothing.** `mail_classify`
  reads with `EXAMINE`, `BODY.PEEK` and `BODYSTRUCTURE`, so messages stay
  unread (proven: its plan contains no command that can change a mailbox).
  It sends header facts and attachment names, and message text only with
  `MAILBEND_TYPESAFE_CONTENT=body` and `MAILBEND_TYPESAFE_ZERO_RETENTION=1`
  (proven: a headers-mode request holds no text, and one about an outgoing
  message is the same whatever its body). Jev's gates can only block a
  send or delete, never change it (proven). Requests go only to
  `https://api.typesafe.ai/v1/systemone`, fixed in `mailbend-typesafe`,
  over verified TLS. That helper reads the key from
  `MAILBEND_TYPESAFE_KEY_FILE` and first re-executes itself with only its
  own settings (the key file, time budget, DoH, CA file and HTTPS proxy), so
  the key and the mail password are never in the same process; any copy of
  the key in an answer is redacted.
- **`MAILBEND_CA_FILE` replaces the trust store.** It exists for the local
  test server; whoever sets it decides which servers are trusted, so never
  set it in production. `scripts/mailbend` prints a warning when it is set.
- Commands run one at a time and stop at the first rejection; message
  contents are framed as IMAP literals, so a message cannot spoof a server
  reply.
- **What the proofs cover.** The laws are about the pure IMAP command plans,
  the SMTP envelope, Jev's requests and gates, and their rendering. Jev's
  gate laws cover the pure wrappers only; the IO that calls them is covered
  by the end-to-end tests and a CI check. The native helpers, TLS, MIME
  parsing, the agent's choices and the runtime configuration are covered by
  tests and review, not by proofs.

## How it works

```mermaid
flowchart LR
  agent["AI agent"] -- "MCP JSON-RPC on stdio" --> core
  subgraph core["Bend core: never reads the password"]
    direction TB
    tools["23 tools"] --> plans["command plans<br/>(safety laws proven)"]
    plans --> parse["render and parse<br/>IMAP, MIME, JSON"]
  end
  core -- "IMAP script or SMTP envelope on stdin" --> helper["mailbend-tls (Rust, rustls)<br/>verified TLS, login,<br/>lock-step commands"]
  helper -- "transcript on stdout" --> core
  helper <--> imap[("IMAP implicit TLS<br/>default imap.mail.me.com:993")]
  helper <--> smtp[("SMTP STARTTLS<br/>default smtp.mail.me.com:587")]
  secrets[["MAILBEND_APP_PASSWORD"]] -. "read by the helper only" .-> helper
  core -- "dir, path, byte budget" --> reader["mailbend-attach (Rust)<br/>no credentials, openat2"]
  reader -- "file bytes" --> core
  reader --> files[("MAILBEND_ATTACH_DIR")]
  core -- "count: state dir, limit, day" --> reader
  reader --> sends[("MAILBEND_STATE_DIR/sends")]
  core -- "save: name, file bytes" --> reader
  reader --> downloads[("MAILBEND_DOWNLOAD_DIR")]
  core -- "Jev request on stdin" --> jev["mailbend-typesafe (Rust)<br/>no mail password,<br/>fixed endpoint"]
  jev <--> typesafe[("TypeSafe HTTPS<br/>api.typesafe.ai:443")]
  key[["MAILBEND_TYPESAFE_KEY_FILE"]] -. "read by this helper only" .-> jev
```

Each tool call runs one or two short IMAP sessions (login, a few commands,
logout); nothing runs in the background. The detailed component diagram,
the read and change sequences, and a table of where each safety rule is
enforced are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#diagrams).

## Development

```sh
sh scripts/install-lean.sh   # once: the Lean that bend --verdict needs
bend PROOF.bend --verdict    # the safety laws, rechecked by the proven kernel: must print "ALL PROOFS CHECK"
sh tests/run-unit.sh         # Bend unit tests (JSON, codecs, IMAP, MIME, addresses)
bash tests/test-transport.sh # TLS helper against a local TLS server
python3 tests/test-cloud-network.py # local HTTPS DNS, address fallback, TLS/SNI
python3 tests/test-e2e.py    # every tool, CLI and MCP, against the local server
```

`tests/fake_mail_server.py` is a small IMAP/SMTP server over TLS with a
throwaway CA; it records every command and the mailbox state so the tests can
check what really happened. `tests/fake_typesafe.py` plays TypeSafe behind a
local proxy, checking each request's shape and size and recording it. Tool
schemas are generated by `tools/gen-schema.py`. See
[CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) for
contributor rules, and [SECURITY.md](SECURITY.md) to report a vulnerability
privately.

## Not yet

- Monitoring: a watcher with IDLE/polling, filters and a delivery ledger.
  `mail_get_new` already provides the checkpoint semantics it needs.

Known limits: each character of a fetched message is a separate value in
memory, so very large messages (the 16 MiB `mail_get` / 25 MiB forward caps)
use a lot of RAM; retrying a `mail_send` that timed out may send the message
twice. A small `max_bytes` can truncate a fetched message before its body,
leaving the returned body empty; increase the budget when needed.

## License

MIT; see [LICENSE](LICENSE).
