# Grok Bot / Cursor cloud setup and recovery

Keep MailBend's clone in `/workspace/MailBend` (or your durable home folder),
run `sh scripts/setup-cloud.sh`, and register `scripts/mailbend-cloud` as the
MCP command. This opts into fresh DNS-over-HTTPS (DoH) for each mail session
without editing `/etc/hosts`. After a computer rebuild, rerun setup from that
clone. The ordinary `scripts/mailbend` launcher still uses system DNS unless
you explicitly set `MAILBEND_DOH_URL`.

MailBend runs on Linux. These commands run **inside the cloud computer**,
including when your desktop app runs on Windows. Installing in the desktop,
IDE, a Cursor Cloud Agent VM, and a Grok Bot computer are separate operations.

## Install or restore a personal Grok Bot computer

On first install, clone into durable storage:

```sh
git clone https://github.com/albertc71/MailBend.git /workspace/MailBend
cd /workspace/MailBend
sh scripts/setup-cloud.sh
```

On every **computer update/rebuild**, Recover or Reset, wait for the computer
to finish reconnecting, then run:

```sh
cd /workspace/MailBend
sh scripts/setup-cloud.sh
MAILBEND_READ_ONLY=1 scripts/mailbend-cloud call mail_probe
```

Setup installs Debian/Ubuntu build and runtime dependencies, installs the
pinned Bend and Rust (Rust with a checksum-verified rustup, into `~/.cargo`)
if missing,
builds the three native helpers, checks the safety proofs, and compiles the
Bend core. Run it as the computer user; it uses noninteractive `sudo`
only for apt (or apt directly when already root). It needs working package
repositories and HTTPS downloads. It does not read mail credentials, modify
DNS, register services, or send mail. Repeated runs are safe; they rebuild
the current checkout. Do not run the whole script with `sudo`, which would
put Bend in root's home. If noninteractive sudo is unavailable, have the
environment owner install the packages listed in
[setup-cloud.sh](../scripts/setup-cloud.sh), then run
`sh scripts/install.sh --install-bend --install-rust` as your user.

Setup reuses Bend when it is already installed; otherwise it installs the
release tested in CI, pinned with its sha256 in
[install-bend.sh](../scripts/install-bend.sh) (Linux x64 only). For a
compiler-related rebuild failure, compare an existing Bend with that pinned
version. Setup does not downgrade an installed Bend.

Re-enable/restart the MCP server after setup so it uses the rebuilt binaries.
Its command must be `/workspace/MailBend/scripts/mailbend-cloud`. Ensure the
platform still supplies the two credential variables below. Setup does not
recreate secrets or client configuration. A successful `mail_probe` verifies
**IMAP**, not SMTP delivery. Do not test SMTP by sending real mail until you
intend to do so.

For a personal Bot instruction or routine, use:

```text
Before using MailBend, run:
sh /workspace/MailBend/scripts/setup-cloud.sh --check
If it fails, run sh /workspace/MailBend/scripts/setup-cloud.sh, then restart
the MailBend MCP server and run mail_probe with read-only mode enabled.
Keep credentials in the platform's secret environment; never print them.
```

`--check` performs a local, credential-free readiness check, including running
the TLS and TypeSafe helpers and the core to detect missing shared libraries. On failure it
names the component that needs rebuilding, without exposing process output.
It neither installs packages nor checks DNS, connectivity, authentication,
or source freshness. After updating MailBend source, run full setup again. This routine
is on-demand recovery, not a guaranteed boot hook. No personal post-rebuild
setup hook is documented in the sources checked on 2026-10-04.

## What survives an update

Cursor distinguishes a software-only update, which keeps installed apps,
from a computer update, which rebuilds the OS and removes installed apps and
packages. Saved files and logins are restored; recent unsaved data can be
lost during recovery. See [computer recovery](https://cursor.com/help/grok-bot/computer-recovery).

Cursor staff specifically identify the workspace and home folder as durable,
and system installs/services as disposable. Computers can update during idle
time and sleep between work, so a daemon or cron job is not a durable recovery
strategy. Keep the install recipe in the clone, and back up important source
independently. See the staff reply in
[Cloud computer wipes packages after rebuild](https://forum.cursor.com/t/cloud-computer-wipes-packages-after-rebuild/169847/2).

Treat `/etc/hosts`, apt packages, `/usr/local` installs and service
registrations as disposable. A surviving binary can also lose its shared
libraries. No setup command can restore unsaved/deleted workspace files;
recover the clone first if it is missing.

## Secrets and MCP registration

Set these in the environment's secret settings, never in the repo or a prompt:

```text
MAILBEND_EMAIL
MAILBEND_APP_PASSWORD
```

Start with `MAILBEND_READ_ONLY=1`, and consider `MAILBEND_DRAFTS_ONLY=1` once
writes are on. `MAILBEND_ATTACH_DIR` is optional; attachments are disabled
without it, and it must be a dedicated directory (never the home directory
or the clone). All options are in [.env.example](../.env.example).

For clients supporting Cursor's MCP configuration, use the actual absolute
path in the appropriate `.cursor/mcp.json` or MCP server registration:

```json
{
  "mcpServers": {
    "mailbend": {
      "command": "/workspace/MailBend/scripts/mailbend-cloud",
      "args": ["mcp"]
    }
  }
}
```

The process must inherit the secrets. If the client requires explicit
environment interpolation, Cursor supports entries such as:

```json
"env": {
  "MAILBEND_EMAIL": "${env:MAILBEND_EMAIL}",
  "MAILBEND_APP_PASSWORD": "${env:MAILBEND_APP_PASSWORD}"
}
```

Never substitute the actual values into that file.

Reload tools, then run `mail_probe` through the agent as well as the CLI.
Expect `"ok": true`, `"tls_verified": true`, authenticated capabilities and
discovered folders. Authentication errors and missing-secret errors are
separate from DNS errors.

### Optional: Jev

To use [Jev](JEV.md), keep the TypeSafe key in a file, not in a secret
variable: a variable would be in the environment of every MailBend process,
including the one that holds the mail password, and
`MAILBEND_TYPESAFE_API_KEY` fails every tool. Write the key once into
durable storage such as your home folder, without echoing it or putting it
on a command line. The snippet removes any old file first, so the new one is
created private:

```sh
(umask 077; rm -f "$HOME/.mailbend-typesafe-key"; stty -echo; head -n 1 > "$HOME/.mailbend-typesafe-key"; stty echo)   # paste the key, then Enter
```

Then set `MAILBEND_TYPESAFE=1` and `MAILBEND_TYPESAFE_KEY_FILE` to that
file's absolute path in the MCP server's environment, and restart it. The
other [Jev settings](JEV.md#settings) are optional; start with the default
`headers` content mode.

## Why DoH instead of hosts pins

On the reported Grok Bot computer, system DNS returned `198.18.0.1` for both
iCloud mail hosts. Cloudflare DoH returned public Apple addresses, and direct
IMAP TLS to those addresses with Apple's hostname succeeded. This is user
reported evidence from that computer, not a claim about every Cursor network.
The address is within IANA's non-global
[benchmarking range](https://www.iana.org/assignments/iana-ipv4-special-registry/).
An HTTP-aware fake-IP route can fail for raw IMAP/SMTP sockets; DNS success
alone does not prove the returned address is usable.

The native helper has its own small [RFC 8484](https://www.rfc-editor.org/rfc/rfc8484)
DNS-over-HTTPS client for A/AAAA lookup. Mail TLS and authentication use the
same verified rustls configuration as before the lookup. The cloud launcher
defaults to:

```text
MAILBEND_DOH_URL=https://cloudflare-dns.com/dns-query
```

The helper bootstraps that resolver using `1.1.1.1` and `1.0.0.1`, still
verifying `cloudflare-dns.com` over HTTPS, so a broken system lookup for the
resolver cannot defeat the default. Apple IPs are never hard-coded. Each
helper invocation resolves again, including later calls in an MCP process
that has stayed running through sleep/wake. The lookup succeeds when either
the A or the AAAA question returns addresses; the helper then tries each
address in turn (IPv4 first), giving each attempt an equal share of the time
left. No TTL cache or refresh daemon is maintained by MailBend. DNS and TCP share `MAILBEND_TIMEOUT_MS` (30 seconds by
default). A connected endpoint that fails TLS/protocol checks stops the call;
MailBend does not replay mail operations on another address.

| Approach | Main dependency and first failure |
| --- | --- |
| `/etc/hosts` pins from DoH | Root plus repeated refresh; stale on Apple IP churn and lost on rebuild. Useful as a temporary system-wide diagnostic. |
| Numeric connection override | A currently reachable address; becomes stale without manual refresh. Preserves the service's TLS name. |
| Native DoH (recommended here) | Reachable HTTPS resolver and outbound mail TCP; fails when either is blocked. No extra dependency. |
| Desktop routing | Connected desktop and traffic coverage; not a documented raw IMAP/SMTP route. |

The old `# mailbend-dns-pin` workaround is unnecessary with DoH. MailBend does
not remove or rewrite existing hosts entries. If retiring that workaround,
review and remove only its tagged lines yourself; preserve all unrelated
entries. Stale pins still affect other programs and MailBend's system-DNS mode.

## Resolver and network catches

- **Policy and blocked DoH:** opt in only where alternate DNS/direct mail
  egress is permitted. DoH cannot open blocked TCP ports: IMAP needs 993 and
  SMTP needs 587 plus STARTTLS. A network allowlist may need the resolver and
  mail destinations approved. There is no silent fallback to the broken
  system resolver when a DoH lookup fails.
- **Alternate resolvers:** set `MAILBEND_DOH_URL` to an approved HTTPS DNS
  wire-format endpoint (RFC 8484, POST). DoH JSON APIs are not compatible.
  A custom resolver's hostname needs working system DNS for bootstrap;
  alternatively use a numeric HTTPS URL only if its certificate covers that
  IP. The fixed bootstrap applies only to `cloudflare-dns.com:443`.
- **Privacy and trust:** the resolver learns queried hostnames, not passwords
  or mail. Both resolver HTTPS and mail TLS verify peers and names. Normal
  system CA trust applies, including any administrator-installed CA. There
  is no certificate/fingerprint pinning and no verification bypass.
  `MAILBEND_CA_FILE` replaces trust for both paths and is intended for local
  tests; do not use it to work around an unexpected certificate failure.
- **IPv6:** mail resolution includes A/AAAA and connection fallback. The
  default resolver bootstrap requires IPv4 connectivity; an IPv6-only
  environment needs a reachable approved resolver URL/bootstrap. Bad IPv6
  routing can consume part of the connection budget.
- **DNS timeouts:** system DNS lookups (including a custom resolver's
  bootstrap) run on their own thread and are abandoned at the deadline, so
  `MAILBEND_TIMEOUT_MS` bounds every lookup, proxy reply and handshake.
- **Proxies:** raw mail TCP never uses a proxy. The DoH requests use an
  `http://` proxy from `https_proxy`, `HTTPS_PROXY`, `all_proxy` or
  `ALL_PROXY` (through HTTP `CONNECT`, with optional Basic credentials in the
  URL) unless `no_proxy`/`NO_PROXY` lists the resolver. Other proxy schemes,
  such as `socks5://` or `https://`, are not supported: the helper then exits
  with a usage error rather than bypassing the proxy. DNS changes cannot fix a network that
  permits only proxied HTTP(S).
- **Sleep and retries:** reconnecting resolves fresh addresses. Sleeping
  computers do not provide an always-on mail watcher. If sending mail times
  out after DATA, delivery may already have happened; never automatically
  replay `mail_send`, reply, forward, or destructive operations.

For an emergency, set `MAILBEND_IMAP_CONNECT_IP` and/or
`MAILBEND_SMTP_CONNECT_IP` to one freshly resolved bare IPv4/IPv6 address
each. Keep `MAILBEND_IMAP_HOST=imap.mail.me.com` and
`MAILBEND_SMTP_HOST=smtp.mail.me.com`: these names drive SNI and verification.
Changing `*_HOST` to an Apple IP instead would verify the certificate against
that IP and normally fail. The overrides take precedence over DoH and need
manual refresh; unset them when returning to DoH.

To compare system DNS without editing configuration:

```sh
getent ahosts imap.mail.me.com
getent ahosts smtp.mail.me.com
MAILBEND_DOH_URL= MAILBEND_READ_ONLY=1 scripts/mailbend-cloud call mail_probe
MAILBEND_READ_ONLY=1 scripts/mailbend-cloud call mail_probe
```

Unset connection IP overrides first if you want this comparison to test DNS.
`MAILBEND_DOH_URL=` explicitly selects system DNS even in the cloud launcher.
Leave that variable absent, rather than empty, for the launcher's DoH default.

### Route traffic through the desktop

The setting is under Settings > Computer > Network > Route traffic through
this computer. Current [Cursor docs](https://cursor.com/docs/grok-bot/settings)
describe web traffic. A [Cursor staff explanation dated 2026-09-18](https://forum.cursor.com/t/grok-bot-stuck-on-reconnecting-to-your-computer-fully-unusable-malformed-listagents-gateway-response/170736/28)
specifically says browser traffic is routed while terminal commands still
egress from the cloud, and the route requires the desktop app to remain open
and connected. Do not rely on this setting to repair MailBend's native TCP
sockets. Test actual IMAP and SMTP reachability if platform behaviour changes.

## Enterprise Team Setup and Cursor Cloud Agents

Grok Bot **Team Setup is Enterprise-only**, including on self-serve Teams.
Its scripts run at computer startup and approximately daily while running.
Entries run sequentially; a successful Check Script skips Setup, and the
check runs again after setup. Failed scripts are retried later and do not
prevent computer startup. See [Team Setup mechanics](https://cursor.com/docs/grok-bot/private-networks).

An admin-managed entry can use the following (adjust clone location and
revision policy; setup/check need no mail credentials):

```sh
# Setup Script
set -eu
if [ ! -d /workspace/MailBend/.git ]; then
  git clone https://github.com/albertc71/MailBend.git /workspace/MailBend
fi
sh /workspace/MailBend/scripts/setup-cloud.sh
```

```sh
# Check Script
sh /workspace/MailBend/scripts/setup-cloud.sh --check
```

The example restores the installed checkout; it does not pull a new revision
or silently update source. Manage source rollout separately, and rerun Setup
when changing revisions. Team Setup does not register an MCP server or make
Team Secrets a permanent Bot environment. Configure those separately.

Cursor **Cloud Agents** have a different setup mechanism:
`.cursor/environment.json` can set `"install": "sh scripts/setup-cloud.sh"`
when MailBend is the environment repository. Install runs when preparing a
Build; startup commands run when the agent starts. Register the cloud
launcher for runtime DoH, since exported shell variables are not captured in
a Build. See [Cloud Environment Setup](https://cursor.com/docs/cloud-agent/setup).
That file is not a documented personal Grok Bot post-rebuild hook.

## Live iCloud record

These results describe the reported account and computer, not every
provider or cloud network.

**Earlier helpers.** A user-reported run on Grok Bot, with
`MAILBEND_READ_ONLY=0` and the helpers that preceded the current Rust ones,
found TLS verification, IDLE and UIDPLUS available and MOVE absent. The
discovered folders were `INBOX`, `Archive`, `Junk`, `Drafts`, `Sent` and
`Deleted`; Trash and Sent advertised special-use roles, Drafts did not.
Probe, folder listing, search, get, new mail, flag changes, move, trash,
permanent deletion of a disposable message, sending to self with an
attachment, reply-send and forward-send passed. `mail_save_draft`, and
`mail_reply` and `mail_forward` with `as_draft: true`, each created a draft
in the intended Drafts mailbox without sending it.

**Current Rust helpers.** On 2026-10-05, `mail_probe` passed with system
DNS, with DoH and with `MAILBEND_IMAP_CONNECT_IP`, and an SMTP send to self
passed. On 2026-10-06 the whole [checklist](#live-icloud-checklist) below
was run with the Rust `mailbend-tls`, `mailbend-attach` and
`mailbend-typesafe` (Jev `jev-1.13.0`), on disposable messages sent to the
account's own address and on test folders:

| Item | Result | Observed |
| --- | --- | --- |
| 1. TLS helper | pass | `tls_verified: true` with system DNS, DoH and `MAILBEND_IMAP_CONNECT_IP`; SMTP STARTTLS send to self accepted. IPv6 not tested: the network had no IPv6 route and no AAAA answer for `imap.mail.me.com`. CAPABILITY has IDLE, UIDPLUS, CONDSTORE, QRESYNC, ESEARCH and LIST-STATUS, but neither MOVE nor SPECIAL-USE; LIST still marks `Sent Messages` `\Sent` and `Deleted Messages` `\Trash`. Drafts, Junk and Archive resolve by name |
| 2. Delimiter | pass | `/`; INBOX is listed with `\Noinferiors` |
| 3. Create | pass | `MailBend Test` and `MailBend Test/Nested` created and subscribed. iCloud also accepted `INBOX/MailBend Test` in spite of `\Noinferiors` (MailBend allows children of INBOX by design). Visibility on iCloud.com and in Apple Mail: left to the user |
| 4. Rename | pass | `MailBend Test` renamed with its subfolder and renamed back, with subscriptions following. Renaming a role folder, or the parent of one (`MAILBEND_ARCHIVE_FOLDER=MailBend Test/Nested`), was refused before any change, as was creating inside a role folder or `To Delete` |
| 5. Thread search | pass | `UID SEARCH HEADER Message-ID` finds the message. A message marked `\Deleted` and not expunged **is** returned by `mail_search` (with `\Deleted` in its flags), by the header search and by `mail_get_thread` |
| 6. Labels | pass | `UID COPY + UID EXPUNGE`: one copy in the label folder, none left in INBOX; `mail_move` back gave one copy in INBOX (new UID) and none in the label |
| 7. Flag colours | pass (server) | PERMANENTFLAGS includes `$MailFlagBit0`–`2` and `\*`; `colour_kept: true` for all seven colours. Bits: red none, orange 0, yellow 1, green 0+1, blue 2, purple 0+2, grey 1+2; `mail_unflag` cleared `\Flagged` and every bit. Colours shown in Apple Mail: left to the user |
| 8. Sent copies | iCloud does not file | No Sent copy of either SMTP send after several minutes (subject and Message-ID searches). With `MAILBEND_SAVE_SENT=1`, a reply was appended once to `Sent Messages`, marked `\Seen` (`sent_copy: "saved to Sent Messages"`) |
| 9. Downloads | pass | A 1024-byte attachment holding every byte value came back byte for byte (same sha256), saved with mode 600; the message stayed unread |
| 10. Threads | pass | From the original, the delivered reply and the reply's Sent copy, `mail_get_thread` searched INBOX and `Sent Messages` and returned the same three messages |
| 11. Jev, headers | pass | `mail_classify` on 20 and on 50 INBOX messages: all `checked`, flags unchanged, no request refused. A reply with a stranger in Bcc and a send of personal data to a stranger were blocked (`recipients: high`); a send to self proceeded. A permanent delete of a junk test message proceeded (every keep answer low). With TypeSafe unreachable (proxy on a closed port) or the key rejected (HTTP 401), a send was blocked and `mail_search` returned its messages `unchecked`. `mail_triage` filed one test message into the only folder Jev chose with high confidence (0.79), left the others (Jev's 0.56 for another folder reads as mid), and moved nothing into `To Delete` |
| 11. Jev, body | pass, partial | Refused without `MAILBEND_TYPESAFE_ZERO_RETENTION=1`. With it, the fresh test messages were `keep` with the veto "less than 30 days old" (and "has attachments"), so nothing went to `To Delete`; that move could not be shown with fresh mail. Body mode was used only on test messages, so a large body-mode batch is not tested |
| 11. Request size | recorded | Headers-mode requests of 18 messages were about 58,200–58,450 bytes for 16,814–16,926 input tokens (about 3.45 bytes per token) |
| 12. Send limit | pass | With `MAILBEND_MAX_SENDS_PER_DAY=2`, the third send was refused with nothing sent. After trashing the delivered copies and the only Sent copy (the reply's; iCloud kept none of the two counted sends), a send was still refused |

The test folders `MailBend Test`, `MailBend Test/Nested`,
`MailBend live check` (created as `INBOX/MailBend Test`) and `To Delete`
remain, because no MailBend tool deletes a folder. Every test message was
permanently deleted.

For another provider or localised/nested folders, follow the
[server and folder configuration](../README.md#configure). Inspect
`mail_probe` for resolved roles and `mail_list_folders` for actual advertised
metadata; a folder resolved by name or override can still have
`special_use: null`.

With read-only mode enabled, run `mail_probe`, `mail_list_folders`,
`mail_search`, `mail_get_new`, and `mail_get` on a known unread message.
Confirm in Mail.app that it remains unread and record MOVE, UIDPLUS,
SPECIAL-USE, IDLE and discovered folder roles. Only then use a disposable
test message for intentional move/trash/delete, draft and send checks. A
successful probe alone does not establish every iCloud operation's behaviour.

A small `max_bytes` can truncate a fetched message before its body and return
an empty body; increase the budget when needed. SMTP delivery does not
guarantee a Sent copy: MailBend appends one only with `MAILBEND_SAVE_SENT=1`,
after checking that the server did not file the message itself. iCloud does
not file SMTP-sent mail on its own (item 8 above), so set
`MAILBEND_SAVE_SENT=1` on iCloud to keep a Sent copy.

## Live iCloud checklist

Run this list on a real account after a change to a helper or to how a
feature talks to the server; the last run is in the
[record](#live-icloud-record) above, with what it left for a person to
check. Use disposable messages and folders, start with
`MAILBEND_READ_ONLY=1` where an item only reads, and record pass or fail
with the value observed.

1. **TLS helper**: `mail_probe` (IMAP on `imap.mail.me.com:993`), a send to
   yourself (SMTP STARTTLS on 587), the same with `MAILBEND_DOH_URL` set and
   with `MAILBEND_IMAP_CONNECT_IP`; IPv6 if the network has it.
2. **Delimiter**: the hierarchy delimiter `mail_list_folders` reports.
3. **Create**: `mail_create_folder` at top level and nested; the folders
   show on iCloud.com and in Apple Mail; whether a folder under INBOX is
   accepted or refused.
4. **Rename**: `mail_rename_folder` of a folder with a subfolder; renaming
   the parent of a role folder is refused.
5. **Thread search**: `UID SEARCH HEADER Message-ID` finds a known message;
   whether searches return messages marked `\Deleted` but not expunged.
6. **Labels**: `mail_label` moves a message into a label folder (iCloud has
   no MOVE, so through the copy fallback): it appears there once, is gone
   from INBOX, and no duplicate remains; `mail_move` back to INBOX removes
   the label.
7. **Flag colours**: `mail_flag` with each colour shows that colour in Apple
   Mail; whether iCloud keeps `$MailFlagBit*` (PERMANENTFLAGS `\*`).
8. **Sent copies**: after a send to yourself, whether iCloud filed the
   message in Sent by itself; this decides the recommended
   `MAILBEND_SAVE_SENT` value.
9. **Downloads**: `mail_get_attachment` saves a binary attachment
   byte for byte.
10. **Threads**: `mail_get_thread` across INBOX and Sent.
11. **Jev**:
    - headers mode: `mail_classify` on 20 messages; a send to an obviously
      wrong recipient is blocked; a delete of junk proceeds; `mail_triage`
      files messages into confident existing folders and never into
      `To Delete`;
    - TypeSafe unreachable: a send is blocked, and a search continues with
      each message `unchecked`;
    - body mode: a disposable message goes to `To Delete`, and a large batch
      is not refused by TypeSafe (a sign the size estimate fits, not a
      proof).
12. **Send limit**: with `MAILBEND_MAX_SENDS_PER_DAY=2` the third send is
    refused, and trashing the Sent copies does not reset the count.
