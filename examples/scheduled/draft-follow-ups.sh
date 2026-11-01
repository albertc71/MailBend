#!/usr/bin/env bash

set -euo pipefail
recipe=drafts
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/common.sh"
export MAILBEND_DRAFTS_ONLY=1
: "${MAILBEND_RECIPE_QUEUE:?Set a private absolute MAILBEND_RECIPE_QUEUE}"
queue=$MAILBEND_RECIPE_QUEUE
[[ $queue = /* && -d $queue && $(realpath -e -- "$queue") = "$queue" &&
   $(stat -c '%u:%a' -- "$queue") = "$(id -u):700" ]] || fail 'Use a private, canonical queue directory of mode 700.'
mkdir -p -- "$state/claims"
shopt -s nullglob
export LC_ALL=C
for claim in "$state"/claims/*; do
    [[ -f $claim/done || -f $claim/reviewed ]] ||
        fail 'A draft claim needs review. Inspect Drafts and the private claim before another attempt.'
done
for job in "$queue"/*.json; do
    name=${job##*/}
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.json$ ]] || fail 'Use a short, stable alphanumeric job filename.'
    claim=$state/claims/$name
    if [[ -d $claim ]]; then
        continue
    fi
    [[ -f $job && ! -L $job && $(stat -c '%u:%a' -- "$job") = "$(id -u):600" ]] ||
        fail 'Each queued job must be a regular, non-symlink file you own of mode 600.'
    jq -sce '
        def uid: type == "number" and . == floor and . >= 1 and . <= 4294967295;
        if length == 1 then .[0] else error("Expected one draft job") end |
        if keys == ["body","folder","uid","uidvalidity"] and
           (.folder | type == "string" and length > 0) and
           (.uid | uid) and (.uidvalidity | uid) and (.body | type == "string")
        then . + {as_draft:true,reply_all:false} else error("Invalid draft job") end
    ' "$job" >"$work/request.json" || fail 'Invalid draft job. Nothing was attempted.'
    mkdir -- "$claim"
    cp -- "$work/request.json" "$claim/request.json"
    # Persist the claim before APPEND, even if its acknowledgement is later lost.
    sync -f "$state"
    "$bin" call mail_reply "$(cat "$claim/request.json")" >"$claim/result.json" 2>"$claim/error.txt" ||
        fail 'Draft outcome needs review. The claim remains and will not be retried.'
    jq -e '.ok == true and (.saved_to | type == "string") and
        (.uid == null or (.uid | type == "number" and . > 0)) and
        (.message_id | type == "string") and
        (has("sent") | not)' "$claim/result.json" >/dev/null ||
        fail 'Unconfirmed draft result. The claim remains and will not be retried.'
    touch "$claim/done"
    sync -f "$state"
    printf '%s\n' 'One draft saved for human review. Nothing was sent.'
    exit 0
done
printf '%s\n' 'No new queued draft.'
