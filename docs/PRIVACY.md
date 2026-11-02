# Privacy Policy and data handling

Reviewed 2 November 2026. This describes MailBend's code and the public provider
statements linked below. It is not legal advice, a compliance certification or a
promise about an operator's account contract.

## Collection, use and local storage

MailBend is software you run, not a hosted MailBend service. The maintainers do
not receive mailbox data merely because you run it. It reads the configuration,
mail and local attachment data needed for the requested operations, and returns
results to the calling CLI or MCP client. Mail remains untrusted input.

There is no MailBend mailbox database or background sync daemon. MailBend does
not create application log files, but it emits results and diagnostics on stdout
and stderr. Your shell, MCP client, agent platform or process supervisor may
capture them, retain transcripts and send results to its own model provider.
Their policies and your configuration govern that use, not this statement.

Persistent local data is not limited to a counter. It includes operator-created
configuration and credential files, files you explicitly download under
`MAILBEND_DOWNLOAD_DIR`, and the optional daily send-count file. Attachment
inputs under `MAILBEND_ATTACH_DIR` remain your files. Downloads, configuration and counter entries
have no automatic retention expiry; manage their retention and backups yourself.
The counter appends a day entry per send reservation, not a copy of the messages. MailBend's process
holds working data in memory; this is not a secure-erasure guarantee for the OS,
swap, backups or caller logs. See [configuration](../README.md#configure) and the
[file helper](../native/mailbend-attach/src/main.rs).

The [launcher](../scripts/mailbend) and [installer](../scripts/install.sh) set
`BEND_NO_TELEMETRY=1`. Direct contributor invocation of Bend outside those scripts
is a separate path; this document does not establish what its telemetry sends.
Installers also leave toolchains, dependencies and build outputs on disk.

## Destinations and third-party sharing

Run `scripts/mailbend diagnose --posture`, or
`scripts/mailbend-cloud diagnose --posture` for the cloud launcher's resolver
setting. The [offline inventory](CLOUD_AGENT.md#offline-posture) reports configured
egress, not captured traffic or contractual approval. The table follows
[`posture_endpoints`](../src/diagnostics.bend) and its
[native inventory audit](../tests/posture-egress-inventory.json). Install-time
and caller-controlled traffic are separate from that runtime inventory.

| Recipient | Data and purpose | When and retention boundary |
| --- | --- | --- |
| Configured IMAP/SMTP mail provider | Login credentials over verified TLS, mailbox commands and selected mail; SMTP receives the envelope, body and attachments for an authorized send. Delivery also discloses mail to its recipients and their providers. | Requested mail operations and explicitly enabled online diagnostics. Mail, drafts and sent copies remain subject to provider retention, backups and recipient handling; MailBend cannot erase those copies. |
| TypeSafe at `https://api.typesafe.ai/v1/systemone` | The enabled Jev request categories below, authenticated with the TypeSafe key. | Only tools that ask Jev with Jev enabled. Account terms and the dated public statements below govern processing and retention. |
| Configured DNS-over-HTTPS resolver | Queried hostnames and connection metadata to resolve destinations, not mail or mail passwords. `mailbend-cloud` defaults to `https://cloudflare-dns.com/dns-query`. | When native resolution needs DoH. The resolver's terms govern logging and retention; this repository has not established a retention period for it. |
| System DNS resolver | Hostname lookups in system-DNS mode and bootstrap lookups where needed, including a custom DoH resolver or proxy host. | Route-dependent. Fixed Cloudflare bootstrap and numeric connect overrides can avoid particular lookups, not all network metadata. Resolver/operator retention is outside MailBend. |
| Configured HTTPS proxy | Optional proxy authentication, target host/port and traffic metadata for DoH and TypeSafe HTTPS. TLS protects payloads from a tunnelling proxy unless the configured trust permits interception. | Proxy precedence and per-host bypass apply. Raw IMAP/SMTP TCP does not use this proxy. Proxy retention and administrator-installed trust are operator responsibilities. |
| Install and build hosts | Download requests, source IP and normal network metadata, not mailbox content from the install scripts. GitHub/release delivery hosts supply Bend and elan; `static.rust-lang.org` supplies rustup, and toolchain/package hosts supply Rust, Lean and Cargo dependencies. | Installation/build, outside the posture report. See the [Bend](../scripts/install-bend.sh), [Rust](../scripts/install-rust.sh), [Lean](../scripts/install-lean.sh) and [build](../scripts/install.sh) scripts. Host policies control request-log retention; checksums verify artifacts, not privacy. |
| Calling client and its services | Tool arguments, results, mail, attachments or diagnostics that the caller requests or captures. | CLI/MCP output is local transport, not a promise that the client stays local. Check its logging, model, sharing and retention settings separately. |

The [network guide](CLOUD_AGENT.md#resolver-and-network-catches) explains resolver,
proxy and trust behaviour. Never change trust settings to bypass an unexpected
certificate failure. The TypeSafe key and mail password have separate native
readers; neither is included in tool results. See [native boundaries](../AGENTS.md).

### What Jev receives

With `MAILBEND_TYPESAFE` off, no tool asks Jev. Turning it on does not make every
tool call contact TypeSafe. See [the per-tool guide](JEV.md) and
[request construction](../src/jev.bend) for the exact paths.

- Headers mode can send decoded From, To, Cc, Subject, Date, List-Id,
  List-Unsubscribe, Auto-Submitted and Precedence fields, attachment names and a
  UID or list position. Account identity, folder names, prompts and category
  options can accompany requests.
  These can be personal or confidential data, even without a message body.
- Body mode adds bounded readable text for `mail_get`, `mail_classify`,
  `mail_triage` and `mail_delete`. List reads (`mail_search`, `mail_get_new`,
  `mail_get_thread`) still send header facts only. Selected-part reads annotate
  only the selected view; metadata-only section listing does not ask Jev.
- Outbound checks describe sender/recipient fields, subject, attachment names
  and the original message's header facts for a reply or forward. Body mode also
  permits the outbound body. Draft-only reply/forward do not call Jev.
- Only opted-in `mail_classify` can send eligible PNG/JPEG image parts, within
  the documented count and byte limits. Stripping is selective, not anonymity.
  JPEG APP0, including embedded thumbnails, and APP14 remain; PNG chunks not
  named for removal remain. Pixels themselves can reveal private information.
  See [the exact image policy](JEV.md#what-leaves-the-machine) and
  [image processing](../src/image.bend).

Headers mode requires **no zero-retention statement**. Body mode and images
require `MAILBEND_TYPESAFE_ZERO_RETENTION=1` (or `true`), which is **the operator's
statement** that their TypeSafe account has a zero-retention plan. MailBend cannot
verify the contract or its scope. Setting the variable does not purchase,
activate or prove that plan. Read-only mode still permits allowed Jev sharing.

## TypeSafe terms and verification limits

All sources below were checked on **2 November 2026**. Public policies can change;
recheck them and your account's signed terms before sharing sensitive data.

- [Legal documentation](https://docs.typesafe.ai/legal), accessed on the review
  date, offers zero data retention for enterprise customers. It does not establish
  ZDR for every account or every category of data.
- [Data Processing Addendum](https://typesafe.ai/legal/data-processing), updated
  **24 April 2026**, describes customer controller and TypeSafe processor roles,
  subprocessors and transfer safeguards. Schedule I uses purpose-based retention,
  not a fixed number of days. Confirm that the applicable agreement covers your
  account and intended processing.
- [Privacy policy](https://typesafe.ai/legal/privacy-policy), updated
  **19 November 2025**, states that services are hosted in the US and data is
  transferred there for storage and processing. It says input is not used to
  train or fine-tune models. This is not a no-storage promise; account-specific
  regions, exceptions and retention arrangements have not been verified here.
- [Jev 1.14 announcement](https://typesafe.ai/blog/jev-1-14), dated
  **14 October 2026**, describes opt-in query sharing for debugging. We have not
  verified your account's setting or the current console default. Check it rather
  than assuming that no queries are shared.
- The DPA links the [subprocessor register](https://trust.typesafe.ai/subprocessors).
  Its JavaScript-rendered full list could not be verified during this review.
  Partial search results are not a complete inventory. Obtain the current list
  and relevant locations from TypeSafe before relying on it.
- A TypeSafe HIPAA Business Associate Agreement (BAA) was **not verified** from
  the reviewed public legal material. That does not establish that none is
  available. Do not infer coverage from ZDR or a general DPA.

MailBend has not verified a fixed default TypeSafe retention period, account-level
query sharing, a complete current subprocessor list, a BAA, or an account-specific
processing region. Those remain operator checks, not product guarantees.

## Checklist for regulated or confidential mail

This is an operational checklist, not a finding of legal compliance. Get advice
from the person responsible for privacy/security in your organisation.

| Context | Before enabling access or sharing |
| --- | --- |
| GDPR / UK GDPR personal data | Establish lawful handling and the applicable DPA/transfer arrangements for **any** Jev mode, including headers. Review the caller/model provider, subprocessors, retention and data-subject handling too. |
| Health or other sensitive data | Keep Jev off unless the required agreements and safeguards, including a BAA where applicable, are independently verified for the actual use. Also assess the calling agent's access and onward sharing. |
| Confidential mail | Start with Jev off and the narrowest needed reads. Use `MAILBEND_READ_ONLY` or `MAILBEND_DRAFTS_ONLY` and a reviewed `MAILBEND_ALLOWED_RECIPIENTS` allowlist for sends. These controls do not prevent an agent from repeating data it has read to its own services. |

Review [safety](../README.md#safety), the
[compromised-agent matrix](INCIDENTS.md) and your client's controls. A Jev answer
or the permanent-delete confirmation word is not human approval. Do not weaken
runtime gates or set a retention statement merely to make a request succeed.

## Contact and retention requests

For suspected security or privacy vulnerabilities, use
[GitHub private vulnerability reporting](https://github.com/albertc71/MailBend/security/advisories/new)
as described in [SECURITY.md](../SECURITY.md). Never include real credentials,
mail or unredacted transcripts. For non-sensitive documentation questions, open a
[repository issue](https://github.com/albertc71/MailBend/issues).

For provider-held data, contact the relevant mail provider, TypeSafe or client
service under its own terms. The maintainers cannot delete data held by those
services or your local files. TypeSafe lists its privacy contact in its
[privacy policy](https://typesafe.ai/legal/privacy-policy).
