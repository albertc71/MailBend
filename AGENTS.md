# MailBend agent instructions

MailBend is a small Linux-first iCloud Mail connector.

## Constraints
- Keep the core in Bend 2.
- Keep the native boundary tiny: TLS/socket/process interoperability only.
- Never log, print, commit, persist, or return MAILBEND_APP_PASSWORD.
- TLS peer and hostname verification are mandatory.
- Read operations must not mutate message flags.
- Destructive operations must be explicit.
- Prefer IMAP UID commands over sequence-number commands.
- Detect server capabilities after authentication; do not assume optional IMAP extensions.
- Treat iCloud "labels" as IMAP mailboxes/folders.

## Prototype order
1. configuration and command model
2. TLS connection + authenticated IMAP capability probe
3. list/search/fetch without setting \\Seen
4. flags and folder operations
5. drafts
6. SMTP compose/send
7. MCP adapter for Cursor Cloud Agent
8. monitoring/deduplication
