# Prototype plan

## Why IMAP + SMTP

iCloud Mail exposes standard mail protocols rather than a Gmail-style public
mail REST API. MailBend therefore uses IMAP for mailbox/message operations and
SMTP for delivery.

Defaults:

- IMAP: `imap.mail.me.com:993` using TLS
- SMTP: `smtp.mail.me.com:587` using STARTTLS
- authentication: iCloud address + Apple app-specific password

## Semantics

| MailBend operation | Protocol representation |
| --- | --- |
| list folders | IMAP LIST |
| search | IMAP UID SEARCH |
| read without marking read | UID FETCH with BODY.PEEK |
| mark read | UID STORE +FLAGS (\\Seen) |
| mark unread | UID STORE -FLAGS (\\Seen) |
| label/folder | IMAP mailbox + UID MOVE/COPY |
| trash | move to discovered Trash mailbox |
| delete | explicit deletion path; never implied by read |
| save draft | APPEND to discovered Drafts mailbox with \\Draft |
| compose/send | SMTP |
| attachments | MIME message construction |

Folder names such as Drafts/Trash must be discovered instead of hard-coded
where the server advertises special-use mailboxes.

## Linux transport boundary

Bend owns the domain and protocol decisions. A minimal native Linux component
will provide verified TLS byte streams. Requirements:

1. certificate-chain verification
2. hostname verification
3. no `rejectUnauthorized=false` equivalent
4. secrets supplied by environment, never command-line arguments
5. bounded reads and timeouts
6. zero application logging of authentication material

The prototype should prefer the smallest implementation that can be compiled
on a Cursor Cloud Agent.

## MCP surface after live connectivity is proven

Read-only:
- `mail_list_folders`
- `mail_search`
- `mail_get`
- `mail_get_new`

Mutating:
- `mail_mark_read`
- `mail_mark_unread`
- `mail_move`
- `mail_trash`
- `mail_delete`
- `mail_save_draft`
- `mail_send`

Mutation tools stay separate so an agent cannot accidentally turn a read into
a write.

## Monitoring later

Monitoring will checkpoint `mailbox + UIDVALIDITY + UID`. It will not use
the read/unread flag as delivery state. If authenticated CAPABILITY advertises
IDLE, the watcher may use it; otherwise it will poll with backoff.
