#!/usr/bin/env sh
# Scans the working tree and the whole git history for secrets with a pinned,
# sha256-verified gitleaks (rules: .gitleaks.toml). Findings are redacted and
# fail the run. CI runs this; contributors can too (Linux x64 only).
set -eu
GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || fail "the pinned gitleaks release is Linux x64 only"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is needed (coreutils)"

name="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$name" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/$name"
echo "${GITLEAKS_SHA256}  $tmp/$name" | sha256sum -c - >/dev/null \
  || fail "gitleaks archive checksum mismatch"
tar -xzf "$tmp/$name" -C "$tmp" gitleaks

cd "$root"
"$tmp/gitleaks" dir --config .gitleaks.toml --redact --no-banner .
"$tmp/gitleaks" git --config .gitleaks.toml --redact --no-banner --log-opts="--all" .
