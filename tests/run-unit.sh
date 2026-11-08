#!/usr/bin/env sh
# Keep the shell entry point for existing callers.
set -eu
cd "$(dirname "$0")/.."
export BEND_NO_TELEMETRY=1
exec python3 tests/run-unit.py "$@"
