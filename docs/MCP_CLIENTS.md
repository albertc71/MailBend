# Connect MailBend to an MCP client

Install MailBend with the [build instructions](../README.md#install-linux) first.
The examples below run MailBend on Linux through `scripts/mailbend mcp`.
Do not register `bin/mailbend-core` directly. The launcher handles socket-backed
stdin through `mailbend-stdio`.

Replace `/home/you/MailBend`, `/home/you/.config/mailbend`, and
`you@example.test` with your checkout, private configuration directory, and
account address. Keep the paths absolute. JSON does not expand `~` or `$HOME`.
The client must run as the Linux user who owns the password file.

These examples start in read-only mode with TypeSafe off. They cannot send,
move, delete, save drafts, or download attachments. Read-only mode still allows
mail content to reach the agent's model when you request a read. Review the
client's data policy before connecting a real mailbox.

## Create a private password file

Use the provider's app-specific password where required. Keep the file outside
the checkout and outside attachment directories. The TLS helper requires a
regular file owned by your user, mode `0600`, with no symlink in any path
component. Do not paste the password into a chat, shell argument, or client
configuration.

Run this in an interactive Linux terminal. The prompt does not echo input, and
the command refuses to replace an existing password file.

```sh
python3 - <<'PY'
import getpass
import os
from pathlib import Path
import warnings

directory = Path.home() / '.config' / 'mailbend'
directory.mkdir(mode=0o700, parents=True, exist_ok=True)
with warnings.catch_warnings():
	warnings.simplefilter('error', getpass.GetPassWarning)
	password = getpass.getpass('Mail app password: ')
if not password:
	raise SystemExit('The password must not be empty')
fd = os.open(directory / 'personal.password', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as output:
	output.write(password + '\n')
PY
```

Unset `MAILBEND_APP_PASSWORD` in the environment that starts your client.
MailBend refuses to use both password sources. Remove other inherited
`MAILBEND_*` overrides unless you intend to keep them. Never set
`MAILBEND_TYPESAFE_API_KEY`, even to an empty value.

For a provider other than iCloud, add the endpoint settings from
[`.env.example`](../.env.example) to the same client's `env` block.
The launcher does not load `.env.example` or a `.env` file.

## Check the local installation

Run redacted setup checks without connecting to IMAP, SMTP, or TypeSafe:

```sh
MAILBEND_EMAIL=you@example.test \
MAILBEND_PASSWORD_FILE=/home/you/.config/mailbend/personal.password \
MAILBEND_READ_ONLY=1 MAILBEND_TYPESAFE=0 \
/home/you/MailBend/scripts/mailbend diagnose
```

Resolve reported setup errors before starting the client. `diagnose` without
flags does not test login or delivery. Network checks require an explicit
`--imap` or `--smtp` flag. See the
[setup check overview](../README.md#why-mailbend).

## Claude Code

Register a personal stdio server. The `--transport` option separates the
environment pairs from the server name because `--env` accepts multiple pairs.
See [Claude Code's MCP configuration](https://code.claude.com/docs/en/mcp).

```sh
claude mcp add --scope user \
	--env MAILBEND_EMAIL=you@example.test \
	--env MAILBEND_PASSWORD_FILE=/home/you/.config/mailbend/personal.password \
	--env MAILBEND_READ_ONLY=1 --env MAILBEND_TYPESAFE=0 \
	--transport stdio mailbend -- /home/you/MailBend/scripts/mailbend mcp
```

Start Claude Code and inspect `/mcp` for the `mailbend` connection.

## Claude Desktop

Open **Settings**, then **Developer**, then **Edit Config**. Merge this entry
into the existing `mcpServers` object instead of replacing other servers.
On Linux, the file is `~/.config/Claude/claude_desktop_config.json`, as documented
in the [MCP local-server guide](https://modelcontextprotocol.io/docs/develop/connect-local-servers).
The [official Linux desktop beta](https://support.claude.com/en/articles/10065433-install-claude-desktop)
supports Ubuntu 22.04+ and Debian 12+.

```json
{
	"mcpServers": {
		"mailbend": {
			"command": "/home/you/MailBend/scripts/mailbend",
			"args": ["mcp"],
			"env": {
				"MAILBEND_EMAIL": "you@example.test",
				"MAILBEND_PASSWORD_FILE": "/home/you/.config/mailbend/personal.password",
				"MAILBEND_READ_ONLY": "1",
				"MAILBEND_TYPESAFE": "0"
			}
		}
	}
}
```

Restart Claude Desktop. For a Windows client, use the WSL2 entry below.
MailBend's native helpers do not run directly on macOS or Windows.

## Cursor

Merge this entry into your personal `~/.cursor/mcp.json`.
See [Cursor's MCP configuration](https://cursor.com/docs/mcp).

```json
{
	"mcpServers": {
		"mailbend": {
			"type": "stdio",
			"command": "/home/you/MailBend/scripts/mailbend",
			"args": ["mcp"],
			"env": {
				"MAILBEND_EMAIL": "you@example.test",
				"MAILBEND_PASSWORD_FILE": "/home/you/.config/mailbend/personal.password",
				"MAILBEND_READ_ONLY": "1",
				"MAILBEND_TYPESAFE": "0"
			}
		}
	}
}
```

Restart or reconnect the server in Cursor's MCP settings.

## VS Code

Run **MCP: Open User Configuration** for a private user-profile configuration.
The same format works in `.vscode/mcp.json`, but do not commit personal account
settings. VS Code's native format uses `servers`, not `mcpServers`.
See the [VS Code MCP configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration).

```json
{
	"servers": {
		"mailbend": {
			"type": "stdio",
			"command": "/home/you/MailBend/scripts/mailbend",
			"args": ["mcp"],
			"env": {
				"MAILBEND_EMAIL": "you@example.test",
				"MAILBEND_PASSWORD_FILE": "/home/you/.config/mailbend/personal.password",
				"MAILBEND_READ_ONLY": "1",
				"MAILBEND_TYPESAFE": "0"
			}
		}
	}
}
```

Use the server's **Start** action and review the trust prompt.

## Codex CLI

Add this table to your personal `~/.codex/config.toml`.
See [Codex's MCP configuration](https://developers.openai.com/codex/mcp).

```toml
[mcp_servers.mailbend]
command = "/home/you/MailBend/scripts/mailbend"
args = ["mcp"]

[mcp_servers.mailbend.env]
MAILBEND_EMAIL = "you@example.test"
MAILBEND_PASSWORD_FILE = "/home/you/.config/mailbend/personal.password"
MAILBEND_READ_ONLY = "1"
MAILBEND_TYPESAFE = "0"
```

Restart Codex and inspect `/mcp`.

## Gemini CLI

Merge this entry into your personal `~/.gemini/settings.json`.
Declare each required variable in `env`. Gemini filters sensitive-looking
inherited variable names, including names containing `PASSWORD`.
See [Gemini CLI's MCP configuration](https://geminicli.com/docs/tools/mcp-server/).

```json
{
	"mcpServers": {
		"mailbend": {
			"command": "/home/you/MailBend/scripts/mailbend",
			"args": ["mcp"],
			"env": {
				"MAILBEND_EMAIL": "you@example.test",
				"MAILBEND_PASSWORD_FILE": "/home/you/.config/mailbend/personal.password",
				"MAILBEND_READ_ONLY": "1",
				"MAILBEND_TYPESAFE": "0"
			}
		}
	}
}
```

Restart Gemini CLI. Leave its tool confirmation settings enabled.

## OpenClaw

With the local Gateway stopped, save the server definition through
[OpenClaw's MCP registry](https://docs.openclaw.ai/cli/mcp/registry).
The command below contains a password-file path, not a password.

```sh
openclaw mcp set mailbend '{"command":"/home/you/MailBend/scripts/mailbend","args":["mcp"],"env":{"MAILBEND_EMAIL":"you@example.test","MAILBEND_PASSWORD_FILE":"/home/you/.config/mailbend/personal.password","MAILBEND_READ_ONLY":"1","MAILBEND_TYPESAFE":"0"}}'
```

Use `openclaw mcp doctor mailbend` for a static configuration check.
Restart the Gateway or agent process after changing its saved configuration.

## Use a Windows client with WSL2

Install and build MailBend inside your WSL2 distro. Keep the checkout and
password file on the distro's Linux filesystem, such as `/home/you`, not
under `/mnt/c`. WSL1 is unsupported. Create the password file inside the distro
with the terminal command above.

For Claude Desktop on Windows, use this entry. Replace `Ubuntu` with the distro
name and `/home/you` with that distro user's home. The variables are set inside
Linux, so this example does not need Windows secret variables or `WSLENV`.

```json
{
	"mcpServers": {
		"mailbend": {
			"command": "wsl.exe",
			"args": [
				"--distribution", "Ubuntu", "--exec", "env",
				"MAILBEND_EMAIL=you@example.test",
				"MAILBEND_PASSWORD_FILE=/home/you/.config/mailbend/personal.password",
				"MAILBEND_READ_ONLY=1", "MAILBEND_TYPESAFE=0",
				"/home/you/MailBend/scripts/mailbend", "mcp"
			]
		}
	}
}
```

If you instead forward Windows environment variables, use `WSLENV` with `/u`
for Windows-to-WSL values, as described by
[Microsoft's WSL environment guide](https://learn.microsoft.com/en-us/windows/wsl/filesystems#share-environment-variables-between-windows-and-wsl-with-wslenv).
Keep the password itself in Linux. This WSL2 launch recipe has not been tested
with a live Windows client. A parsed configuration is not a successful launch.

## Connect two accounts

Create a separate private password file for the second account. Copy the
client's server entry and name the entries `mailbend_personal` and
`mailbend_work`. Give each entry its own `MAILBEND_EMAIL`,
`MAILBEND_PASSWORD_FILE`, and provider endpoint settings. In TOML, use two
`mcp_servers` tables with those names.

Each entry starts a separate MailBend process. There is no account selector in
a tool call. Choose the intended server before reading mail. If you later
enable sends, use separate `MAILBEND_STATE_DIR` paths so each account has its
own daily send counter.

## Verify the offered tools

Inspect your client's discovered tools after it connects. TypeSafe is off in
these examples, so `mail_classify` and `mail_triage` are absent. Read-only mode
also hides every tool that can write mail or a local file. Drafts-only mode
is different: it hides `mail_send`, but still allows mailbox changes and
draft replies and forwards.

The complete catalog comes from [`tools/gen-schema.py`](../tools/gen-schema.py).
[`Ops.listed`](../src/ops.bend) filters it for the current configuration.
`scripts/mailbend tools` reports that filtered list without logging in.
Do not treat a fixed tool count as a connection test. Discovery does not prove
that the mailbox credentials work.

The configuration shapes and CLI syntax above were checked against the linked
primary documentation on 2026-10-31. The repository's offline tests parse the
snippets and check launcher and password-file use. They do not install clients,
log in to a mailbox, or verify live client interoperability.
