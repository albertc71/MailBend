# Native boundary: mailbend-tls, mailbend-attach and mailbend-typesafe

MailBend has three small native programs:

- `mailbend-tls/` (Rust): sockets, TLS and login, the only code that reads the
  password. Which commands to send, and what the answers mean, is decided
  by the Bend core. TLS is rustls with the ring provider; name resolution
  is the system resolver or the helper's own DNS-over-HTTPS client
  (`mailbend-net/`). It links only libc and libgcc_s.
- `mailbend-attach/` (Rust): reads one attachment file safely (Bend cannot open a
  file without following symlinks), saves downloaded attachments as new
  files, and keeps the daily send counter. It holds no credentials: it first
  re-executes itself with an empty environment (so even
  `/proc/self/environ` is empty) and opens no connection.
- `mailbend-typesafe/` (Rust): carries one request from the Bend core to
  TypeSafe's Jev and its answer back, and is the only code that reads the
  TypeSafe key. It never holds the mail password: it re-executes itself
  with an allow-listed environment first. What to ask, and what the answer
  means, is decided by the core.

```sh
(cd native && cargo build --release --locked -p mailbend-tls -p mailbend-attach -p mailbend-typesafe)
```

The Rust workspace (`native/Cargo.toml`) pins Rust 1.99, its MSRV, in
`native/rust-toolchain.toml`; build from inside `native/` so rustup picks it
up. Our crates forbid `unsafe` code, and `native/deny.toml` bans OpenSSL,
native-tls and other TLS stacks from the dependency tree.
`mailbend-attach` depends only on `nix` and the local, network-free
`mailbend-io` crate (environment settings, `openat2` helpers, stderr reports
and the byte encoding shared with the core). `mailbend-typesafe` reuses
`mailbend-net` for TLS, DoH and the proxy, and `mailbend-io` for its
settings and the key file.
Tests run with `cargo test --locked`.

## Layout

- `mailbend-io/`: `env` (environment settings), `fs` (`openat2` helpers),
  `secret` (the mail password and TypeSafe key files, and the refusal of a
  key in the environment), `report` (stderr reports) and `transcript` (the
  byte encoding of what the helpers and the core pass each other); no
  network, shared by all three programs.
- `mailbend-net/`: `connect` (deadline, system DNS, address fallback),
  `tls` (the one verified client configuration), `http` (bounded HTTP/1.1
  responses), `proxy` (HTTP `CONNECT`), and the DoH client: `doh` built on
  `dns`, `http`, `url` and `proxy`.
- `mailbend-tls/`: the binary is a thin `main.rs` over the library.
  `settings`, `creds` and `route` are read and checked before connecting;
  `connection` owns the socket and the transcript; `imap/` and `smtp/` each
  hold the input validator (`script`, `envelope`), the response parser
  (`response`, `reply`) and the `session` that drives them.
- `mailbend-attach/`: the attachment reader, the download writer (`save`)
  and the send counter.
- `mailbend-typesafe/`: `environment` (the allow-listed re-execution),
  `settings` (key, request, time budget and route, checked before
  connecting), `api` (the fixed endpoint, retries, redaction) and `exit`
  (the exit statuses).
- `fuzz/`: one cargo-fuzz target per parser (its own workspace, nightly).

## Contract

```text
mailbend-tls imap   < tagged IMAP commands   > server transcript
mailbend-tls smtp   < SMTP envelope + DATA   > server transcript
mailbend-tls --check  # credential-free local runtime check; no network
mailbend-attach <dir> <path> <max-bytes>    > the file's bytes
mailbend-attach count <state-dir> <limit> <utc-day>   > ok <n> | full <n>
mailbend-attach save <attach-dir> <download-dir> <name> <max-bytes> <path-list>
                                            < the file's bytes
mailbend-typesafe ask   < Jev request JSON   > TypeSafe's answer JSON
mailbend-typesafe --check  # credential-free local runtime check; no network
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
  `.gnupg`, `.aws`, `.config` or `.git`, or one that is or lies inside a
  directory so named. It checks the file's type through
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
- **Send counter** (`mailbend-attach count <state-dir> <limit> <utc-day>`):
  creates `<state-dir>` with mode 0700 if it is missing, resolves it once
  with `realpath` and opens it with `RESOLVE_NO_SYMLINKS`, then opens or
  creates `sends` (mode 0600) beneath it with `openat2(RESOLVE_BENEATH |
  RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS)` and refuses anything but a
  regular file. Under an exclusive `flock` it counts the lines equal to
  `<utc-day>` (`YYYY-MM-DD`); below `<limit>` it appends one, syncs it and
  prints `ok <n>` (counting this send), else it appends nothing and prints
  `full <n>`. It only compares the number the core supplies; the core
  decides to refuse. Exit 2 with the reason on stderr when the directory or
  file cannot be used.
- **Downloads** (`mailbend-attach save <attach-dir> <download-dir> <name>
  <max-bytes> <path-list>`): `<attach-dir>` is `MAILBEND_ATTACH_DIR` (empty
  when unset) and `<path-list>` the caller's `PATH`, passed as arguments
  because the helper drops its environment; nothing else from the
  environment is passed. `<name>` must be one path component of at most
  255 bytes, not `.` or `..`. `<download-dir>` is resolved and opened as
  `<dir>` is for attachments and refused on the same grounds; it is also
  refused when it is, contains or lies inside `<attach-dir>` (a set
  `<attach-dir>` that cannot be opened is refused too), when it is or lies
  inside `~/.config`, `~/.local/bin` or `~/.local/share/applications` (home
  from the password database; refused when it has none), when any of its components is named
  `autostart` or `systemd`, or when it is a directory in `<path-list>`.
  Directories are compared by device and inode, walking `..` up from the
  opened descriptors, so a symlink alias or another spelling of the same
  directory is refused too. Only then does it read stdin, in the byte
  encoding above (stdin is decoded from it; any other character is
  refused), into an unnamed file (`O_TMPFILE`, mode 0600) in
  `<download-dir>`, refuses more than `<max-bytes>` (capped at 25 MiB),
  syncs it and names it `<name>` with `linkat`, which fails rather than
  replace an existing file. A helper stopped before that, even by SIGKILL,
  leaves no file. Prints nothing; exit 2 with the reason on stderr when
  refused. Needs a file system with `O_TMPFILE` support.
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
  copied. Attachment output uses this encoding too, and a download's
  bytes arrive on stdin in it.
- **Limits**: DNS plus TCP connect budget and per-read timeout
  `MAILBEND_TIMEOUT_MS` (default 30 s), which also bounds system DNS (run on
  its own thread), the DoH exchange and any proxy reply. Size limits are 32 MiB per line, 64 MiB per literal and per script,
  and 60 MiB per transcript before stdout's byte-to-UTF-8 encoding
  (at most 120 MiB after encoding).
- **Transport exit status**: 0 ok, 2 usage/config, 3 connect/TLS/verification,
  4 authentication rejected, 5 command rejected, 6 protocol/timeout/limit.

## TypeSafe (`mailbend-typesafe ask`)

- **Environment**: if `MAILBEND_TYPESAFE_API_KEY` is set (even empty) it
  exits 2. Otherwise it re-executes itself with only
  `MAILBEND_TYPESAFE_KEY_FILE`, `MAILBEND_TIMEOUT_MS`, `MAILBEND_DOH_URL`,
  `MAILBEND_CA_FILE`, `https_proxy`, `HTTPS_PROXY`, `all_proxy`,
  `ALL_PROXY`, `no_proxy` and `NO_PROXY`, so `/proc/<pid>/environ` holds no
  mail password or other setting.
- **Key**: read from `MAILBEND_TYPESAFE_KEY_FILE` with the same rules as
  `MAILBEND_PASSWORD_FILE` (absolute, a regular file owned by the user, not
  readable by group or others, no symlink in any component); it must be one
  line of at least 8 characters of RFC 6750's Bearer token grammar (letters,
  digits and `. _ ~ + / -`, then optional `=` padding). It is kept in a
  buffer wiped on drop, sent only as the `Authorization: Bearer` header,
  never formatted into a message, and every copy of it in an answer, also
  the JSON spelling with `\/` for `/`, is replaced by `[redacted]`.
- **Request**: stdin, nonempty UTF-8 of at most 1 MiB, sent unchanged as
  `POST /v1/systemone` to `api.typesafe.ai:443`; host, port and path are
  constants. The `User-Agent` is `mailbend`.
- **Route and TLS**: through an `http://` proxy from `https_proxy`,
  `HTTPS_PROXY`, `all_proxy` or `ALL_PROXY`, the first set (HTTP `CONNECT`,
  unless `no_proxy` or `NO_PROXY` lists the host), else the DoH resolver of
  `MAILBEND_DOH_URL`, else system DNS; then the same verified TLS as the
  mail helper (`MAILBEND_CA_FILE` replaces the trust store). Each attempt
  has `MAILBEND_TIMEOUT_MS` from connecting to the end of the answer, whose
  size is capped at 4 MiB.
- **Retries**: HTTP 429 and 5xx answers, and timeouts, are tried again after
  1 s and 2 s (three attempts at most); nothing else is retried.
- **Output**: a 2xx answer on stdout, exit 0. A refusal's answer (TypeSafe's
  reason) is written to stdout too, redacted, with the exit status; the
  reason for any failure is on stderr.
- **Exit status**: 0 answered, 2 key file, input or setting problem, 3
  cannot reach TypeSafe (connect, proxy or TLS), 6 unexpected answer, 7 key
  rejected (401, 403), 8 request refused (400, 413, 422), 9 overloaded or
  timed out after the retries.
