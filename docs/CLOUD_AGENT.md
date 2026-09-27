# Cursor Cloud Agent / Grok Bot setup

MailBend runs as a local stdio MCP server inside the agent's Linux
environment. Test the exact environment you use: installing an MCP server in
one Cursor environment does not install it in others.

## 1. Secrets

Add these in the platform's secret / environment settings (not in the repo,
not in a prompt):

```text
MAILBEND_EMAIL          your iCloud address
MAILBEND_APP_PASSWORD   an Apple app-specific password
```

Optional: `MAILBEND_READ_ONLY=1` for a first run against a real mailbox, and
`MAILBEND_ATTACH_DIR` to allow attachments from one directory. All optional
variables are in [.env.example](../.env.example).

## 2. Install

In the environment's setup / install step (or once in a terminal):

```sh
sudo apt-get install -y build-essential libssl-dev clang   # skip what is present
curl -fsSL https://bend-lang.com/install.sh | sh
git clone https://github.com/albertc71/MailBend.git ~/MailBend
~/MailBend/scripts/install.sh
```

Without clang the install still works; the server then starts through `bend`
(about 9 seconds per start instead of milliseconds).

## 3. Register the MCP server

Cursor reads `.cursor/mcp.json` in the project (or `~/.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "mailbend": {
      "command": "/home/ubuntu/MailBend/scripts/mailbend",
      "args": ["mcp"]
    }
  }
}
```

Use the real absolute path of your clone. The server takes
`MAILBEND_EMAIL`/`MAILBEND_APP_PASSWORD` from its environment. If your client
starts MCP servers without the agent's secrets, pass them through with the
client's environment interpolation, if it has one (Cursor:
`"env": {"MAILBEND_EMAIL": "${env:MAILBEND_EMAIL}", "MAILBEND_APP_PASSWORD": "${env:MAILBEND_APP_PASSWORD}"}`);
never write the values themselves into the file. Restart or reload the agent
so it discovers the tools.

## 4. Verify

From a terminal in the environment:

```sh
~/MailBend/scripts/mailbend call mail_probe
```

Expect `"ok": true`, `"tls_verified": true`, the authenticated capabilities
(`idle`, `move`, `uidplus`) and the special folders (iCloud's Trash is usually
"Deleted Messages"). Then ask the agent to run `mail_probe` and
`mail_search` to confirm tool discovery and invocation.

Errors are specific: "TLS verification failed: ..." (trust store or
interception), "authentication failed ..." (address or app-specific password),
"configuration error: MAILBEND_APP_PASSWORD is not set" (secret not passed to
the MCP process).

## 5. First live run, safely

1. With `MAILBEND_READ_ONLY=1`: `mail_probe`, `mail_list_folders`,
   `mail_search`, `mail_get` on a known message; confirm in Mail.app that it
   is still unread.
2. Unset read-only and use a test message you sent yourself:
   `mail_mark_read`, `mail_mark_unread`, `mail_move` to a scratch folder,
   `mail_trash`, then `mail_delete` with `"confirm": "permanently-delete"`;
   each takes the `uidvalidity` that `mail_search` reported.
3. `mail_save_draft`, then `mail_send` to your own address; check whether
   iCloud filed the sent copy in "Sent Messages".
