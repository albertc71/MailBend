---
phase: 1
title: "Phase 1: Rust workspace and attachment reader"
status: todo
priority: P1
effort: "1d"
dependencies: []
---

# Phase 1: Rust workspace and attachment reader

## Goal

Create the Rust workspace, its CI and install path, and replace
`native/mailbend-attach.c` with a Rust `mailbend-attach` that keeps the exact
contract, so every existing attachment test passes unchanged.

## Evidence

- User: "Rewrite 2 of them in rust and update all related documents."
- Research and measurements: [Rust helpers research](./research/researcher-rust-helpers.md).
- Contract: `mailbend-attach <dir> <path> <max-bytes>`, exit 0 or 2, stdout
  bytes with 0x80-0xFF as UTF-8 of U+0080-U+00FF
  (`native/mailbend-attach.c:20-34`); re-exec with an empty environment;
  realpath, openat2 directory with RESOLVE_NO_SYMLINKS|NO_MAGICLINKS;
  O_PATH probe with RESOLVE_BENEATH; regular file; reopen through
  `/proc/self/fd/<probe>` and compare dev/inode; refuse nlink > 1, procfs and
  sysfs, over-budget files; refuse `/`, home or an ancestor, and directories
  holding `.ssh`, `.gnupg`, `.aws`, `.config`, `.git`.
- Tests that pin it: `tests/test-e2e.py:296-344` (home, ancestors, `.ssh`,
  hard link, `/proc/self/environ`, symlink escape, `MAILBEND_ATTACH_DIR=/proc/self`)
  and `:428` (attach dir reached through a symlink).
- Past C bugs here were Linux path semantics (commits dd75027, 65122f8,
  f765ef7, 2b99c9a); Rust does not remove that class, so the port follows
  the C steps one for one.

## Design

```
native/
  Cargo.toml          workspace: resolver 3, edition 2024, rust-version 1.85,
                      [workspace.lints.rust] unsafe_code = "forbid",
                      clippy unwrap_used/expect_used/panic denied,
                      release: lto, codegen-units 1, strip
  Cargo.lock          committed; every cargo call uses --locked
  rust-toolchain.toml pinned to 1.85 (the MSRV and Ubuntu's cargo-1.85),
                      profile minimal; nightly only for fuzzing
  clippy.toml         disallowed-methods: rustls dangerous() APIs
  deny.toml           bans, licences, advisories (see research)
  mailbend-attach/    depends on nix only (no rustls, no network)
  mailbend-net/       shared TLS config and connect code (phase 2)
  mailbend-tls/       phase 2
  mailbend-typesafe/  phase 9
  fuzz/               separate cargo-fuzz workspace
```

- `mailbend-attach` keeps the exact 3-argument read form
  (`mailbend-attach <dir> <path> <max-bytes>`, called positionally by
  `tests/test-e2e.py:287,350`); phase 5 adds `count` and phase 6 adds
  `save` as named first arguments that cannot collide with a directory
  path (they never start with `/`, and the read form requires an absolute
  directory).
- A panic hook exits 2 without printing the payload.
- Error messages keep the substrings tests assert ("home directory",
  ".ssh", "hard link", "outside", "must not be /").

## Files

- Create: `native/Cargo.toml`, `native/Cargo.lock`,
  `native/rust-toolchain.toml`, `native/clippy.toml`, `native/deny.toml`,
  `native/mailbend-attach/Cargo.toml`, `native/mailbend-attach/src/main.rs`,
  `native/mailbend-attach/src/lib.rs`.
  (`mailbend-net`, `mailbend-tls` and `mailbend-typesafe` come in phases 2
  and 9.)
- Delete: `native/mailbend-attach.c` (after the Rust binary passes every
  test).
- Modify: `scripts/install.sh` (resolve `${CARGO:-cargo}`, else
  `cargo-1.85` (Ubuntu's package installs only `/usr/bin/cargo-1.85`),
  else fail with an actionable message; `cargo build --release --locked
  --manifest-path native/Cargo.toml`; copy binaries to `bin/`; fmt and
  clippy are not needed to install; add `--install-rust` mirroring
  `--install-bend`: download rustup-init, check sha256, minimal profile,
  toolchain 1.85; keep the C compiler requirement, which ring's build and
  the clang-compiled core still need), `scripts/setup-cloud.sh`
  (cargo-1.85 on Ubuntu 24.04 or `--install-rust`), `.github/workflows/ci.yml`
  (Rust job), `.github/dependabot.yml` (cargo for `/native`).

## Steps

1. Workspace files, lints, deny and clippy configs.
2. Port attach step for step; Rust unit tests for path relativisation and
   limits in `lib.rs`.
3. Install and CI: fmt, clippy `-D warnings`, test, deny, MSRV check, grep
   backstop, then the existing suites against the Rust binary.
4. Run `python3 tests/test-e2e.py` unchanged; delete the C file.

## Verification

- `cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked` in `native/`.
- `cargo deny check`.
- `scripts/install.sh && python3 tests/test-e2e.py` (all attachment checks).
- `ldd bin/mailbend-attach` shows only libc (and libgcc_s).

## Risks

- `getpwuid` must use glibc NSS (dynamic linking), or the home-directory
  refusal weakens; static musl is not used.
- Untested by the suite: openat2 ENOSYS on kernels before 5.6; keep the C
  error text and add a Rust unit test with an injected error.

## Security

- `forbid(unsafe_code)` in our crates; unsafe stays inside nix and std.
- No network crate in the attach dependency tree (checked by `cargo tree`
  in CI).
