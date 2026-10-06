# Native boundary: mailbend-tls and mailbend-attach

MailBend has two small native programs:

- `mailbend-tls/` (Rust): sockets, TLS and login, the only code that reads the
  password. Which commands to send, and what the answers mean, is decided
  by the Bend core. TLS is rustls with the ring provider; name resolution
  is the system resolver or the helper's own DNS-over-HTTPS client
  (`mailbend-net/`). It links only libc and libgcc_s.
- `mailbend-attach/` (Rust): reads one attachment file safely (Bend cannot open a
  file without following symlinks). It holds no credentials: it first
  re-executes itself with an empty environment (so even
  `/proc/self/environ` is empty) and opens no connection.

```sh
(cd native && cargo build --release --locked -p mailbend-tls -p mailbend-attach)
```

The Rust workspace (`native/Cargo.toml`) pins Rust 1.99, its MSRV, in
`native/rust-toolchain.toml`; build from inside `native/` so rustup picks it
up. Our crates forbid `unsafe` code, and `native/deny.toml` bans OpenSSL,
native-tls and other TLS stacks from the dependency tree.
`mailbend-attach` depends only on `nix` and the local, network-free
`mailbend-io` crate (the shared output encoding and `openat2` helpers).
Tests run with `cargo test --locked`.

## Layout

- `mailbend-io/`: the stdout byte encoding and `openat2` helpers (no
  network), shared by both programs.
- `mailbend-net/`: `connect` (deadline, system DNS, address fallback),
  `tls` (the one verified client configuration), and the DoH client:
  `doh` built on `dns`, `http`, `url` and `proxy`.
- `mailbend-tls/`: the binary is a thin `main.rs` over the library.
  `settings`, `creds` and `route` are read and checked before connecting;
  `connection` owns the socket and the transcript; `imap/` and `smtp/` each
  hold the input validator (`script`, `envelope`), the response parser
  (`response`, `reply`) and the `session` that drives them.
- `mailbend-attach/`: the attachment reader.
- `fuzz/`: one cargo-fuzz target per parser (its own workspace, nightly).

## Contract

```text
mailbend-tls imap   < tagged IMAP commands   > server transcript
mailbend-tls smtp   < SMTP envelope + DATA   > server transcript
mailbend-tls --check  # credential-free local runtime check; no network
mailbend-attach <dir> <path> <max-bytes>    > the file's bytes
```

- **TLS**: rustls (ring provider), TLS 1.2+, peer certificate required,
  chain verified against the system trust store (or `MAILBEND_CA_FILE`, which
  replaces it), host name verified (DNS names against the certificate's DNS
  names, numeric hosts against its IP addresses), SNI sent for DNS names.
  There is no way to skip verification: one function builds every TLS
  configuration, clippy forbids rustls's `dangerous()` API, and CI greps for
  it. Certificates must carry subjectAltName entries (no CN-only
  certificates).
  SMTP must offer STARTTLS; the helper refuses to authenticate without it.
- **Resolution**: system DNS by default; a nonempty `MAILBEND_DOH_URL`
  selects an HTTPS DNS resolver without fallback to system DNS for the mail
  hostname. The helper asks for A and AAAA records (RFC 8484 POST) and uses
  whichever answers; it then tries each address in turn within the time
  budget. The default cloud resolver, `cloudflare-dns.com:443`, is
  bootstrapped with Cloudflare's `1.1.1.1` and `1.0.0.1` anycast addresses.
  Other resolver hostnames use system DNS for bootstrap. DoH verifies both
  its peer and hostname, using the system CA store or `MAILBEND_CA_FILE`.
  Every helper process resolves anew; no addresses or credentials are cached
  on disk. The resolver sees only DNS queries, never mail credentials/content.
- **Connection overrides**: `MAILBEND_IMAP_CONNECT_IP` and
  `MAILBEND_SMTP_CONNECT_IP` each accept one bare numeric IPv4/IPv6 address.
  They take precedence over DoH for that service, without changing `*_HOST`,
  SNI, the certificate name, port, or command plan. They are manual overrides,
  not refreshed DNS. Invalid nonempty values fail with exit 2, as do an
  invalid or non-HTTPS DoH URL, an invalid host name or port, and any set
  setting that is not UTF-8.
- **No proxy for mail**: the raw mail socket is never routed through a
  proxy. Only the DoH requests may use an `http://` proxy (HTTP `CONNECT`)
  from `https_proxy`/`HTTPS_PROXY`/`all_proxy`/`ALL_PROXY`, honouring
  `no_proxy`; another proxy scheme, or an unreadable proxy setting, is a
  usage error (exit 2) when DoH is configured. A TLS/protocol
  failure after TCP connects stops the session rather than replaying
  commands on another address.
- **TypeSafe key**: if `MAILBEND_TYPESAFE_API_KEY` is set, `imap` and `smtp`
  exit 2 before reading anything: the TypeSafe key must never share a
  process with the mail password.
- **Credentials**: `MAILBEND_EMAIL` and `MAILBEND_APP_PASSWORD` from the
  environment, or the password from `MAILBEND_PASSWORD_FILE` (an absolute
  path to a regular file owned by the user, mode 600, opened with
  `openat2(RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)`, so no component
  of the path may be a symlink: give its real path; needs Linux 5.6+; one
  trailing LF or CRLF is ignored; setting both is
  refused). The helper sends `L LOGIN` (IMAP) or `AUTH PLAIN`/`LOGIN`
  (SMTP) itself, wipes temporary password-bearing buffers, and never writes
  credentials to stdout or stderr.
  The server's replies to the login are checked but not forwarded either, so
  a server that echoes the credentials cannot pass them to the core.
- **IMAP script**: CRLF lines in IMAP wire form; a line ending in `{N}` is
  followed by N literal bytes. Tags `L` and `Z` are reserved, and LOGIN,
  AUTHENTICATE, STARTTLS and LOGOUT are refused. Each command waits for its
  tagged answer; the first `NO`/`BAD` stops the run (later commands are never
  sent), then the helper logs out. A line `=EXPECT <text>` right after a
  command is not sent: the run stops (exit 5) unless one of that command's
  untagged replies starts with `<text>` (case-insensitive). The core uses it
  to pin a folder's UIDVALIDITY after `SELECT`, in the same session that
  changes messages.
  `=EXPECT-WORD <word>` asks for `<word>` as a whole word (any case) in one
  of those lines; the core uses it to confirm UIDPLUS before anything is
  marked `\Deleted`.
- **Attachments** (`mailbend-attach`): re-executes itself with an empty
  environment, refuses files on procfs or sysfs, resolves
  `<dir>` once with `realpath` and opens
  that canonical path with `RESOLVE_NO_SYMLINKS` (so swapping a component
  for a symlink afterwards fails), then opens `<path>` (relative to `<dir>`,
  or absolute inside it) with `openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS |
  RESOLVE_NO_MAGICLINKS)`, so no symlink or `..` leads outside `<dir>`. It
  refuses a `<dir>` that is `/`, the user's home directory (from the
  password database) or a directory containing it, or one holding `.ssh`,
  `.gnupg`, `.aws`, `.config` or `.git`. It checks the file's type through
  an `O_PATH` descriptor first, so a device or FIFO found there is not
  opened; it then reopens that same inode for reading through
  `/proc/self/fd/<descriptor>` (not by walking the path again) and confirms
  the inode once more, so a file a concurrent local writer substitutes
  under the name is never opened. What can still change after the checks
  is that same file's contents and links. It
  refuses a file with more than one hard link, and
  checks the opened descriptor is a regular file of at most `<max-bytes>`
  (capped at 25 MiB; the core passes what remains of the 25 MiB total budget)
  before reading it, and enforces that limit while reading if the file grows.
  Exit 2 with the reason on stderr when refused. Needs
  Linux 5.6+.
- **SMTP envelope**: `MAIL FROM`, `RCPT TO`, ..., `DATA`, the dot-stuffed
  message, `.`. EHLO, HELO, STARTTLS, AUTH and QUIT are refused in the
  envelope. The helper owns greeting, STARTTLS, authentication and QUIT.
  Envelope commands and final message acceptance require 2xx replies; DATA
  requires a 354 continuation before the message is sent. A rejection stops
  the run.
- **Output**: the server's bytes; bytes 0x80-0xFF are written as the UTF-8
  encoding of U+0080-U+00FF, so the core reads one character per byte and
  literal lengths stay exact. IMAP literals are consumed by byte count and
  emitted with the same encoding, so message content can never be mistaken
  for a tagged reply. IMAP `+` continuation requests are consumed, not
  copied. Attachment output uses this encoding too.
- **Limits**: DNS plus TCP connect budget and per-read timeout
  `MAILBEND_TIMEOUT_MS` (default 30 s), which also bounds system DNS (run on
  its own thread), the DoH exchange and any proxy reply. Size limits are 32 MiB per line, 64 MiB per literal and per script,
  and 60 MiB per transcript before stdout's byte-to-UTF-8 encoding
  (at most 120 MiB after encoding).
- **Transport exit status**: 0 ok, 2 usage/config, 3 connect/TLS/verification,
  4 authentication rejected, 5 command rejected, 6 protocol/timeout/limit.
