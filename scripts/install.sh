#!/usr/bin/env sh
# Builds MailBend in place:
#   bin/mailbend-tls     the TLS helper (Rust, rustls)
#   bin/mailbend-attach  the attachment reader and send counter (Rust, no credentials)
#   bin/mailbend-core    the Bend core, compiled (needs clang 14+)
# and checks the safety proofs. Pass --install-bend to install the pinned,
# checksum-verified Bend release (scripts/install-bend.sh) when it is missing,
# and --install-rust to install Rust 1.99 with a checksum-verified rustup
# (scripts/install-rust.sh) when no cargo 1.99+ is found.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
export BEND_NO_TELEMETRY=1
PATH="$HOME/.bend/bin:$HOME/.cargo/bin:$PATH"

say() { printf 'mailbend: %s\n' "$*"; }
fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

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
say "building bin/mailbend-tls and bin/mailbend-attach ($rustc_version)"
# Build from native/: rustup finds rust-toolchain.toml from the working
# directory, not from --manifest-path.
(CDPATH= cd native && "$cargo" build --release --locked --quiet -p mailbend-tls -p mailbend-attach)
cp native/target/release/mailbend-tls bin/mailbend-tls
cp native/target/release/mailbend-attach bin/mailbend-attach
bin/mailbend-tls --check || fail "the built TLS helper cannot run"

say "checking the safety laws (bend PROOF.bend)"
bend PROOF.bend

if command -v clang >/dev/null 2>&1; then
  say "compiling the Bend core to bin/mailbend-core (takes about a minute)"
  bend main.bend -o bin/mailbend-core 2>/dev/null || bend main.bend -o bin/mailbend-core
else
  say "clang not found: scripts/mailbend will run main.bend through bend (slower start)"
fi

say "done. Test it with: scripts/mailbend call mail_probe"
say "MCP command: $root/scripts/mailbend mcp"
