---
phase: 2
title: "Phase 2: Rust TLS helper"
status: todo
priority: P1
effort: "3d"
dependencies: [1]
---

# Phase 2: Rust TLS helper

## Goal

Replace `native/mailbend-tls.c` with a Rust `mailbend-tls` that keeps the
exact contract (modes, environment, stdin/stdout/stderr, exit codes,
routing, TLS policy), so `tests/test-transport.sh`,
`tests/test-cloud-network.py` and `tests/test-e2e.py` pass unchanged, and
drop the OpenSSL and libcurl build dependencies.

## Evidence

- Research and prototype results: [Rust helpers research](./research/researcher-rust-helpers.md).
- Contract (scout report, verified against the source):
  - Modes `imap`, `smtp`, `--check`; anything else exits 2
    (`native/mailbend-tls.c:959-963`).
  - Exit codes 0, 2, 3, 4, 5, 6 (`:67`), interpreted by the core in
    `src/tools.bend:166-179`.
  - IMAP script validation before connecting: tags, forbidden verbs LOGIN,
    AUTHENTICATE, STARTTLS, LOGOUT (`:588-589`), literals, `=EXPECT` and
    `=EXPECT-WORD` (`:609-623`), 64 MiB script cap.
  - LOGIN with quoted escaping, replies suppressed; lock-step; first NO/BAD
    stops with exit 5 and the stderr line the core matches; best-effort
    LOGOUT.
  - SMTP: 220 greeting, EHLO, mandatory STARTTLS, no buffered bytes before
    the handshake, EHLO again, AUTH PLAIN or LOGIN quietly, envelope checks,
    QUIT best effort and skipped after 421.
  - Output limits: 60 MiB transcript, 32 MiB line, 64 MiB literal (exit 6).
  - Password: `MAILBEND_APP_PASSWORD` xor `MAILBEND_PASSWORD_FILE` (absolute,
    owned, mode 600, at most 1024 bytes, openat2 without symlinks); wiped
    after use.
  - Routing: `*_CONNECT_IP` override, DoH (`MAILBEND_DOH_URL`, HTTPS only,
    Cloudflare bootstrap, no fallback), system DNS; mail socket never
    proxied; DoH may use the HTTPS proxy (`docs/CLOUD_AGENT.md:205-206`).
- Tests: `tests/test-transport.sh` 20 cases, `tests/test-cloud-network.py`
  14 tests (override, IPv6 override, DoH refresh, proxy ignored for mail,
  DoH failures fail closed, certificate always checked).

## Design

- `mailbend-net` (lib, shared with phase 9's `mailbend-typesafe`): the one
  function that builds the rustls `ClientConfig` (ring provider, TLS 1.3 and
  1.2, native roots or `MAILBEND_CA_FILE`), server name handling (DNS name
  with SNI, IP literal without), connect with a shared deadline and
  address fallback, the DoH client with HTTP CONNECT proxy support, and the
  byte-to-U+0080..U+00FF output encoder.
- `mailbend-tls/src/lib.rs`: pure, fuzzable parsers (IMAP script
  validation, response framing and literals, SMTP replies and envelope,
  DNS answers, HTTP responses).
- `mailbend-tls/src/main.rs`: environment, credentials (`Zeroizing`),
  exit codes, the IMAP and SMTP loops, panic hook exiting 6 without the
  payload.
- AUTH PLAIN/LOGIN base64 with base64ct.
- Same stderr texts the tests and core assert (for example
  "TLS verification failed:", "command <tag> rejected; later commands
  skipped").
- `--check` exits 0 without credentials.
- Contract addition: exit 2 with a clear message when
  `MAILBEND_TYPESAFE_API_KEY` is present in the environment (the core
  refuses that configuration first; this is defence in depth so the TypeSafe
  key can never sit next to the mail password).

## Files

- Create: `native/mailbend-net/{Cargo.toml,src/lib.rs,src/tls.rs,src/connect.rs,src/doh.rs}`,
  `native/mailbend-tls/{Cargo.toml,src/main.rs,src/lib.rs,src/imap.rs,src/smtp.rs,src/creds.rs}`,
  `native/fuzz/{Cargo.toml,fuzz_targets/imap_script.rs,imap_response.rs,smtp_reply.rs,dns_answer.rs,http_response.rs}`.
- Delete: `native/mailbend-tls.c` (after all suites pass).
- Modify: `scripts/install.sh` (no OpenSSL/libcurl probe; `--check` still
  run), `tests/test-transport.sh:36` (build via cargo instead of `cc`),
  `.github/workflows/ci.yml` (drop `libssl-dev libcurl4-openssl-dev`, add
  the fuzz smoke step), `scripts/setup-cloud.sh`.

## Steps

1. `mailbend-net`: TLS config, connect, DoH with proxy CONNECT; unit tests
   with the repo's test certificates (`tests/gen-test-certs.sh`).
2. Parsers in `lib.rs` with unit tests mirroring the transport cases.
3. IMAP and SMTP loops, credentials, exit codes.
4. Run `bash tests/test-transport.sh`, `python3 tests/test-cloud-network.py`,
   `scripts/install.sh && python3 tests/test-e2e.py` unchanged; fix until
   green; then delete the C file.
5. Fuzz targets; CI smoke run of 60 s per target on a pinned nightly.

## Verification

- All three Python/shell suites pass with no test edits except the build
  line in `tests/test-transport.sh:36`.
- `cargo test --locked`, clippy, deny, MSRV check, grep backstop.
- `ldd bin/mailbend-tls` shows no libssl or libcurl.

## Risks

- Stricter certificate checks than OpenSSL (no CN-only certificates, no
  CBC-only TLS 1.2): low risk for iCloud; README notes it.
- Address fallback is sequential (slower than curl's happy eyeballs on
  broken IPv6); IPv6 untested in the research sandbox, covered by
  `test-cloud-network.py`'s IPv6 override test in CI.
- Live iCloud handshake not testable in the sandbox: phase 13's live
  checklist covers IMAP login, SMTP STARTTLS send, DoH and the
  `*_CONNECT_IP` override with the Rust helper.
- The C sources are deleted in this PR (user chose one PR); they stay
  recoverable from the commit before deletion, which the PR names.

## Security

- Verification cannot be disabled: clippy `disallowed-methods`, grep
  backstop, cargo-deny bans; one shared config function.
- No `unsafe` in our crates; secrets in `Zeroizing` buffers; panic hook
  never prints data.
