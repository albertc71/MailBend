# MailBend

Lightweight, Linux-first iCloud Mail connector for AI agents, with the core written in Bend 2.

> Experimental prototype. Use a test mailbox until live transport and destructive-operation tests pass.

## Target

MailBend is being designed for Cursor Cloud Agent / Grok Bot first, while keeping the mail layer reusable by other MCP-capable assistants.

```text
Cursor Cloud Agent / Grok Bot
            |
        MCP adapter
            |
          Bend 2
   domain + IMAP/SMTP
            |
    minimal Linux TLS bridge
            |
        iCloud Mail
```

Apple Mail operations are represented through IMAP and SMTP. iCloud folders are the closest equivalent to Gmail labels.

## Prototype operations

- list folders
- search and read without changing unread state
- mark read/unread
- move to folders ("labels")
- trash and explicit delete
- save drafts
- compose/send
- reply/forward and attachments after live transport is proven

## Configuration

Copy `.env.example` conceptually into your Cloud Agent secrets/environment. Never commit the real values.

```sh
export MAILBEND_EMAIL='you@icloud.com'
export MAILBEND_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'
```

The password must be an Apple app-specific password.

## Security

- credentials are environment-only
- TLS certificate and hostname verification are mandatory
- reads and mutations are separate operations
- message access will use stable IMAP UIDs
- server capabilities and special-use folders are discovered
- no credential logging

## Development

The current commit establishes the Bend command model and transport contract. Next milestone: compile on Linux and add the smallest verified TLS bridge, then perform an authenticated iCloud IMAP CAPABILITY smoke test.

See [docs/PROTOTYPE.md](docs/PROTOTYPE.md) and [AGENTS.md](AGENTS.md).
