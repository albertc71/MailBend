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
  (`tests/fake_mail_server.py`) with a synthetic password.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Checks

Run these before opening a pull request (CI runs the same on Linux x64):

```sh
scripts/install.sh --install-bend   # builds, installs the pinned Bend if missing
bend PROOF.bend                     # must print "ALL PROOFS CHECK"
sh tests/run-unit.sh
bash tests/test-transport.sh
python3 tests/test-cloud-network.py
python3 tests/test-e2e.py
```

After editing `tools/gen-schema.py`, regenerate `src/schema.bend` with
`python3 tools/gen-schema.py`.

Use [Conventional Commits](https://www.conventionalcommits.org/) messages
(`fix:`, `feat:`, `docs:`, ...). By contributing you agree that your work is
licensed under the [MIT License](LICENSE).
