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
| `mail_mark_read` / `mail_mark_unread` | Add / remove `\Seen` | flags |
| `mail_move` | Move to another folder | yes |
| `mail_trash` | Move to the resolved Trash folder (recoverable) | yes |
| `mail_delete` | **Permanent** delete; needs `"confirm": "permanently-delete"` and the folder's `uidvalidity` | yes |
| `mail_save_draft` | Compose into Drafts (with attachments) | yes |
| `mail_send` | Compose and send over SMTP (to/cc/bcc, attachments) | sends |
| `mail_reply` | Reply or reply-all, threaded; or save as draft (needs `uidvalidity`) | sends |
| `mail_forward` | Forward with the original attached; or save as draft (needs `uidvalidity`) | sends |

Read tools open folders with `EXAMINE` and fetch with `BODY.PEEK`, so reading
never marks mail as read. Tools that change messages take the `uidvalidity`
that came with the UIDs and report which UIDs were `changed` or `missing`. The safety rules are laws checked by the Bend
compiler (see [Safety](#safety)).

## Install (Linux)

Needs a C compiler, OpenSSL and libcurl 7.76+ headers, and Bend 2 (clang 14+
to compile the core; without clang the core runs through `bend` with a slower start).

```sh
sudo apt-get install -y build-essential libssl-dev libcurl4-openssl-dev clang ca-certificates curl
git clone https://github.com/albertc71/MailBend.git && cd MailBend
scripts/install.sh --install-bend
```

`scripts/install.sh` builds `bin/mailbend-tls` and `bin/mailbend-attach`, checks the safety proofs with
`bend PROOF.bend`, and compiles the core to `bin/mailbend-core`. With
`--install-bend` and no `bend` on the `PATH`, it first runs
`scripts/install-bend.sh`, which installs the Bend release tested in CI to
`~/.bend` after checking the archive's sha256. That pinned release is Linux
x64 only; elsewhere, install Bend 2.0.32 yourself and run
`scripts/install.sh`. An already installed Bend is reused as is.

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
`MAILBEND_TIMEOUT_MS`, and `MAILBEND_TLS_HELPER` / `MAILBEND_ATTACH_HELPER`.
The two switches take `1`/`true` or `0`/`false`/empty; any other value is a
configuration error that fails every tool, rather than silently meaning off.

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
that require that role; MailBend never creates a mailbox or guesses a path.

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
- **Attachments stay inside one directory.** Attachments are read only from
  `MAILBEND_ATTACH_DIR` (off without it), at most 32 and 25 MB in total, by
  `mailbend-attach`, a separate program with no credentials. It opens them
  beneath that directory with `openat2`, refusing any symlink or `..` that
  leaves it, and checks the opened file itself, so a prompt-injected message
  cannot make the agent mail out a file from outside that directory (such as
  `/proc/self/environ`), even by racing a path swap. Any file inside it can
  be sent, so use an empty, dedicated directory holding only files you are
  willing to mail. The reader refuses `/`, your home directory or any
  directory containing it, and a directory holding `.ssh`, `.gnupg`, `.aws`,
  `.config` or `.git`; it checks the file's type before opening it, so a
  device or FIFO is not opened (one a concurrent local writer substitutes
  just before the read open may be opened, but is then refused), and it
  refuses a file with a second hard link (whose other name may be
  elsewhere).
- **`MAILBEND_CA_FILE` replaces the trust store.** It exists for the local
  test server; whoever sets it decides which servers are trusted, so never
  set it in production. `scripts/mailbend` prints a warning when it is set.
- Commands run one at a time and stop at the first rejection; message
  contents are framed as IMAP literals, so a message cannot spoof a server
  reply.
- **What the proofs cover.** The laws are about the pure IMAP command plans
  and their rendering. The native helpers, TLS, MIME parsing, the agent's
  choices and the runtime configuration are covered by tests and review,
  not by proofs.

## How it works

```mermaid
flowchart LR
  agent["AI agent"] -- "MCP JSON-RPC on stdio" --> core
  subgraph core["Bend core: never reads the password"]
    direction TB
    tools["14 tools"] --> plans["command plans<br/>(safety laws proven)"]
    plans --> parse["render and parse<br/>IMAP, MIME, JSON"]
  end
  core -- "IMAP script or SMTP envelope on stdin" --> helper["mailbend-tls (C, OpenSSL)<br/>verified TLS, login,<br/>lock-step commands"]
  helper -- "transcript on stdout" --> core
  helper <--> imap[("IMAP implicit TLS<br/>default imap.mail.me.com:993")]
  helper <--> smtp[("SMTP STARTTLS<br/>default smtp.mail.me.com:587")]
  secrets[["MAILBEND_APP_PASSWORD"]] -. "read by the helper only" .-> helper
  core -- "dir, path, byte budget" --> reader["mailbend-attach (C)<br/>no credentials, openat2"]
  reader -- "file bytes" --> core
  reader --> files[("MAILBEND_ATTACH_DIR")]
```

Each tool call runs one or two short IMAP sessions (login, a few commands,
logout); nothing runs in the background. The detailed component diagram,
the read and change sequences, and a table of where each safety rule is
enforced are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#diagrams).

## Development

```sh
bend PROOF.bend              # the safety laws: must print "ALL PROOFS CHECK"
sh tests/run-unit.sh         # Bend unit tests (JSON, codecs, IMAP, MIME, addresses)
bash tests/test-transport.sh # TLS helper against a local TLS server
python3 tests/test-cloud-network.py # local HTTPS DNS, address fallback, TLS/SNI
python3 tests/test-e2e.py    # every tool, CLI and MCP, against the local server
```

`tests/fake_mail_server.py` is a small IMAP/SMTP server over TLS with a
throwaway CA; it records every command and the mailbox state so the tests can
check what really happened. Tool schemas are generated by
`tools/gen-schema.py`. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[AGENTS.md](AGENTS.md) for contributor rules, and [SECURITY.md](SECURITY.md)
to report a vulnerability privately.

## Not yet

- A recipient allowlist for sending. Until then, `MAILBEND_DRAFTS_ONLY=1`
  keeps a person in front of every outgoing message.
- Monitoring: a watcher with IDLE/polling, filters and a delivery ledger.
  `mail_get_new` already provides the checkpoint semantics it needs.
- Folder create/delete, and copying sent mail into Sent (check first whether
  the provider already files SMTP-sent mail there). SMTP delivery may succeed
  without a Sent copy; resolving the Sent role does not append one.

Known limits: each character of a fetched message is a separate value in
memory, so very large messages (the 16 MiB `mail_get` / 25 MiB forward caps)
use a lot of RAM; retrying a `mail_send` that timed out may send the message
twice. A small `max_bytes` can truncate a fetched message before its body,
leaving the returned body empty; increase the budget when needed.

## License

MIT; see [LICENSE](LICENSE).
