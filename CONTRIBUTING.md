# Contributing

Thanks for helping. MailBend is small on purpose; please open an issue to
discuss larger changes before writing them.

## Ground rules

- Read [AGENTS.md](AGENTS.md): it holds the invariants every change must keep
  (verified TLS with no off switch, `EXAMINE` and `BODY.PEEK` for reads, no
  plain `EXPUNGE`, UID commands, discovered special-use folders, and the
  native-helper boundaries).
- Keep safety rules in `LAWS.bend`. Do not weaken a law to make code pass.
- Never put real credentials, account addresses or mail in code, tests,
  fixtures, issues or pull requests. Tests run against the local fake server
  (`tests/fake_mail_server.py`) with a synthetic password, and CI scans the
  tree and history for secrets (`scripts/scan-secrets.sh`).
- Maintainers: never build or run an unreviewed pull request where real mail
  credentials are set; CI has none, so it is the place to run them. Read
  changes to `native/`, `LAWS.bend`, `PROOF.bend`, `src/ops.bend`,
  `tools/gen-schema.py`, `scripts/` and `.github/` with particular care.
- The `permanently-delete` confirmation is not a person's approval (the agent
  supplies it); do not describe it, or any tool argument, as one.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Checks

Run these before opening a pull request (CI runs the same on Linux x64):

```sh
scripts/install.sh --install-bend   # builds, installs the pinned Bend if missing
sh scripts/scan-secrets.sh          # redacted secret scan, tree and history
sh scripts/install-lean.sh          # once: the Lean that bend --verdict needs
bend PROOF.bend --verdict           # must print "ALL PROOFS CHECK"
sh tests/run-unit.sh
bash tests/test-transport.sh
python3 tests/test-cloud-network.py
python3 tests/test-e2e.py
```

After editing `tools/gen-schema.py`, regenerate `src/schema.bend` with
`python3 tools/gen-schema.py`.

## Bend style

The Bend files follow `bend guide` and Base (`bend base`). In particular:

- A file opens with a short comment saying what it is, then a blank line,
  then its imports. Sections are a title underlined with `-` (or `=` for a
  group of sections), with a blank line above and below.
- Lists are matched as `Nil{}` and `h <> t`.
- Write `+` only on a value that is used more than once on some path.
- A helper is named after the def it serves, with a dotted suffix for its
  role: `.go` for the loop, `.step` for one step of it, `.fin` for the
  result from its final state, `.if` for a branch on a computed Bool or
  check, `.put` for a branch on another computed value, `.run` for the IO
  work once the checks pass, or a noun for any other part.
- Arguments are built before the call, so `Bool.pick`, `&&` and `||` build
  both sides. Where a side is costly or recursive, pass the test to a
  helper that matches it.

Use [Conventional Commits](https://www.conventionalcommits.org/) messages
(`fix:`, `feat:`, `docs:`, ...). By contributing you agree that your work is
licensed under the [MIT License](LICENSE).
