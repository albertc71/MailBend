#!/usr/bin/env sh
set -eu

command -v bend >/dev/null 2>&1 || {
  echo "bend is not installed" >&2
  exit 1
}

echo "Running MailBend Bend smoke test..."
bend main.bend
