#!/usr/bin/env sh
# Installs Lean with elan (~/.elan) for `bend PROOF.bend --verdict`, which
# builds Bend's proven BendTT kernel with it. elan's archive sha256 is
# verified before it runs. LEAN_TOOLCHAIN is the one the pinned Bend release
# (scripts/install-bend.sh) asks for; recheck it whenever BEND_VERSION
# changes. Only the Linux x64 elan release is pinned.
set -eu
ELAN_VERSION=4.2.4
ELAN_SHA256=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63
LEAN_TOOLCHAIN=leanprover/lean4:v4.34.0

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] \
  || fail "the pinned elan release is Linux x64 only; install $LEAN_TOOLCHAIN yourself"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is needed (coreutils)"

name="elan-x86_64-unknown-linux-gnu.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'mailbend: installing %s with elan %s (sha256-verified)\n' "$LEAN_TOOLCHAIN" "$ELAN_VERSION"
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$name" \
  "https://github.com/leanprover/elan/releases/download/v${ELAN_VERSION}/$name"
echo "${ELAN_SHA256}  $tmp/$name" | sha256sum -c - >/dev/null \
  || fail "elan archive checksum mismatch; nothing was installed"
tar -xzf "$tmp/$name" -C "$tmp"
"$tmp/elan-init" -y --no-modify-path --default-toolchain none
"$HOME/.elan/bin/elan" toolchain install "$LEAN_TOOLCHAIN"
