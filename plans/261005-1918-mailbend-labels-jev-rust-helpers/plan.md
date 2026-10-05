---
title: "MailBend: labels, Jev decisions, and Rust helpers"
description: "Add folder labels, flags, send safety, downloads, threads and dry runs, consult TypeSafe Jev inside outbound, delete and read tool calls, and rewrite both native helpers in Rust."
status: pending
priority: P1
effort: 20d
branch: main
tags: [feature, backend, security, refactor]
blockedBy: []
blocks: []
created: 2026-10-05
---

# MailBend: labels, Jev decisions, and Rust helpers

## Overview

Delivers the accepted brainstorm
([brainstorm report](../reports/brainstorm-261005-1855-mailbend-next-features.md)):
labels as iCloud folders (a move, one copy once it completes), flag colours, Sent copies with a recipient
allowlist and send limit, attachment download, threads, dry-run previews,
TypeSafe Jev consulted inside the tool calls where it helps (veto before outbound and irreversible actions, annotations on mail content), and
both native helpers rewritten in Rust with an unchanged contract. The user
runs the live iCloud checks once the PR is ready.

Scope mode: HOLD SCOPE (no `--yagni`). Evidence rules: every claim cites a
file and line, a primary doc, or is marked unverified and turned into a
check.

## Settled decisions

| Decision | Source |
| --- | --- |
| A label is an iCloud folder: `mail_label` moves the message there (one copy once the move completes; an interrupted fallback move is reported as `partial`); removing a label is a move back to INBOX; there is no unlabel or labels-of tool | user, after the review PR opened (replaces the earlier copy-based labels) |
| No folder-delete tool: MailBend creates and renames folders only; folders are deleted in Apple Mail or iCloud.com (IMAP has no "delete only if empty") | user, after the plan review |
| Jev's category is the label: triage moves each message into one existing folder; when none fits, the agent proposes names and Jev chooses in a second call; a new folder exists only via `mail_create_folder` | user, after the review PR opened |
| `mail_create_folder` is the only way a mailbox is created; AGENTS.md rule reworded | user, brainstorm section 7 |
| Jev never deletes; a safe verdict moves mail into a "To Delete" review folder | user, brainstorm section 7 |
| Bodies go to TypeSafe only with `MAILBEND_TYPESAFE_ZERO_RETENTION=1`; headers by default | user, brainstorm section 2 |
| Tiered Jev (when `MAILBEND_TYPESAFE=1` and a key is set): veto before send/reply/forward and permanent delete; annotations on get, search, new mail, threads; classify and triage tools; no Jev on reversible or content-free calls. Jev can only veto or annotate | user, after [Jev gating research](./research/researcher-jev-gating-evidence.md) |
| A separate `mailbend-typesafe` helper calls TypeSafe with a key read only from `MAILBEND_TYPESAFE_KEY_FILE`; a key in the environment is a configuration error, so the key never reaches the core or `mailbend-tls` | user, this session; red team |
| The daily send limit is a local counter file kept by `mailbend-attach count`, reserved before sending; no tool can change it | user, red-team round |
| `mail_get_attachment` is not a read tool: refused and hidden in read-only mode | user, red-team round |
| One PR for all phases; no MCP registry `server.json` now | user, red-team round |
| TypeSafe unreachable: block send, reply, forward and permanent delete; reads continue marked "unchecked" | user, this session |
| Both helpers rewritten in Rust; all related docs updated | user, brainstorm section 8 |

## Components

```mermaid
flowchart TB
  agent["AI agent (MCP client)"]
  subgraph core["Bend core: decides everything, never reads secrets"]
    direction TB
    dispatch["tools.bend dispatcher (gated)<br/>schema check, read-only and drafts-only switches"]
    jev["jev.bend (new)<br/>questions, content mode, answer bands, policy"]
    ops["ops.bend plan_* defs<br/>folders, labels, flags, sent copy, triage"]
    laws["LAWS.bend + PROOF.bend<br/>new laws: veto only subtracts, labels copy only, ..."]
    imap["imap.bend / mime.bend / smtp.bend<br/>render and parse"]
  end
  subgraph rust["Rust native helpers (replace the C ones)"]
    tls["mailbend-tls<br/>imap, smtp modes<br/>rustls, verification mandatory"]
    tsh["mailbend-typesafe (new)<br/>only the TypeSafe key, empty env<br/>fixed host"]
    attach["mailbend-attach<br/>read, save and count modes<br/>openat2 sandbox, no credentials"]
  end
  imapsrv[("IMAP iCloud")]
  smtpsrv[("SMTP iCloud")]
  ts[("api.typesafe.ai<br/>fixed host")]
  files[("MAILBEND_ATTACH_DIR")]
  dl[("MAILBEND_DOWNLOAD_DIR")]
  state[("MAILBEND_STATE_DIR<br/>send counter")]
  keyf[["MAILBEND_TYPESAFE_KEY_FILE"]]

  agent -- "tools/call" --> dispatch
  dispatch --> jev
  dispatch --> ops
  laws -. "proves" .-> ops
  laws -. "proves" .-> jev
  ops --> imap
  imap -- "script" --> tls
  jev -- "JSON questions" --> tsh
  tls <--> imapsrv
  tls <--> smtpsrv
  tsh <--> ts
  dispatch -- "path, budget" --> attach
  attach <--> files
  attach --> dl
  attach <--> state
  keyf -. "read only here" .-> tsh
```

## Workflow: one tool call with Jev

```mermaid
sequenceDiagram
  autonumber
  participant A as Agent
  participant D as Bend dispatcher
  participant J as jev.bend policy
  participant H as mailbend-tls
  participant Y as mailbend-typesafe
  participant T as TypeSafe Jev
  participant S as IMAP/SMTP
  A->>D: tools/call (e.g. mail_send or mail_delete)
  D->>D: schema, switches, build the plan (deterministic)
  D->>H: read-only preflight (EXAMINE, BODY.PEEK headers)
  H->>S: fetch
  S-->>H: headers (+ body only with zero retention)
  H-->>D: transcript
  alt Jev on and this tool is gated
    D->>J: build questions for this tool and content
    J->>Y: request (one batch, pinned jev-1.13.0)
    Y->>T: POST /v1/systemone
    T-->>Y: typed answers
    Y-->>J: answers (or failure: send and delete blocked)
    J->>J: bands, then veto or proceed
  end
  alt Jev vetoed
    D-->>A: blocked, with reasons (nothing changed)
  else proceed (or Jev off)
    D->>H: run the unchanged plan (pinned session)
    H->>S: commands
    S-->>H: replies
    H-->>D: transcript
    D-->>A: result + Jev notes (or "unchecked")
  end
```

Gated before the change: send, reply, forward (a local secret check in Bend
plus Jev on headers and recipients; the body only in body mode), permanent
delete (blocked only when a veto scores high). For
`mail_get` (full) and search, new mail and threads (headers only) the order
is fetch, then Jev on the fetched content, then the result with a `jev`
object (reply_needed, priority, category, suggested_action, and
suspected_injection only when flagged). Flags, labels, folders, move, trash,
drafts and downloads do not call Jev. Laws prove that the pure decision
functions the tools must call (`outbound_checked`, `delete_checked`) return
the plan without Jev or nothing; that the IO code calls only them is covered
by end-to-end tests and a CI grep, not by a proof.

## Workflow: labels (folders) and the "To Delete" review

```mermaid
flowchart LR
  m["Message in INBOX"] --> c{"Jev classify<br/>(label folder, delete vetoes)"}
  c -- "all vetoes low, body mode,<br/>code facts pass" --> r["Move into 'To Delete'<br/>(proven move plan)"]
  c -- "label = existing folder,<br/>confident" --> cat["Move into label folder<br/>(proven move plan)"]
  c -- "label = none" --> nn["needs_new_category"]
  nn --> ag["Agent proposes names"]
  ag --> c2{"Jev call 2: choose among<br/>existing folders + candidates"}
  c2 --> mk["Agent: mail_create_folder<br/>(explicit, never implicit)"]
  mk --> c
  c -- "any veto or uncertain" --> k["Keep; report to agent"]
  r --> u{"User reviews in Apple Mail"}
  u -- "agrees" --> del["User deletes"]
  u -- "keeps" --> back["Moves it back"]
```

## Phase dependencies

```mermaid
flowchart LR
  p1["1 Rust attach"] --> p2["2 Rust TLS"]
  p1 --> p6["6 Download"]
  p1 --> p5
  p3 --> p5
  p3["3 Folders, labels"] --> p10
  p2 --> p9["9 Jev classify"]
  p9 --> p10["10 Jev triage"]
  p8 --> p10
  p10 --> p11["11 Jev in every call"]
  p5["5 Send safety"] --> p11
  p4["4 Flags"] --> p8["8 Dry run"]
  p3 --> p8
  p5 --> p8
  p6 --> p8
  p3 --> p7["7 Threads"]
  p7 --> p11
  p8 --> p11
  p11 --> p12["12 Documentation"]
  p12 --> p13["13 Checks and PR"]
```

## Phases

| # | Phase | Effort | Status |
|---|-------|--------|--------|
| 1 | [Rust workspace and attachment reader](./phase-01-rust-workspace-and-attachment-reader.md) | 1d | Pending |
| 2 | [Rust TLS helper](./phase-02-rust-tls-helper.md) | 3d | Pending |
| 3 | [Folders and labels](./phase-03-folders-and-labels.md) | 2.5d | Pending |
| 4 | [Flags and colours](./phase-04-flags-and-colours.md) | 0.5d | Pending |
| 5 | [Send safety](./phase-05-send-safety.md) | 2d | Pending |
| 6 | [Attachment download](./phase-06-attachment-download.md) | 1.5d | Pending |
| 7 | [Threads](./phase-07-threads.md) | 1d | Pending |
| 8 | [Dry-run preview](./phase-08-dry-run-preview.md) | 0.5d | Pending |
| 9 | [Jev foundation and classify](./phase-09-jev-foundation-and-classify.md) | 2.5d | Pending |
| 10 | [Jev triage and delete review](./phase-10-jev-triage-and-delete-review.md) | 1.5d | Pending |
| 11 | [Jev decision gates](./phase-11-jev-decision-gates.md) | 2d | Pending |
| 12 | [Documentation update](./phase-12-documentation-update.md) | 1d | Pending |
| 13 | [Release checks and PR](./phase-13-release-checks-and-pr.md) | 0.5d | Pending |

## Success criteria

- [ ] `bend PROOF.bend` prints "ALL PROOFS CHECK" with every new law listed in each phase.
- [ ] `sh tests/run-unit.sh`, `bash tests/test-transport.sh`, `python3 tests/test-cloud-network.py`, `scripts/install.sh && python3 tests/test-e2e.py` pass against the Rust helpers, with test edits limited to the build line in `tests/test-transport.sh:36` and the documented tool-count and tool-list updates.
- [ ] CI adds cargo fmt, clippy, test, deny, an MSRV check, the `dangerous()` grep and a fuzz smoke run, all green.
- [ ] With `MAILBEND_TYPESAFE` unset, every existing e2e behaviour assertion passes (only the tool-count and tool-list assertions change).
- [ ] Every new or changed law is listed verbatim in the PR for the user's review.
- [ ] README, ARCHITECTURE, native/README, AGENTS, CONTRIBUTING, CLOUD_AGENT and .env.example describe the new behaviour.
- [ ] A live iCloud checklist is in `docs/CLOUD_AGENT.md` for the user to run on the PR.

## Red Team Review

### Session — 2026-10-05
**Findings:** 15 (15 accepted, 0 rejected; one reviewer line citation, `docs/CLOUD_AGENT.md:287`, was itself wrong and ignored)
**Severity breakdown:** 3 Critical, 9 High, 3 Medium

| # | Finding | Severity | Disposition | Applied To |
|---|---------|----------|-------------|------------|
| 1 | `mail_changes`/`loses_mail` catch-alls made folder laws vacuous | Critical | Accept | Phase 3 (`mailbox_changes`, `destroys_mail`, no catch-alls) |
| 2 | `mail_unlabel` expunged without confirmation on a forgeable Message-ID | Critical | Accept (user: expunge with confirm word) | Phases 3, 11 |
| 3 | TypeSafe key shared processes with the mail password | Critical | Accept | Phases 2, 9; plan decisions |
| 4 | Folder delete: stale emptiness check, DELETE destroys mail | High | Accept | Phase 3 (confirm word, adjacent check, exact law) |
| 5 | Delete gate blocked every delete in headers mode; `safety_check` toggle | High | Accept | Phases 10, 11 |
| 6 | Send secret check would send bodies to TypeSafe by default | High | Accept | Phase 11 (local check in Bend) |
| 7 | Send limit bypassable via Sent; X-Mailer; missing dependency | High | Accept (user: local counter) | Phase 5 |
| 8 | "To Delete" unprotected and caller-chosen | High | Accept | Phases 3, 10 |
| 9 | Create/rename could hijack role resolution; INBOX case | High | Accept | Phase 3 |
| 10 | No configuration record; missing key degraded to "unchecked"; annotations wrong | High | Accept | Phases 9, 11 |
| 11 | Headers state needed unfetched fields; batch budget | High | Accept | Phases 9, 11 |
| 12 | Download in read-only mode, wrong-process dir check, partial files, names | High | Accept (user: refuse in read-only) | Phase 6 |
| 13 | Laws claimed to cover IO; allowlist proof and address details | Medium | Accept | Phases 5, 11; plan workflow text |
| 14 | Rust install path, toolchain pin, live TLS checks, C deletion | Medium | Accept (user: one PR) | Phases 1, 2, 13 |
| 15 | Ordering, dry-run coverage, triage order, citations, scope extras | Medium | Accept | Phases 4, 7, 8, 10, 12, 13 |

Note (after the review PR opened): finding 2 is superseded. Labels are now
moves into a folder, so `mail_unlabel`, its expunge and its Message-ID check
no longer exist. Finding 4 is superseded by the decision in validation
session 3: there is no folder-delete tool.

### Whole-Plan Consistency Sweep
- Files reread: plan.md, phase-01 to phase-13, research/*.md.
- Decision deltas checked: 12 (key file, unlabel confirm, counter file,
  download not read-only, one PR, no server.json, review folder constant,
  delete gate rule, local secret check, configuration record, fetch items,
  dropped extras).
- Reconciled stale references: removed `MAILBEND_TYPESAFE_API_KEY` as a key
  source, `safety_check`, `review_folder`, `X-Mailer`, `check-docs.py`,
  `MAILBEND_TYPESAFE_CONNECT_IP`, `detail`, duplicate schema and dependabot
  steps; fixed "phase 12 live check" to phase 13, `native/attach/` to
  `native/mailbend-attach/`, the fake-server line to `:461-462`.
- Unresolved contradictions: 0.

## Validation Log

### Session 1 — 2026-10-05
Questions asked: 6 (red-team disposition, unlabel semantics, send limit,
download in read-only, delivery, registry file).

| Question | Answer |
| --- | --- |
| Apply the red-team fixes? | Apply all |
| How does unlabel remove a copy? | Expunge with the confirmation word |
| Send limit design? | Local counter file |
| Download in read-only mode? | Refused |
| Delivery? | One PR for everything |
| MCP registry `server.json`? | Not now |

### Verification Results
- Tier: Full (13 phases); claims checked by four reviewers: 34 + 30+ each.
- Failed citations found and fixed: `tests/fake_mail_server.py:468-469`
  (now `:461-462`), `native/attach/` path; `gated` is at
  `src/tools.bend:1608` (the plan references the function by name).
- Unverified items remain marked and are on the phase 13 live checklist.

### Session 2 — 2026-10-05 (after the review PR opened)

| Question | Answer |
| --- | --- |
| Should triage file the category? | Move into the category folder |
| Where do categories come from? | Existing folders; when none fits, the agent proposes names and Jev chooses in a second call |
| Labels: copy or move? | "mail label should move to a folder in icloud mail please, no duplicate mails" |

Propagated to phases 3, 9, 10, 11, 12, 13 and this file: `mail_label` is a
proven move; `mail_unlabel` and `mail_labels_of` are removed; the category
is the label; triage makes at most one move per message.

#### Whole-Plan Consistency Sweep
- Searched all plan files for `unlabel`, `labels_of`, label copies and
  per-label Nouls; remaining mentions are the decision row and this log.
- Unresolved contradictions: 0.

### Session 3 — 2026-10-05 (external plan review of `ef0ef98`)

The review reported 11 issues (3 high, 8 medium). All were checked against
the source and accepted.

| # | Issue | Resolution |
| --- | --- | --- |
| 1 | Empty-folder delete races with arriving mail; `=EXPECT` stays satisfied once matched (`native/mailbend-tls.c:529-533`) | User: no folder-delete tool. `CDelete` is removed from the command model (phase 3) |
| 2 | Secret check misses the forwarded original (`src/tools.bend:1490-1500`) | Scan the decoded outgoing content, including `message/rfc822` and `text/*` parts, within limits; a scan that cannot cover everything reports `incomplete` (phase 11) |
| 3 | Triage rules, laws, tests and checklist contradicted each other | The delete-review verdict is separated from the final filing action; one table drives the law, the unit tests, the e2e and the checklist (phases 10, 13) |
| 4 | Exact-name checks miss parents and children | Checks cover the whole hierarchy using the reported delimiter; parents must already exist (phase 3) |
| 5 | A 20-message batch ignores both token limits | Batches are split by size against the 32k and 64k limits, using the byte count as the token bound; single oversized messages are handled; the fake service enforces the limits (phase 9) |
| 6 | "Proven no duplicates" is too strong for an interrupted fallback | The one-copy guarantee holds only for a completed move; an interrupted one returns `partial`; fault-injection tests (phase 3) |
| 7 | Rust dispatch would break relative attach directories | The mode is chosen by argument count (3, 4 or 6); a parity test runs both helpers on directories named `attachments`, `count` and `save` (phase 1) |
| 8 | The installer ignores `native/rust-toolchain.toml` | Build from inside `native/`; check the cargo and rustc versions; test with an older default toolchain (phase 1) |
| 9 | The save helper cannot see the caller's PATH | PATH is passed as an explicit non-secret argument and compared by inode (phase 6) |
| 10 | Dry-run tests ignore local file changes | Snapshot the download directory and the counter; record helper calls (phase 8) |
| 11 | The fake server cannot serve BODYSTRUCTURE | Fixture responses are added; missing or malformed structure is `Unknown` and never counts as "no attachments" (phases 9, 10) |

#### Whole-Plan Consistency Sweep
- I searched every plan file for folder delete, `CDelete`, "no duplicate",
  "batches of at most 20", the delete-only triage expectation and absolute
  directory dispatch. I updated phases 1, 3, 5, 6, 8, 9, 10, 11, 12 and 13
  and this file.
- The earlier sweep results (0 contradictions) applied to the plan as it
  stood then. After this session the triage table, its laws, its tests and
  the checklist agree.
- Unresolved contradictions: 0.
- Still unverified and on the phase 13 checklist: that TypeSafe's tokenizer
  is byte-level (the byte bound depends on it), the iCloud delimiter, and
  HEADER search behaviour.

### Session 4 — 2026-10-05 (re-review of `f6b98c8`)

| # | Issue | Resolution |
| --- | --- | --- |
| 1 | An incomplete secret scan still let a send through | The scan result is `Found`, `Incomplete` or `Clean`, and it is an input to `outbound_checked`; anything other than `Clean` blocks SMTP; drafts stay available; law `secret_scan_blocks`; tests place a secret beyond each limit (phase 11) |
| 2 | A truncated body could still reach `SafeToDelete` | Body completeness (`Complete` or `Partial`) is part of `Facts`; `Partial` rules out `SafeToDelete`, as `Unknown` attachments do; test with a deadline marker in the removed tail (phases 9, 10) |
| 3 | Child-path checks refused ordinary renames | Children are checked against the tree the rename produces; the existing-parent rule applies only to the root destination's parent; tests for two-level and three-level renames (phase 3) |
| 4 | `SafeToDelete` with a missing category matched two rows | The missing-category row is limited to `Keep` and `Review`; the rows are disjoint; tests cover every combination (phase 10) |
| — | Byte bound described as a proof | Reworded as a local size estimate; 422 is a general validation error and its detail is kept; one bounded retry, then a terminal error; triage classifies every batch before any move; tests where the fake service disagrees with the estimate (phases 9, 10) |

The research findings on flag colours and the Sent folder name were applied
after the user approved them (phases 4 and 5).

#### Whole-Plan Consistency Sweep
- Searched for "proceeds only with that status", "upper bound on tokens",
  "any | category answer", "child's new path must also pass" and "one Jev
  request per batch"; none remain.
- Unresolved contradictions: 0.
