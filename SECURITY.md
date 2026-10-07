# Security policy

MailBend handles mail credentials and mailbox contents, so please report
vulnerabilities privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/albertc71/MailBend/security/advisories/new)
(the **Security** tab, then **Report a vulnerability**). Do not open a public
issue, pull request or discussion for a suspected vulnerability.

Include the MailBend commit, your Linux distribution, and the smallest steps
that reproduce the problem. Use the local fake server (`tests/fake_mail_server.py`) or a throwaway mailbox when you can.

**Never include real credentials or mail.** Leave out app passwords
(`MAILBEND_APP_PASSWORD`), account addresses, message contents and
unredacted IMAP/SMTP transcripts. If a credential may have been exposed,
revoke it with your provider first (for iCloud: account.apple.com, Sign-In
and Security, App-Specific Passwords).

You should get an acknowledgement within a week. Fixes are released on
`main`; there are no maintained release branches.

## Scope

In scope: anything that breaks the guarantees in the README's
[Safety](README.md#safety) section and [AGENTS.md](AGENTS.md), for example

- a way to skip or weaken TLS peer or host name verification;
- the app password reaching a tool result, log or error message, or being
  read by the Bend core, `mailbend-attach` or `mailbend-typesafe`;
- the TypeSafe key reaching a tool result, log or error message, or a
  process that holds the mail password; or message text reaching TypeSafe
  without `MAILBEND_TYPESAFE_CONTENT=body` and
  `MAILBEND_TYPESAFE_ZERO_RETENTION=1`, or a request going to an endpoint
  other than `https://api.typesafe.ai/v1/systemone`;
- with Jev on, a send or permanent delete that goes ahead although the
  secret scan or Jev blocked it, or TypeSafe failed;
- a Jev check that changes an action instead of only blocking it;
- a read tool changing mailbox state (flags, `SELECT`, `EXPUNGE`);
- a plain `EXPUNGE`, or a change hitting messages other than the given UIDs;
- a way around `MAILBEND_READ_ONLY` or `MAILBEND_DRAFTS_ONLY`;
- reading an attachment from outside `MAILBEND_ATTACH_DIR`, or through a
  symlink, hard link, device or FIFO; or a download written outside
  `MAILBEND_DOWNLOAD_DIR` or over an existing file;
- IMAP, SMTP or MIME command or header injection.

Out of scope:

- an agent following instructions found in mail it was allowed to read
  (treat mail as untrusted input; use `MAILBEND_READ_ONLY=1` where writes are
  not needed and `MAILBEND_DRAFTS_ONLY=1` to review every send);
- regular files that `MAILBEND_ATTACH_DIR` itself holds;
- a wrong or missed answer from Jev;
- a secret the best-effort scan does not recognise (it catches mistakes; it
  is not a boundary against an agent set on leaking);
- problems that need control of MailBend's own configuration, binaries or
  trust store (`MAILBEND_CA_FILE` replaces the trust store by design and is
  for tests only).
