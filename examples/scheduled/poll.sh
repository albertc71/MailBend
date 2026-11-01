#!/usr/bin/env bash

set -euo pipefail
[[ $# = 1 && ( $1 = brief || $1 = notify ) ]] || { echo 'Usage: poll.sh brief|notify' >&2; exit 2; }
mode=$1
recipe=$mode
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$script_dir/common.sh"
export MAILBEND_READ_ONLY=1
folder=${MAILBEND_RECIPE_FOLDER:-INBOX}
checkpoint=$state/checkpoint.json

if [[ ! -e $checkpoint ]]; then
    args=$(jq -nc --arg folder "$folder" '{folder:$folder,limit:1}')
    "$bin" call mail_search "$args" >"$work/page.json" 2>"$work/error.txt" ||
        fail 'Checkpoint seed failed. No checkpoint was saved.'
    jq -e --arg folder "$folder" '
        def uid: type == "number" and . == floor and . >= 1 and . <= 4294967295;
        .folder == $folder and (.uidvalidity | uid) and
        ((.total == 0 and .messages == []) or
         (.total > 0 and (.messages | length) == 1 and (.messages[0].uid | uid)))
    ' "$work/page.json" >/dev/null || fail 'Invalid or vanished seed message. Run again to seed.'
    jq '{folder,uidvalidity,since_uid:(.messages[0].uid // 0)}' "$work/page.json" >"$work/checkpoint.json"
    mv -T -- "$work/checkpoint.json" "$checkpoint"
    sync -f "$state"
    printf '%s\n' 'Checkpoint seeded. Existing mail was not reported.'
    exit 0
fi

jq -e --arg folder "$folder" '
    def uint: type == "number" and . == floor and . >= 0 and . <= 4294967295;
    .folder == $folder and (.uidvalidity | uint and . > 0) and (.since_uid | uint)
' "$checkpoint" >/dev/null || fail 'Invalid checkpoint or different folder. Keep the file and reconcile it.'
args=$(jq -c '. + {limit:50}' "$checkpoint")
"$bin" call mail_get_new "$args" >"$work/page.json" 2>"$work/error.txt" ||
    fail 'Read failed. The checkpoint is unchanged.'
jq -e --slurpfile old "$checkpoint" '
    def uint: type == "number" and . == floor and . >= 0 and . <= 4294967295;
    . as $page |
    .folder == $old[0].folder and .uidvalidity == $old[0].uidvalidity and
    .uidvalidity_changed == false and (.has_more | type == "boolean") and
    (.next_since_uid | uint) and .next_since_uid >= $old[0].since_uid and
    (.messages | type == "array") and all(.messages[];
        (.uid | uint) and .uid > $old[0].since_uid and .uid <= $page.next_since_uid)
' "$work/page.json" >/dev/null || fail 'Mailbox identity changed or response is invalid. Keep the checkpoint and reconcile it.'
count=$(jq '.messages | length' "$work/page.json")
if [[ $mode = notify && $count != 0 ]]; then
    notify-send -- 'MailBend' "$count new messages in the next batch" ||
        fail 'Notification failed. The checkpoint is unchanged.'
elif [[ $mode = brief ]]; then
    page=$(jq -r --slurpfile old "$checkpoint" '
        "\(.uidvalidity)-\($old[0].since_uid)-\(.next_since_uid).txt"' "$work/page.json")
    jq -r '"MailBend arrival batch", "", (.messages[] |
        "UID \(.uid) | \(.from | @json) | \(.subject | @json)"),
        "", "More batches waiting: \(.has_more)"' "$work/page.json" >"$work/brief.txt"
    mv -T -- "$work/brief.txt" "$state/$page"
    sync -f "$state"
fi
jq '{folder,uidvalidity,since_uid:.next_since_uid}' "$work/page.json" >"$work/checkpoint.json"
mv -T -- "$work/checkpoint.json" "$checkpoint"
sync -f "$state"
printf '%s\n' 'Batch completed.'
