# Contributing

Thanks for helping. MailBend is small on purpose; please open an issue to
discuss larger changes before writing them.

## Ground rules

- Read [AGENTS.md](AGENTS.md): it holds the invariants every change must keep
  (verified TLS with no off switch, `EXAMINE` and `BODY.PEEK` for reads, no
  plain `EXPUNGE`, UID commands, discovered role folders, the
  native-helper boundaries and what Jev may do).
- Keep safety rules in `LAWS.bend`. Do not weaken a law to make code pass.
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

Run these before opening a pull request. CI runs the same on Linux x64,
plus `cargo deny check`, a fuzz smoke run and the source checks in
[.github/workflows/ci.yml](.github/workflows/ci.yml). The native helpers
need the Rust release pinned in `native/rust-toolchain.toml`.

```sh
scripts/install.sh --install-bend --install-rust  # build; installs Bend and Rust if missing
sh scripts/scan-secrets.sh                        # redacted secret scan, tree and history
sh scripts/install-lean.sh                        # once: the Lean that bend --verdict needs
bend PROOF.bend --verdict                         # must print "ALL PROOFS CHECK"
sh tests/run-unit.sh
bash tests/test-transport.sh
python3 tests/test-cloud-network.py
python3 tests/test-e2e.py
(cd native && cargo fmt --all --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked)
```

After editing `tools/gen-schema.py`, regenerate `src/schema.bend` with
`python3 tools/gen-schema.py`, and update the length and hash pinned in
`tests/unit/schema.bend`.

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
   request.
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
