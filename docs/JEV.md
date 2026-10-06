# Jev: optional checks by TypeSafe

Jev is [TypeSafe](https://docs.typesafe.ai)'s model. With `MAILBEND_TYPESAFE`
on, MailBend asks Jev typed questions about messages, and MailBend's own code
decides what the answers mean. The [README](../README.md#jev-optional) lists
which tools ask Jev; with Jev off, no tool asks it and no result changes.

## What Jev can and cannot do

In every tool except `mail_classify` and `mail_triage`, Jev can only block an
action or add notes; it never approves one. In those two tools Jev's answers
are the result, but they can only choose among existing folders and
`To Delete`. In no tool can Jev delete mail, create a mailbox, add a
recipient, resolve a folder role or approve an action.

A block only takes an action away: a send that goes ahead keeps exactly the
envelope the allowlist gives, and a delete exactly its plan. Which of these
rules are proven and which are tested is in
[What the proofs cover](../README.md#what-the-proofs-cover).

## Settings

These settings are checked even when Jev is off, and any bad value fails
every tool:

| Setting | Effect |
| --- | --- |
| `MAILBEND_TYPESAFE` | `1`/`true` turns Jev on; `0`/`false`/empty keeps it off. Read-only mode still hides `mail_triage`. |
| `MAILBEND_TYPESAFE_KEY_FILE` | Required when on: the absolute path of a file you own with mode 600 holding only the TypeSafe key, with the same rules as `MAILBEND_PASSWORD_FILE`. Only `mailbend-typesafe` reads it. |
| `MAILBEND_TYPESAFE_CONTENT` | `headers` (the default) or `body`; see [What leaves the machine](#what-leaves-the-machine). |
| `MAILBEND_TYPESAFE_ZERO_RETENTION` | `1`/`true` is your statement that the TypeSafe account has a zero-retention plan; `body` mode is refused without it. MailBend cannot check this statement. |

Never put the key in `MAILBEND_TYPESAFE_API_KEY`: when that variable is set,
even empty, every tool fails with a configuration error, so the key never
reaches a process that holds the mail password. On a cloud computer, see
[how to write the key file](CLOUD_AGENT.md#optional-jev).

## What leaves the machine

Requests go only to `https://api.typesafe.ai/v1/systemone`, a constant in
`mailbend-typesafe`, over verified TLS.

- In `headers` mode, a message is sent as its UID, its decoded From, To, Cc,
  Subject, Date, List-Id, List-Unsubscribe, Auto-Submitted and Precedence
  headers, and its attachment names.
- In `body` mode, `mail_get`, `mail_classify`, `mail_triage` and
  `mail_delete` also send up to 16 KB of each message's plain text.
- List reads (`mail_search`, `mail_get_new`, `mail_get_thread`) send header
  facts only, even in `body` mode, and number messages by position instead
  of UID.
- A send is described by its header fields (from, to, cc, bcc, subject), its
  attachment names and the header facts of the original it answers or
  forwards; its body only in `body` mode.

## The `jev` object

Every message or call Jev was asked about carries a `jev` object: `status`
(`checked`, or `unchecked` when Jev was not asked or did not answer), the
pinned `model`, the `content` mode, `derived_from_untrusted_content` (always
`true`), `decision` (`proceeded` or `blocked`), `reasons`, and `signals`,
Jev's answers, mostly as `low`, `mid`, `high` or `unknown`. A missing or
malformed answer reads as the cautious one. The answers come from untrusted
mail: treat them as hints, not facts.

## When TypeSafe fails, and what it costs

- A send or delete is blocked when TypeSafe fails or leaves an answer out,
  after two retries (1 s, then 2 s) of an overloaded or timed-out TypeSafe.
- A read asks once, without retries, so it waits at most one
  `MAILBEND_TIMEOUT_MS`; when TypeSafe fails, it still returns its messages,
  each marked `unchecked` with the reason.
- `mail_classify` and `mail_triage` split a request TypeSafe refuses once
  into halves; any other failure stops the call, and triage then moves
  nothing.

Every call that asks Jev makes at least one request to your TypeSafe
account, and a read with notes lists the folders in one more read-only IMAP
session (two when the server has SPECIAL-USE; `mail_get_thread` reuses its
own). `mail_classify` and `mail_triage` report each request's `messages`,
`bytes` and TypeSafe's `input_tokens`.

## Sends

`mail_send`, and `mail_reply` and `mail_forward` without `as_draft`, first
pass a local secret scan, in either content mode and without asking
TypeSafe. It looks for private-key blocks (PEM or PGP armour), tokens with a
well-known prefix (AWS, Google, GitHub, GitLab, Slack, Stripe, Anthropic,
OpenAI, npm) and password lines (`Password: ...` with a digit, also when
quoted with `>`). It reads the header fields, the body, attachment names,
every text part of the attachments and of a forwarded original, the headers
of attached or forwarded messages, and, best effort, every other part's
bytes; compressed formats are not inspected.

A secret found blocks the send, and so does text the scan cannot read in
full (its limits are in the
[enforcement table](ARCHITECTURE.md#where-each-safety-rule-is-enforced)).
A block names the part by position (`attachment 1 > text/plain`), never by
file name, and TypeSafe is not asked. The scan catches mistakes; it is not a
boundary against an agent set on leaking.

A clean message then goes to Jev, which is asked whether a recipient does
not belong and whether the message shares confidential information; for
reply-all, whether it should go only to the sender; for a forward, whether
the original asks not to be shared. The result holds `secret_scan`
(`clean`, `found` or `incomplete`) and the `jev` object. A blocked send says
so and suggests `mail_save_draft`, which is never checked.

## Deletes

A delete always needs UIDPLUS; with Jev on, nothing is asked without it.
`mail_delete` then takes at most 50 UIDs and asks Jev the keep questions
(record, account security, personally written, open action, needed again)
about every message first; any high answer blocks the whole delete. Only the
messages Jev was asked about are deleted: a UID that did not exist then is
reported in `missing`, even if a message took it meanwhile.

## Reads

`mail_search`, `mail_get`, `mail_get_new` and `mail_get_thread` (marked
`openWorldHint` for this reason) add the `jev` object to each message shown.
Its `signals` are `reply_needed`, `action_required`, `priority`, `category`
(chosen from the folder list), `suggested_action`, and `suspected_injection`
only when Jev suspects one.

## `mail_classify`

`mail_classify` changes nothing: no flag, no move, no folder. It reads with
`EXAMINE`, `BODY.PEEK` and `BODYSTRUCTURE`, so messages stay unread (proven:
its plan contains no command that can change a mailbox). For each
message it returns `category` (the existing folder Jev chose among the
selectable folders other than INBOX, the role folders and `To Delete`, or
`null`) and the `jev` object, whose `signals` are `reply_needed`,
`action_required`, `deadline_present`, `priority`, `suggested_action`,
`keep`, `disposable` and, when suspected, `suspected_injection`.

When Jev answers but chooses no folder with high confidence (it chose none,
or chose a folder with lower or missing confidence), `needs_new_category` is
`true`. Call again with `candidates` (new folder names, checked as
`mail_create_folder` checks them), and a chosen one is returned as
`new_category`. It is never created; create it with `mail_create_folder`.
A message whose header facts alone exceed a request is `unchecked`. The
result also lists `not_found` UIDs and the requests made.

## `mail_triage` and the To Delete folder

`mail_triage(folder, uids, uidvalidity, dry_run?)` reads the messages as
`mail_classify` does, asks Jev about every one of them before anything
moves, and then moves each message at most once, following one table
(`filing` in `src/jev.bend`):

| Delete review | Category answer | Action |
| --- | --- | --- |
| safe to delete | any | move into `To Delete` |
| keep, review, or unanswered | an existing folder with high confidence | move into that folder |
| keep, review, or unanswered | a candidate, no fitting folder, a lower confidence, or none | stay |

A message is safe to delete only when every check passes:

- the content mode is `body` and Jev saw the whole text (a `body_truncated`
  message never is);
- it is not flagged or answered, has no attachments (and they can be told),
  and is at least 30 days old;
- it has one From field with one readable address, and you have never
  written to that sender in To or Cc (two read-only searches of the Sent
  folder per sender; Bcc is not searched);
- every keep answer is low, and the disposability score is high with high
  confidence.

Such a message is asked about in a request of its own, and only those
answers can send it to `To Delete`; the others are asked in batches, as
`mail_classify` asks. Just before the moves, a short read-only session reads
the flags of the messages bound for `To Delete` again: one you flagged or
answered meanwhile is kept, and filed like any kept message. Each message's
result gives its `verdict` (`safe_to_delete`, `keep`, `review` or
`unanswered`), the code's `vetoes`, its `destination` (or `null`) and the
`jev` object; `moves` lists one move per destination folder.

Triage never deletes: `To Delete` is a folder for you to review, and
`mail_delete` remains the only way to remove mail permanently. Create it
once with `mail_create_folder`. When a message is safe to delete but
`To Delete` is missing (or is a role folder), the call is refused and moves
nothing, but its error still lists every message's verdict and proposed
destination. If any TypeSafe request fails, nothing moves. A move cut off
part way fails the call with `partial: true` and leaves the later moves
unmade.

Only `mail_triage` moves mail into `To Delete` or a folder inside it.
`mail_move` and `mail_label` may move a message you keep out of it;
`mail_trash` does not, and triage never files mail out of it. No folder tool
renames it or creates a folder inside it, and no `MAILBEND_*_FOLDER`
override may name it or a folder inside it.
