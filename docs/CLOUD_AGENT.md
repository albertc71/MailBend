# Grok Bot / Cursor cloud setup and recovery

Keep MailBend's clone in `/workspace/MailBend` (or your durable home folder),
run `sh scripts/setup-cloud.sh`, and register `scripts/mailbend-cloud` as the
MCP command. This opts into fresh DNS-over-HTTPS (DoH) for each mail session
without editing `/etc/hosts`. After a computer rebuild, rerun setup from that
clone. The ordinary `scripts/mailbend` launcher still uses system DNS unless
you explicitly set `MAILBEND_DOH_URL`.

MailBend is Linux-first. These commands run **inside the cloud computer**,
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

Setup installs Debian/Ubuntu build and runtime dependencies, installs Bend if
missing, builds both native helpers, checks the safety proofs, and compiles
the Bend core. Run it as the computer user; it uses noninteractive `sudo`
only for apt (or apt directly when already root). It needs working package
repositories and HTTPS downloads. It does not read mail credentials, modify
DNS, register services, or send mail. Repeated runs are safe; they rebuild
the current checkout. Do not run the whole script with `sudo`, which would
put Bend in root's home. If noninteractive sudo is unavailable, have the
environment owner install the packages listed in
[setup-cloud.sh](../scripts/setup-cloud.sh), then run
`sh scripts/install.sh --install-bend` as your user.

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
the TLS helper and core to detect missing shared libraries. On failure it
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

Never substitute the actual values into that file. Reload tools, then run
`mail_probe` through the agent as well as the CLI. Expect `"ok": true`,
`"tls_verified": true`, authenticated capabilities and discovered folders.
Authentication errors and missing-secret errors are separate from DNS errors.

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
sockets. Test actual IMAP and SMTP reachability if platform behavior changes.

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

## Live compatibility and draft retest

The user-reported iCloud run on Grok Bot used `MAILBEND_READ_ONLY=0`.
TLS verification and IDLE were available, MOVE was absent, and UIDPLUS was
available. The discovered folders were `INBOX`, `Archive`, `Junk`, `Drafts`,
`Sent` and `Deleted`. Trash and Sent advertised special-use
roles; the existing Drafts mailbox did not advertise its role.

Probe, folder listing, search, get, new mail, flag changes, move, trash,
permanent deletion of a disposable message, sending to self with an
attachment, reply-send and forward-send passed. Compose-draft, reply-as-draft
and forward-as-draft also passed after the per-role repair. These results describe
that reported account and computer, rather than every provider or cloud network.

For another provider or localized/nested folders, follow the
[server and folder configuration](../README.md#configure). Inspect
`mail_probe` for resolved roles and `mail_list_folders` for actual advertised
metadata; a folder resolved by name or override can still have
`special_use: null`.

With read-only mode enabled, run `mail_probe`, `mail_list_folders`,
`mail_search`, `mail_get_new`, and `mail_get` on a known unread message.
Confirm in Mail.app that it remains unread and record MOVE, UIDPLUS,
SPECIAL-USE, IDLE and discovered folder roles. Only then use a disposable
test message for intentional move/trash/delete, draft and send checks. A
successful probe alone does not establish every iCloud operation's behavior.

The folder-role repair was live-tested on iCloud after the merge. `mail_probe`
resolved Drafts, and `mail_save_draft`, `mail_reply` with `as_draft: true`, and
`mail_forward` with `as_draft: true` each created a draft in the intended
Drafts mailbox without sending it.

A small `max_bytes` can truncate a fetched message before its body and return
an empty body; increase the budget when needed. SMTP delivery does not
guarantee a Sent copy, and MailBend does not append one automatically. Those
limits are unchanged by folder-role resolution.
