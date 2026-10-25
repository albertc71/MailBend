#!/usr/bin/env sh
# Builds MailBend in place:
#   bin/mailbend-tls       the TLS helper (Rust, rustls)
#   bin/mailbend-attach    the attachment helper (Rust, no credentials)
#   bin/mailbend-typesafe  the TypeSafe helper (Rust, rustls; only it reads
#                          the TypeSafe key)
#   bin/mailbend-core      the Bend core, compiled (needs clang 14+)
#   bin/mailbend-stdio     inherited stdin adapter for MCP (Rust)
# and checks the safety proofs. Pass --install-bend to install the pinned,
# checksum-verified Bend release (scripts/install-bend.sh) when it is missing,
# and --install-rust to install Rust 1.99 with a checksum-verified rustup
# (scripts/install-rust.sh) when no cargo 1.99+ is found.
#
# Nothing in bin/ changes until everything is built and checked: each
# binary is staged as bin/NAME.new.<pid>, the helpers' --check runs on those
# copies, the safety proofs are checked and the core is compiled to its own
# copy, and only then are all five renamed into place. One install runs at
# a time; it needs util-linux flock and coreutils sync.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
trap 'rm -f bin/*.new.$$' EXIT
# dash skips the EXIT trap when a signal ends it, so each signal exits
# through it.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
export BEND_NO_TELEMETRY=1
PATH="$HOME/.bend/bin:$HOME/.cargo/bin:$PATH"

say() { printf 'mailbend: %s\n' "$*"; }
fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

helpers="mailbend-tls mailbend-attach mailbend-typesafe mailbend-stdio"

# cp opens its destination with O_TRUNC, and the kernel rejects that with
# ETXTBSY while the file is executed, so a binary is staged as a sibling
# and renamed over its destination, which does not open the running inode.
stage_bin() {
  cp "$1" "$2.new.$$"
}

# The staged file's data reaches the disk before the rename, so a power
# loss leaves the old file or the new one, never a short one; bin/ itself
# is synced once after the last rename.
publish_bin() {
  sync -- "$1.new.$$"
  mv -f "$1.new.$$" "$1"
}

publish_helpers() {
  for name in $helpers; do
    publish_bin "bin/$name"
  done
}

install_bend=0 install_rust=0
for arg in "$@"; do
  case "$arg" in
    --install-bend) install_bend=1 ;;
    --install-rust) install_rust=1 ;;
    *) fail "usage: install.sh [--install-bend] [--install-rust]" ;;
  esac
done

if ! command -v bend >/dev/null 2>&1; then
  if [ "$install_bend" = 1 ]; then
    sh scripts/install-bend.sh
  else
    fail "Bend is not installed. Rerun this script with --install-bend"
  fi
fi

# The minor version of the native helpers' MSRV, Rust 1.99 (rust-version in
# native/Cargo.toml).
rust_minor=99
# Whether a "<tool> 1.N.x ..." version line is at least the MSRV.
at_least_msrv() {
  minor=$(printf '%s\n' "$1" | sed -n 's/^[a-z]* 1\.\([0-9][0-9]*\)\..*/\1/p')
  [ -n "$minor" ] && [ "$minor" -ge "$rust_minor" ]
}
# Uses cargo $1 with rustc $2 if both meet the MSRV. Asked from native/ so
# rustup's proxies report the toolchain native/rust-toolchain.toml pins.
try_cargo() {
  cargo_version=$(CDPATH= cd native && "$1" --version 2>/dev/null) || return 1
  rustc_version=$(CDPATH= cd native && "$2" --version 2>/dev/null) || return 1
  at_least_msrv "$cargo_version" && at_least_msrv "$rustc_version" || return 1
  cargo=$1 RUSTC=$2
  export RUSTC
}
# $CARGO if set, else cargo (rustup).
find_cargo() {
  try_cargo "${CARGO:-cargo}" "${RUSTC:-rustc}"
}
if ! find_cargo; then
  if [ "$install_rust" = 1 ]; then
    sh scripts/install-rust.sh
    find_cargo || fail "Rust 1.$rust_minor was installed but cargo still cannot be used"
  else
    fail "cargo and rustc 1.$rust_minor+ are needed for the native helpers. Rerun this script with --install-rust"
  fi
fi

# ring (the TLS helper's cryptography) is partly C, built by cargo.
command -v cc >/dev/null 2>&1 || fail "a C compiler is needed (apt-get install build-essential)"

mkdir -p bin
# The lock is on bin/ itself, so it adds no file there, and it holds across
# PID namespaces that share the checkout, where two installs could have the
# same pid. Under it, siblings left by an install that was killed outright
# are removed.
exec 9<bin
flock -n 9 || fail "another install is running in $root; rerun this script when it ends"
rm -f bin/*.new.*

say "building native helpers ($rustc_version)"
# Build from native/: rustup finds rust-toolchain.toml from the working
# directory, not from --manifest-path.
(CDPATH= cd native && "$cargo" build --release --locked --quiet -p mailbend-tls -p mailbend-attach -p mailbend-typesafe -p mailbend-stdio)
for name in $helpers; do
  stage_bin "native/target/release/$name" "bin/$name"
done
"bin/mailbend-tls.new.$$" --check || fail "the built TLS helper cannot run"
"bin/mailbend-typesafe.new.$$" --check || fail "the built TypeSafe helper cannot run"
"bin/mailbend-stdio.new.$$" --check || fail "the built stdio helper cannot run"

say "checking the safety laws (bend PROOF.bend)"
bend PROOF.bend

if command -v clang >/dev/null 2>&1; then
  say "compiling the Bend core (takes about a minute)"
  core_tmp="bin/mailbend-core.new.$$"
  if bend main.bend -o "$core_tmp" 2>/dev/null || bend main.bend -o "$core_tmp"; then
    publish_helpers
    publish_bin bin/mailbend-core
  else
    exit 1
  fi
else
  # Without clang there is no new core, so the new helpers are published
  # beside the core already there, if any.
  publish_helpers
  if [ -x bin/mailbend-core ]; then
    printf '%s\n' \
      'mailbend: warning: clang not found; keeping existing bin/mailbend-core.' \
      'mailbend: the launcher will use it, and it may be out of date. Install clang and rerun.' >&2
  else
    say "clang not found: scripts/mailbend will run main.bend through bend (slower start)"
  fi
fi
sync -- bin

say "done. Test it with: scripts/mailbend call mail_probe"
say "MCP command: $root/scripts/mailbend mcp"
# The core starts the helpers by path on every call, so a running server
# already uses the new helpers with its old core.
say "restart any MCP server already running, so its core matches the new helpers"
