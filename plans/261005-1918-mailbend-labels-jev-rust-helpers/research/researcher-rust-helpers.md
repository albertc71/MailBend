# Research: Rust rewrite of the native helpers

Date: 2026-10-05. Crate claims were checked by building a scratch
prototype (not committed); behaviour claims come from reading the C helpers.

## Recommended stack

| Need | Choice | Why | Rejected |
| --- | --- | --- | --- |
| TLS | rustls >= 0.23.45 (fixes RUSTSEC-2026-0285), `default-features = false, features = ["ring","std","tls12"]` | Verification on by default; prototype rejected the repo's wronghost, expired and selfsigned test certs; SNI only for DNS names; IP SAN works | OpenSSL via FFI (keeps C stack) |
| Crypto provider | ring 0.17.14 | 34 s build, 1.25 MB; aws-lc-rs needs CMake under sanitizers, 2.0 MB, 44 s, five 2026 advisories. Post-quantum key exchange is lost, but the C helper on Ubuntu 24.04 (OpenSSL 3.0) has none either | aws-lc-rs |
| Trust store | rustls-native-certs 0.8.4; `MAILBEND_CA_FILE` loaded with `rustls_pki_types::CertificateDer::pem_file_iter` | Mirrors OpenSSL default paths; zero certs is the old "cannot load the trust store" error | rustls-platform-verifier (cannot replace the store), webpki-roots (ignores admin CAs), rustls-pemfile (RUSTSEC-2025-0134) |
| DoH | Minimal RFC 8484 client over the same rustls config (POST `application/dns-message`, A and AAAA, skip CNAME, bounded compression, RCODE 0), plus an HTTP CONNECT step honouring `https_proxy`/`all_proxy`/`no_proxy` | No new crates; keeps the documented "DoH may honor proxy" behaviour (`docs/CLOUD_AGENT.md:205-206`, `native/README.md:51-53`) | curl crate (needs unsafe FFI for the socket), ureq (exposes `disable_verification`), hickory (tokio, 137 crates, MSRV 1.88) |
| Syscalls | nix 0.31.3 `features = ["fs","user"]` | openat2 + ResolveFlag, O_PATH, fstatfs with PROC/SYSFS magic, getpwuid | rustix (no SYSFS_MAGIC, no getpwuid) |
| Secrets | zeroize 1.9.0 (`Zeroizing`, preallocated) | Wipes password and key buffers | n/a |
| Base64 | base64ct 1.8.3 (`alloc`) | Constant-time, no deps | base64 0.23 default `simd-unsafe` |
| Unsafe | `[workspace.lints.rust] unsafe_code = "forbid"` | Prototype compiled with it | n/a |

Measured: clean release build about 30 s; stripped binaries 1.16 MB
(tls) and 0.36 MB (attach); only libc and libgcc_s linked. MSRV 1.85 matches
Ubuntu 24.04 `cargo-1.85` (apt candidate `1.85.1+dfsg0ubuntu2~bpo0-0ubuntu0.24.04.2`,
checked in this container) and Debian 13. Debian 12's rustc 1.63 is too old.

## Contract to keep (from the C source)

- Exit codes `EX_OK 0, EX_USAGE 2, EX_CONNECT 3, EX_AUTH 4, EX_REJECTED 5,
  EX_PROTO 6` (`native/mailbend-tls.c:67`); attach exits 0 or 2.
- Modes `imap`, `smtp`, `--check` (`native/mailbend-tls.c:959-963`).
- Bytes 0x80-0xFF as UTF-8 of U+0080-U+00FF on stdout
  (`native/mailbend-tls.c:36,114-118`; `native/mailbend-attach.c:30-32`).
- Routing: `*_CONNECT_IP` override, else DoH via `MAILBEND_DOH_URL`
  (HTTPS only, no fallback, Cloudflare bootstrap 1.1.1.1/1.0.0.1,
  `native/mailbend-tls.c:267-277,313-316`), else system DNS; mail socket
  never proxied (`:292`); one `MAILBEND_TIMEOUT_MS` budget.
- Everything else (script validation, =EXPECT, literals, LOGIN quiet mode,
  password file openat2 rules, attach sandbox) as specified in the scout
  contract; covered by `tests/test-transport.sh` (20 cases),
  `tests/test-cloud-network.py` (14 tests) and `tests/test-e2e.py`
  (password file at :612-633, hard link at :311, /proc/self at :332-344,
  symlinks at :341, :428, :633).

## CI design

- `clippy.toml` `disallowed-methods` for `rustls::ClientConfig::dangerous`
  and `rustls::ConfigBuilder::dangerous` (clippy flagged both in the
  prototype) + a grep backstop for `dangerous(`, `client::danger`,
  `ServerCertVerifier`.
- `deny.toml`: ban openssl, openssl-sys, native-tls, aws-lc-sys,
  webpki-roots, rustls-pemfile, curl-sys; deny rustls features
  aws_lc_rs/aws-lc-rs/fips; licence allow-list MIT, Apache-2.0, ISC,
  BSD-3-Clause, Apache-2.0 WITH LLVM-exception.
- Actions pinned by SHA (resolved with `git ls-remote`):
  dtolnay/rust-toolchain `7e38f4b43b4db5c8dd498af069a4f6196df1d067`,
  Swatinem/rust-cache `6323deb102c322ba6fcbdcafc7e3dddab59af2b6` (v2.9.2),
  EmbarkStudios/cargo-deny-action `3c6349835b2b7b196a839186cb8b78e02f7b5f25` (v2.1.1),
  taiki-e/install-action `183e4297cca2404691e9380e1307288dced5c82a` (v2.87.25).
- Steps: fmt, clippy `-D warnings`, test `--locked`, grep, deny, MSRV
  `cargo +1.85 check --locked`, existing Python suites, fuzz smoke
  (cargo-fuzz 0.13.2, nightly, `-max_total_time=60` per target).
- Dynamic glibc linking; static musl would weaken the home-directory
  refusal (no NSS).

## Risks

- New parsers on network data (DNS, HTTP response): fuzzed and size-bounded.
- webpki is stricter than OpenSSL (no CN-only certificates, no CBC-only TLS
  1.2 servers); low risk for iCloud.
- Sequential address fallback is slower than curl's happy eyeballs on broken
  IPv6.
- IPv6 and live iCloud mail ports were not testable in the research sandbox.

## Unverified

rustls-native-certs honouring SSL_CERT_FILE/SSL_CERT_DIR; curl's exact
per-address timeout split; rustls wiping plaintext buffers; minimal-profile
toolchain size; bit-identical builds with `--remap-path-prefix`.
