#!/usr/bin/env sh
# Re-runnable Debian/Ubuntu install recipe for a durable MailBend clone.
# Run as the computer user; only apt needs root. No mail credentials needed.
set -eu
root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd -P)

fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

check_readiness() {
  . "$root/scripts/install-layout.sh"
  mb_root_open
  flock -sn 8 || fail "installation is busy; retry the readiness check"
  selected_bin=$root/bin
  if mb_marker; then
    mb_capture
    [ "$MB_KIND" != bootstrap ] || fail "installation is incomplete; rerun setup-cloud.sh"
    selected_bin=$MB_GENERATION
  elif [ -d "$root/bin" ] && [ ! -L "$root/bin" ]; then
    exec 9<"$root/bin"
    flock -sn 9 || fail "legacy installation is busy; retry the readiness check"
  fi
  # Run the binaries: surviving executables can lose their shared libraries
  # in an image rebuild. These local checks do not connect to mail.
  "$selected_bin/mailbend-tls" --check >/dev/null 2>&1 \
    || fail "TLS helper cannot run; rerun setup-cloud.sh"
  [ -x "$selected_bin/mailbend-attach" ] \
    || fail "attachment helper is missing; rerun setup-cloud.sh"
  "$selected_bin/mailbend-typesafe" --check >/dev/null 2>&1 \
    || fail "TypeSafe helper cannot run; rerun setup-cloud.sh"
  "$selected_bin/mailbend-stdio" --check >/dev/null 2>&1 \
    || fail "stdio helper cannot run; rerun setup-cloud.sh"
  [ -x "$selected_bin/mailbend-core" ] \
    || fail "compiled core is missing; rerun setup-cloud.sh"
  "$root/scripts/mailbend" tools >/dev/null 2>&1 \
    || fail "compiled core cannot run; rerun setup-cloud.sh"
  mb_root_same
  exec 8<&-
  exec 9<&-
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
# Rust 1.99 for the native helpers is not packaged by Debian or Ubuntu, so
# install.sh --install-rust installs it with a checksum-verified rustup.
as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential clang ca-certificates curl >&2
sh "$root/scripts/install.sh" --install-bend --install-rust >&2
sh "$root/scripts/setup-cloud.sh" --check || fail "installed binaries failed the readiness check"
printf 'mailbend: ready; use %s/scripts/mailbend-cloud call mail_probe\n' "$root" >&2
