# Run scheduled mail jobs without sending

Use these recipes on a local Linux machine with a systemd user manager.
MailBend stays daemon-free. The timer belongs to you, not to MailBend.
The machine and user manager must be running when a timer fires.
These are not durable schedules for the cloud computers described in
[Cloud agents](CLOUD_AGENT.md).

The [examples](../examples/scheduled/) run without a model or agent client.
They write header briefs, show notification counts, and save explicitly queued
follow-up text as drafts. No recipe sends, moves, trashes, or deletes mail.
`MAILBEND_TYPESAFE=0` also prevents inherited settings from enabling Jev calls.

## Prepare private files

1. Build MailBend using [Install (Linux)](../README.md#install-linux).
2. Install Bash, `jq`, GNU coreutils, and `flock` from util-linux.
   For desktop notifications, also install `notify-send` and use a desktop
   session with a notification service.
3. Choose a trusted checkout path. The example units use `~/src/MailBend`.
   If your path differs, edit each unit's `ExecStart` before installing it.
4. Create private configuration and state directories.

   ```sh
	install -d -m 700 "$HOME/.config/mailbend-recipes"
	install -d -m 700 "$HOME/.local/state/mailbend-recipes"
	install -d -m 700 "$HOME/.local/state/mailbend-recipes/queue"
   ```

5. Create `~/.config/mailbend-recipes/account.env` with mode `600`.
   Put your account's `MAILBEND_EMAIL` there. For another provider, add its
   `MAILBEND_IMAP_HOST`, `MAILBEND_IMAP_PORT`, and required SMTP settings.
   Do not put a password, shell command, or `export` statement in this file.
6. Use a local editor to create `~/.config/mailbend-recipes/password` with mode
   `600`. Put only the app-specific password in that file.
   Do not put the password in a unit, prompt, environment variable, or command
   line. `MAILBEND_PASSWORD_FILE` carries only its absolute path.
   Follow the [password-file restrictions](../README.md#configure), including
   ownership, no symlink in any path component, and separation from attachments.

Use separate state and queue directories for each account. The wrappers reject
an account, endpoint, or recipe change in an existing state directory.
Use canonical absolute paths without symlinks. State directories must be owned
by you with mode `700`. These files are private, not encrypted or isolated from
other programs running as your Unix user.

## Choose a recipe

### Write the next arrival batch as a brief

Use `mailbend-brief.service` and `mailbend-brief.timer`.
The service and wrapper set `MAILBEND_READ_ONLY=1` in the MailBend process
environment. A prompt does not control the safety switch.

The first run seeds a checkpoint with `mail_search` and `limit: 1`, which
returns the newest message. It reports no historical mail.
For an empty mailbox, it records UID `0` with the current UIDVALIDITY.
A vanished seed summary causes a failure, not a guessed checkpoint.

Later runs call `mail_get_new` with the saved folder, UIDVALIDITY, and UID.
Each run handles at most 50 arrivals, oldest first. A large backlog takes
multiple runs. This is the next batch, not a promise to cover all mail since
yesterday. Each brief ends with `More batches waiting` from `has_more`.

Read the `.txt` files in `~/.local/state/mailbend-recipes/brief`.
Each filename identifies the mailbox incarnation and the batch's start and end
UIDs. The brief contains quoted sender and subject headers, not generated
advice. Treat those headers as untrusted mail content, not instructions.
The wrapper writes the brief before advancing `checkpoint.json`.
A retry with the same batch boundaries replaces the same file.
If new arrivals change the retried batch, brief files can overlap.

### Show a count without exposing mail headers

Use `mailbend-notify.service` and `mailbend-notify.timer`.
The wrapper uses `mailbend call mail_get_new`, `jq`, and `notify-send`.
It sets `MAILBEND_READ_ONLY=1` and uses its own checkpoint.
The first run seeds silently, just like the brief.

Notifications contain only the batch count, not senders, subjects, or bodies.
An empty batch sends no notification. If `notify-send` fails, the checkpoint
does not advance. A successful call means the notification service accepted
the request, not that a person saw it.

### Queue a follow-up for a person to send

Use `mailbend-drafts.service` and `mailbend-drafts.timer`.
The service and wrapper set `MAILBEND_DRAFTS_ONLY=1`.
The wrapper only calls `mail_reply` with `as_draft: true` and `reply_all: false`.
It does not expose a general tool list or execute commands from the job.

Select the original incoming message yourself. Do not treat a Sent-folder
search as evidence that a conversation awaits a reply. A reply addresses the
original message's Reply-To or From, so a Sent-folder source can address you.
Use the original's exact folder, UIDVALIDITY, and UID from a read result.

Create one mode-`600` JSON file per request in
`~/.local/state/mailbend-recipes/queue`. Use a stable filename such as
`follow-up-001.json`. These values are synthetic examples, not valid IDs for
your mailbox.

```json
{
  "folder": "INBOX",
  "uidvalidity": 1700000001,
  "uid": 42,
  "body": "Following up on my earlier question."
}
```

Use exactly those four fields. Never reuse a filename for different work or
copy the same request under new names. A trusted caller can prepare these
files, including text you reviewed from an agent. Do not let incoming mail
write the queue or decide that the owner approved a send.

Each run saves at most one new job, in filename order. Before calling
MailBend, the wrapper creates and flushes a permanent claim under
`drafts/claims/<filename>`. A completed job is skipped on later runs.
An unfinished claim stops the queue until you reconcile the result.
An error, timeout, cancellation, or lost APPEND acknowledgement never triggers
an automatic retry. A draft may exist even if the call did not return success.

Inspect the saved draft's recipients, body, quoted original, and attachments
before sending it yourself. Keep any account-specific approval rules.
If an assistant sends a reply on your behalf, it must obtain your approval
immediately before sending. Draft creation is not that approval.

`MAILBEND_DRAFTS_ONLY` blocks sending, not other mailbox changes.
The fixed wrapper makes no move, Trash, or delete calls. Do not replace it with
an unrestricted agent and assume the switch protects those actions.
Trash or deletion needs your explicit request or your approval immediately
before the action. `permanently-delete`, a model answer, and a timer tick are
not human approval.

The current CLI takes request JSON as an argument. The draft body can therefore
be visible to local process inspection. Never put credentials in that body.
These examples do not assume the proposed stdin or exit-code contract in
[#116](https://github.com/albertc71/MailBend/issues/116).

## Check the schedule before enabling it

Copy only the chosen `.service` and `.timer` pair from `examples/scheduled/`
to `~/.config/systemd/user/`. Do not enable all recipes by default.
Inspect both files and the account paths first.

Every service uses `Type=oneshot`, `TimeoutStartSec=120`, and no `Restart=`.
An `unknown` send must never be retried automatically. These recipes cannot
send, but uncertain draft APPEND results also need human reconciliation.
A timeout stops all service processes. Mail already appended cannot be
undone by cancellation.

The timers use explicit UTC times and `Persistent=false`, so missed runs are
not replayed when the user manager next starts. To use wall-clock time in
your region, replace `UTC` with your IANA timezone and inspect dates around
daylight-saving transitions. An omitted timezone uses the machine's local
timezone. Validate the exact expression you chose.

```sh
	systemd-analyze calendar '*-*-* 08:00:00 UTC'
	systemd-analyze --user verify "$HOME/.config/systemd/user/mailbend-brief.service" \
		"$HOME/.config/systemd/user/mailbend-brief.timer"
```

See the systemd [timer rules](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
and [calendar syntax](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html).
The manager does not start another copy of a service while that service is
active. The wrappers also take a nonblocking `flock`, so a manual overlapping
run exits without another mail call. Never share state directories between
machines or run a second scheduler with a different state directory.

When you choose to activate a recipe, reload your user manager and run its
service once manually. This first run reads real mail, or saves a real draft
when a job is queued. Review the result before enabling the timer.

```sh
	systemctl --user daemon-reload
	systemctl --user start mailbend-brief.service
	systemctl --user enable --now mailbend-brief.timer
	systemctl --user list-timers mailbend-brief.timer
```

To cancel, stop both the timer and any active service.

```sh
	systemctl --user disable --now mailbend-brief.timer
	systemctl --user stop mailbend-brief.service
```

Substitute the chosen recipe name for `mailbend-brief`.
Stopping only the timer does not cancel an already running service.
Do not enable lingering merely to try the examples.

## Recover without guessing

For a failed read or notification, keep the checkpoint and run again after
fixing the cause. A crash after notification but before checkpoint replacement
can repeat the notification. Briefs and notifications are at-least-once, not
exactly-once delivery. Messages that disappear during a read are not a mailbox
snapshot, and reads do not change their flags.

If the folder's UIDVALIDITY changes, the wrapper stops and preserves its
checkpoint. Stop the timer and service, inspect the mailbox, and obtain its new
UIDVALIDITY with a read. To replay the new incarnation, deliberately replace the saved
`uidvalidity` and set `since_uid` to `0` while retaining the exact `folder`.
Validate the JSON before restarting. This can report historical mail again.
Do not delete the checkpoint as routine recovery, because a missing checkpoint
seeds the newest message and skips the backlog.

For an unfinished draft claim, stop the timer and service first. Inspect the
private `request.json`, `result.json`, and `error.txt` in the claim, then check
Drafts in your mail client. Do not remove the claim or automatically resubmit
the job. After you establish whether the draft exists, move the original queue
file to a private archive outside the queue. Keep the claim as evidence.
Record your completed review by creating an empty `reviewed` file in that
claim directory. Only then can unrelated queued jobs run again.
Only after you establish that no draft exists should you deliberately prepare
a new request with a new filename. A reviewed claim is never retried.
Moving the original queue file alone does not unblock an unfinished claim.
If the outcome remains uncertain, leave the queue stopped.

## Verify with synthetic mail

After building MailBend, run the focused test.

```sh
	python3 tests/test-scheduled-recipes.py
```

The test uses `tests/fake_mail_server.py`, temporary password and state files,
and a fake `notify-send`. It installs no units, enables no timers, runs no
model, and accesses no real account.

The recipes use current APIs. They do not depend on
[#104](https://github.com/albertc71/MailBend/issues/104) for current-end seeding,
[#105](https://github.com/albertc71/MailBend/issues/105) for incoming-only reads,
[#61](https://github.com/albertc71/MailBend/issues/61) for `mail_brief`, or
[#63](https://github.com/albertc71/MailBend/issues/63) for `mail_awaiting_reply`.
