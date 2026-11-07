# Independent audit preparation

This pack gives a reviewer a frozen source target and a route through the existing
evidence for [issue #174](https://github.com/albertc71/MailBend/issues/174).
It is preparation, not an independent audit report. Reviewer selection, funding,
and the audit itself remain open. This document does not close the issue.

## Frozen source

The production target is commit `0a9b4fc24a6d13e9c03cf3f9e7316c7c15078c90`.
Browse the [frozen source tree](https://github.com/albertc71/MailBend/tree/0a9b4fc24a6d13e9c03cf3f9e7316c7c15078c90).
This is a source snapshot, not a release, tag, or claim about a deployed binary.
The later commit that adds this pack is separate from the production target.
Record both commits in any audit report. A change of production target needs a
new explicit scope and a review of the intervening diff.

Read all source paths below from the frozen checkout, including its contributor
checks and claim manifests. Relative links viewed on a later branch may differ.
This pack itself is not present at the frozen production commit. Start with
[AGENTS.md](../../AGENTS.md), [architecture](../ARCHITECTURE.md), and
[native contracts](../../native/README.md).
The [threat model](../THREAT-MODEL.md) describes the earlier commit
`9a154c1a793690fef17e367da2ffe1c79548214c`. Its assumptions and evidence are
background to revalidate against this target, not an audit of this target.

## Review boundaries

Review the MailBend implementation and its dependency use across these boundaries.
The [security policy](../../SECURITY.md#scope) defines vulnerability-reporting scope.

| Boundary | Source and questions to review |
| --- | --- |
| Client input to Bend | [main.bend](../../main.bend), [JSON](../../src/json.bend), [MCP](../../src/mcp-protocol.bend), [schema](../../src/schema.bend), [tools](../../src/tools.bend), and [policy](../../src/policy.bend). Check framing, argument validation, bounds, fail-closed settings, hidden-tool refusal, and response handling. |
| Bend plans to mail transport | [ops](../../src/ops.bend), [IMAP](../../src/imap.bend), [SMTP](../../src/smtp.bend), and [mailbend-tls](../../native/mailbend-tls/). Check exact UID and UIDVALIDITY use, role discovery, EXAMINE and BODY.PEEK reads, copy-before-expunge, absence of plain EXPUNGE, SMTP ordering, recipient checks, and partial or unknown outcomes. |
| Untrusted message bytes | [MIME](../../src/mime.bend), [codec](../../src/codec.bend), [images](../../src/image.bend), [response](../../src/response.bend), and native IMAP/SMTP parsers. Check literal framing, header injection, charset handling, attachment names, truncation, and resource bounds. The [synthetic MIME corpus](../../tests/corpus/README.md) supplies independent expected results. |
| Credentials and network | [mailbend-tls](../../native/mailbend-tls/), [mailbend-typesafe](../../native/mailbend-typesafe/), [mailbend-io](../../native/mailbend-io/), and [mailbend-net](../../native/mailbend-net/). Check separate secret readers, re-execution environments, secret files, redaction, TLS peer and hostname verification, DNS, DoH, proxy routing, and timeouts. |
| Local files and child processes | [mailbend-attach](../../native/mailbend-attach/) and [mailbend-stdio](../../native/mailbend-stdio/). Check directory confinement, no-clobber downloads, send-counter reservations, descriptor handling, bounded relay, signal forwarding, child cleanup, and fixed core selection. |
| Optional Jev integration | [jev](../../src/jev.bend), [secrets](../../src/secrets.bend), and [mailbend-typesafe](../../native/mailbend-typesafe/). Check request disclosure gates, response interpretation, veto-only send/delete gates, fail-closed failures, key confinement, and the fixed TypeSafe endpoint. See [privacy](../PRIVACY.md) and [Jev](../JEV.md). |
| Build and client integration | [install and launch scripts](../../scripts/), [native dependencies](../../native/Cargo.lock), [CI](../../.github/workflows/ci.yml), [hook implementation](../../src/hook.bend), [hook declarations](../../hooks/), and [plugin declarations](../../.claude-plugin/). Check artifact selection, environment forwarding, dependency constraints, and the distinction between a client prompt and enforced tool policy. |

Bend owns policy, command plans, MIME behavior, and result interpretation. The four
native programs supply OS and protocol boundaries, not mail decisions. Review
their shared `mailbend-net` and `mailbend-io` crates as well as each executable.
An environment password can be inherited by the core and adapter even though
their code does not read it. This is not isolation from another same-user process.

The audit excludes Jev answer quality, the agent's choices or resistance to mail
instructions, and external provider behavior, retention, or delivery promises.
MailBend's validation of those inputs and handling of their failures remain in scope.
The [security-policy exclusions](../../SECURITY.md#scope) also apply, including
attacks that require control of the configured binaries, configuration, or trust
store. A delete confirmation word is not human approval. TLS authenticates the
configured peer, not the peer's honesty.

## Repeat the build and checks

Use a fresh disposable Linux VM or container on x86_64 or aarch64, with Linux 5.6+
and glibc 2.34+. Provision trusted system tools before running repository code.
The [CI workflow](../../.github/workflows/ci.yml) uses Ubuntu 24.04, Python 3.13.18,
`jsonschema==4.26.0`, build-essential, clang, OpenSSL, jq, and GNU time.
Git, curl, tar, coreutils, util-linux `flock`, and Python venv support are also needed.
Require clang 14+ so that the core is compiled rather than interpreted or reused.

Do not mount personal homes, credential stores, mailboxes, or host agent sockets.
Use an empty home and a clean environment with no inherited MailBend, proxy,
compiler, or credential overrides. For example, enter this shell in the disposable
environment after provisioning its system tools:

```sh
env -i HOME="$(mktemp -d)" PATH=/usr/local/bin:/usr/bin:/bin \
	BEND_NO_TELEMETRY=1 /bin/bash --noprofile --norc
```

The setup commands below download source, toolchains, and dependencies. They do
not test mail or Jev. Run them only in that disposable environment:

```sh
set -eu
umask 077
git clone https://github.com/albertc71/MailBend.git
cd MailBend
source_commit=0a9b4fc24a6d13e9c03cf3f9e7316c7c15078c90
git checkout --detach "$source_commit"
test "$(git rev-parse HEAD)" = "$source_commit"
test -z "$(git status --porcelain)"
command -v clang
python3 -c 'import sys; assert sys.version_info[:3] == (3, 13, 18)'
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install jsonschema==4.26.0
sh scripts/install-bend.sh
sh scripts/install-rust.sh
sh scripts/install-lean.sh
export PATH="$HOME/.bend/bin:$HOME/.cargo/bin:$HOME/.elan/bin:$PATH"
bend --version
(cd native && rustc --version && cargo --version)
elan run leanprover/lean4:v4.34.0 lean --version
clang --version
python3 --version
getconf GNU_LIBC_VERSION
uname -srmo
scripts/install.sh
sha256sum bin/mailbend-*
git diff --exit-code
```

The frozen installers select Bend 2.0.35, Rust channel `1.99` through rustup 1.29.1,
and Lean `leanprover/lean4:v4.34.0` through elan 4.2.4. They verify the downloaded
Bend archive and bootstrap installers against architecture-specific SHA-256 pins.
See [Bend](../../scripts/install-bend.sh), [Rust](../../scripts/install-rust.sh),
[Lean](../../scripts/install-lean.sh), and [the Rust toolchain file](../../native/rust-toolchain.toml).
Keep the resolved version output, installer output, source commit, and binary hashes.
Run Cargo from `native/` and preserve `Cargo.lock` with `--locked`.
`scripts/install.sh` alone does not enforce these pins when tools already exist.

This is a repeatable build procedure, not evidence of bit-identical binaries.
The host, clang, glibc, package repositories, and transitive toolchain downloads
are not fully pinned here. Record the image identity and package versions too.
Repeat on both supported architectures for evidence about both.

After setup, run the [contributor checks](../../CONTRIBUTING.md#checks) from the
frozen checkout and the additional lanes in its [CI workflow](../../.github/workflows/ci.yml).
Keep setup downloads separate from runtime tests. Stage required dependencies
before restricting runtime-test egress to the local fixtures. Do not substitute
live accounts when a fixture fails. In particular, the build's `bend PROOF.bend`
does not replace these three kernel checks:

```sh
bend PROOF.bend --verdict
bend src/tools.bend --verdict
bend tests/formal/tool-laws.bend --verdict
```

The first command must print `ALL PROOFS CHECK`; record every exit status and
complete output, including failures. The contributor list includes unit, proof
mutation, Rust, transport, MIME, CLI, MCP, attachment, and lifecycle checks.
CI also specifies claim mutations, dependency policy, and bounded parser fuzzing.
Its fuzz job uses `nightly-2026-10-06` and `cargo-fuzz` 0.13.2; cargo-deny is 0.20.2.
Neither this pack nor a link to CI records those checks as completed.

## Evidence and limits

Use [README safety claims](../../README.md#safety), the
[claim manifest](../safety-claims.json), [claim coverage](../PROOF-COVERAGE.md),
and [law catalogue](../LAWS.md) to select assertions to challenge.
[Writing laws](../WRITING-LAWS.md) explains checks against vacuous claims.
[Incident tests](../INCIDENTS.md) assume an already-compromised agent.

Pure Bend laws establish their stated function properties. They do not prove
native I/O, MIME parsing, environment loading, runtime wiring, cryptography,
compiler output, or the user's intent. The SMTP ordering model abstracts the Rust
transport. JSON size equalities use `U32` arithmetic and have wraparound limits.
See [what the proofs cover](../../README.md#what-the-proofs-cover) for the full limits.
Generated references establish that named evidence exists, not that a claim is
true. Selected mutation rejections are negative controls, not exhaustive coverage.
Synthetic tests do not establish live provider conformance or client prompt display.

An audit report should separate newly run checks, reused evidence tied to exact
source, source inspection, skipped checks, and unresolved findings. Include the
reviewer's identity, scope, tool versions, and any deviations from this procedure.

## Safe testing and private findings

For this audit, use only the repository's local fake IMAP, SMTP, and TypeSafe
servers, synthetic credentials, synthetic messages, and disposable local files.
Keep TLS verification enabled. Fixture trust roots stay local to the tests.
Never use real accounts, send real mail, call the live TypeSafe service, or publish
credentials, account addresses, message contents, or unredacted transcripts.
The pack grants no permission to test third-party services and no legal safe harbor.

Report suspected vulnerabilities through the current
[private GitHub vulnerability route](https://github.com/albertc71/MailBend/security/advisories/new)
described in [SECURITY.md](../../SECURITY.md#reporting-a-vulnerability).
Do not open a public issue, pull request, or discussion for a finding.
Include the frozen commit, host and tool versions, a minimal synthetic reproducer,
expected and observed effects, and redacted logs. Confirm the current security
policy before disclosure. Public audit results require a separate disclosure decision.
