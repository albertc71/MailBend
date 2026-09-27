#!/usr/bin/env sh
# Development-only connectivity proof. Does not print the password and does
# not fetch or mutate any message. Remove this shell probe once the Bend
# transport adapter owns the exchange.
set -eu

: "${MAILBEND_EMAIL:?MAILBEND_EMAIL is required}"
: "${MAILBEND_APP_PASSWORD:?MAILBEND_APP_PASSWORD is required}"

IMAP_HOST="${MAILBEND_IMAP_HOST:-imap.mail.me.com}"
IMAP_PORT="${MAILBEND_IMAP_PORT:-993}"

# IMAP quoted strings need backslash and quote escaping.
escape_imap() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

USER_Q=$(escape_imap "$MAILBEND_EMAIL")
PASS_Q=$(escape_imap "$MAILBEND_APP_PASSWORD")

# Commands are generated in-process; the password never appears in argv.
{
  printf 'a001 LOGIN "%s" "%s"\r\n' "$USER_Q" "$PASS_Q"
  printf 'a002 CAPABILITY\r\n'
  printf 'a003 LIST "" "*"\r\n'
  printf 'a004 LOGOUT\r\n'
} | openssl s_client \
      -quiet \
      -verify_return_error \
      -verify_hostname "$IMAP_HOST" \
      -connect "$IMAP_HOST:$IMAP_PORT"
