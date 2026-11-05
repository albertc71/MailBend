# Provider setup and evidence

Only the existing iCloud profile has a recorded live MailBend run. This guide
separates provider documentation from tests of MailBend itself. Sources were
checked on 2026-11-05; no provider was contacted with account credentials for
this guide. A source-check date is not a live-test date.

## Evidence tiers

| Tier | Evidence required |
| --- | --- |
| Live-tested | A recorded, authorized MailBend run with a date, account profile, and tested operations. New records must also name the MailBend version or commit. |
| Fake-tested | Named provider behavior reproduced in the synthetic server with a linked passing test. This establishes only that behavior, not access to that provider. |
| Community-reported | A redacted user report with a date, commit, issue link, and successful IMAP and SMTP diagnostic stages. Individual mail operations remain unverified unless the report tests them. |
| Unverified | Documented settings or a candidate configuration without a qualifying MailBend run or provider-specific conformance test. |
| Unsupported | The described profile requires authentication or transport that MailBend cannot use. |

The unverified tier prevents a settings page from being mistaken for a test.
The existing [iCloud record](CLOUD_AGENT.md#live-icloud-record) is dated but
does not name a MailBend revision. Its historical live-tested status does not
establish a live pass for every later commit.
The [synthetic transport suite](../tests/test-transport.sh) covers verified
TLS and both SMTP modes. It does not make every provider below fake-tested.
No provider has a community-reported entry in this guide yet.

## Shared setup rules

Start with `MAILBEND_READ_ONLY=1`. The print-only
[setup command](../README.md#print-a-provider-configuration) supplies reviewed
presets where available. Review its host names, ports, and account prerequisites
before applying anything. It does not prove that an account works.

- Put the credential only in an owner-only file with mode `600`, referenced by
  `MAILBEND_PASSWORD_FILE`. Use an absolute path outside attachment directories.
  Do not put a password in command arguments, JSON, a report, or this repository.
  Follow the [password-file instructions](../README.md#print-a-provider-configuration).
- `MAILBEND_EMAIL` is the full sending address. Unless an entry says otherwise,
  leave `MAILBEND_LOGIN` unset so it uses that address. A nonempty login is used
  for both IMAP and SMTP; it does not change the From address.
- Set `MAILBEND_IMAP_HOST` and `MAILBEND_IMAP_PORT` explicitly. IMAP requires
  implicit TLS. Set `MAILBEND_SMTP_HOST`, `MAILBEND_SMTP_PORT`, and
  `MAILBEND_SMTP_TLS_MODE` together. The mode is `implicit` or `starttls`;
  a port number never selects it. There is no plaintext fallback or
  certificate-verification bypass.
- After the account owner authorizes a connection,
  `mailbend diagnose --imap --smtp` checks the configured transports without reading messages. Share
  only its redacted output. `mailbend setup --check` and `mail_probe` can expose
  local folder names, so their output is not a public report.
- Discover folders before choosing overrides. MailBend uses an explicit
  override, a unique selectable advertised role, then a unique conventional
  name. See [role resolution](../README.md#role-folder-resolution).
  `MAILBEND_DRAFTS_FOLDER`, `MAILBEND_TRASH_FOLDER`, `MAILBEND_SENT_FOLDER`,
  `MAILBEND_JUNK_FOLDER`, and `MAILBEND_ARCHIVE_FOLDER` must name existing,
  selectable folders exactly. Do not copy a guessed English name or create a
  folder to make an unresolved role disappear.
- `MAILBEND_SAVE_SENT=0` is the conservative starting setting outside the
  recorded iCloud profile. It can leave no Sent copy when the provider does
  not save one. Before enabling writes, establish the account's behavior with
  an authorized disposable message, then use `1` if a MailBend copy is needed.
  A failed Sent copy is never a reason to send an accepted message again.

Provider send and login limits belong in the
[operator runbook](OPERATIONS.md#set-a-cap-below-provider-limits). Its limits
guidance applies to every entry below. A local cap does not replace a provider's
limits or grant permission to send.

## iCloud Mail

Tier: **live-tested**, for the existing IMAP implicit-TLS and SMTP STARTTLS
profile. Sources checked 2026-11-05. The recorded Rust-helper live checklist
completed on 2026-10-06, not on this guide's review date.

| Setting | Value |
| --- | --- |
| IMAP | `imap.mail.me.com`, port `993`, implicit TLS |
| SMTP | `smtp.mail.me.com`, port `587`, `MAILBEND_SMTP_TLS_MODE=starttls` |
| Login | Full primary iCloud Mail address for both protocols |
| Sent copy | `MAILBEND_SAVE_SENT=1` |

[Apple's settings](https://support.apple.com/en-us/102525) permit the full
address for IMAP and require it for SMTP. An
[app-specific password](https://support.apple.com/en-us/102654) requires
two-factor authentication. Alias, custom-domain, and Hide My Email sending
are not established by this profile.

The [live record](CLOUD_AGENT.md#live-icloud-record) found that SMTP did not
save a Sent copy. Sent and Trash had advertised roles; Drafts, Junk, and
Archive resolved by name. Those observations are not names to hard-code on
another account. IPv6 and the remaining gaps stay listed in that record.

## Gmail

Tier: **unverified** as a provider integration. Sources checked 2026-11-05.

| Setting | Value |
| --- | --- |
| IMAP | `imap.gmail.com`, port `993`, implicit TLS |
| SMTP | `smtp.gmail.com`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full Google account email address |
| Sent copy | `MAILBEND_SAVE_SENT=0` |

[Google's endpoints](https://developers.google.com/workspace/gmail/imap/imap-smtp)
also allow SMTP port `587` with `starttls`. MailBend needs an
[app password](https://support.google.com/accounts/answer/185833), which
requires 2-Step Verification. App passwords may be unavailable with
security-key-only verification, an organization account, or Advanced
Protection. Do not weaken those protections to use MailBend.
[Google saves SMTP-sent mail](https://support.google.com/mail/answer/78892),
so a second Sent copy is not recommended.

[Gmail's IMAP extensions](https://developers.google.com/workspace/gmail/imap/imap-extensions)
expose labels as folders. MailBend's `mail_label` moves between folders;
do not assume it adds a tag while retaining INBOX membership. That distinction
is tracked in [#176](https://github.com/albertc71/MailBend/issues/176).
An expunge outside Trash can remove a label instead of permanently removing
the message. Do not rely on `mail_delete` as proof of global deletion while
[#101](https://github.com/albertc71/MailBend/issues/101) remains unresolved.

Google's example advertises Drafts, Sent, Junk, Trash, All Mail, and
`[Gmail]/Important`, but no Archive role. MailBend keeps folders advertising
`\Important` (see [#123](https://github.com/albertc71/MailBend/issues/123)) or
`\All`, and their descendants, out of classification, triage and `mail_label`
destinations. It refuses create/rename destinations there and refuses renaming
a reserved folder or any parent containing it. `mail_move` can still use such
a folder when explicitly named, subject to the normal move checks.
Choose `MAILBEND_ARCHIVE_FOLDER` only after reviewing the actual folder list and
intended archive semantics. Do not silently substitute All Mail. Names and
visibility can differ by account.

## Google Workspace

Tier: **unverified** when the organization's policy permits an app password;
otherwise **unsupported** by MailBend. Sources checked 2026-11-05.

Use the [Gmail endpoints](#gmail), the full Workspace account address, and
`MAILBEND_SAVE_SENT=0`. Gmail's role, label, and deletion caveats also apply.
The `gmail` setup preset does not inspect organization policy.

Google's [authentication transition guide](https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth)
retains an app-password exception. This is not a promise that every Workspace
user can create one. The administrator controls
[IMAP access and allowed clients](https://knowledge.workspace.google.com/admin/sync/turn-pop-and-imap-on-or-off-for-users).
Enforced security-key 2-Step Verification
[disables app passwords](https://knowledge.workspace.google.com/admin/security/how-2-step-verification-works-with-legacy-apps).
Confirm eligibility with the administrator; do not request weaker policy.
An OAuth-only account cannot use MailBend's password authentication.

## Yahoo Mail

Tier: **unverified**. Sources checked 2026-11-05, using indexed Yahoo help
content because direct page fetches were rate-limited.

| Setting | Value |
| --- | --- |
| IMAP | `imap.mail.yahoo.com`, port `993`, implicit TLS |
| SMTP | `smtp.mail.yahoo.com`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full Yahoo Mail address |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified |

[Yahoo's server settings](https://help.yahoo.com/kb/SLN4075.html) require a
[third-party app password](https://help.yahoo.com/kb/SLN15241.html).
If Yahoo does not offer app-password creation, stop rather than substitute
the main password. This entry is the Yahoo profile, not a claim about every
partner-hosted or migrated account.

Drafts and junk names, including whether a Bulk folder advertises `\Junk`,
remain unverified. Inspect LIST and the resolved roles before setting
`MAILBEND_DRAFTS_FOLDER` or `MAILBEND_JUNK_FOLDER`.

## AOL Mail

Tier: **unverified**. Sources checked 2026-11-05. The endpoints and login
format below come from [Thunderbird ISPDB](https://github.com/thunderbird/autoconfig/blob/master/ispdb/aol.com.xml),
not verified AOL server documentation; the direct AOL help pages had no
readable text.

| Setting | Value |
| --- | --- |
| IMAP | `imap.aol.com`, port `993`, implicit TLS |
| SMTP | `smtp.aol.com`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full AOL Mail address |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified |

Follow [AOL's app-password instructions](https://help.aol.com/articles/create-and-manage-app-password);
app-password eligibility is controlled by AOL. The app-password guidance
was checked through indexed AOL help content, not the unreadable direct page.
These are not settings for a Verizon.net account.

Drafts and junk names and special-use attributes remain unverified. Discover
them before choosing overrides, particularly for a folder named Bulk.

## Fastmail

Tier: **unverified**. Sources checked 2026-11-05.

| Setting | Value |
| --- | --- |
| IMAP | `imap.fastmail.com`, port `993`, implicit TLS |
| SMTP | `smtp.fastmail.com`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full primary Fastmail username, not an alias |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified here |

[Fastmail's server reference](https://www.fastmail.help/hc/en-us/articles/1500000278342-Server-names-and-ports)
also permits SMTP `587` with `starttls`. Basic plans do not include IMAP or
SMTP. Create an [app password with mail access](https://www.fastmail.help/hc/en-us/articles/360058752854-App-passwords);
the regular account password does not work.

Fastmail documents an empty IMAP path prefix and `/` as the separator.
MailBend has no prefix setting. In `MAILBEND_*_FOLDER` overrides and folder
arguments, use the exact decoded LIST names, including any namespace prefix
(see [Role folder resolution](../README.md#role-folder-resolution)). This guide
has no live evidence for role attributes or Sent filing. Discover role folders
and test the Sent-copy choice before enabling writes.

## Zoho Mail

Tier: **unverified**. Sources checked 2026-11-05.

| Account profile | IMAP, implicit TLS on `993` | SMTP, `implicit` on `465` |
| --- | --- | --- |
| Documented .com personal profile | `imap.zoho.com` | `smtp.zoho.com` |
| Documented .com paid organization profile | `imappro.zoho.com` | `smtppro.zoho.com` |

The [IMAP reference](https://www.zoho.com/mail/help/imap-access.html) makes the
account's **Server Configuration Details** authoritative. Datacenter,
account type, plan eligibility, and organization policy can change the
endpoints or availability. The setup preset prints only the .com personal
profile. Do not guess regional hosts by editing their suffix.

Use the full account address for login. Enable eligible IMAP access and use an
[app password when two-factor authentication requires one](https://www.zoho.com/mail/help/adminconsole/two-factor-authentication.html).
Zoho's [SMTP reference](https://www.zoho.com/mail/help/zoho-smtp.html)
documents the account's **Save Sent Mail Copy** setting. Keep
`MAILBEND_SAVE_SENT=0` while that setting is checked. If it is unchecked,
establish the account's behavior and use `1` when MailBend should save a copy.

Folder visibility, inclusion of archived messages, and expunge behavior have
account controls in the IMAP reference. Review them without changing them
automatically. No role names or deletion semantics are live-verified here.
Use discovered roles or explicit existing-folder overrides.

## GMX.com

Tier: **unverified**. Sources checked 2026-11-05.

| Setting | Value |
| --- | --- |
| IMAP | `imap.gmx.com`, port `993`, implicit TLS |
| SMTP | `mail.gmx.com`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full GMX email address |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified |

[GMX's server settings](https://support.gmx.com/pop-imap/imap/server.html)
also allow SMTP `587` with `starttls`. This is the GMX.com profile, not a
claim about GMX.net. [IMAP access](https://support.gmx.com/pop-imap/toggle.html)
is off by default and can be disabled after inactivity. Use an
[application-specific password](https://support.gmx.com/security/2fa/application-specific-passwords.html).
The [provider's client instructions](https://support.gmx.com/pop-imap/imap/windowsmailapp.html)
use the full email address.

GMX's [Thunderbird instructions](https://support.gmx.com/pop-imap/imap/thunderbird.html)
map client copies to Sent and map Drafts and Trash. They do not establish
SMTP auto-filing or the actual special-use attributes returned to MailBend.
Inspect roles before choosing overrides; do not assume translated folder names.

## WEB.DE

Tier: **unverified**, with manual login review required. Sources checked
2026-11-05.

| Setting | Value |
| --- | --- |
| IMAP | `imap.web.de`, port `993`, implicit TLS |
| SMTP | `smtp.web.de`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Thunderbird ISPDB specifies the local part before `@` for both protocols |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified |

[WEB.DE's server reference](https://hilfe.web.de/pop-imap/imap/imap-serverdaten.html)
also lists SMTP `587` with `starttls`. Enable eligible
[POP3/IMAP access](https://hilfe.web.de/pop-imap/einschalten.html) and use an
[application-specific password](https://hilfe.web.de/sicherheit/2fa/anwendungsspezifisches-passwort.html).

The login form comes from
[Thunderbird's configuration source](https://github.com/thunderbird/autoconfig/blob/master/ispdb/web.de.xml),
not a verified MailBend login. The reviewed provider pages did not settle
full-address authentication. `MAILBEND_LOGIN` can represent the local part
while `MAILBEND_EMAIL` remains the full address. Confirm the account's required
login before setting it. The print-only setup preset deliberately remains
manual; this guide does not change it.

Actual role names and special-use attributes remain unverified. Discover
them before setting Drafts, Junk, or other overrides.

## mailbox.org

Tier: **unverified**. Sources checked 2026-11-05.

| Setting | Value |
| --- | --- |
| IMAP | `imap.mailbox.org`, port `993`, implicit TLS |
| SMTP | `smtp.mailbox.org`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full main mailbox.org email address, not an arbitrary alias |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified |

The [account configuration reference](https://kb.mailbox.org/en/private/e-mail/e-mail-configuration/)
also permits SMTP `587` with `starttls`. An
[email application password](https://kb.mailbox.org/en/private/security-and-privacy/e-mail-password/)
provides client access with two-factor authentication. It must allow both
IMAP and SMTP for MailBend.

Role attributes and folder names are unverified for MailBend. Discover the
account's folders before choosing overrides or enabling Sent copies.

## Posteo

Tier: **unverified**. Sources checked 2026-11-05. Only the Thunderbird
configuration source was readable; Posteo's help pages blocked retrieval.

| Setting | Value from Thunderbird ISPDB |
| --- | --- |
| IMAP | `posteo.de`, port `993`, implicit TLS |
| SMTP | `posteo.de`, port `465`, `MAILBEND_SMTP_TLS_MODE=implicit` |
| Login | Full Posteo email address |
| Sent copy | Start with `MAILBEND_SAVE_SENT=0`; automatic filing is unverified |

[Thunderbird's configuration source](https://github.com/thunderbird/autoconfig/blob/master/ispdb/posteo.de.xml)
also lists SMTP `587` with `starttls`. These are candidate settings, not a
provider-verified or live-tested setup. Review Posteo's
[mail-client guide](https://posteo.de/hilfe/wie-richte-ich-posteo-in-einem-mailprogramm-ein-pop3-imap-und-smtp)
and [app-password requirements](https://posteo.de/en/blog/how-to-use-app-passwords-with-posteo)
locally before use. Their current prerequisites and interaction with
additional account protection remain unverified here. Do not disable account
protection to make a connection succeed.

Role names, special-use attributes, and Sent behavior remain unverified.
Use only roles discovered on the authorized account or explicit existing-folder
overrides.

## Proton Mail Bridge

Tier: **unsupported for the default Bridge profile**. Sources checked 2026-11-05.

Bridge requires a [paid plan that includes Proton Mail](https://proton.me/mail/bridge)
and a locally running Bridge application. Its
[settings](https://proton.me/support/comprehensive-guide-to-bridge-settings)
control ports and connection modes. The client username and password come
from Bridge's account details, not the normal Proton password. Do not guess
ports or credentials from another installation.

The default loopback connection uses a
[locally generated self-signed certificate](https://proton.me/support/bridge-ssl-connection-issue).
Proton's [STARTTLS troubleshooting](https://proton.me/support/not-receiving-messages-email-client)
does not provide a MailBend workaround. MailBend requires verified TLS and
implicit-TLS IMAP. Certificate exceptions, plaintext IMAP, and disabling
verification are not accepted fixes. Trust and transport changes need the
separate decision in [#175](https://github.com/albertc71/MailBend/issues/175).

Proton documents [automatic Sent copies](https://proton.me/support/protonmail-bridge-clients-macos-outlook-2019),
so a future validated profile would normally keep `MAILBEND_SAVE_SENT=0`.
Its [labels appear as folders](https://proton.me/support/labels-in-bridge),
which does not imply MailBend's move-based labelling has the desired semantics.
Special-use roles remain unverified. Folder overrides cannot fix the current
connection blocker.

## Self-hosted Dovecot

Tier: **unverified**, for each individual deployment. Sources checked 2026-11-05.

There is no universal Dovecot host, login form, app-password workflow, or
SMTP service. Obtain those from the operator. A compatible deployment needs
IMAP with implicit TLS, password authentication, and a separately configured
SMTP submission service with STARTTLS or implicit TLS.

For example, an operator might provide `imap.example.com:993` with implicit
TLS and `smtp.example.com:587` with `MAILBEND_SMTP_TLS_MODE=starttls`. These
are placeholders, not discoverable endpoints. Each certificate must match
the configured host and chain to the configured trust store. Keep
`MAILBEND_EMAIL` as the sending address; use `MAILBEND_LOGIN` only when the
operator provides a different, compatible login for both protocols.

[Dovecot's submission service](https://doc.dovecot.org/2.4.5/core/config/submission.html)
requires configuration and a relay MTA; an IMAP installation alone does not
establish SMTP availability. Its [TLS guide](https://doc.dovecot.org/2.4.5/howto/ssl/)
distinguishes implicit TLS from STARTTLS. A private-CA deployment requires
separate trust-store review, not a verification bypass.

[Namespaces and special-use roles](https://doc.dovecot.org/latest/core/config/namespaces.html)
are operator-configurable. Discover the account's actual selectable folders
before setting overrides. Start with `MAILBEND_SAVE_SENT=0`; automatic Sent
filing depends on the deployment. Establish that behavior before enabling
writes, then use `1` if MailBend must save the copy. Obtain a dedicated
credential under the operator's policy and keep it only in
`MAILBEND_PASSWORD_FILE`.

## Outlook.com and Microsoft 365

Tier: **unsupported**. Sources checked 2026-11-05.

[Outlook.com requires OAuth2](https://support.microsoft.com/en-gb/outlook/pop-imap-and-smtp-settings-for-outlook-com)
for IMAP and SMTP. Its documented endpoints are `outlook.office365.com:993`
with implicit TLS and `smtp-mail.outlook.com:587` with STARTTLS, using the full
email address. These are reference facts, not a MailBend configuration.
An app password does not add OAuth support to MailBend.

[Exchange Online removed Basic authentication for IMAP](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-basic-authentication-exchange-online).
The separate [SMTP AUTH timeline](https://techcommunity.microsoft.com/blog/exchange/updated-exchange-online-smtp-auth-basic-authentication-deprecation-timeline/4489835)
says behavior remains unchanged through December 2026, then Basic SMTP AUTH
is disabled by default for existing tenants. Administrators can still enable
it then. New tenants after December 2026 default to OAuth. Microsoft plans
to announce the final removal date in the second half of 2027; that is not
an announced removal date. This SMTP exception does not restore IMAP access.

MailBend retains password-only authentication under
[#28](https://github.com/albertc71/MailBend/issues/28). Do not weaken tenant
security or generate credentials for this unsupported integration. Folder
overrides and `MAILBEND_SAVE_SENT` are not applicable until authentication
support changes.

## Reporting a new provider result

An endpoint list or a successful TCP connection cannot promote a provider's
tier. A community report needs the MailBend commit, date, public provider
profile, and redacted `mailbend diagnose --imap --smtp` output with all
IMAP and SMTP stages successful. Read-only operation results should be
reported without mail, addresses, or folder names.

The extended report and issue form are tracked in
[#172](https://github.com/albertc71/MailBend/issues/172). No `--report` option
is claimed here. A maintainer must review and link the evidence before changing
this guide. A read-only report does not establish Sent filing, label behavior,
drafts, or deletion semantics. Test those only with separately authorized
disposable accounts, messages, and recipients. The
[live checklist](CLOUD_AGENT.md#live-icloud-checklist) identifies those boundaries.
