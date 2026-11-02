# CLI reference

Use an existing configured installation's public `scripts/mailbend` launcher,
not its internal core binary. Work from that checkout or use its absolute path.
[Launcher and setup](https://github.com/albertc71/MailBend/blob/main/README.md#use).

```sh
scripts/mailbend call mail_probe
scripts/mailbend call mail_search - < arguments.json
scripts/mailbend tools
```

For the second command, prepare only the requested search arguments in a private
JSON file. `mail_search.from` and `mail_search.limit` are example keys.
Read the [CLI contract](https://github.com/albertc71/MailBend/blob/main/docs/CLI.md)
for a complete JSON example. Stdin accepts one UTF-8 document, at most 8 MiB
including whitespace, and waits for EOF. It keeps JSON out of argv, not out of
files or the caller's reach. Never put credentials in tool arguments.
[Credential boundary](https://github.com/albertc71/MailBend/blob/main/README.md#safety).

`call` prints the JSON result after dispatch; input errors produce no tool
result. Inspect the result, not only its exit status.

| Exit | Meaning |
| --- | --- |
| 0 | Command succeeded; still inspect result details. |
| 1 | Tool failure or partial result; a change may have happened. |
| 2 | Usage/input error, or no available core/runtime. |
| 6 | Core cannot open inherited socket stdin; use a pipe/file and the public launcher. |

Signals and runtime failures can produce other nonzero statuses. No separate
exit 3 is currently implemented. Never automatically retry a write after a
nonzero exit, an unknown SMTP result or an interrupted call. Check state first.
[SMTP outcomes](https://github.com/albertc71/MailBend/blob/main/README.md#smtp-outcomes),
[interrupted changes](https://github.com/albertc71/MailBend/blob/main/README.md#safety).

Never set or unset `MAILBEND_*` variables yourself. Do not read password or
TypeSafe key files. An agent with a shell controls its own environment and can
read the password file as the same user. Use MCP with switches set by the owner
in client configuration for the least-privilege choice; this does not make mail
trusted or turn client prompts into approval.
[Safety limits](https://github.com/albertc71/MailBend/blob/main/README.md#safety).
