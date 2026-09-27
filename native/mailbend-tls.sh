#!/usr/bin/env sh
# Minimal TLS transport used by the prototype.
# Secrets are read from the environment and never passed as argv.
set -eu

: "${MAILBEND_EMAIL:?MAILBEND_EMAIL is required}"
: "${MAILBEND_APP_PASSWORD:?MAILBEND_APP_PASSWORD is required}"

IMAP_HOST="${MAILBEND_IMAP_HOST:-imap.mail.me.com}"
IMAP_PORT="${MAILBEND_IMAP_PORT:-993}"

# OpenSSL verifies the certificate chain and hostname. -quiet keeps protocol
# traffic clean enough for the Bend-side IMAP state machine.
exec openssl s_client \
  -quiet \
  -verify_return_error \
  -verify_hostname "$IMAP_HOST" \
  -connect "$IMAP_HOST:$IMAP_PORT"
