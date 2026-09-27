# Cursor Cloud Agent prototype setup

MailBend is Linux-first.

## Packages

The prototype currently needs:
- Bend 2
- OpenSSL
- POSIX shell

Install Bend using the current official Bend installer. Verify with:

```sh
bend --version
openssl version
```

## Secrets

Configure these as Cloud Agent secrets/environment variables rather than
putting them in a repository file or prompt:

```text
MAILBEND_EMAIL
MAILBEND_APP_PASSWORD
```

Optional endpoint overrides are documented in `.env.example`.

## Local/core smoke test

```sh
bend main.bend
bend LAWS.bend
```

## Live IMAP proof

Only after secrets are configured:

```sh
sh scripts/imap-probe.sh
```

The probe performs LOGIN, CAPABILITY, LIST, and LOGOUT. It deliberately does
not select a mailbox, fetch messages, change flags, or delete anything.

The shell probe is temporary. It exists to prove Linux/iCloud/TLS connectivity
before we spend complexity on the Bend foreign-effect boundary.
