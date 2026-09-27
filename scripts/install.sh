#!/usr/bin/env sh
# Builds MailBend in place:
#   bin/mailbend-tls   the TLS helper (C, OpenSSL)
#   bin/mailbend-core  the Bend core, compiled (needs clang 14+)
# and checks the safety proofs. Pass --install-bend to install Bend with its
# official installer (https://bend-lang.com/install.sh) when it is missing.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
export BEND_NO_TELEMETRY=1
PATH="$HOME/.bend/bin:$PATH"

say() { printf 'mailbend: %s\n' "$*"; }
fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

if ! command -v bend >/dev/null 2>&1; then
  if [ "${1:-}" = "--install-bend" ]; then
    say "installing Bend from https://bend-lang.com/install.sh"
    curl -fsSL https://bend-lang.com/install.sh | sh
  else
    fail "Bend is not installed. Run: curl -fsSL https://bend-lang.com/install.sh | sh
      (or rerun this script with --install-bend)"
  fi
fi

command -v cc >/dev/null 2>&1 || fail "a C compiler is needed (apt-get install build-essential)"
printf '#include <openssl/ssl.h>\nint main(void){return 0;}\n' > /tmp/mailbend-ssl-check.c
cc /tmp/mailbend-ssl-check.c -o /tmp/mailbend-ssl-check -lssl -lcrypto 2>/dev/null \
  || fail "OpenSSL headers are needed (apt-get install libssl-dev)"
rm -f /tmp/mailbend-ssl-check.c /tmp/mailbend-ssl-check

mkdir -p bin
say "building bin/mailbend-tls"
cc -std=c11 -O2 -Wall -Wextra -o bin/mailbend-tls native/mailbend-tls.c -lssl -lcrypto

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
