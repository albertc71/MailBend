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

Add explicit folder management and Gmail-style labels emulated as copies on
iCloud: `mail_create_folder`, `mail_rename_folder`, `mail_delete_folder`
(empty only, confirmed), `mail_label`, `mail_unlabel` (confirmed),
`mail_labels_of`, with laws that can actually see mailbox-level commands.

## Evidence

- User asked for "the tool call to create folders that act like a label for
  iCloud mail similarly to gmail"; approach A (copies) chosen; unlabel is a
  permanent expunge guarded by the confirmation word (user, red-team round).
- codefuturist/email-mcp emulates Proton labels the same way: COPY into a
  label folder, remove by Message-ID (`label-strategy.ts`).
- `mailbend-tls` refuses only LOGIN, AUTHENTICATE, STARTTLS, LOGOUT
  (`native/mailbend-tls.c:588-589`), so CREATE/RENAME/DELETE/SUBSCRIBE pass.
- AGENTS.md:42 "never create a target mailbox"; README.md:113. Rewording
  accepted by the user.
- Apple: deleting an iCloud folder deletes its contents and subfolders
  (support.apple.com/guide/icloud/organize-email-with-folders-mm6b1a6730/icloud).
- Thunderbird bug 1935884: folders vanished after create until resubscribed
  (unconfirmed cause), so SUBSCRIBE after CREATE/RENAME.
- **Laws would be vacuous without new predicates:** `mail_changes`
  (`src/ops.bend:290-307`) and `loses_mail` (`:238-248`) end in `case _`, so
  CREATE/RENAME/DELETE would be silently skipped and a law such as
  `label_changes_exactly` would still hold for a plan containing
  `CDelete{"Archive"}`. `writes` (`src/imap.bend:113-145`) has no catch-all,
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

- `Cmd` gains `CCreate{mbox}`, `CRename{from, to}`, `CDelete{mbox}`,
  `CSubscribe{mbox}`; `writes()` is True for all four.
- `Key` gains `KHeader{name, value}` and `KUndeleted{}`.

Predicates (`src/ops.bend`), written without catch-alls so the compiler
forces every new command to be classified:

- `mailbox_changes(cs)`: every CCreate, CRename, CDelete, CSubscribe in order.
- `destroys_mail(c)`: True for `CExpunge` and `CDelete` (DELETE removes the
  folder's messages on iCloud); `any_destroys_mail(cs)`.
- `mail_changes` and `loses_mail` are rewritten to list every `Cmd` case
  explicitly (no behaviour change for existing commands; existing laws keep
  their exact statements).

Plans:

- `plan_create(m) = [CCreate{m}, CSubscribe{m}]`.
- `plan_rename(a, b) = [CRename{a, b}, CSubscribe{b}]`.
- `plan_delete_folder(m, confirm)`: with the exact confirmation word,
  `[CExamine{m}, CExpect{"* 0 EXISTS"}, CDelete{m}]`, otherwise `[]`. The
  emptiness check and DELETE are adjacent in one session. Whether iCloud
  accepts DELETE of the examined mailbox is a live check; if not, the tool
  reports the server's refusal and deletes nothing.
- `plan_label(src, uids, label, uidv)` = pinned guard + `CCopy{uids, label}`.
- `plan_unlabel(label, uids, confirm, uidplus, uidv)` = exactly the
  confirmed delete plan applied to the label folder (empty without the
  confirmation word or UIDPLUS).
- `plan_labels_of(folders, mid)` = per folder
  `[CExamine{f}, CSearch{[KHeader{"Message-ID", mid}, KUndeleted{}]}]`,
  followed by header fetches so Message-IDs are compared exactly.

Tool rules (`src/tools.bend`, deterministic, no Jev):

- Protected names, refused as create targets, rename source or target,
  delete targets and label targets: INBOX (via `same_name`), every resolved
  or advertised role folder, every conventional role name compared
  case-insensitively, and the review folder `To Delete` (except that
  `mail_create_folder` may create `To Delete` itself, once).
- Create: name non-empty, no NUL/CR/LF, not an existing folder; the only
  tool that creates a mailbox.
- Delete folder: refused when LIST shows children (`name<delim>...`); a
  failed emptiness expectation is reported as "the folder is not empty;
  nothing was deleted". Marked destructive.
- Label: label folder exists, selectable, not protected, differs from the
  source. Candidates in the label folder come from the HEADER search, then
  the fetched Message-ID is compared exactly (whole angle-bracketed value);
  only absent messages are copied; report `copied`, `already_labelled`,
  `no_message_id` (copied without dedupe).
- Unlabel: requires `confirm: "permanently-delete"` and the label folder's
  `uidvalidity`; marked destructive; the phase 11 delete gate applies when
  Jev is on. Before expunging, each message must have a non-empty
  Message-ID and an exact match (Message-ID and RFC822.SIZE) in another
  folder that is not Trash, Junk, Drafts, `To Delete` or the label folder
  itself; otherwise that UID is kept and reported in `kept_last_copy`. The
  check runs in a session before the expunge session; the window is one
  tool call and is documented.
- Labels of: searches user folders (not INBOX, not protected), compares
  Message-IDs exactly.

Laws (`LAWS.bend`, proofs in `PROOF.bend`):

- `create_changes_exactly`: `mailbox_changes(plan_create(m)) == [CCreate{m}, CSubscribe{m}]`
  and `mail_changes(plan_create(m)) == []`.
- `rename_changes_exactly` likewise.
- `delete_folder_needs_confirmation`: wrong word gives `[]`.
- `delete_folder_is_exact`: with the word,
  `plan_delete_folder(m, w) == [CExamine{m}, CExpect{"* 0 EXISTS"}, CDelete{m}]`
  (the deleted mailbox is the examined one).
- `label_changes_exactly`: `mail_changes(plan_label(...)) == [CCopy{uids, label}]`
  and `mailbox_changes(plan_label(...)) == []` and `any_destroys_mail == False`.
- `label_is_pinned`; `unlabel_equals_confirmed_delete`;
  `unlabel_needs_confirmation`.
- `labels_of_writes_nothing`.
- `read_only_tools_are_exactly_five` is renamed and restated with the final
  list from phases 3, 6, 7 and 9 (each change explained in the PR; the law
  still pins the exact list).

## Contract consumers to update

- `src/ops.bend:8-120` (Op, `name`, `all_ops`, `is_read_only`,
  `is_destructive` adds `ODeleteFolder` and `OUnlabel`).
- `src/tools.bend:1557-1586` (`run_op`), `:1589-1603` (`sends`, `refusal`).
- `tools/gen-schema.py` (destructive annotations on delete folder and
  unlabel); `src/schema.bend` regenerated.
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
   like real servers) and UNDELETED keys, CREATE, RENAME, DELETE (deletes
   contents, like iCloud), SUBSCRIBE, and a `--delim` option ("/" and ".").
2. Command model, rendering and unit tests (`mutf7_encode` for names).
3. Predicates without catch-alls; existing laws re-proven unchanged.
4. Plans and new laws; `bend PROOF.bend`.
5. Tools, schema, gating and refusals; contract consumers above.
6. e2e: create; duplicate create refused; protected names refused
   (including `inbox`, `Sent Messages`, `Deleted Messages`); rename;
   delete non-empty refused with the "not empty" message; delete without the
   word refused; delete empty; label twice gives one copy; label without
   Message-ID; unlabel without the word refused; unlabel whose only other
   copy is in Trash kept; unlabel with a forged Message-ID of different
   size kept; unlabel with a true copy removed; labels_of.
7. Reword AGENTS.md:42: "Never create a mailbox implicitly: role
   resolution, move, label, triage and save never create their target. Only
   `mail_create_folder` creates a mailbox, with a name the caller gives
   explicitly." Update README.md:113 to match.

## Verification

- `bend PROOF.bend` prints "ALL PROOFS CHECK".
- `sh tests/run-unit.sh`; `scripts/install.sh && python3 tests/test-e2e.py`.

## Risks

- Unlabel's other-copy check and the expunge run in separate sessions; a
  concurrent delete of the other copy in that window could leave none.
  Mitigated by the confirmation word and the delete gate; documented.
- iCloud HEADER search, delimiter and DELETE of the examined mailbox are
  unverified: phase 13 live checklist.

## Security

- Labels never touch the source message and never change mailboxes (laws).
- Every message-destroying command (UID EXPUNGE, DELETE) needs the
  confirmation word and is marked destructive.
- No implicit mailbox creation; role resolution cannot be redirected through
  the new tools.
