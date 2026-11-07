# Governance

## Ownership and review

MailBend's current owner is [@albertc71](https://github.com/albertc71).
[CODEOWNERS](.github/CODEOWNERS) assigns every path to the owner and lists
safety-critical paths explicitly.

Every pull request needs the owner's approval. This includes documentation,
tests, and synthetic fixtures. Those are useful places to start contributing,
but they have no approval exemption. Passing checks does not replace review.
CODEOWNERS records ownership; it does not by itself enforce branch protection.

## Proposals

The [issue chooser](https://github.com/albertc71/MailBend/issues/new/choose)
offers bug reports, feature requests, and provider conformance reports.
Larger changes start with an issue that describes the problem, desired outcome,
and affected [AGENTS.md constraints](AGENTS.md). The owner decides whether a
proposal fits the project before contributors invest in a large implementation.
An accepted proposal still needs a reviewed pull request.

Suspected vulnerabilities go through the private route in
[SECURITY.md](SECURITY.md), not a public issue or pull request.
Reports, proposals, and patches must not contain real credentials, account
addresses, or mail. Reproductions use synthetic data and the
[local fake server](tests/fake_mail_server.py).

## Law changes

The owner reviews changes to [LAWS.bend](LAWS.bend), including the observer
contracts described in [Contributing](CONTRIBUTING.md#ground-rules).
Each proposal explains the safety promise and why it needs to change.
The pull request quotes every new or changed law and explains its effect.
It includes the proofs, tests, and rejected mutations required by
[Writing laws](docs/WRITING-LAWS.md) and the
[contributor checks](CONTRIBUTING.md#checks).

Never weaken a law, observer, premise, or test to make code pass.
Changes to this governance policy also need owner approval.
