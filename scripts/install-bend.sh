#!/usr/bin/env sh
# Installs the pinned Bend release to ~/.bend (bin/bend, bend2, guide),
# verifying the archive's sha256 before unpacking. This is the one place the
# tested Bend version is pinned; CI and scripts/install.sh both use it.
# Only the Linux x64 release is pinned.
set -eu
BEND_VERSION=2.0.32
BEND_SHA256=5c365ddb12954d0933cef751802e0f7d9875f842edcb80f9661f89cd1a9ff7b6

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] \
  || fail "the pinned Bend release is Linux x64 only; install Bend $BEND_VERSION yourself"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is needed (coreutils)"

name="bend-${BEND_VERSION}-linux-x64.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'mailbend: installing Bend %s to ~/.bend (sha256-verified)\n' "$BEND_VERSION"
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$name" \
  "https://github.com/bendlang/bend/releases/download/v${BEND_VERSION}/$name"
echo "${BEND_SHA256}  $tmp/$name" | sha256sum -c - >/dev/null \
  || fail "Bend archive checksum mismatch; nothing was installed"
tar -xzf "$tmp/$name" -C "$tmp"
mkdir -p "$HOME/.bend/bin"
rm -rf "$HOME/.bend/bend2" "$HOME/.bend/guide"
mv "$tmp/bend/bend2" "$tmp/bend/guide" "$HOME/.bend/"
mv "$tmp/bend/bin/bend" "$HOME/.bend/bin/bend"
