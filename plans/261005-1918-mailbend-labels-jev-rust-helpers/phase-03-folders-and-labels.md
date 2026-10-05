---
phase: 3
title: "Phase 3: Folders and labels"
status: todo
priority: P1
effort: "2.5d"
dependencies: []
---

# Phase 3: Folders and labels

## Goal

Add explicit folder management and labels as iCloud folders:
`mail_create_folder`, `mail_rename_folder`, and `mail_label`, which moves
messages into a label folder (one copy when the move completes), with laws
that can actually see mailbox-level commands. There is no folder-delete
tool (user decision after the plan review: IMAP cannot delete a folder
"only if still empty", RFC 3501 6.3.4, and iCloud deletes a folder's
contents). Folders are deleted by the user in Apple Mail or iCloud.com.

## Evidence

- User asked for "the tool call to create folders that act like a label for
  iCloud mail similarly to gmail", then decided: "mail label should move to
  a folder in icloud mail please, no duplicate mails". On iCloud a label is
  therefore a folder, one per message (brainstorm approach C), applied with
  the existing move plan. Removing a label is a move back to INBOX with
  `mail_move`; the folder a message is in is its label, so no unlabel or
  labels-of tool is needed.
- `plan_move` is already proven never to lose mail and to expunge only the
  copied UIDs (`LAWS.bend` `move_never_loses_mail`,
  `move_expunges_only_copied`, `copy_move_changes_exactly`).
- `mailbend-tls` refuses only LOGIN, AUTHENTICATE, STARTTLS, LOGOUT
  (`native/mailbend-tls.c:588-589`), so CREATE/RENAME/SUBSCRIBE pass.
- RENAME renames every child folder too and may create missing superior
  folders of the destination; CREATE may create missing superiors
  (RFC 3501 6.3.3, 6.3.5). Exact-name checks therefore do not protect a
  nested role folder such as `MAILBEND_SENT_FOLDER=Mail/Sent` when `Mail` is
  renamed; the override validation (`src/tools.bend:389-403`) would then
  fail. Checks must cover the whole affected hierarchy.
- The fallback move is COPY, `\Deleted` store, UID EXPUNGE
  (`src/ops.bend:179-197`); the laws fix the command order, not atomicity.
  An interruption after COPY leaves the message in both folders
  (RFC 6851 section 3 describes these intermediate states).
- AGENTS.md:42 "never create a target mailbox"; README.md:113. Rewording
  accepted by the user.
- Apple: deleting an iCloud folder deletes its contents and subfolders
  (support.apple.com/guide/icloud/organize-email-with-folders-mm6b1a6730/icloud).
- Thunderbird bug 1935884: folders vanished after create until resubscribed
  (unconfirmed cause), so SUBSCRIBE after CREATE/RENAME.
- **Laws would be vacuous without new predicates:** `mail_changes`
  (`src/ops.bend:290-307`) and `loses_mail` (`:238-248`) end in `case _`, so
  CREATE/RENAME would be silently skipped and a law such as
  a law about label plans would still hold for a plan containing
  `CRename{"Archive", x}`. `writes` (`src/imap.bend:113-145`) has no catch-all,
  which is the pattern to follow.
- **Test-server bug:** `tests/fake_mail_server.py:461-462` makes any
  unrecognised SEARCH key "match everything rather than fail". A HEADER
  search the fake server does not parse would match every message.
- Role resolution falls back to conventional names (`Drafts`, `Trash`,
  `Deleted Messages`, `Sent`, `Sent Messages`, `Junk`, `Archive`;
  `src/tools.bend:384`), so creating or renaming a folder to one of these
  names could change which folder MailBend treats as Trash or Sent.
- INBOX compares case-insensitively only through `same_name`
  (`src/imap.bend:936-937`); RENAME INBOX moves all INBOX mail (RFC 3501
  6.3.5).
- A failed `=EXPECT` exits 5 with no NO line (`native/mailbend-tls.c:711-716`),
  which the core reports as an empty "server rejected" message
  (`src/tools.bend:174-176`, `src/imap.bend:1087-1092`).
- IMAP HEADER search is a substring match (`src/imap.bend:17-18` notes server
  substring matching), and a sender controls its Message-ID.

## Design

Command model (`src/imap.bend`):

- `Cmd` gains `CCreate{mbox}`, `CRename{from, to}`, `CSubscribe{mbox}`;
  `writes()` is True for all three. There is no DELETE command in the
  model, so no plan can render one.
- `Key` gains `KHeader{name, value}` and `KUndeleted{}`.

Predicates (`src/ops.bend`), written without catch-alls so the compiler
forces every new command to be classified:

- `mailbox_changes(cs)`: every CCreate, CRename, CSubscribe in order.
- `destroys_mail(c)`: True only for `CExpunge`; `any_destroys_mail(cs)`.
- `mail_changes` and `loses_mail` are rewritten to list every `Cmd` case
  explicitly (no behaviour change for existing commands; existing laws keep
  their exact statements).

Plans:

- `plan_create(m) = [CCreate{m}, CSubscribe{m}]`.
- `plan_rename(a, b) = [CRename{a, b}, CSubscribe{b}]`.
- `plan_label(src, uids, label, move, uidplus, uidv) = plan_move(src, uids, label, move, uidplus, uidv)`:
  a label is a move, so every move law applies to it unchanged.
- `KHeader` and `KUndeleted` are added here for phases 5 and 7 (Sent-copy
  de-duplication and threads), together with the fake-server fix.

Tool rules (`src/tools.bend`, deterministic, no Jev):

- Protected folders: INBOX (via `same_name`), every resolved or advertised
  role folder (including overrides such as `Mail/Sent`), every conventional
  role name compared case-insensitively, and the review folder `To Delete`.
- Paths are split with the delimiter LIST reports for the folder (tests
  cover "/" and "."). For any create or rename:
  - the target, and every superior of the target, must not be protected or
    sit under a protected folder (so `Work` cannot become `Trash/Work`);
  - the target's parent must already exist (no implicit superior creation),
    and the target must not exist;
  - for rename, the source must not be protected, must not be an ancestor of
    any protected folder (renaming `Mail` would move `Mail/Sent`). Children
    are checked against the folder tree the rename produces: a child's new
    path must not be protected or under a protected folder, and must not
    collide with an existing folder outside the renamed tree. Its new parent
    is supplied by the same rename, so the existing-parent rule applies only
    to the root destination's parent (renaming `Work` with `Work/Invoices`
    to `Projects` is allowed when `Projects` does not exist).
  `mail_create_folder` may create `To Delete` itself, once, at top level.
- Create: name non-empty, no NUL/CR/LF; the only tool that creates a
  mailbox.
- Label: the label folder must exist (created with `mail_create_folder`),
  be selectable, not be protected, and differ from the source; the call
  takes the source folder's `uidvalidity` like `mail_move` and reports
  `changed` and `missing` the same way.
- Interrupted moves (label, `mail_move`, triage): when the helper fails
  after the plan's COPY or STORE, the result is `partial` (not an error that
  implies nothing changed) and names both folders: "the message may now be
  in both folders; check the destination before retrying". The one-copy
  guarantee is stated only for a completed move.

Laws (`LAWS.bend`, proofs in `PROOF.bend`):

- `create_changes_exactly`: `mailbox_changes(plan_create(m)) == [CCreate{m}, CSubscribe{m}]`
  and `mail_changes(plan_create(m)) == []`.
- `rename_changes_exactly` likewise.
- `folder_plans_destroy_nothing`: `any_destroys_mail` is False for every
  create and rename plan.
- `label_is_move`: `plan_label(...) == plan_move(...)` for every argument,
  so `move_never_loses_mail`, `move_expunges_only_copied` and the pinning
  laws cover labels; and `mailbox_changes(plan_label(...)) == []`.
- `read_only_tools_are_exactly_five` is renamed and restated with the final
  list from phases 3, 6, 7 and 9 (each change explained in the PR; the law
  still pins the exact list).

## Contract consumers to update

- `src/ops.bend:8-120` (Op, `name`, `all_ops`, `is_read_only`,
  `is_destructive` unchanged: no new destructive tool).
- `src/tools.bend:1557-1586` (`run_op`), `:1589-1603` (`sends`, `refusal`).
- `tools/gen-schema.py`; `src/schema.bend` regenerated.
- `tests/test-e2e.py:508` (tool count), `:511` (read tools), `:531`
  (`MUTATING_CALLS` gains every new mutating tool), `:576-580` (read-only
  and drafts-only lists), `:59-72` (`env()` pops every new `MAILBEND_*`
  variable added by this plan).

## Files

- Modify: `src/imap.bend`, `src/ops.bend`, `src/tools.bend`, `LAWS.bend`,
  `PROOF.bend`, `tools/gen-schema.py`, `src/schema.bend` (generated),
  `tests/unit/imap.bend`, `tests/fake_mail_server.py`, `tests/test-e2e.py`,
  `AGENTS.md:42`, `README.md:113`.

## Steps

1. Fake server: unknown SEARCH keys answer `BAD`; add HEADER (substring,
   like real servers) and UNDELETED keys, CREATE, RENAME (children follow,
   missing superiors created, as RFC 3501 allows), SUBSCRIBE, a `--delim`
   option ("/" and "."), and fault injection that drops the connection after
   a chosen command (after COPY, after STORE).
2. Command model, rendering and unit tests (`mutf7_encode` for names).
3. Predicates without catch-alls; existing laws re-proven unchanged.
4. Plans and new laws; `bend PROOF.bend`.
5. Tools, schema, gating and refusals; contract consumers above.
6. e2e: create; duplicate create refused; protected names refused
   (including `inbox`, `Sent Messages`, `Deleted Messages`); rename;
   renaming `Mail` refused when `Mail/Sent` is a role or override (both
   delimiters); `Work` to `Trash/Work` refused; rename or create under a
   missing parent refused; renaming two-level and three-level ordinary
   trees succeeds with "/" and "."; a destination that collides with an
   existing folder refused; label moves the message (gone from the source,
   present once in the label folder) on servers with and without MOVE;
   label into a protected folder refused; moving back to INBOX with
   `mail_move` removes the label; connection dropped after COPY and after
   STORE: actual state of both folders checked, result is `partial`, never
   "nothing changed".
7. Reword AGENTS.md:42: "Never create a mailbox implicitly: role
   resolution, move, label, triage and save never create their target. Only
   `mail_create_folder` creates a mailbox, with a name the caller gives
   explicitly." Update README.md:113 to match.

## Verification

- `bend PROOF.bend` prints "ALL PROOFS CHECK".
- `sh tests/run-unit.sh`; `scripts/install.sh && python3 tests/test-e2e.py`.

## Risks

- iCloud HEADER search and delimiter are unverified: phase 13 live
  checklist.
- Interrupted fallback moves can leave two copies; the result says so and
  advises checking before a retry.

## Security

- Labels are proven moves: nothing lost, no mailbox changes, and one copy
  once the move completes (laws cover command order; interruption is
  reported as `partial`).
- No tool can delete a folder; UID EXPUNGE stays limited to the proven move
  fallback and the confirmed `mail_delete`.
- No implicit mailbox creation; role resolution cannot be redirected through
  the new tools.
