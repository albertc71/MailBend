#!/usr/bin/env bash

set -euo pipefail
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }

: "${MAILBEND_EMAIL:?Set MAILBEND_EMAIL}"
: "${MAILBEND_PASSWORD_FILE:?Set MAILBEND_PASSWORD_FILE}"
: "${MAILBEND_RECIPE_STATE:?Set a private absolute MAILBEND_RECIPE_STATE}"
[[ $MAILBEND_PASSWORD_FILE = /* ]] || fail 'Use an absolute password-file path.'
[[ ! ${MAILBEND_APP_PASSWORD+x} ]] || fail 'Unset MAILBEND_APP_PASSWORD; use only the password file.'
export MAILBEND_TYPESAFE=0

state=$MAILBEND_RECIPE_STATE
[[ $state = /* && ! -L $state ]] || fail 'Use an absolute, non-symlink state directory.'
mkdir -p -m 700 -- "$state"
[[ $(realpath -e -- "$state") = "$state" && $(stat -c '%u:%a' -- "$state") = "$(id -u):700" ]] ||
    fail 'The state directory must be canonical, owned by you, and mode 700.'
exec 9>"$state/lock"
flock -n 9 || exit 0
work=$(mktemp -d "$state/.run.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
bin=${MAILBEND_BIN:-"$script_dir/../../scripts/mailbend"}

jq -n --arg email "$MAILBEND_EMAIL" --arg host "${MAILBEND_IMAP_HOST:-imap.mail.me.com}" \
    --arg port "${MAILBEND_IMAP_PORT:-993}" --arg recipe "$recipe" \
    '{email:$email,host:$host,port:$port,recipe:$recipe}' >"$work/identity.json"
if [[ -e $state/identity.json ]]; then
    cmp -s "$state/identity.json" "$work/identity.json" ||
        fail 'Account, endpoint, or recipe changed. Use a separate state directory.'
else
    mv -T -- "$work/identity.json" "$state/identity.json"
    sync -f "$state"
fi
