#!/usr/bin/env sh
# Installs the pinned Bend release to ~/.bend (bin/bend, bend2, guide),
# verifying the archive's sha256 before unpacking. This is the one place the
# tested Bend version is pinned; CI and scripts/install.sh both use it.
# Linux x86_64 and aarch64 releases are pinned.
set -eu
BEND_VERSION=2.0.35

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

# Digests come from the pinned upstream release, not the running machine.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    target=x64
    BEND_SHA256=63039d1a119f716767ac5a7d8fe0717cfacf219c6c253c35192148e0dade722f
    ;;
  Linux-aarch64)
    target=arm64
    BEND_SHA256=09b813073241628f590f2c2fe420299ec25e4dddd6cf3fdc49c9486339989564
    ;;
  *) fail "this installer supports only Linux x86_64 and aarch64" ;;
esac
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is needed (coreutils)"

name="bend-${BEND_VERSION}-linux-${target}.tar.gz"
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
