#!/usr/bin/env sh
# Installs Rust 1.99, the native helpers' pinned toolchain
# (native/rust-toolchain.toml), with rustup into ~/.cargo and ~/.rustup,
# verifying the pinned rustup-init's sha256 before running it. The
# Linux x86_64 and aarch64 rustup-init binaries are pinned.
set -eu
RUSTUP_VERSION=1.29.1
RUST_TOOLCHAIN=1.99

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

# Digests come from the pinned upstream release, not the running machine.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    target=x86_64-unknown-linux-gnu
    RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
    ;;
  Linux-aarch64)
    target=aarch64-unknown-linux-gnu
    RUSTUP_SHA256=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433
    ;;
  *) fail "this installer supports only Linux x86_64 and aarch64" ;;
esac
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is needed (coreutils)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'mailbend: installing Rust %s with rustup %s (sha256-verified)\n' "$RUST_TOOLCHAIN" "$RUSTUP_VERSION"
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/rustup-init" \
  "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init"
echo "${RUSTUP_SHA256}  $tmp/rustup-init" | sha256sum -c - >/dev/null \
  || fail "rustup-init checksum mismatch; nothing was installed"
chmod +x "$tmp/rustup-init"
"$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
"$HOME/.cargo/bin/rustup" toolchain install "$RUST_TOOLCHAIN" --profile minimal -c clippy -c rustfmt
