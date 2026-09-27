# Native boundary: mailbend-tls

`mailbend-tls.c` is MailBend's only native code: sockets, TLS and login,
plus one safe file read for attachments (Bend cannot open a file without
following symlinks).
Which commands to send, and what the answers mean, is decided by the Bend
core. It links only against OpenSSL.

```sh
cc -std=c11 -O2 -Wall -Wextra -o bin/mailbend-tls native/mailbend-tls.c -lssl -lcrypto
```

## Contract

```text
mailbend-tls imap   < tagged IMAP commands   > server transcript
mailbend-tls smtp   < SMTP envelope + DATA   > server transcript
mailbend-tls attach <dir> <path>             > the file's bytes
```

- **TLS**: TLS 1.2+, peer certificate required, chain verified against the
  system trust store (or `MAILBEND_CA_FILE`, which replaces it), host name
  verified (`SSL_set1_host`), SNI sent. There is no way to skip verification.
  SMTP must offer STARTTLS; the helper refuses to authenticate without it.
- **Credentials**: `MAILBEND_EMAIL` and `MAILBEND_APP_PASSWORD` from the
  environment only. The helper sends `L LOGIN` (IMAP) or `AUTH PLAIN`/`LOGIN`
  (SMTP) itself, wipes its copies, and never writes them to stdout or stderr.
- **IMAP script**: CRLF lines in IMAP wire form; a line ending in `{N}` is
  followed by N literal bytes. Tags `L` and `Z` are reserved, and LOGIN,
  AUTHENTICATE, STARTTLS and LOGOUT are refused. Each command waits for its
  tagged answer; the first `NO`/`BAD` stops the run (later commands are never
  sent), then the helper logs out. A line `=EXPECT <text>` right after a
  command is not sent: the run stops (exit 5) unless one of that command's
  untagged replies starts with `<text>`. The core uses it to pin a folder's
  UIDVALIDITY after `SELECT`, in the same session that changes messages.
  `=EXPECT-WORD <word>` asks for `<word>` as a whole word (any case) in one
  of those lines; the core uses it to confirm UIDPLUS before anything is
  marked `\Deleted`.
- **Attachments**: `attach` opens `<path>` (relative to `<dir>`, or absolute
  inside it) with `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS |
  RESOLVE_NO_MAGICLINKS)`, so no symlink or `..` leads outside `<dir>`, then
  checks the opened descriptor is a regular file of at most 25 MiB before
  reading it. It reads no credentials and opens no connection. Needs Linux
  5.6+.
- **SMTP envelope**: `MAIL FROM`, `RCPT TO`, ..., `DATA`, the dot-stuffed
  message, `.`. EHLO, STARTTLS, AUTH and QUIT are the helper's own and are
  refused in the envelope. Any non-2xx reply stops the run.
- **Output**: the server's bytes; bytes 0x80-0xFF are written as the UTF-8
  encoding of U+0080-U+00FF, so the core reads one character per byte and
  literal lengths stay exact. Server literals are copied as raw bytes, so
  message content can never be mistaken for a tagged reply.
- **Limits**: connect and per-read timeout `MAILBEND_TIMEOUT_MS` (default
  30 s), 1 MiB per line, 64 MiB per literal and per script, 128 MiB per
  transcript.
- **Exit status**: 0 ok, 2 usage/config, 3 connect/TLS/verification,
  4 authentication rejected, 5 command rejected, 6 protocol/timeout/limit.
