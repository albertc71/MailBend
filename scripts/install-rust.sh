#!/usr/bin/env sh
# Installs Rust 1.99, the native helpers' pinned toolchain
# (native/rust-toolchain.toml), with rustup into ~/.cargo and ~/.rustup,
# verifying the pinned rustup-init's sha256 before running it. Only the
# Linux x64 rustup-init is pinned.
set -eu
RUSTUP_VERSION=1.29.1
RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
RUST_TOOLCHAIN=1.99

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] \
  || fail "the pinned rustup-init is Linux x64 only; install Rust $RUST_TOOLCHAIN yourself"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is needed (coreutils)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'mailbend: installing Rust %s with rustup %s (sha256-verified)\n' "$RUST_TOOLCHAIN" "$RUSTUP_VERSION"
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/rustup-init" \
  "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init"
echo "${RUSTUP_SHA256}  $tmp/rustup-init" | sha256sum -c - >/dev/null \
  || fail "rustup-init checksum mismatch; nothing was installed"
chmod +x "$tmp/rustup-init"
"$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
"$HOME/.cargo/bin/rustup" toolchain install "$RUST_TOOLCHAIN" --profile minimal -c clippy -c rustfmt
