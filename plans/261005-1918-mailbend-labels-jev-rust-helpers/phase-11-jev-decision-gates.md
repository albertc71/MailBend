---
phase: 11
title: "Phase 11: Jev decision gates"
status: todo
priority: P1
effort: "2d"
dependencies: [3, 5, 7, 8, 10]
---

# Phase 11: Jev decision gates

## Goal

Consult Jev inside tool calls where the evidence shows it helps (the tiered
design the user chose): a veto before outbound and irreversible actions,
typed annotations on results that carry mail content, and nothing on
reversible or content-free calls.

## Evidence

Full table: [Jev gating research](./research/researcher-jev-gating-evidence.md).

- A pre-call check on a read sees only arguments; read plans are proven
  read-only (`LAWS.bend` *_writes_nothing).
- TypeSafe: "Nothing here is a security boundary"; adaptive attacks bypass
  classifier defenses (arXiv 2510.09023). Jev is an extra layer next to the
  existing laws and switches.
- User decisions: tiered Jev; bodies only with zero retention; TypeSafe
  unreachable blocks send, reply, forward and permanent delete, while reads
  continue marked "unchecked".
- Red team: a body-level secret check through Jev would send the body to
  TypeSafe in the default headers mode; with phase 10's verdict as the
  delete gate, headers mode would block every delete.
- TypeSafe skill: "Keep known rules, calculations, exact lookups, and
  execution in code".
- LAWS.bend covers pure plans only (`LAWS.bend:5-9`); the SMTP envelope is
  built in IO (`src/tools.bend:1229`, `:1325-1333`).

## Design

| Tool | Jev | On TypeSafe failure |
| --- | --- | --- |
| `mail_send`, `mail_reply`, `mail_forward` (not `as_draft`) | Before SMTP: a local, deterministic check in Bend for credentials and secrets (private-key blocks, common token prefixes, password lines) in the body and attachment names, in every mode; Jev questions on headers and recipients (does the recipient fit the conversation, is reply-all appropriate, did the original ask for this forward), plus the body only in body mode | Block, say why, suggest `mail_save_draft` |
| `mail_delete`, `mail_unlabel` | Before the expunge: the five delete vetoes; block only when a veto is `High` (no body requirement, no `SafeToDelete` requirement) | Block |
| `mail_get` | After the fetch: reply_needed, action_required, priority, category, suggested_action, suspected_injection when flagged | Result returned, `jev.status: unchecked` |
| `mail_search`, `mail_get_new`, `mail_get_thread` | After the fetch: headers-only annotations, batches of at most 20 messages per request | `unchecked` |
| `mail_classify`, `mail_triage` | Jev is the tool (phases 9-10) | classify: error; triage: no change |
| Probe, folders, labels_of, mark, flag, label, folder create/rename/delete, move, trash, save draft, attachment download | No Jev | n/a |

`jev.status` says what was checked (`checked`, with `content: headers` or
`body`), so a headers-mode send never claims the body was judged by Jev.
The local secret check reports its own result.

Pure wrappers that the IO code must call (a CI grep checks there is no
other path to `smtp_run` or to the delete plan):

- `outbound_checked(allow, verdict, rcpts, from, msg) -> Maybe<String>`
  (wraps phase 5's `outbound`).
- `delete_checked(verdict, plan) -> List<Cmd>`.

Laws (about these pure functions; IO wiring is covered by e2e, and the
README says so):

- `send_veto_only_subtracts`: for every verdict, the result is
  `outbound(...)` or None.
- `delete_veto_only_subtracts`: for every verdict, the result is the plan
  or `[]`.
- `failure_blocks_outbound`: `Missing` gives None / `[]`.
- `outgoing_headers_state_has_no_body`: the outgoing Jev state in headers
  mode has no body field (extends phase 9's law).

MCP annotations: the four annotated reads get `openWorldHint: true` (content
may leave the machine when Jev is on; the schema is static).

`dry_run` on gated tools includes the Jev verdict; an e2e enumerates every
tool that is not read-only and asserts it accepts `dry_run`.

## Files

- Modify: `src/jev.bend`, `src/tools.bend`, `src/smtp.bend`, `LAWS.bend`,
  `PROOF.bend`, `tools/gen-schema.py`, `tests/unit/jev.bend`,
  `tests/fake_typesafe.py`, `tests/test-e2e.py`, `.github/workflows/ci.yml`
  (the wiring grep).

## Steps

1. Local secret rules with unit tests (true and false positives).
2. Send gate and wrappers; laws.
3. Delete gate on `mail_delete` and `mail_unlabel`; laws.
4. Annotations for get and lists with batching.
5. e2e: Jev off changes nothing; Jev on in headers mode: a send carrying a
   fake credential is blocked locally and nothing reaches SMTP or TypeSafe
   with the body; a normal send proceeds; a delete with low vetoes
   proceeds; a high veto blocks; TypeSafe down blocks send, reply, forward,
   delete, unlabel and returns `unchecked` on get; annotations only on the
   listed tools; `suspected_injection` omitted when low.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `python3 tests/test-e2e.py`
  (Jev off and on).

## Risks

- False positives block legitimate sends: high bar to veto, reasons always
  returned, drafts remain available.
- Measured benefit of annotations is unverified; the live check records
  whether they let the agent skip `mail_get` calls.
