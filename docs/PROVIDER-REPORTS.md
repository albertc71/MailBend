# Share a provider report

Use an authorized account to collect setup evidence for a provider. The report
is opt-in and does not submit anything to GitHub or another service.

```sh
mailbend diagnose --imap --smtp --report
```

Review the output, then open a **Provider conformance report** issue. Include
the exact MailBend commit, test date, provider product, public documented
endpoints and TLS mode. Record pass, fail or not tested for each read-only tool
you tried. Do not paste the output of those tools. Never share account
addresses, credentials, private endpoints, folder names, message content or
unredacted transcripts. Follow [SECURITY.md](../SECURITY.md) for suspected
vulnerabilities and exposed credentials.

## What the JSON contains

`--report` adds `server_facts` to the normal diagnostic JSON. Omitting the flag
preserves the existing output. The flag does not authorize a connection by
itself. `--imap` and `--smtp` remain the network opt-ins, and both safety modes
remain supported.

- `mailbend_version` is the version reported by `mailbend version`.
- `imap_capabilities.tokens` contains a fixed allow-list of IMAP capability
  tokens, including UIDPLUS, MOVE, CONDSTORE and X-GM-EXT-1. Known tokens appear
  once in a stable order. `unknown_count` counts nonempty unrecognized token
  occurrences, never their contents. Parameterized tokens not listed exactly
  are unknown too. The allow-list lives in `src/provider-report.bend`.
- `roles` maps inbox, drafts, trash, sent, junk and archive to `override`,
  `advertised`, `name`, `ambiguous` or `unresolved`. It uses the existing role
  candidates and selectability rules. A single unselectable advertised folder
  is unresolved, while multiple competing candidates are ambiguous. Inbox
  uses its unique conventional name. No folder name appears.
- `smtp_auth.mechanisms` contains only PLAIN, LOGIN, XOAUTH2 and OAUTHBEARER,
  observed in EHLO after verified TLS. `unknown_count` counts other offered
  mechanism occurrences without returning them. An offer does not mean
  MailBend supports that mechanism. MailBend still authenticates only with
  PLAIN or LOGIN.

A `null` observation means it was not collected, or discovery failed. For
example, an invalid role override prevents reporting role methods. It does
not mean that the provider lacks a capability or authentication mechanism.
Inspect the existing `checks` array for the failed or skipped stage.

Reporting sends exactly the same commands as normal diagnostics. It reuses
the existing authenticated CAPABILITY, LIST, optional special-use LIST and
optional quota check, plus the existing SMTP TLS negotiation, EHLO, AUTH and
disconnect. It does not read messages, change flags, send mail or reserve a
send allowance. The JSON contains no host, IP, address, folder name, server
prose, credentials or message content.

## Evidence needed for a provider tier

A provider becomes **community-reported** only when a recorded report shows
`ok` for every applicable IMAP and SMTP stage. Both network flags must have
been used. Protocol-inapplicable stages can remain `skipped`, such as SMTP
EHLO stages on IMAP or the second EHLO in implicit SMTP mode. A skipped DNS
lookup is not a verified lookup. Missing, failed, uncertain or other skipped
applicable stages do not qualify.

A report must name the tested provider product, public settings, TLS mode,
commit and date. It is evidence for that configuration, not every plan or
account at the provider. A successful report does not establish write-path
compatibility or justify a live-tested tier. Do not change a guide's tier
without linking the recorded report or an authorized live-run record.

This change does not promote any provider. Fake-server tests validate the
reporting code, not a real provider.

## Separate write-path checklist

Only test writes when separately authorized on a disposable account with
synthetic messages and recipients. Record observations without message data.

- Labels: whether folder operations add or move labels, and how multiple
  labels affect copies, searches and deletion.
- Sent filing: whether SMTP files a Sent copy, whether MailBend's configured
  copy creates a duplicate, and which existing folder receives it.
- Deletion: the effects of move-to-trash, targeted permanent deletion and
  provider retention. Do not infer permanent deletion from disappearance in
  one folder.

Do not run these checks as part of `diagnose --report`. Do not use a production
mailbox to fill gaps in provider evidence.
