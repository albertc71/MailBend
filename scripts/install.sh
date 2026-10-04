#!/usr/bin/env sh
# Builds MailBend in place:
#   bin/mailbend-tls     the TLS helper (C, OpenSSL, libcurl)
#   bin/mailbend-attach  the attachment reader (C, no credentials)
#   bin/mailbend-core    the Bend core, compiled (needs clang 14+)
# and checks the safety proofs. Pass --install-bend to install the pinned,
# checksum-verified Bend release (scripts/install-bend.sh) when it is missing.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
export BEND_NO_TELEMETRY=1
PATH="$HOME/.bend/bin:$PATH"

say() { printf 'mailbend: %s\n' "$*"; }
fail() { printf 'mailbend: %s\n' "$*" >&2; exit 1; }

if ! command -v bend >/dev/null 2>&1; then
  if [ "${1:-}" = "--install-bend" ]; then
    sh scripts/install-bend.sh
  else
    fail "Bend is not installed. Rerun this script with --install-bend"
  fi
fi

command -v cc >/dev/null 2>&1 || fail "a C compiler is needed (apt-get install build-essential)"
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
cat > "$probe/check.c" <<'EOF'
#include <openssl/ssl.h>
#include <curl/curl.h>
#if LIBCURL_VERSION_NUM < 0x074c00
#error libcurl 7.76+ required
#endif
int main(void) { return 0; }
EOF
cc "$probe/check.c" -o "$probe/check" -lssl -lcrypto -lcurl 2>/dev/null \
  || fail "OpenSSL and libcurl 7.76+ headers are needed (apt-get install libssl-dev libcurl4-openssl-dev)"

mkdir -p bin
say "building bin/mailbend-tls"
cc -std=c11 -O2 -Wall -Wextra -o bin/mailbend-tls native/mailbend-tls.c -lssl -lcrypto -lcurl
say "building bin/mailbend-attach"
cc -std=c11 -O2 -Wall -Wextra -o bin/mailbend-attach native/mailbend-attach.c

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
