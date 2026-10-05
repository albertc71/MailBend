---
phase: 9
title: "Phase 9: Jev foundation and classify"
status: todo
priority: P1
effort: "2.5d"
dependencies: [2]
---

# Phase 9: Jev foundation and classify

## Goal

Connect MailBend to TypeSafe's Jev safely (one configuration record, a key
read only from a key file by a separate helper, content modes, typed
answers, the shared `jev` result object) and ship `mail_classify`, which
changes nothing and returns per-message decisions the agent can act on
without reading each email.

## Evidence (docs.typesafe.ai, read 2026-10-05)

- API: `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer`,
  body `{model, state, questions}`; answers `noul`, `choice`, `score`;
  errors 401, 422, 429, 529 with backoff advised (`/api.md`).
- Model `jev-1.13.0`: 64k tokens per request, 32k for state plus the
  longest question; $0.042 per million input tokens; 80 requests/s; text
  only; no training on customer data; zero retention for enterprise
  customers only (`/models.md`, `/legal.md`).
- Research rules (`research/researcher-jev-gating-evidence.md`): pin
  `jev-1.13.0`; answers are derived from untrusted content; omit
  `suspected_injection` unless flagged; `suggested_action` never suggests
  sending or deleting.
- The Bend core cannot open TLS (Bend 2.0.32 effects: TCP, UDP, files,
  processes; `~/.bend/bend2/effs/`).
- **Key isolation needs a key file:** `Process.run` gives every child the
  core's whole environment (`~/.bend/guide/GUIDE.md:383-385`,
  `process_run.c:185`), and `mailbend-tls` only calls `getenv`
  (`native/mailbend-tls.c:93,414-416`). A key in an environment variable
  would sit next to the mail password in every helper.
  `MAILBEND_PASSWORD_FILE` (`native/mailbend-tls.c:376`) is the existing
  pattern.
- Switches today live in `Mode{read_only, drafts_only}`
  (`src/tools.bend:83-85`), read by `mode()` (`:126-130`), and drive
  `offered` (`:1640-1641`) and `offered_for` (`:1664-1675`), called from
  `main.bend:93,345`.
- Core error mapping reads exit 4 as "authentication failed (check
  MAILBEND_EMAIL and the app-specific password)" (`src/tools.bend:166-170`),
  so TypeSafe failures need their own mapping.
- `plan_headers` fetches only From, To, Cc, Reply-To, Subject, Date,
  Message-ID, In-Reply-To, References (`src/imap.bend:441-442`); there is no
  BODYSTRUCTURE item (`:37-43`). RFC 3501 6.4.5: BODYSTRUCTURE does not set
  `\Seen`.
- Proxy-only egress exists in cloud agents (`docs/CLOUD_AGENT.md:205-207`).

## Design

Configuration record (replaces `Mode`, parsed once per call in `mode()`,
used by `gated` and `offered_for`; any bad value is a configuration error
for every tool, as today):

| Variable | Values | Meaning |
| --- | --- | --- |
| `MAILBEND_TYPESAFE` | 1/true/0/false/empty | Jev on or off |
| `MAILBEND_TYPESAFE_KEY_FILE` | absolute path | the only key source; same owner, mode 600, no-symlink rules as `MAILBEND_PASSWORD_FILE`; read only by `mailbend-typesafe` |
| `MAILBEND_TYPESAFE_API_KEY` | must be unset | if present, every tool fails with a configuration error telling the operator to use the key file, so a key never reaches any helper |
| `MAILBEND_TYPESAFE_CONTENT` | `headers` (default) or `body` | what leaves the machine |
| `MAILBEND_TYPESAFE_ZERO_RETENTION` | bool | operator's attestation; `body` without it is a configuration error |

Jev on without a key file path is a configuration error in Bend (the path
is not secret). A key file the helper cannot use exits 2, which the core
maps to a configuration error for every Jev-consulted tool, never to
"unchecked".

Helper `mailbend-typesafe` (new Rust binary sharing `mailbend-net`):

- Re-executes itself with an allow-listed environment: `MAILBEND_TYPESAFE_KEY_FILE`,
  `MAILBEND_TIMEOUT_MS`, `MAILBEND_DOH_URL`, `MAILBEND_CA_FILE`,
  `https_proxy`/`HTTPS_PROXY`, `no_proxy`/`NO_PROXY`. `MAILBEND_APP_PASSWORD`
  and everything else is dropped.
- stdin: the JSON request (size-capped); stdout: the response body.
- Host and path are compile-time constants. Through an HTTPS proxy it uses
  CONNECT to that fixed host with full verification. Tests reach a local
  fake through the existing `MAILBEND_DOH_URL` (resolving `api.typesafe.ai`
  to 127.0.0.1) and `MAILBEND_CA_FILE`; no new redirect setting exists.
- Exit codes: 0 on 2xx; 2 key file or input problem; 3 connect/TLS;
  7 rejected key (401); 8 request refused (422); 9 overloaded or timed out
  (429/529/timeout after at most two retries). The core maps these to
  TypeSafe-specific messages.
- Built by `scripts/install.sh`; `scripts/mailbend` sets
  `MAILBEND_TYPESAFE_HELPER`; `scripts/setup-cloud.sh` readiness checks it;
  the core's absolute-path helper check (`src/tools.bend:147-152`) becomes
  generic over helper variables.

Bend side, new `src/jev.bend`:

- Question sets as data per decision (classify, delete vetoes, outgoing
  checks, injection screen), wording from the brainstorm.
- Fetch items: `IHeaders` gains List-Id, List-Unsubscribe, Auto-Submitted,
  Precedence; new `IStructure` renders `BODYSTRUCTURE`. `peek_safe` accepts
  `BODYSTRUCTURE` (deliberate, explained in the PR; the law
  `fetch_items_never_set_seen` keeps its statement).
- `Facts` record: headers, flags, size, attachment list from BODYSTRUCTURE;
  it has no body field. `state_of(Headers, facts)` reads only `Facts`;
  `state_of(Body, facts, text)` adds at most 16 KB of plain text with quoted
  replies and signatures removed.
- Strict response parser into typed answers; probabilities are quantised
  into `Band` (Low, Mid, High) at parse time; missing or malformed answers
  become `Missing`.
- Shared result object: `jev: {status: checked|unchecked|blocked, model:
  "jev-1.13.0", content: headers|body, derived_from_untrusted_content: true,
  decision: proceeded|blocked, reasons, signals}`.

`mail_classify(folder, uids, candidates?)` (does not change mail;
`is_read_only` True; listed only when Jev is on; MCP `openWorldHint: true`):

- A message's label is its category: one folder per message (user decision:
  labels move mail, no duplicates). Category options are discovered, not
  configured: the existing user folders from LIST (excluding INBOX, every role folder and `To Delete`),
  in a stable sorted order (Jev has option-order bias, jev-1.13 jaggedness
  page), plus "none". At most 254 folders fit one Choice (255 options,
  `/api.md`); more is an error that names the limit.
- Jev returns typed answers only and cannot invent names. When a message's
  category is "none" or below the confidence floor, the result marks it
  `needs_new_category`. The agent then proposes new names and calls
  `mail_classify` again with `candidates`: a second Jev request in which
  the Choice options are the existing folders plus the agent's candidates
  (plus "none"), so Jev picks for every message from one consistent list.
  A chosen candidate is returned as `new_category`; it is never created
  implicitly: the agent creates it with `mail_create_folder` (phase 3)
  before triage can file into it. Candidate names go through phase 3's
  protected-name rules.
- Per UID it also returns reply_needed, action_required, deadline_present, priority (Score),
suggested_action (Choice: read_now, read_later, label, review, none), the
delete verdict inputs, and suspected_injection when flagged. Messages are
sent in batches of at most 20 per request so the state stays under 32k
tokens.

Laws:

- `headers_state_has_no_body`: `state_of(Headers, f)` for every `Facts`
  value (the type has no body, so the law is about the builder's output
  fields) equals the documented header-only shape.
- `classify_writes_nothing`.
- `missing_answer_is_cautious`: `Missing` maps to keep / block / no action
  in every policy.
- `tools_listed_per_config`: the listed tool names for each combination of
  read-only, drafts-only and Jev on/off.

## Files

- Create: `src/jev.bend`, `tests/unit/jev.bend`, `tests/fake_typesafe.py`
  (TLS fake implementing the documented shapes, recording requests),
  `native/mailbend-typesafe/{Cargo.toml,src/main.rs}`.
- Modify: `src/tools.bend` (configuration record, error mapping, helper
  check), `src/imap.bend` (fetch items), `src/ops.bend`, `main.bend`
  (listing call sites), `LAWS.bend`, `PROOF.bend`, `tools/gen-schema.py`,
  `scripts/install.sh`, `scripts/mailbend`, `scripts/setup-cloud.sh`,
  `tests/run-unit.sh`, `tests/test-e2e.py` (`env()` pops every
  `MAILBEND_TYPESAFE*`), `.env.example`.

## Steps

1. Configuration record replacing `Mode`, with fail-closed unit tests; all
   existing switch tests still pass.
2. `mailbend-typesafe` with Rust tests for environment allow-listing, exit
   codes, proxy CONNECT and key redaction.
3. Fetch items and `Facts`; laws.
4. `jev.bend`: request builder, parser, bands; unit tests.
5. `mail_classify`; e2e against the fake: headers mode request has no body
   text (recorded request), body mode without attestation fails, env key
   set fails every tool, key file missing fails every Jev tool, 401/422/429
   map to TypeSafe messages, `/proc/<pid>/environ` of `mailbend-typesafe`
   holds no `MAILBEND_APP_PASSWORD`.

## Verification

- `bend PROOF.bend`; `sh tests/run-unit.sh`; `cargo test --locked`;
  `python3 tests/test-e2e.py` (Jev off and on).

## Risks

- Thresholds are TypeSafe's examples, not calibrated for this mailbox;
  cautious defaults.
- Zero retention cannot be verified by MailBend; README says so.
