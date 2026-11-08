# Threat model and assurance map

MailBend limits what its mail tools can do after an agent chooses a call.
It does not establish that the call serves the user's intent. This document
connects those limits to their evidence and to the threats left outside them.
It describes the repository at `9a154c1a793690fef17e367da2ffe1c79548214c`,
reviewed on 5 November 2026. It is not a certification or a new security policy.
[SECURITY.md](../SECURITY.md#scope) defines the reporting scope.

The [architecture diagram](ARCHITECTURE.md#components-and-trust-boundaries)
and [native contracts](../native/README.md) describe the implementation.
The [incident matrix](INCIDENTS.md) tests permitted actions after a synthetic
agent compromise. The [privacy policy](PRIVACY.md) describes data destinations,
retention, and provider-verification limits. Those documents remain the source
for incident results and data-handling details.

## Scope, assets, and adversaries

The target is the Linux CLI and local MCP stdio server, the Bend core, and its
four native helpers. MailBend has no hosted MCP HTTP listener or agent planner.
Its optional Jev integration is an external service.
The calling client, operating system, provider, and build tools remain separate
parts of the deployment.

The assets are:

- The mail password and TypeSafe key, including their configured files and
  temporary process buffers.
- Mailbox confidentiality and integrity, including bodies, headers, attachments,
  folders, flags, and the folder/UIDVALIDITY/UID identity used for changes.
- The user's sending identity and reputation, the exact envelope recipients,
  and the distinction between SMTP acceptance and recipient delivery.
- Files allowed under `MAILBEND_ATTACH_DIR`, new files under
  `MAILBEND_DOWNLOAD_DIR`, and the optional daily send-counter state.
- Availability of the serial MCP process and provider account, and the
  operator's mail and TypeSafe usage budgets.
- The integrity of source, compiled binaries, tool definitions, configuration,
  trust roots, and the client's record of results.

The adversaries have different access:

- A hostile sender controls message headers, bodies, MIME structure, and
  attachment bytes or names. The sender can try to inject instructions into
  the agent's context or exploit a parser, but does not thereby control the
  server's protocol framing or the operator's configuration.
- A misled or compromised agent can issue any valid call available to its
  client, repeat calls, choose recipients and attachment paths, and supply the
  delete confirmation word. It may also possess unrelated tools that MailBend
  cannot restrict. The [incident matrix](INCIDENTS.md) assumes an agent already
  obeys the attacker; it does not measure whether a model resists injection.
- A network attacker can observe connection metadata, disrupt connections,
  or influence untrusted DNS answers. TLS still requires an accepted chain
  for the configured hostname. A compromised provider or a trusted intercepting
  endpoint is stronger than this network-only attacker.
- A malicious dependency, build input, or substituted binary can change code
  before it runs. Source-level proofs and CI checks of the intended checkout
  do not constrain arbitrary replacement code.
- Another process running as the same local user may read that user's files,
  change configuration or binaries, or use the account credentials separately.
  Helper boundaries do not isolate MailBend from that attacker or from root.

## Assumptions and trust boundaries

The assurance argument assumes the intended source and binaries run on an
uncompromised supported Linux host. The operator controls the launch environment,
helper paths, credential files, dedicated file directories, state directory,
and effective trust store. The mail provider is trusted to implement mailbox
semantics and report protocol results honestly. TLS cannot establish those
facts. TypeSafe transport authentication cannot establish Jev's answer quality
or an account's retention contract.

The boundaries follow [AGENTS.md](../AGENTS.md#native-boundaries):

1. The client passes untrusted JSON and mail arguments through stdin, or the
   CLI passes them to the same tool layer. The core owns JSON framing, schema
   validation, tool selection, policy, plans, MIME processing, and result
   interpretation. Possession of the input channel is the local authority to
   call tools. There is no independent per-user authorization service inside
   MailBend.
2. `mailbend-stdio` converts inherited socket stdin to a bounded pipe for the
   fixed sibling core, with an interpreter fallback. It creates no sockets,
   reads no credentials, and makes no JSON or mail decisions. It
   inherits the launch environment. In socket-input mode it also relays
   nonblocking stdout. Its 64 KiB buffer for each relayed direction and process
   supervision are transport mechanics, not an authentication or OS sandbox.
3. The core supplies complete scripts or envelopes to `mailbend-tls` over
   stdin. That helper owns sockets, credential reads, verified TLS, protocol
   framing, and lock-step execution. It checks the whole input before
   connecting and stops on rejection or an unmet expectation. It must never
   choose, reorder, synthesize, or alter mail operations. Transcripts return
   to the core for interpretation.
4. `mailbend-attach` re-executes with an empty environment before attachment
   reads, downloads, or counter access. It must not implement mail policy or
   network access, and reads no credentials. Its filesystem checks apply to
   those operations, not to every file the local user or calling agent can access.
5. The core builds Jev requests and interprets answers. `mailbend-typesafe`
   re-executes with an allow-listed environment before reading its key file,
   then transports the request to the fixed
   `https://api.typesafe.ai/v1/systemone` endpoint. No mail password remains
   in that re-executed environment. The helper must not read mail credentials
   or make mail-policy decisions, including when credentials are file-backed.
6. Network helpers use the shared `mailbend-net` TLS implementation. Mail
   sockets connect directly to the configured IMAP or SMTP destination.
   System DNS is the default; `mailbend-cloud` opts into DoH. A numeric
   connect override changes the connection address, not the hostname verified
   by TLS. DoH verifies its own HTTPS endpoint and does not fall back to system
   DNS for the queried destination, although resolver/proxy bootstrap may use
   system DNS. HTTPS proxy settings apply to DoH and TypeSafe, not raw mail
   sockets. Endpoint TLS protects the HTTPS payload from the proxy unless the
   effective trust store authorizes interception. The proxy still sees the
   destination and connection metadata. None of these routes is an egress
   allowlist.
7. Mail and results cross back into the calling client's context, logs, and
   possible model services. MailBend does not control that client's retention,
   onward disclosure, permission prompts, or execution of downloaded content.

The environment password can be inherited by the core and adapter even though
their code never reads it. A password file removes that environment copy, not
the local user's access to the file. The secret-reading helpers disable core
dumps and Linux dumpability before reading secrets, but this is process-local
hardening. It does not make a compromised same-user process safe. See
[credential limits](ARCHITECTURE.md#credentials) and the
[network privacy boundaries](PRIVACY.md#destinations-and-third-party-sharing).

## Evidence and control limits

**Proved** below means a stated property of the linked pure Bend functions.
It does not mean the OS, native I/O, deployed binary, or agent was proved safe.
**Tested** identifies a runtime behavior exercised by named synthetic tests.
**Reviewed** identifies source inspection without a proof of that behavior.
Test links identify evidence to run, not a claim that this document reran every
suite or establishes a particular deployment's state.

The [law catalogue](LAWS.md), [claim coverage](PROOF-COVERAGE.md), and
[claim manifest](safety-claims.json) retain the detailed mappings and negative
controls. [What the proofs cover](../README.md#what-the-proofs-cover) defines
their limits. A generated inventory or a source grep alone does not establish
that a prose security claim follows from a law.

### C1. Calls obey configured policy, not inferred intent

Proved properties include [read_only_refuses_writes](../LAWS.bend),
[drafts_only_refuses_sends](../LAWS.bend),
[malformed_switch_is_bad](../LAWS.bend),
[bad_read_only_rejects_config](../LAWS.bend),
[bad_drafts_only_rejects_config](../LAWS.bend),
[bad_typesafe_rejects_config](../LAWS.bend),
[bad_zero_retention_rejects_config](../LAWS.bend),
[bad_images_rejects_config](../LAWS.bend), and
[allowlist_refuses_unlisted](../LAWS.bend).
The pure [policy](../src/policy.bend) rejects forbidden calls, even if the caller
knows a hidden tool's name. The [SMTP envelope builder](../src/smtp.bend)
checks every envelope recipient, including Bcc.

`MAILBEND_READ_ONLY` refuses mutations and hides mutating tools.
`MAILBEND_DRAFTS_ONLY` refuses sends and hides `mail_send`; reply and forward
remain listed because they can save drafts with `as_draft=true`. An unrecognized
value in the shared Boolean configuration (`MAILBEND_READ_ONLY`,
`MAILBEND_DRAFTS_ONLY`, `MAILBEND_TYPESAFE`, `MAILBEND_TYPESAFE_ZERO_RETENTION`,
or `MAILBEND_TYPESAFE_IMAGES`) fails closed, never reads as off: every known
tool call fails, although listing falls back to the read tools that do not
need Jev. These switches are not the complete fail-closed set: the other TypeSafe
settings checked by [`config_of`](../src/policy.bend) can also reject the shared
configuration; those other rejections are tested, not proved. The laws cover
pure classification, malformed-switch configuration rejection, and policy refusal.
Environment loading, listing, and the runtime refusal path in [the tool layer](../src/tools.bend)
remain tested wiring. [End-to-end tests](../tests/test-e2e.py) exercise these
paths in `read_only`, `jev_switches`, `jev_images`, and `setup_diagnostics`;
`gates_tool_list` checks the offered tool metadata. Send-only settings are
separate: `send_settings` tests malformed send settings refusing sends while
leaving drafts and reads working. `allowlist`, `allowlist_reply_all`, and
`daily_limit` cover the recipient and quota controls.
The same suite's `compose` cases test malformed argument types and names
before any send. Schema validation is a tested input boundary, not a proof of
the caller's intent.

The daily cap is a tested, locked [local reservation counter](../native/mailbend-attach/src/count.rs),
not a proof of delivery or a tamper-resistant account-wide quota. A reservation
can survive a failed send. Drafts-only still permits other mailbox changes.
Read-only still reveals mail and can permit configured Jev sharing. An allowed
recipient can be malicious, and no allowlist means no recipient restriction.

### C2. Plans preserve mailbox identity and command structure

The [plan constructors](../src/ops.bend) and [wire renderer](../src/imap.bend)
have narrow proofs such as [get_writes_nothing](../LAWS.bend),
[fetch_items_never_set_seen](../LAWS.bend),
[delete_pins_callers_uidvalidity](../LAWS.bend),
[move_expunges_only_copied](../LAWS.bend), and
[expunge_renders_uid_expunge](../LAWS.bend).
These cover command selection, identity guards, and specific rendering, not
provider correctness or a transactional rollback.

The [native IMAP session](../native/mailbend-tls/src/imap/session.rs) handles
literals as bytes and waits for each command's tagged result.
[Transport tests](../tests/test-transport.sh) exercise spoofed protocol lines
inside literals, rejected commands, and refused APPEND literals.
[End-to-end tests](../tests/test-e2e.py) exercise stale UIDVALIDITY, mutations,
fallback plans, and header/envelope injection refusals in `compose`.
The [native SMTP envelope parser](../native/mailbend-tls/src/smtp/envelope.rs)
tests forbidden helper verbs and incomplete DATA input. MIME parsing and
native framing remain tested code.
Stopping after an earlier command succeeds can leave a partial change.

### C3. Secrets have separate readers, not separate user identities

Reviewed code places the mail credential read in
[`creds::load`](../native/mailbend-tls/src/creds.rs) and the TypeSafe key read
behind [environment confinement](../native/mailbend-typesafe/src/environment.rs).
The shared [secret-file reader](../native/mailbend-io/src/secret.rs) checks an
absolute, non-symlink regular file owned by the process user, without group or
other access. [Dump controls](../native/mailbend-io/src/process.rs) precede
secret reads. Login replies are not forwarded; TypeSafe's
[response handling](../native/mailbend-typesafe/src/api.rs) redacts its key.

[Native process tests](../native/mailbend-io/tests/process.rs),
[credential-lifetime tests](../native/mailbend-tls/src/credential_lifetime.rs),
[transport tests](../tests/test-transport.sh), and
[end-to-end `password_file` cases](../tests/test-e2e.py) exercise these controls.
They are not Bend proofs or secure-erasure guarantees. Libraries, inherited
environments, privileged debugging, and user-readable credential files remain
outside any claim of isolation from a compromised local user.

### C4. TLS authenticates the configured endpoint

The shared [TLS client](../native/mailbend-net/src/tls.rs) requires TLS 1.2 or
1.3 with chain and hostname verification. IMAP uses implicit TLS. SMTP uses
mandatory STARTTLS or the explicitly configured implicit mode, without a
plaintext fallback. [Transport tests](../tests/test-transport.sh) reject bad
roots, wrong names, expired certificates, and self-signed certificates.
[Cloud-network tests](../tests/test-cloud-network.py) check trust overrides,
DoH, numeric connection overrides, and direct mail ignoring proxy settings.

The [SMTP ordering model](../tests/formal/smtp-tls.bend) is a proved abstraction,
not a proof of Rust or cryptography. Operators choose the trusted roots and
configured mail hosts. Trust overrides can authorize an intercepting peer.
The [mail route](../native/mailbend-tls/src/route.rs) and
[TypeSafe route](../native/mailbend-typesafe/src/api.rs) preserve endpoint
identity but do not restrict all outbound traffic from the host or client.

### C5. Local file operations stay within configured roots

The tested [attachment reader](../native/mailbend-attach/src/read.rs) uses
`openat2` and descriptor checks to refuse paths that escape the root, symlinks,
non-regular files, extra hard links, and procfs/sysfs files. The
[download writer](../native/mailbend-attach/src/save.rs) separates download and
attachment roots, refuses executable/startup destinations, and links a new
unnamed file without replacing an existing path.
[End-to-end tests](../tests/test-e2e.py) include `attach_dir_guards` and
`downloads`; [native CLI tests](../native/mailbend-attach/tests/cli.rs) exercise
the helper itself.

These controls do not authorize disclosure of ordinary files already inside
the attachment root. A concurrent local writer can still change an opened
file's contents or links. Downloaded content remains untrusted; MailBend does
not establish that another program can safely open or execute it.

### C6. Jev may veto or annotate, not approve

[headers_state_has_no_body](../LAWS.bend) and
[outgoing_headers_state_has_no_body](../LAWS.bend) concern the pure
[request builders](../src/jev.bend). Body mode requires the operator's
zero-retention statement. Only opted-in classification sends eligible images.
That statement is configuration, not verification of a TypeSafe contract.
Headers, addresses, subjects, and attachment names can themselves be sensitive.
Exact categories and image limitations are in the [privacy policy](PRIVACY.md#what-jev-receives).

[send_veto_only_subtracts](../LAWS.bend),
[delete_veto_only_subtracts](../LAWS.bend), and
[failure_blocks_outbound](../LAWS.bend) prove properties of the pure gates.
[CI source checks](../.github/workflows/ci.yml) restrict alternative callers;
[end-to-end tests](../tests/test-e2e.py) include `gates_vetoes`,
`gates_delete_vetoes`, `gates_failure`, and `gates_secret_scan`.
Those tests use deterministic answers, not evidence of Jev's accuracy.

Jev is off by default. With Jev off, TypeSafe requests are skipped. Outgoing
sends require the local scan when Jev is on or `MAILBEND_SECRET_SCAN` is
enabled; drafts remain unscanned. The scan is best effort, not an
arbitrary-exfiltration boundary. Classification and triage use Jev's answers
among offered folders and `To Delete`; a wrong answer can still produce a
wrong filing decision.
Jev never grants human approval or makes untrusted mail safe to follow.

### C7. Results preserve uncertainty and work has finite local bounds

[smtp_unconfirmed_is_unknown](../LAWS.bend) and
[smtp_acceptance_survives_exit](../LAWS.bend) prove pure outcome interpretation.
The [end-to-end `smtp_outcomes` tests](../tests/test-e2e.py) check native progress
wiring. SMTP acceptance is not recipient delivery. The
[stdio lifecycle tests](../tests/test-stdio.py) check that a started helper may
continue after the core stops. The helper cannot report a new plan result then,
although already-written response bytes can still drain to the client.
MailBend does not replay SMTP automatically.

The [MCP input loop](../main.bend) bounds lines to 8 MiB. The
[stdio adapter](../native/mailbend-stdio/src/relay.rs) bounds its relay buffer.
The [tool runner](../src/tools.bend) limits helper output and runtime while
the core lives. [Response](../src/response.bend) and [image](../src/image.bend)
budgets have pure proofs and tested acquisition paths, with the byte-counter
premises in [the proof limits](../README.md#what-the-proofs-cover).
These are not a total MCP wire-size, total workflow cost, or account login-rate
guarantee. [Resource work](https://github.com/albertc71/MailBend/issues/83) and
[login pacing](https://github.com/albertc71/MailBend/issues/159) remain open.

### C8. Build checks constrain the reviewed source

Tool definitions come from the [schema generator](../tools/gen-schema.py).
[CI](../.github/workflows/ci.yml) regenerates them and rejects drift. It also
pins action revisions and checks forbidden transport APIs and gate callers.
[Bend](../scripts/install-bend.sh), [rustup-init](../scripts/install-rust.sh),
and [elan](../scripts/install-lean.sh) downloads have SHA256 pins checked before
execution. [Installer tests](../tests/test-toolchain-installers.py) exercise
asset selection and refusal paths. The lockfile and
[`cargo-deny` policy](../native/deny.toml) constrain dependency resolution,
sources, licenses, and named forbidden crates.

These are reviewed build controls, not proof that a dependency or installed
binary is benign. They do not attest releases or authenticate another MCP
server's tool definitions. [Attested releases](https://github.com/albertc71/MailBend/issues/71)
and [crate allow-listing and cargo-vet](https://github.com/albertc71/MailBend/issues/127)
remain open.

### C9. Prompts and diagnostics are not consent or an audit journal

[delete_needs_confirmation](../LAWS.bend) proves that the wrong word produces
no delete plan. An agent can supply the right word. The optional
[Claude Code hook](CLAUDE-HOOK.md) has an ask-or-no-decision contract backed by
[hook_never_allows_or_denies](../LAWS.bend) and
[hook tests](../tests/test-hook.py). It does not prove a client displayed a
prompt or a human approved the action. Direct CLI calls and other clients do
not acquire that hook's behavior.

The [generated schemas](../tools/gen-schema.py) also set
`anthropic/requiresUserInteraction: true` on send, reply, forward, and permanent
delete tools. This includes dry runs and replies or forwards saved as drafts.
[Schema tests](../tests/test-output-schema.py) check this static metadata.
It requests client interaction, not an enforced server approval gate. Other
clients may ignore it, the CLI does not use it, and a client or SDK callback
can answer without a person. The [MCP client-prompt contract](MCP.md#client-prompts-and-tool-annotations)
records the vendor-specific behavior and its verification limits.
[Client-attested approval](https://github.com/albertc71/MailBend/issues/88)
remains undecided.

Results and diagnostics can be captured by the client, but MailBend has no
persistent application audit journal. The send counter records reservations,
not calls or their outcomes. The [offline posture report](CLOUD_AGENT.md#offline-posture)
describes configuration, not observed traffic or a security verdict.
The opt-in [redacted provider report](PROVIDER-REPORTS.md) adds diagnostic
observations without submitting them anywhere. Its `provider_reports`
[end-to-end cases](../tests/test-e2e.py) test the finite report fields and
redaction; they are not a proof. The operator must review the output before
sharing it in a public issue. A report does not establish write-path support
or compatibility for every account at a provider.
[Audit and trace proposals](https://github.com/albertc71/MailBend/issues/91)
remain open. A reviewer cannot infer missing actions from an absent client log.

## Framework mappings

The following sources were read on **5 November 2026**:

- [OWASP MCP Top 10](https://owasp.org/projects/mcp-top-10), beta,
  identifiers `MCP01:2025` through `MCP10:2025`.
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/),
  Version 2026, December 2025, published 9 December 2025.
- [CoSAI MCP security whitepaper](https://github.com/cosai-oasis/ws4-secure-design-agentic-systems/blob/main/whitepapers/model-context-protocol-security.md),
  version 2.0, last updated 12 August 2026, marked Draft.

The MCP rows use OWASP's item names; the other short labels summarize their
categories. The mappings are MailBend's analysis, not an OWASP or CoSAI assessment. **Addressed** means the narrowly
stated property has a law or test and no identified gap in that scope.
**Partial** means controls cover only part of the category. **Out of scope**
means this connector does not own the capability or trust decision.
**Open** means a relevant gap remains without an implemented solution.
Broad categories are not marked addressed merely because one local gate works.
No CoSAI assurance level or framework compliance is claimed.

### OWASP MCP Top 10

| Item and short label | Status | Evidence and covered behavior | Residual risk |
| --- | --- | --- | --- |
| MCP01:2025 Token Mismanagement & Secret Exposure | partial | [C3](#c3-secrets-have-separate-readers-not-separate-user-identities) separates secret readers and tests file, process, and output controls. | Inherited environments and same-user file access remain. No compromised-host or secure-erasure guarantee exists. |
| MCP02:2025 Privilege Escalation via Scope Creep | partial | [C1](#c1-calls-obey-configured-policy-not-inferred-intent) proves policy refusals and the recipient allowlist; [C5](#c5-local-file-operations-stay-within-configured-roots) tests file scope. | The caller gets the configured account access, not per-task delegated scopes. Read-only does not hide sensitive folders. [Least-privilege reads](https://github.com/albertc71/MailBend/issues/90) remain proposed. |
| MCP03:2025 Tool Poisoning | partial | [C8](#c8-build-checks-constrain-the-reviewed-source) records static generated schemas and CI drift checks. | Static definitions can still be malicious if source or binaries are replaced. MailBend cannot authenticate other tools or prevent a client from trusting hostile mail. |
| MCP04:2025 Software Supply Chain Attacks & Dependency Tampering | partial | [C8](#c8-build-checks-constrain-the-reviewed-source) records checksum pins, locked dependencies, and CI controls. | Pins do not establish benign upstream code. [Attestation](https://github.com/albertc71/MailBend/issues/71) and [crate audit coverage](https://github.com/albertc71/MailBend/issues/127) remain open. |
| MCP05:2025 Command Injection & Execution | partial | [C2](#c2-plans-preserve-mailbox-identity-and-command-structure) links exact rendering laws and native literal-framing tests. [C5](#c5-local-file-operations-stay-within-configured-roots) covers download destinations. | Native parsing and MIME handling are tested, not proved. A caller's shell or later execution of a download is outside these controls. |
| MCP06:2025 Prompt Injection via Contextual Payloads | open | [SECURITY.md](../SECURITY.md#scope) excludes an agent obeying mail; the [incident matrix](INCIDENTS.md) measures containment after compromise. | Valid malicious calls can succeed. [Content signals](https://github.com/albertc71/MailBend/issues/57), [post-read policy](https://github.com/albertc71/MailBend/issues/89), and [restricted reads](https://github.com/albertc71/MailBend/issues/90) are not implemented protections. |
| MCP07:2025 Insufficient Authentication & Authorization | partial | [C4](#c4-tls-authenticates-the-configured-endpoint) tests endpoint authentication. [C1](#c1-calls-obey-configured-policy-not-inferred-intent) constrains calls after local launch. | Stdio possession authorizes calls under shared configuration. There is no independent caller identity, per-human consent, or protection from the same local user. |
| MCP08:2025 Lack of Audit and Telemetry | open | [C9](#c9-prompts-and-diagnostics-are-not-consent-or-an-audit-journal) distinguishes current results, diagnostics, and the counter from the [audit proposal](https://github.com/albertc71/MailBend/issues/91). | Caller logs can be absent, altered, or lost with a stopped process. There is no complete or tamper-evident action history. |
| MCP09:2025 Shadow MCP Servers | out of scope | [Client configuration](MCP_CLIENTS.md) selects a local launcher; [C8](#c8-build-checks-constrain-the-reviewed-source) covers this repository's build controls. | MailBend does not discover or govern other servers, client registrations, or substituted installations. Deployment inventory remains the operator's responsibility. |
| MCP10:2025 Context Injection & Over-Sharing | partial | [C6](#c6-jev-may-veto-or-annotate-not-approve) bounds Jev request categories. [Privacy boundaries](PRIVACY.md) identify the caller's onward sharing. | Headers can be confidential. Returned mail remains hostile context. Read-only, truncation, and a secret scan do not prevent arbitrary disclosure through the caller or an allowed send. |

### OWASP Top 10 for Agentic Applications

| Item and short label | Status | Evidence and covered behavior | Residual risk |
| --- | --- | --- | --- |
| ASI01 Goal hijacking | open | The [incident matrix](INCIDENTS.md) exercises tool sequences after agent compromise; [C1](#c1-calls-obey-configured-policy-not-inferred-intent) limits configured effects. | MailBend cannot decide the agent's true goal or distinguish an attacker-induced valid call from an intended one. Prompt-injection resistance is not established. |
| ASI02 Tool misuse | partial | [C1](#c1-calls-obey-configured-policy-not-inferred-intent), [C2](#c2-plans-preserve-mailbox-identity-and-command-structure), and [C6](#c6-jev-may-veto-or-annotate-not-approve) link policy, exact plans, and optional veto evidence. | An allowed send, move, or confirmed delete can still be unwanted. Dry-run previews do not bind or approve a later call. |
| ASI03 Identity and privilege abuse | partial | [C3](#c3-secrets-have-separate-readers-not-separate-user-identities) limits credential handling; [C1](#c1-calls-obey-configured-policy-not-inferred-intent) restricts mail effects. | The agent acts through the user's configured account. There is no per-agent identity or independent human authorization, and same-user credential access remains. |
| ASI04 Agentic supply-chain compromise | partial | [C8](#c8-build-checks-constrain-the-reviewed-source) records repository build controls and [#127](https://github.com/albertc71/MailBend/issues/127). | The model, client, other tools, upstream dependencies, and substituted binaries are not made trustworthy by MailBend's proofs. |
| ASI05 Unexpected code execution | partial | [C2](#c2-plans-preserve-mailbox-identity-and-command-structure) tests protocol framing; [C5](#c5-local-file-operations-stay-within-configured-roots) restricts file writes. The [schema generator](../tools/gen-schema.py) and [generated tool list](../src/schema.bend) expose no arbitrary-shell tool, checked by the [schema unit pins](../tests/unit/schema.bend). The proved [tools_listed_per_config](../LAWS.bend) law fixes the pure operation-name list for each configuration. | Parsers and dependencies remain trusted implementation code. Separate shell tools, compromised binaries, and later execution of downloaded content are outside the boundary. |
| ASI06 Poisoned memory or context | partial | [C6](#c6-jev-may-veto-or-annotate-not-approve) limits external model requests; [privacy documentation](PRIVACY.md#collection-use-and-local-storage) records the absence of a MailBend mailbox database. | Hostile mail persists at the provider and may be reread. The client can retain poisoned context or memory; MailBend does not sanitize agent memory or learn trusted facts from it. |
| ASI07 Insecure agent communication | partial | [C4](#c4-tls-authenticates-the-configured-endpoint) covers mail and TypeSafe transport; [the stdio boundary](#assumptions-and-trust-boundaries) is local inherited I/O. | TLS does not authenticate an email author's intent or an inter-agent instruction. MailBend supplies no agent-to-agent authorization or trust negotiation. |
| ASI08 Cascading failures | partial | [C7](#c7-results-preserve-uncertainty-and-work-has-finite-local-bounds) preserves uncertain outcomes and local bounds; [C2](#c2-plans-preserve-mailbox-identity-and-command-structure) stops a rejected plan. | Earlier effects are not rolled back. A stopped core loses results, external retries can duplicate effects, and repeated valid calls can exhaust provider or API budgets. |
| ASI09 Exploited human trust | partial | [C9](#c9-prompts-and-diagnostics-are-not-consent-or-an-audit-journal) links the mistake guard, interaction metadata, optional ask-only hook, and [approval decision](https://github.com/albertc71/MailBend/issues/88). | A word, dry run, Jev answer, metadata flag, or hook output does not attest human consent. A misleading client presentation or auto-accepting client remains possible. |
| ASI10 Rogue agents | partial | [C1](#c1-calls-obey-configured-policy-not-inferred-intent) and the [incident matrix](INCIDENTS.md) establish specific connector limits even for an obedient attacker-controlled caller. | MailBend does not detect rogue intent, revoke a caller's other tools, or prevent all exfiltration. The operator and provider own credential revocation. |

### Supplemental CoSAI concern

CoSAI's [MCP-T10 resource-management category](https://github.com/cosai-oasis/ws4-secure-design-agentic-systems/blob/main/whitepapers/model-context-protocol-security.md#mcp-t10-resource-managementrate-limiting-absence)
has no direct OWASP MCP Top 10 counterpart in its mapping. It merits a separate
row even though some effects also fit ASI08. The local stdio and outbound network
boundaries above also address the deployment questions raised by CoSAI's
[MCP-T7 transport category](https://github.com/cosai-oasis/ws4-secure-design-agentic-systems/blob/main/whitepapers/model-context-protocol-security.md#mcp-t7-session-and-transport-security-failures)
and [MCP-T8 network-isolation category](https://github.com/cosai-oasis/ws4-secure-design-agentic-systems/blob/main/whitepapers/model-context-protocol-security.md#mcp-t8-network-bindingisolation-failures).
Having no HTTP listener does not restrict outbound destinations or isolate
processes of the same user.

| Item and short label | Status | Evidence and covered behavior | Residual risk |
| --- | --- | --- | --- |
| MCP-T10 Resource and cost limits | partial | [C7](#c7-results-preserve-uncertainty-and-work-has-finite-local-bounds) records input, output, response, image, and runtime bounds. [C1](#c1-calls-obey-configured-policy-not-inferred-intent) records the optional daily send cap. | There is no general tool-call, login-rate, or TypeSafe cost budget. Serial calls can block later work. The counter is not tamper-resistant, and a helper can outlive the core without a total-plan deadline. [#159](https://github.com/albertc71/MailBend/issues/159) and [#83](https://github.com/albertc71/MailBend/issues/83) track related work. |

## Residual risks and upkeep

The reporting exclusions in [SECURITY.md](../SECURITY.md#scope) still apply.
In particular, this document does not claim protection from an agent following
mail, an allowed attachment's disclosure, a wrong Jev answer, an unrecognized
secret, or control of MailBend's configuration, binaries, or trust store.
It also does not establish recipient delivery, attested human consent, or
containment of arbitrary exfiltration through the wider agent environment.

Claims about an untested provider, a compromised dependency, or a client's
permission enforcement remain review-only assumptions or attack hypotheses,
not validated findings. The incident fixtures and failure tests cover specified
synthetic cases, not every attack or deployment. Open issue links identify
proposals or missing evidence, not promises that those mitigations will ship.

Changes to helpers, plans, gates, tool schemas, credentials, egress, file access,
or client authority can change this map. The pull request template asks whether
the map is affected. The existing [claim-maintenance process](SAFETY-CLAIMS.md)
and [contributor checks](../CONTRIBUTING.md#checks) remain unchanged.
