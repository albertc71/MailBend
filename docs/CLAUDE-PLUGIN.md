# Install the MailBend plugin in Claude Code

The optional plugin connects an existing MailBend installation, loads the
existing [mail skill](../skills/mailbend/SKILL.md), and adds the
[send/delete prompt](CLAUDE-HOOK.md). It does not build MailBend, collect a
password, grant tool permissions, or probe your account automatically.
Plugin version `0.1.1` is packaging metadata, not a MailBend binary release.

Use Claude Code **2.1.295 or later** on a supported
[Linux installation](../README.md#install-linux). The hook uses exec-form
arguments and `onFailure: "block"`, supported from that Claude Code version.
The manifest cannot enforce this minimum. On older versions, a hook that
fails to start or times out may not block the tool call, so a send or delete
may proceed without the hook's prompt. Check `claude --version` first.
Other clients can use the [MCP quickstarts](MCP_CLIENTS.md).

## Prepare the installation

1. [Build MailBend](../README.md#install-linux). Keep the installation outside
   Claude's plugin cache. Its `scripts/mailbend` launcher and `bin/` binaries
   must remain together.
2. [Create a private password file](MCP_CLIENTS.md#create-a-private-password-file).
   Use an absolute path outside the checkout. The file must belong to your
   Linux user, have mode `0600`, and have no symlink in its path.
3. [Run the offline setup check](MCP_CLIENTS.md#check-the-local-installation).
   This does not check your mail login.
4. Before starting Claude Code, unset conflicting credential variables:

   ```sh
   unset MAILBEND_APP_PASSWORD MAILBEND_TYPESAFE_API_KEY
   ```

The plugin passes only the password-file path and overrides
`MAILBEND_APP_PASSWORD` with an empty string in the MCP server environment.
The TLS helper treats that empty value as unset and reads the file. Unsetting
it before starting Claude also keeps an inherited password out of Claude and
its hook processes. The plugin cannot unset `MAILBEND_TYPESAFE_API_KEY`:
MailBend refuses that variable even when it is empty, so it must be unset
before starting Claude.

Review the environment that starts Claude. The plugin deliberately inherits
provider endpoints, trust-store overrides, proxies, helper paths, and other
MailBend settings. Remove overrides you do not intend to keep. For a provider
other than iCloud, export the endpoint settings from
[`.env.example`](../.env.example) before starting Claude. Neither the plugin nor
the launcher loads `.env`.

## Install and configure the plugin

Use the repository marketplace rather than a built checkout as the plugin
directory:

```sh
claude plugin marketplace add albertc71/MailBend
claude plugin install mailbend@mailbend --scope user
```

In Claude Code's `/plugin` menu, configure the installed `mailbend` plugin:

- `mailbend_dir`: the absolute installation root containing `scripts/` and `bin/`.
- `email`: your primary account login address, not an alias.
- `password_file`: the absolute path to your private password file, never its contents.
- `read_only`: keep the default `1`.
- `drafts_only`: keep the default `1`.

The plugin sets `MAILBEND_LOGIN` to empty so the primary email address is the
login. It forces `MAILBEND_TYPESAFE=0`, overriding an inherited
`MAILBEND_TYPESAFE=1`. Jev's send and permanent-delete vetoes are then absent,
and `mail_classify` and `mail_triage` are unavailable. There is no plugin option
to enable Jev; use a [manual MCP registration](MCP_CLIENTS.md) if you need it.
Inherited `MAILBEND_TYPESAFE_CONTENT`, `MAILBEND_TYPESAFE_ZERO_RETENTION` and
`MAILBEND_TYPESAFE_IMAGES` are still validated while Jev is off, so an invalid
value in one of those settings fails every tool closed.

The client still sends requested mail content to its own model. Read-only
mode is not a privacy boundary. Review Claude's data policy before connecting
a real mailbox.

Restart Claude Code after configuration changes. Check `/mcp` for the plugin's
MailBend server, `/skills` for `mailbend:mailbend`, and `/hooks` for its
`PreToolUse` hook. Do not also register the same account through `claude mcp add`
or copy a second version of the skill or hook.

## Verify the connection and prompt

Ask Claude to call `mail_probe` only when you are ready to connect to the
account. Confirm that only read tools are listed. The plugin's tool names use
the prefix `mcp__plugin_mailbend_mailbend__`.

Check the installed hook command offline with synthetic arguments:

```sh
printf '%s\n' '{"hook_event_name":"PreToolUse","tool_name":"mcp__plugin_mailbend_mailbend__mail_send","tool_input":{"to":["recipient@example.test"],"subject":"Example"}}' |
  /absolute/path/to/MailBend/scripts/mailbend hook claude-pretooluse
```

Replace the installation path first. The output must contain
`permissionDecision: "ask"`. A dry run with the JSON Boolean `"dry_run": true`
produces no output. See the [hook decision contract](CLAUDE-HOOK.md#decision-contract)
for the existing send, delete, and draft rules.

Verify the prompt in your installed Claude version with synthetic arguments
and cancel it before allowing any tool call. Command output and manifest
validation do not prove that the client displays a prompt. MailBend has not
verified the plugin's interactive configuration, prompt display, or behavior
under `bypassPermissions`. Do not rely on this hook in that mode.

The hook is optional client-side prompting, enabled with the plugin. You can
disable it through Claude's hook controls. It cannot attest human consent or
protect shell calls, other clients, or unmatched servers. The plugin requests
`onFailure: "block"` with a 30-second timeout for hook execution failures.
Disabled hooks and client permission behavior remain outside that guarantee.
Keep MailBend's server-side restrictions in place.

## Enable writes deliberately

1. To permit mailbox changes and drafts, set `read_only` to `0` in the plugin's
   configuration. Keep `drafts_only=1` to continue refusing sends. This setting
   permits other writes, including deletion, folder creation and renaming,
   and `mail_get_attachment` writing files to local disk. It is not a
   drafts-only mailbox.
2. To permit sends, also set `drafts_only` to `0`. Review the
   [send safeguards](../README.md#safety) and obtain human approval for each
   send or delete. Neither a tool argument nor a client prompt proves consent.

Restart Claude after either change. Leave both settings at `1` unless the
task needs broader access. The plugin adds no second copy of MailBend's policy.

## Test a local checkout

For plugin development, `claude --plugin-dir /absolute/path/to/MailBend` loads
the repository root. Claude adds a plugin's `bin/` directory to its Bash tool
PATH, including gitignored binaries in a local checkout. Prefer the marketplace
copy, which excludes those untracked build artifacts. In either mode,
`mailbend_dir` must point to the separate installation you intend to execute.

The [contributor checks](../CONTRIBUTING.md#checks) guard manifest declarations
and exercise a Python substitution/environment-merge harness. Its literal
path tests check Python's argv handling, not Claude's. The runtime smoke runs
the real MailBend launcher and hook against synthetic fixtures; it does not
run a Claude agent or verify client loading. The upstream
[plugin reference](https://code.claude.com/docs/en/plugins-reference),
[marketplace reference](https://code.claude.com/docs/en/plugins/marketplace-reference),
and [command-hook fields](https://code.claude.com/docs/en/hooks#command-hook-fields)
define the client contract.
