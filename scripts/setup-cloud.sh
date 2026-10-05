#!/usr/bin/env sh
# Re-runnable Debian/Ubuntu install recipe for a durable MailBend clone.
# Run as the computer user; only apt needs root. No mail credentials needed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

check_readiness() {
  # Run the binaries: surviving executables can lose their shared libraries
  # in an image rebuild. These local checks do not connect to mail.
  "$root/bin/mailbend-tls" --check >/dev/null 2>&1 \
    || fail "TLS helper cannot run; rerun setup-cloud.sh"
  [ -x "$root/bin/mailbend-attach" ] \
    || fail "attachment helper is missing; rerun setup-cloud.sh"
  [ -x "$root/bin/mailbend-core" ] \
    || fail "compiled core is missing; rerun setup-cloud.sh"
  "$root/scripts/mailbend" tools >/dev/null 2>&1 \
    || fail "compiled core cannot run; rerun setup-cloud.sh"
}

case "${1:-}" in
  --check)
    [ "$#" -eq 1 ] || fail "usage: setup-cloud.sh [--check]"
    check_readiness
    exit 0
    ;;
  '') [ "$#" -eq 0 ] || fail "usage: setup-cloud.sh [--check]" ;;
  *) fail "usage: setup-cloud.sh [--check]" ;;
esac

[ "$(uname -s)" = Linux ] || fail "cloud setup supports Debian/Ubuntu Linux"
command -v apt-get >/dev/null 2>&1 || fail "apt-get is required; see docs/CLOUD_AGENT.md for manual installation"
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}
# Do not re-run the whole script with sudo: Bend belongs in the user's home.
as_root env DEBIAN_FRONTEND=noninteractive apt-get update >&2
# Rust 1.85 for the native helpers: Ubuntu 24.04 packages it as cargo-1.85;
# elsewhere install.sh installs it with a checksum-verified rustup.
rust_pkg=
if apt-cache show cargo-1.85 >/dev/null 2>&1; then rust_pkg=cargo-1.85; fi
as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential libssl-dev libcurl4-openssl-dev clang ca-certificates curl $rust_pkg >&2
sh "$root/scripts/install.sh" --install-bend --install-rust >&2
sh "$root/scripts/setup-cloud.sh" --check || fail "installed binaries failed the readiness check"
printf 'mailbend: ready; use %s/scripts/mailbend-cloud call mail_probe\n' "$root" >&2
