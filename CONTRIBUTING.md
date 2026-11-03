# Contributing

Thanks for helping. MailBend is small on purpose; please open an issue to
discuss larger changes before writing them.

## Ground rules

- Read [AGENTS.md](AGENTS.md): it holds the invariants every change must keep
  (verified TLS with no off switch, `EXAMINE` and `BODY.PEEK` for reads, no
  plain `EXPUNGE`, UID commands, discovered role folders, the
  native-helper boundaries and what Jev may do).
- Keep safety rules in `LAWS.bend`. Do not weaken a law to make code pass.
  The `tests/formal/budget-*-observers.bend` and `budget-observers.bend` modules,
  imported by `LAWS.bend`, are also part
  of that law contract: review changes to `admit_all`, `lengths_exact`,
  `Within` and the other observers as changes to the laws, and explain them
  in the pull request. Do not weaken an observer or premise to make a proof
  pass. The budget mutation check fingerprints `tests/formal/budget-*.bend`,
  `tests/formal/scalar-*.bend` and `tests/formal/json-size-*.bend`, including
  these observer modules, to check that its run leaves the checkout
  unchanged; this is not an approval gate for later contract changes.
- Never put real credentials, account addresses or mail in code, tests,
  fixtures, issues or pull requests. Tests run against the local fake server
  (`tests/fake_mail_server.py`) with a synthetic password, and CI scans the
  tree and history for secrets (`scripts/scan-secrets.sh`).
- Maintainers: never build or run an unreviewed pull request where real mail
  credentials are set; CI has none, so it is the place to run them. Read
  changes to the paths in [.github/CODEOWNERS](.github/CODEOWNERS) with
  particular care.
- The `permanently-delete` confirmation is not a person's approval (the agent
  supplies it); do not describe it, any tool argument or a Jev answer as
  one.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Checks

Run these before opening a pull request. CI runs proofs, unit tests, runtime suites and Rust checks on Linux x86_64
and aarch64. MailBend needs Linux 5.6+ and glibc 2.34+ on either architecture.
Fuzzing, the dedicated mutations job and the
secret scan stay on x86_64. Both architectures run `cargo deny check` and
the source checks in
[.github/workflows/ci.yml](.github/workflows/ci.yml). The native helpers
need the Rust release pinned in `native/rust-toolchain.toml`. The end-to-end
schema checks need Python `jsonschema` (`python3 -m pip install jsonschema==4.26.0`).
Use Python 3.13.18 (the CI pin), or a runtime containing the
[CPython #128110 fix](https://github.com/python/cpython/issues/128110). The MIME oracle
checks this capability: older `email.policy.default` incorrectly inserts whitespace
between adjacent encoded words in display names.
The scheduled recipe test also needs `jq` and `flock` from util-linux.
The scale contract checks need GNU `time` (`sudo apt-get install time` on Ubuntu).

```sh
scripts/install.sh --install-bend --install-rust  # build; installs Bend and Rust if missing
sh scripts/scan-secrets.sh                        # redacted secret scan, tree and history
python3 scripts/check-docs.py                     # documented names and skill tool arguments resolve
python3 tests/test-docs.py                        # drift mutations and client snippets
python3 tests/test-toolchain-installers.py         # pinned asset URLs and installer refusal paths
sh scripts/install-lean.sh                        # once: the Lean that bend --verdict needs
bend PROOF.bend --verdict                         # must print "ALL PROOFS CHECK"
bend src/tools.bend --verdict                     # retain tool-layer kernel coverage
bend tests/formal/tool-laws.bend --verdict        # tool-layer laws kept out of PROOF.bend
python3 tests/formal/check-policy.py              # pure policy boundary and rejected mutations
python3 tests/formal/check-smtp-tls.py             # bounded model plus rejected mutations
python3 tests/formal/check-role-folders.py         # role-folder proofs reject broken resolution
python3 tests/formal/check-response-image-budgets.py # budget proofs reject broken admission/cuts
python3 tests/test-writing-laws.py                # malformed guide fences fail closed
python3 tests/formal/check-writing-laws.py         # compile the guide and reject a broken plan
python3 tests/formal/check-plan-wire-mutations.py   # exact caller guards and UID wire commands
sh tests/run-unit.sh
python3 tests/test-mcp-schema-comparison.py        # bounded comparison startup and descendant cleanup
python3 tests/test-scale-contract.py               # bounded scale lifecycle and comparison controls
python3 tests/test-scale-baseline.py               # historical selected baselines match apparatus
python3 -I tests/test-scale-pair.py                   # fixed-reference paired provenance and failure controls
python3 tests/test-image-budget.py                 # helper MAX_REQUEST equals Bend's image cap
python3 tests/test-image-assets.py                 # the fake TypeSafe's image rules
bash tests/test-transport.sh
python3 tests/test-cloud-network.py
python3 tests/test-stdio.py
python3 tests/test-install.py
python3 tests/formal/check-install-swap.py
python3 tests/test-posture-inventory.py           # native egress changes need an explicit audit
python3 tests/test-posture.py                     # offline capability report and redaction
python3 tools/gen-unicode-tags.py --check         # pinned Unicode flag identifiers
python3 tests/test-output-schema.py               # strict result contract variants
python3 tests/test-mime-corpus.py                  # synthetic MIME/i18n and independent composition oracle
python3 tests/test-e2e.py
MAILBEND_TEST_MCP=1 python3 tests/test-e2e.py --tool-scenarios-only  # tools through structured MCP
python3 tests/test-scheduled-recipes.py            # fake-only one-shot recipes; no timers installed
(cd native && cargo fmt --all --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked)
```

When changing `skills/mailbend/`, run `skills-ref validate skills/mailbend` with
the [Agent Skills reference validator](https://github.com/agentskills/agentskills/tree/main/skills-ref).
Keep the entrypoint under 300 lines, use portable frontmatter without
`allowed-tools`, and retain explicit human approval before sends and deletes.
The documentation check validates tool-scoped names and arguments against
`tools/gen-schema.py`; it is not a behavioral evaluation of an agent.

The first end-to-end run includes the fixed CLI, diagnostic and MCP protocol
checks. The second repeats the tool scenarios through structured MCP without
repeating those fixed routes. Omit `--tool-scenarios-only` for a standalone
complete run, including when `MAILBEND_TEST_MCP=1` is set.

CI runs source checks and unit tests, kernel-rechecked proofs, proof mutation
checks, CLI, structured MCP and support suites on isolated standard Ubuntu
runners. Each runtime runner builds its own binaries
from the checked-out revision. This repeats build work to avoid shared-state
races and artifact storage. Rust and fuzz checks remain separate. Source,
proof and mutation lanes each install their own toolchain. The final
`checks` job requires every lane to succeed, including Rust and fuzz; skipped
or cancelled lanes do not count as a pass.

The goal is at most ten minutes of CI execution. This is a measurement target,
not a timeout or permission to omit tests. Record queue time separately.

The [bounded SMTP model](.agents/skills/smtp-tls-proofs/SKILL.md) checks an
abstraction of authentication ordering, not the Rust implementation or
cryptography. Its mutation check verifies that broken model transitions fail.
The transport suite exercises the actual helper.

The documentation check runs offline with Python 3.11 or later. It checks law
references, environment-variable names, CLI verbs in both usage texts, and every
`src/*.bend` path in the architecture's Layers section. Cite laws with Markdown
links whose labels are the exact law names and whose targets are `LAWS.bend`.
The check also recognizes `law` or `laws` followed by backtick names, a backtick
name followed by `law`, and `Laws.`-qualified references. It checks names, not whether
prose claims follow from the laws.

Environment coverage uses exact `MAILBEND_*` string literals in `main.bend`,
`src/*.bend`, and native Rust source, excluding comments and `cfg(test)` modules.
This includes names passed through helper functions and constants, not just
direct environment reads. List each name in `.env.example`, including forbidden
variables in explanatory comments. Update the checker if a source syntax change
moves configuration names out of string literals.

When the checkout is on a filesystem without Linux `O_TMPFILE` support
(for example WSL's `/mnt/c`), run the end-to-end fixtures on a native Linux
filesystem: `MAILBEND_TEST_TMPDIR=/tmp python3 tests/test-e2e.py`. This changes
only the temporary fixture directory; the attachment sandbox checks remain
in force.

After editing `tools/gen-schema.py`, regenerate `src/schema.bend` with
`python3 tools/gen-schema.py`, and update the length and hash pinned in
`tests/unit/schema.bend`.

## MIME and charset regressions

Every MIME or charset fix adds or deliberately updates a synthetic message and its
expected JSON in [`tests/corpus/`](tests/corpus/README.md). Preserve raw fixture bytes.
Record provenance and license, distinguish malformed-input recovery from valid mail,
and link known-wrong pins to an issue. Never update expected results from the tested
parser automatically. The corpus runner and the existing end-to-end suites also parse
composed messages with Python `email.policy.default`; a disagreement fails the check.

## Adding a tool

1. Add its `Op` in `src/ops.bend` (`all_ops`, `name`, `is_read_only`,
   `needs_jev`), and any IMAP commands it needs as a `plan_*` def there.
2. Add its schema and description to `tools/gen-schema.py` and regenerate
   `src/schema.bend`. Every tool that is not read-only gets `dry_run`.
3. Run it from `run_op` in `src/tools.bend`, through `preview_or_run` when
   it changes mail.
4. State what it must never do as laws in `LAWS.bend`, prove them in
   `PROOF.bend`, and update the tool-list laws, which name every tool.
   Laws are the owner's: explain each new or changed law in the pull
   request. Follow [Writing laws](docs/WRITING-LAWS.md) for proof patterns,
   vacuity checks, and an executable example.
5. Decide what Jev does in it. Most tools never ask Jev. A tool that sends
   or deletes must reach SMTP or the delete plan only through
   `Jev.outbound_checked` or `Jev.delete_checked`, which the CI source
   checks enforce; its questions are `Veto`s like `outgoing_vetoes` in
   `src/jev.bend`: a high answer vetoes, and a missing one blocks too. A
   read that shows messages may add notes through `annotated` in
   `src/tools.bend`.
6. Add end-to-end cases in `tests/test-e2e.py` (with Jev off and on when it
   asks Jev), and list it in the README's tool table (and in
   [docs/JEV.md](docs/JEV.md) when it asks Jev).

## Bend style

The Bend files follow `bend guide` and Base (`bend base`). In particular:

- A file opens with a short comment saying what it is, then a blank line,
  then its imports. Sections are a title underlined with `-` (or `=` for a
  group of sections), with a blank line above and below.
- Lines in `src/`, `main.bend`, `LAWS.bend` and `PROOF.bend` stay within
  100 columns; the generated `src/schema.bend` keeps 80. Unit tests are
  exempt, as their expected-output lines cannot wrap.
- Lists are matched as `Nil{}` and `h <> t`.
- Write `+` only on a value that is used more than once on some path.
- A helper is named after the def it serves, with a dotted suffix for its
  role: `.go` for the loop, `.step` for one step of it, `.fin` for the
  result from its final state, `.if` for a branch on a computed Bool or
  check (a problem string, empty when the check passes), `.put` for a
  branch on another computed value, `.run` for the IO work once the checks
  pass, or a noun for any other part. A def that computes the problem
  string keeps a descriptive noun name, such as `uidv_problem`.
- Arguments are built before the call, so `Bool.pick`, `&&` and `||` build
  both sides. Where a side is costly, or both sides recurse, pass the test
  to a helper that matches it.
- Where the first of several problems wins, new code checks them in a
  `do Result` block, which stops at the first; the existing `first_of`
  chains stay.

Use [Conventional Commits](https://www.conventionalcommits.org/) messages
(`fix:`, `feat:`, `docs:`, ...). By contributing you agree that your work is
licensed under the [MIT License](LICENSE).

## Upgrade Bend

Use the [Bend upgrade canary](.github/workflows/bend-canary.yml) as an early
warning, not as an upgrade approval. It runs on Mondays at 05:23 UTC and on
manual dispatch after the workflow reaches the default branch. It does not
run on pull requests. Never add its job to required checks.

The default candidate is the latest stable official Bend release. A manual
run can select an exact `N.N.N` version. The workflow records the archive
SHA256 and checks it against the release API before running it. This is an
observation of a moving release, not the reviewed checksum pin used by normal
CI. The candidate has a separate home and no mail credentials. Only
GitHub-owned actions run, with read-only repository permission and no saved
checkout credential.

1. Open the latest canary summary. Check the Bend version, archive SHA256,
   requested Lean toolchain, and every step outcome. A failed, skipped, or
   cancelled check is not a pass. Inspect the failing step's log. The smoke
   covers existing fake-server reads, CLI argument handling, and MCP framing
   in both CLI and MCP modes. It does not replace the full contributor suite.
2. Read the [official changelog](https://github.com/bendlang/bend/blob/main/CHANGELOG.md)
   for every release between the current pin and the candidate. In the upgrade
   PR, list each relevant entry and the test that checks it. Check these uses
   even when the changelog does not name a break:
   - `Process.run` in `src/tools.bend`, and helper exit or signal status in
     `src/policy.bend`.
   - `IO.args`, `IO.exit`, and compiled runtime options in `main.bend` and
     `scripts/mailbend`. Keep application arguments separate from `+RTS` and
     `-RTS` runtime options.
   - `IO.get_env` in `src/tools.bend` and configuration refusal paths.
   - `--verdict`, finite-parameter proof checks, and kernel cache invalidation.
3. Use a disposable checkout and an empty home without real credentials for
   candidate runs. Keep its `bin/bend` beside its `bend2` directory. The
   installer prepends `$HOME/.bend/bin`, so changing only `PATH` can select the
   old compiler. Clear `BENDTT`; a prebuilt kernel can bypass the Lean check.
   Run the candidate's `bend version` before each reproduction.
4. Run a tiny valid program with `--verdict` before installing Lean. Its
   infrastructure error states the required `leanprover/lean4:vN.N.N`
   toolchain. The canary does this with an empty home and a failing Lean shim.
   If the diagnostic format changes, update and test the discovery step.
   Do not guess the version or remove the proven-kernel check.
5. When the candidate checks pass, update `BEND_VERSION` and both architecture-specific `BEND_SHA256`
   values together in `scripts/install-bend.sh`. Verify the downloaded Linux
   x86_64 and aarch64 archives against their official release digests. Set `LEAN_TOOLCHAIN` in
   `scripts/install-lean.sh` to the version the candidate requests. Update the
   corresponding expected URLs and checksums in `tests/test-toolchain-installers.py`
   whenever the Bend, elan or rustup installer pins change. Keep those expectations
   independent of the installer source so the test can detect an accidental change.
6. Run every [contributor check](#checks) on the proposed pins, including
   `bend PROOF.bend --verdict`. Require `ALL PROOFS CHECK`. Run normal CI on
   the exact PR commit. Do not weaken laws, expected output, or security
   checks to accept a compiler change.
7. Include the old and new versions, both archive hashes, the requested Lean
   version, changelog coverage, test results, and unresolved limits in the PR.
   Obtain review before merging. A green canary alone does not authorize a pin
   change, a release, or a deployment. Revert both toolchain pins together if
   an upgrade must be withdrawn, then rebuild and restart the MCP process.

### First Bend 2.0.39 observation

On 31 October 2026, a local isolated Linux x64 run tested source commit
`bbe96fe33e7660b980606ad470a02d25669ea284` with the
[official 2.0.39 archive](https://github.com/bendlang/bend/releases/tag/v2.0.39).
Its SHA256 was
`6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab`,
verified against the release API. `bend version` returned `bend 2.0.39`.
The isolated verdict probe requested `leanprover/lean4:v4.34.0`.

| Check | Observed result |
| --- | --- |
| `bend main.bend --check-only` | Failed on the duplicate `Text` constructor at `src/jev.bend:100`. |
| `bend PROOF.bend --verdict` | Failed on the same declaration before proven-kernel rechecking. |
| `sh tests/run-unit.sh` | 14 passed, 11 failed. The failing imports reached the duplicate declaration. |
| `scripts/install.sh` | Native helpers built. The safety-law check rejected the same declaration, so no fresh core was published. |
| Fake-server smoke with the candidate | Skipped because the fresh candidate build failed. |

The compatibility failure is tracked in [#207](https://github.com/albertc71/MailBend/issues/207).
It is not an upgrade recommendation. The canary
adds no product fix for it. Normal CI remains on Bend 2.0.35 and its existing
Lean pin. This first observation is a local report, not a claim that the
scheduled GitHub workflow has run. Retain the workflow run summary and logs
when reproducing it on GitHub.
