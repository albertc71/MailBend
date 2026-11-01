# Email connector comparison

Verified on 2026-10-31. Re-verify each quarter, next by 2027-01-31, and before a deployment decision.

This reference compares MailBend with eight connectors from their primary documentation.
The date records a source check, not a live account test or a security audit.
Unknown means that the cited source did not establish the property. It does not mean that the product lacks it.
A tool argument, MCP annotation, or model verdict is not evidence of human approval.
Vendor test counts and security claims remain self-reported unless stated otherwise.

Each product uses the same twelve dimensions. Links and dates in each cell identify the checked evidence.
MailBend describes the code in this checkout, not pending roadmap PRs.
The mcp-email-server row describes the documented Local Email App V2 contract; it does not imply that every published package includes it.
No comparison of popularity or maintenance health is made from stars, badges, or unverified directory entries.

## MailBend

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Only TLS helper reads password; same-user processes can still access it. [Source, 2026-10-31](../README.md#safety) |
| TLS verification opt-out | No verification-off option. Custom CA file replaces trust roots. [Source, 2026-10-31](../README.md#safety) |
| Read safety | Pure read plans and wire rendering are proven; helper IO is tested. [Source, 2026-10-31](../README.md#what-the-proofs-cover) |
| Delete model | Trash moves; permanent delete requires confirmation word and UIDPLUS. No mailbox-wide EXPUNGE. [Source, 2026-10-31](../LAWS.bend) |
| Send gates | Optional recipient allowlist, daily cap and Jev veto. No built-in human approval. [Source, 2026-10-31](../README.md#safety) |
| Default posture | Read-only and drafts-only are opt-in, fail-closed switches. [Source, 2026-10-31](../README.md#configure) |
| Dry run | Every mail-changing tool supports dry_run. [Source, 2026-10-31](../README.md#what-it-can-do) |
| Untrusted content | Mail remains untrusted. Optional Jev screening is not proof against prompt injection. [Source, 2026-10-31](../README.md#jev-optional) |
| Tests and proofs | Plan laws, bounded models and fake-server tests; native helpers and MIME are not proven. [Source, 2026-10-31](../README.md#what-the-proofs-cover) |
| Install | Build from source with pinned Bend and Rust installers. [Source, 2026-10-31](../README.md#install-linux) |
| Platforms | Linux; openat2 requires kernel 5.6+. [Source, 2026-10-31](../README.md#known-limits) |
| Providers | Password IMAP and SMTP; no OAuth. Only iCloud has live-test evidence. [Source, 2026-10-31](../README.md#known-limits) |

## Google Gmail MCP

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Google-hosted, OAuth 2.0. Client stores OAuth configuration; token storage details unknown. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| TLS verification opt-out | Unknown in setup guide. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| Read safety | Read tools listed; message-flag effects unknown. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp) |
| Delete model | No delete tool listed in this reference. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp) |
| Send gates | No send tool listed; create_draft is available. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp) |
| Default posture | Developer Preview with OAuth scopes and user permissions. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| Dry run | Unknown; draft creation is a real write. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp) |
| Untrusted content | Google requires screening for indirect prompt injection, with Model Armor or another documented solution. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| Tests and proofs | Unknown in cited reference; no proof claim inferred. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp) |
| Install | Cloud project, API enablement, OAuth consent and MCP client configuration. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| Platforms | Remote endpoint; compatible MCP host required. OS support unknown. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) |
| Providers | Gmail. [Source, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp) |

## Microsoft Work IQ MCP

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Microsoft-hosted, Entra ID OAuth. Token storage details unknown. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| TLS verification opt-out | Unknown in overview. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Read safety | Fetch tools available; read side effects unknown. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Delete model | delete_entity exists; resource-specific deletion behavior unknown here. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Send gates | do_action can target /me/sendMail. Human approval guarantee unknown. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Default posture | OAuth permissions and tenant policy govern access. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Dry run | Unknown in overview. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Untrusted content | Unknown in cited overview. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Tests and proofs | Unknown in cited overview; no proof claim inferred. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview) |
| Install | Remote endpoint with tenant administration and OAuth. Availability depends on tenant policy. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview) |
| Platforms | Supported MCP clients; OS support unknown in these sources. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview) |
| Providers | Microsoft 365 resources, including mail. Prefer this over the legacy Mail MCP for new projects. [Source, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview) |

## Superhuman Mail MCP

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Hosted connector; credential storage details unknown. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| TLS verification opt-out | Unknown in product page. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Read safety | Read/search supported; flag effects unknown. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Delete model | Unknown in product page. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Send gates | Vendor says every send needs user approval by default. Not independently tested here. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Default posture | Vendor describes draft review and confirmation before sending. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Dry run | Unknown; drafts are supported. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Untrusted content | Unknown in product page. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Tests and proofs | Unknown in product page; no proof claim inferred. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Install | Connect through supported AI host; vendor supplies connection links. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Platforms | Remote connector for listed hosts; server OS support not applicable. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |
| Providers | Gmail and Outlook, multiple accounts. [Source, 2026-10-31](https://superhuman.com/mail/features/email-mcp) |

## Wh1isper/mcp-email-server

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | V2 managed storage uses local SQLite on Linux/Windows and OS keyring on macOS. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/configuration/) |
| TLS verification opt-out | verify_ssl=false and plaintext modes exist; documentation warns of credential exposure. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/security/) |
| Read safety | mark_as_read defaults false; true requires organize permission. Documentation claim. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/tools/) |
| Delete model | Focused delete requires UIDPLUS and targets UIDs; opt-in protocol commands permit broader deletion. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/tools/) |
| Send gates | Recipient allowlist and mutation grants. Human approval guarantee unknown. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/security/) |
| Default posture | Mutation classes default enabled; explicit empty grants give read-only. Empty recipient allowlist denies sending. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/security/) |
| Dry run | Mail-operation dry run unknown; configuration import has a preview. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/getting-started/) |
| Untrusted content | Documentation treats mail as untrusted; caller-selected attachment paths still require trusted clients. [Source, 2026-10-31](https://mcp-email-server.wh1isper.top/security/) |
| Tests and proofs | README links CI and coverage; proof evidence unknown. Not independently run here. [Source, 2026-10-31](https://github.com/Wh1isper/mcp-email-server/blob/acbe0ec9981876f6cbb4e3a381295ca1b1113c33/README.md) |
| Install | uv source setup or uvx for a release that includes V2. [Source, 2026-10-31](https://github.com/Wh1isper/mcp-email-server/blob/acbe0ec9981876f6cbb4e3a381295ca1b1113c33/README.md) |
| Platforms | Windows, macOS and Linux are documented. [Source, 2026-10-31](https://github.com/Wh1isper/mcp-email-server/blob/acbe0ec9981876f6cbb4e3a381295ca1b1113c33/README.md) |
| Providers | IMAP and SMTP. Specific live-tested provider coverage unknown. [Source, 2026-10-31](https://github.com/Wh1isper/mcp-email-server/blob/acbe0ec9981876f6cbb4e3a381295ca1b1113c33/README.md) |

## ni-c/imap-mcp

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Local Node process reads IMAP_PASSWORD, then removes that environment entry. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/src/config.ts) |
| TLS verification opt-out | IMAP_INSECURE_TLS disables verification; IMAP_TLS=none disables TLS. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/src/config.ts) [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/src/imap.ts) |
| Read safety | BODY.PEEK preserves Seen; list_new_messages can still add AiSeen. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/src/imap.ts) |
| Delete model | Permanent deletion. Human elicitation when supported; otherwise a two-call token, not human approval. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/src/tools/write.ts) |
| Send gates | No send tool. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/README.md) |
| Default posture | Write tools are hidden by default, with IMAP_READ_ONLY=true. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/src/config.ts) |
| Dry run | list_new_messages has dry-run; universal mutation preview unknown. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/README.md) |
| Untrusted content | README claims nonce fencing, hidden-character stripping and image defusing. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/README.md) |
| Tests and proofs | CI configures tests on Ubuntu. No proof evidence established. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/.github/workflows/ci.yml) |
| Install | npx or Docker; Node 22+. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/README.md) |
| Platforms | Ubuntu CI. Other native OS support unknown. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/.github/workflows/ci.yml) |
| Providers | Generic IMAP is documented; independent compatibility coverage unknown. [Source, 2026-10-31](https://github.com/ni-c/imap-mcp/blob/265b33c094c400999899045cff877412f22e84a2/README.md) |

## JulienRabault/icloud-mcp

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Local environment or .env supplies the app password. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/config.py) |
| TLS verification opt-out | SMTP uses a verified context. IMAP verification guarantee unknown; it supplies no explicit context. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/imap_client.py) [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/smtp_client.py) |
| Read safety | Read code uses readonly selection and BODY.PEEK. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/imap_client.py) |
| Delete model | No message-delete tool. Move can expunge after checking unrelated Deleted flags. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/server.py) [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/move.py) |
| Send gates | Send executes directly. Requested conversation approval is not an enforced connector confirmation. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/server.py) |
| Default posture | Writes remain registered; no global read-only switch established. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/server.py) |
| Dry run | Move and organize default to dry_run=true. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/server.py) |
| Untrusted content | Server instructs agents to treat message content as data. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/src/icloud_mcp/server.py) |
| Tests and proofs | README self-reports 49 offline tests; not independently run here. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/README.md) |
| Install | Source setup with uv. README makes uvx conditional on PyPI publication. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/README.md) |
| Platforms | CI specifies Linux, macOS and Windows. This is configured coverage, not a run result. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/.github/workflows/ci.yml) |
| Providers | iCloud. Other-provider compatibility unknown. [Source, 2026-10-31](https://github.com/JulienRabault/icloud-mcp/blob/efee3eef9a24f699b024475f7db950c17646acd8/README.md) |

## epinethrone/icloud-mcp

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | Server environment or macOS Keychain. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| TLS verification opt-out | Verified TLS contexts, but IMAP_SECURITY/SMTP_SECURITY=none permits plaintext. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/src/icloud_mcp/mail.py) |
| Read safety | BODY.PEEK by default; get_message can explicitly mark_read=true. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/src/icloud_mcp/mail.py) |
| Delete model | Trash by default; permanent deletion from Trash is disabled by default. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Send gates | Browser approval when hosted; Drafts when local. SEND_REQUIRES_APPROVAL=false permits direct send. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Default posture | READ_ONLY defaults false. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/src/icloud_mcp/config.py) |
| Dry run | Bulk actions use preview plus message-bound confirmation token. Universal dry-run unknown. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Untrusted content | README claims untrusted labels, character stripping and warnings, not a model guarantee. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Tests and proofs | Over 600 offline tests is self-reported; not independently run here. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Install | uvx/pip, .mcpb bundle or self-hosted Docker. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Platforms | Ubuntu CI; optional Mac helper. Broader tested OS support unknown. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/.github/workflows/tests.yml) [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |
| Providers | iCloud. [Source, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md) |

## skhan61/email-tool

| Dimension | Evidence checked |
| --- | --- |
| Credential custody | OS keyring; OAuth sign-ins encrypted locally with the key in the keyring. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/docs/privacy.md) |
| TLS verification opt-out | Verified client context with TLS 1.2 floor; no verification-off option documented in source. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/tls.py) [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/imap_session.py) |
| Read safety | Read code uses readonly selection and BODY.PEEK. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/message_render.py) [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/imap_session.py) |
| Delete model | UID EXPUNGE when supported; otherwise EXPUNGE only if target is sole Deleted message. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/imap_session.py) |
| Send gates | Optional human elicitation approval refuses when required but unavailable. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/approval.py) |
| Default posture | read_only and require_approval both default false. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/policy.py) |
| Dry run | Unknown in usage guide. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/docs/use.md) |
| Untrusted content | HTML renderer strips script/style/head/title; broader prompt-injection guarantees unknown. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/src/email_tool_mcp/message_render.py) |
| Tests and proofs | Cross-platform CI configured. Control mapping is not certification; no proof evidence established. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/README.md) |
| Install | Claude Code marketplace and .mcpb bundle are documented. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/README.md) |
| Platforms | Linux, macOS and Windows CI configured; not independently run here. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/.github/workflows/ci.yml) |
| Providers | Google/Microsoft OAuth, Gmail app passwords and generic password IMAP. [Source, 2026-10-31](https://github.com/skhan61/email-tool/blob/c19949760c0b28be96cd3225d79b97678792417d/docs/mailboxes.md) |

## When to choose something else

- For Gmail through OAuth, Google's remote MCP is a provider-owned option if its Developer Preview and draft-only send path fit your workflow. [Google setup, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server)
- For Microsoft 365 and tenant controls, Work IQ is Microsoft's current route. The legacy workload Mail MCP is not recommended for new production projects. [Microsoft guidance, 2026-10-31](https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview)
- For a hosted connection to existing Gmail or Outlook accounts with approval before sending, Superhuman describes that default. This is a vendor claim, not an independently verified approval boundary. [Superhuman, 2026-10-31](https://superhuman.com/mail/features/email-mcp)
- For a local connector on macOS or Windows, mcp-email-server documents those platforms. Match the installed release to its documented V2 behavior. MailBend remains Linux-only. [mcp-email-server, 2026-10-31](https://mcp-email-server.wh1isper.top/getting-started/) [MailBend limits](../README.md#known-limits)
- For a downloadable Claude Desktop bundle rather than a source build, epinethrone documents double-click `.mcpb` setup followed by account configuration. [iCloud bundle, 2026-10-31](https://github.com/epinethrone/icloud-mcp/blob/a82879d28b8bc9d1cf7860d3e6f57da47c68424e/README.md)
- For an inbox provisioned for an agent rather than access to an existing personal mailbox, AgentMail documents an API to create inboxes. That is a separate provider choice, outside this connector matrix. [AgentMail, 2026-10-31](https://docs.agentmail.to/introduction)

## Scope and maintenance

The tables compare documented behavior, not product quality scores. An advertised test suite does not establish which release passed it or how well it covers failures.
MailBend's laws concern named pure functions. They do not prove its native helpers, TLS implementation, MIME parser, model judgments, or resistance to prompt injection.
See [proof scope](../README.md#what-the-proofs-cover) and [contributor checks](../CONTRIBUTING.md#checks).

Google's setup and reference pages list different sets of tool names. This page names the relevant operations rather than choosing a tool count.
The checked reference lists draft, read and label operations, with no send or delete operation. That is a dated documentation observation, not a permanent API guarantee.
[Setup, 2026-10-31](https://developers.google.com/workspace/gmail/api/guides/configure-mcp-server) [Reference, 2026-10-31](https://developers.google.com/workspace/gmail/api/reference/mcp)

The incident matrix is tracked in [#130](https://github.com/albertc71/MailBend/issues/130).
When that document exists, link it here rather than duplicate its incident analysis.

Quarterly review checks each cell against its linked primary source, updates its date, and retains unknowns where the evidence is missing.
A changed product name, release contract, approval mechanism, or TLS setting warrants an earlier review.
