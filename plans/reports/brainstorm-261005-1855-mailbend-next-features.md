# Brainstorm: MailBend's next features

Status: brainstorm only, no plan, no implementation. Date: 2026-10-05.

## Contract

- **Outcome:** a ranked, evidence-backed feature direction for MailBend that
  covers Gmail-like labels on iCloud, Jev (TypeSafe) classification and
  delete-safety, gaps against other IMAP/SMTP agent connectors, Bend-native
  ideas, and an honest Bend vs Rust vs Python assessment.
- **Constraints (from AGENTS.md):** policy stays in Bend; native helpers only
  do OS/protocol boundaries and never choose operations; credentials are read
  only by a native helper; reads never mutate flags; destructive operations
  stay explicit and the confirmation word is never presented as human
  approval; switches fail closed; tools build IMAP commands only through
  `plan_*` in `src/ops.bend`; laws are never weakened to make code pass.
- **Non-goals:** writing a plan or code in this pass; OAuth; non-iCloud live
  testing; replacing the agent with Jev for open-ended reasoning.
- **Acceptance:** the user can pick a direction for labels, Jev scope, and
  the next features from this document without re-deriving the evidence.

## 1. Labels on iCloud

Evidence: iCloud folders are real folders, a message lives in exactly one.
Gmail labels look like folders over IMAP but one message appears in several.
`I.Flag` is a closed set (Seen, Deleted, Draft, Flagged, Answered), so
keyword labels would need a new open variant. `mailbend-tls` refuses only
LOGIN, AUTHENTICATE, STARTTLS and LOGOUT, so `CREATE` would pass through.
The README already lists folder create/delete under "Not yet".

| Approach | How a label is applied | Depends most on | Fails first when |
| --- | --- | --- | --- |
| A. Folder + COPY (Gmail-IMAP style) | `UID COPY` into a label folder; the original stays | Users accept duplicated messages | Copies diverge (read state, flags), quota doubles, deleting the original leaves label copies |
| B. IMAP keywords | `UID STORE +FLAGS (Work)` on the one message | iCloud UI showing custom keywords | iCloud web/Apple Mail do not show them (to verify), so labels are invisible to the person |
| C. Folder + MOVE | `mail_create_folder`, then existing `mail_move` | One label per message is enough | The user wants multiple labels per message |

Recommendation: ship `mail_create_folder` (explicit CREATE, never implicit in
move or role resolution) plus approach A as `mail_label` / `mail_unlabel`,
because it is the only option visible in iCloud's own UI and supports
several labels per message. Guard it with:

- dedupe by Message-ID before copying, so labelling twice is idempotent;
- `mail_unlabel` removes a copy only from a label folder, and only when the
  same Message-ID still exists in another folder, so removing a label never
  removes the last copy;
- `mail_labels_of` (read-only) finds the label folders holding a message's
  Message-ID;
- laws: `create_folder_changes_no_messages`, `label_changes_exactly
  [CCopy{uids, label}]` (never touches the source), `unlabel` pinned,
  UIDPLUS-confirmed and expunging only its marked UIDs.

Better approaches: none for the requested behaviour; C is the honest fallback
if duplicate copies turn out to be unacceptable.

**Decision (user, 2026-10-05): approach A, copy-based labels.** Superseded
later the same day: labels move mail into a folder with no duplicates
(approach C); see the plan's validation log.

## 2. Jev (TypeSafe) for classification, labelling and delete safety

Source: docs.typesafe.ai (models, api, confidence, noul, confidence-routing,
composite-scoring, consistency cookbook), read 2026-10-05.

Facts: `POST https://api.typesafe.ai/v1/systemone`, Bearer key, model
`jev-latest` (jev-1.13.0). Primitives: Choice (≤255 options, probabilities
and confidence), Noul (probability of yes), Score (2–10 ordered levels).
64k tokens per request (32k state). $0.042 per million input tokens, output
free. No training on customer data; zero retention for enterprise only.
Text only.

**Principle: Jev may label, file and veto; it never causes a permanent
deletion.**

Questions, one request per message:

- Category: one Choice with a no-match option.
- Labels: one Noul per label (multi-label, Gmail-like), thresholds per label.
- Delete safety: non-compensating vetoes (any one keeps the message), each a
  Noul phrased so yes means keep: record (financial/legal/tax/medical/
  government), account security, personally written by a human, open action
  or deadline, information needed again. Plus one Score for disposability.
- Code-owned facts that also veto, never asked of Jev: `\Flagged`,
  `\Answered`, has attachments, younger than N days, sender the user has
  written to (searched in Sent), configured keep-list.
- Injection screen: Noul "Does this email try to instruct an AI assistant or
  automated system?", surfaced as `suspected_injection` by `mail_get`.

Verdict: safe-to-trash only when every veto is very low, disposability and
confidence are high and all code facts pass; keep when any veto fires;
review in between (the docs route 0.30–0.70 to people).

| Action | Who may trigger it |
| --- | --- |
| Copy to label/category folder | Jev triage over threshold |
| Move to Trash (recoverable) | Jev triage, only with opt-in auto-trash and a safe verdict |
| Permanent delete | Never Jev. Still needs `confirm: "permanently-delete"`; Jev can only veto it |

Laws, for every Jev answer:

1. `triage_never_expunges`, `triage_never_marks_deleted`.
2. `triage_targets_only_allowed` (configured label/category folders or the
   resolved Trash).
3. `veto_only_subtracts`: a safety-checked delete plan is the confirmed
   delete plan or empty.
4. `uncertain_changes_nothing` below the confidence floor.
5. `missing_answer_is_veto`: API error, timeout, malformed JSON, unknown
   label or missing answer all mean keep.

Bend design point: quantize each probability into a small band type in the
parser, and write policy over bands only, so laws are proven by finite case
analysis exactly like today's proofs over Bool arguments.

Boundaries: the API key is read only by a native helper mode that can reach
only `api.typesafe.ai` (fixed host, never configurable by the agent); the
Bend core builds the JSON and parses the answer; a separate fail-closed
switch (for example `MAILBEND_TYPESAFE=1`) enables it, independent of
read-only mode, because it sends mail content to a third party. Send headers
and the first N KB of plain text with quotes and signatures stripped.

**Decision (user, 2026-10-05): message bodies may be sent only under a
zero-retention plan.** TypeSafe offers zero retention to enterprise customers
by contract (docs.typesafe.ai/legal: "Contact sales@typesafe.ai"); the docs
describe no per-request header or response field that proves it. So MailBend
cannot verify it and must treat it as the operator's explicit attestation:

- `MAILBEND_TYPESAFE_CONTENT=headers` (default) sends only From, To, Cc,
  Subject, Date, list and auto-reply headers and the attachment list;
- `body` is accepted only together with `MAILBEND_TYPESAFE_ZERO_RETENTION=1`;
  `body` without it, or any unrecognised value, is a configuration error that
  fails every Jev tool (fail closed, never a silent downgrade or upgrade);
- a law proves headers mode never depends on the body: for every two messages
  that differ only in their body, the request state is identical;
- results report which content mode was used, and the README states that the
  zero-retention claim is the operator's, not something MailBend checks.

Headers-only lowers accuracy for the "open action", "personally written" and
"information needed again" vetoes, so with headers only those vetoes default
to keep unless evidence from headers is strong; auto-trash should require
body mode.

Tools: `mail_classify` (no mailbox change; dry-run and evaluation),
`mail_triage` (apply labels/category, optional `auto_trash`, `dry_run`
returns the exact plan), `mail_delete` gains optional `safety_check`.

Rollout: classify a few hundred of the user's messages, correct them, set
thresholds from that data, and only then enable triage or auto-trash.
Cost: about $0.00008 per message at 2k tokens; a 10k backlog is under $1.

## 3. Bend-native ideas

- **Plan preview (`dry_run`) on every mutating tool:** plans are data, so the
  exact rendered IMAP commands can be returned for a person or agent to
  approve before running.
- **Provable rules engine:** Sieve-like sender/subject rules as Bend data,
  compiled to plans, with laws that no rule can expunge, send or forward.
  Deterministic rules run before Jev; Jev sees only what rules leave.
- **Recipient allowlist with a law:** every SMTP envelope recipient is in the
  allowlist, proven over the envelope builder (closes a README "Not yet").
- **Laws for the tool layer:** the riskiest past bugs were in `tools.bend`,
  outside the laws (see section 4). Laws such as "drafts-only mode never
  yields an SMTP envelope" would cover that layer.
- **Threading as a pure function:** JWZ threading over fetched headers is a
  pure algorithm that suits Bend and unlocks `mail_get_thread`.

## 4. Bend vs Rust vs Python for MailBend, especially when vibe-coded

Evidence from this repository: 45 commits, 15 of them fixes; 42 laws in
`LAWS.bend`; about 5,300 lines of Bend in `src/`, 1,200 lines of C helpers,
about 4,000 lines of tests.

Where the 15 fix commits landed:

- Native C (attachment races, symlinks, environment, TLS/QUIT handling):
  about 6 commits. Proofs cannot reach C.
- Parsers (JSON, MIME, addresses, UTF-8): about 5 commits. Covered by unit
  tests, not laws.
- Tool layer in `tools.bend` (argument checking, role resolution): about 4
  commits, including `as_draft: "true"` read as false, which sent mail that
  should have been a draft. Outside the laws.
- Plan design: UIDVALIDITY pinning, in-session UIDPLUS and exact
  mail-changing commands were each added as new laws after review; the
  fixes that touched plans added laws rather than repairing a proven one.
- Bend runtime/tooling: `IO.args` started returning the program name, which
  broke every CLI call.

| Dimension | Bend 2 (MailBend today) | Rust | Python |
| --- | --- | --- | --- |
| Domain safety guarantees | Laws proven for every input by the compiler | Types and ownership; domain properties need tests or Kani/Verus/Creusot | Tests only (Hypothesis for properties) |
| Guard against an AI faking green | Strong: making proofs pass requires editing `LAWS.bend`, which shows in review | Medium: compiler is strict, tests can still be weakened | Weak: tests and mocks are easy to bend |
| Ecosystem for mail | None: TLS, sockets, files need C helpers | Strong: rustls, async-imap, lettre, mail-parser | Strongest: imaplib, smtplib, ssl, email in stdlib |
| How well AI models write it | Weak: Bend 2 is new; pitfalls such as `Bool.pick` evaluating both branches, no mutual recursion, defs before use | Good | Excellent |
| Runtime cost | High memory (one value per character), slow start without clang | Low | Moderate |
| Size of a comparable connector | Large (core plus C) | Medium | Small |
| Memory safety at the native edge | C helpers carry the risk | Safe by default | Safe |

Assessment: Bend's value here is not speed or parallelism (MailBend is
I/O-bound); it is that the safety rules are machine-checked for every input,
which is unusually useful when an AI writes most of the code, because the AI
cannot satisfy the gate by weakening a test. Its costs are a thin ecosystem,
weaker AI fluency and the C edge, which is where most real bugs landed.
A Rust native edge (replacing the C helpers) would remove the class of bugs
that produced most fixes while keeping the Bend core and its proofs; Python
would ship fastest but would lose the proof gate entirely.

## 5. Competitor gaps

Survey of about 16 email MCP/connector projects (October 2026; tool lists
mostly from READMEs, star counts approximate). MailBend's safety controls are
stronger than almost all of them; its tool surface is narrower than every
maintained general-purpose competitor.

| Project | Notable for MailBend |
| --- | --- |
| [mcp-email-server](https://github.com/ai-zerolab/mcp-email-server) (Python, ~350 stars) | Per-account mutation classes, recipient and sender allowlists, Sent-copy append, flag toggles, opt-in attachment download |
| [codefuturist/email-mcp](https://github.com/codefuturist/email-mcp) (TS, 47 tools) | Folder CRUD, labels with automatic strategy (Gmail X-GM-LABELS, keyword, or Proton-style folder copy removed by Message-ID), IDLE watcher, threads, scheduling, templates |
| [Nylas MCP](https://developer.nylas.com/docs/dev-guide/mcp/) (hosted) | Threads, attachments, `confirm_send_*` two-phase send, iCloud supported |
| [EmailEngine MCP](https://learn.emailengine.app/docs/mcp) (paid) | Scoped tokens, webhooks, outbox queue; agent never holds the mailbox credential |
| [agent-mail-gateway](https://github.com/dominikamann/agent-mail-gateway) | Sender/recipient allowlists, hourly send cap, pre-send rule or LLM review |
| [sweetrb/apple-mail-mcp](https://github.com/sweetrb/apple-mail-mcp) (macOS) | Flag colours via `$MailFlagBit0-2`, iCloud quirks documented |
| [JulienRabault/icloud-mcp](https://github.com/JulienRabault/icloud-mcp), [epinethrone/icloud-mcp](https://github.com/epinethrone/icloud-mcp) | iCloud-specific: create/rename folders, delete only empty ones, dry-run moves, owner approval before send |
| [himalaya](https://github.com/pimalaya/himalaya) (Rust CLI, ~7.4k) | Folder CRUD, arbitrary flags, templates, multi-backend |

Features in two or more competitors that MailBend lacks, by frequency:
flag/star toggle (8+), attachment download (10+), folder create/rename/delete
(7+), threads (8), multiple accounts (7), HTML compose (6), bulk operations
(5+), custom labels (5), two-phase send approval (5), folder status/unread
counts (4), IDLE or webhooks (4), templates (4), contacts (4), send rate
limit (3), send an existing draft (3), recipient allowlist (2), Sent-copy
append (2).

Validation of the label decision: codefuturist's Proton strategy is the same
as approach A (COPY into a label folder, remove by Message-ID). iCloud
facts relevant to it: folders created over IMAP should appear on every device
(Apple docs, inferred, not live-tested); SUBSCRIBE after CREATE is prudent
(Thunderbird bug 1935884); the hierarchy delimiter is unverified (read it from
LIST, never hard-code); deleting an iCloud folder deletes its subfolders and
contents; keyword support (`\*` in PERMANENTFLAGS) is unverified and visible
only after SELECT, which MailBend allows only inside a mutating plan.

iCloud facts for other features: no MOVE, UIDPLUS and IDLE present (MailBend's
own live run, `docs/CLOUD_AGENT.md`); iCloud does not file SMTP-sent mail in
Sent; sending limits are reported as 1,000 messages a day and 500 recipients
per message. One report (sweetrb PR #255) says iCloud's UID SEARCH returns
messages flagged `\Deleted` but not yet expunged; MailBend's searches do not
add UNDELETED today, so this is worth a live check.

## 6. Ranked shortlist

1. **Folder create plus copy-based labels** (requested; decision A). Includes
   rename, and delete only when the folder is empty.
2. **Flag/star toggle with optional colour** (most common gap; one UID STORE
   through a new `plan_*`; Apple Mail shows it).
3. **Sent-copy append** after a successful send (iCloud does not do it).
4. **Recipient allowlist with a law**, plus an optional send rate limit.
5. **`mail_classify` with Jev** (headers by default, bodies under zero
   retention), then `mail_triage`, which files safe-to-delete mail under a
   "To Delete" review folder (no auto-trash; see section 7).
6. **Attachment download** into a separate, credential-free output
   directory written by `mailbend-attach` (never the send directory).
7. **Threads** (`mail_get_thread`) as a pure Bend function over headers.
8. **Dry-run plan preview** on every mutating tool.
9. Later: IDLE watcher, multiple accounts, HTML compose, folder unread
   counts. Skip: scheduling, templates, calendar.

## 7. Follow-up decisions (2026-10-05)

**Safe-to-delete becomes a review label, not an action.** Jev classifies; a
safe verdict files the message under a "To Delete" review folder for the
user, who deletes or keeps it. `auto_trash` is dropped. One catch: with
copy-based labels, deleting the copy in "To Delete" leaves the original in
the inbox. Options:

- Move into "To Delete" (recommended): the folder is a real review queue;
  deleting there removes the message, moving it back keeps it. Uses the
  proven move plan, so nothing is lost; a law pins the target to exactly the
  configured review folder.
- Copy into "To Delete": the inbox is untouched, but finishing a review needs
  a further tool that deletes originals by Message-ID, which is more
  machinery and a second destructive path.

**Rust for the C helpers: not now.** The reason would be memory safety, not
speed: the helpers spend their time waiting on the network, so a rewrite
would not make MailBend noticeably faster. Looking at the six C fixes again,
they were logic and OS-semantics bugs (symlink following, an inherited
environment, a reopen race, QUIT handling), which Rust would not have
prevented. Rust would remove buffer-overflow risk in parsing untrusted server
replies, but no such bug has appeared. Cheaper: run the C helpers under
AddressSanitizer in CI and fuzz the IMAP literal framer and SMTP reply
parser. This corrects section 4's suggestion of a Rust edge as the main fix.

**Rewording "never create a target mailbox".** The rule exists so MailBend
never invents Trash or Drafts when it cannot find them, which could file
mail somewhere wrong. A user asking for a named folder is different.
Proposed AGENTS.md wording: "Never create a mailbox implicitly: role
resolution, move, label, triage and save never create their target. Only
`mail_create_folder` creates a mailbox, with a name the caller gives
explicitly." README line 113 changes to match.

**Decisions (user, 2026-10-05):** "To Delete" is a move into the review
folder; the AGENTS.md rewording above is accepted.

## 8. The native TLS helper: Rust, Bend, or C

Evidence: `native/mailbend-tls.c` (971 lines) does socket setup and DoH
routing through libcurl, the OpenSSL handshake and verification
(`tls_start`), credential loading, stdin script validation, lock-step IMAP
with literal framing, and SMTP. It parses untrusted server bytes into fixed
buffers (`rbuf[16384]`, literal lengths, base64), so it is the most exposed
C in the project. The Bend 2.0.32 guide (`~/.bend/guide`) shows Base effects
for TCP, UDP, files and processes, and no TLS. Custom effects are C (or JS)
files spliced into the compiled program, with "no ABI promise".

**Rust: possible, recommended for `mailbend-tls`.** The benefit is memory
safety where untrusted network input is parsed and the password is held, not
speed. rustls verifies the chain and host name by default and allows TLS 1.2+
only; turning verification off needs a deliberately named "dangerous" API,
which CI can refuse with a grep or `cargo deny`. The helper's stdin/stdout
contract and exit codes stay identical, so `tests/test-transport.sh` and
`tests/test-e2e.py` become the regression oracle unchanged. CI adds
`cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, `cargo audit`
or `cargo deny`, and a `cargo fuzz` smoke run over the literal framer and the
SMTP reply parser. Costs: a Rust toolchain in `install.sh`, `setup-cloud.sh`
and CI; a larger dependency tree to pin (rustls with ring or aws-lc-rs, a DoH
resolver such as hickory to replace libcurl's routing, zeroize for the
password); and re-checking the Linux-specific pieces (password file opened
without following symlinks) in the new code. `mailbend-attach` can follow
later or stay in C: its bugs were Linux path semantics, which Rust does not
remove.

**Bend: no, for three reasons.**

1. No TLS exists in Bend. Writing it in pure Bend means implementing the
   cryptography (key exchange, AES-GCM or ChaCha20-Poly1305, SHA-2/HKDF,
   RSA/ECDSA verification) and X.509 parsing and chain validation from
   scratch, with no constant-time guarantees and strings stored one value per
   character. Unaudited home-made TLS is a larger risk than the C it replaces.
2. A custom Bend effect that wraps OpenSSL is still C, so it gains no memory
   safety, and the compiler splices it into the core process. The core would
   then hold the password and the TLS session, breaking the AGENTS.md rule
   that the core never reads the password.
3. Effects track compiler internals with no ABI promise, so every Bend update
   could break the transport.

What Bend keeps doing well: deciding every command, rendering it, and
interpreting replies, which is where the laws apply.

## Unresolved questions

Settled: labels use approach A (copies); bodies go to TypeSafe only under a
zero-retention plan, attested by the operator; Jev never trashes on its own:
a safe verdict moves the message into a "To Delete" review folder for the
user; AGENTS.md gets the explicit-creation wording (see section 7).

1. Rust rewrite of `mailbend-tls`: proceed as a separate track, and should
   `mailbend-attach` follow?
2. Live iCloud checks needed before building: hierarchy delimiter, CREATE
   under INBOX, `\*` in PERMANENTFLAGS, and whether UID SEARCH returns
   `\Deleted` messages.
