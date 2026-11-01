# Persona replay budgets

Measured local modern MCP replies, not an LLM evaluation. Tokens are an estimate of ceil(result UTF-8 bytes / 4), not tokenizer counts. Bytes include the complete result envelope and both content representations. No timing or model-efficiency claim.

| Task | Tool calls | IMAP logins | Result bytes | Estimated tokens | Budget issue |
| --- | ---: | ---: | ---: | ---: | --- |
| find-flight | 2 | 3 | 2847 | 712 | #66 |
| find-hotel | 2 | 3 | 2845 | 712 | #66 |
| find-receipt | 2 | 3 | 2781 | 696 | #66 |
| find-archive-contract | 2 | 3 | 2919 | 730 | #66 |
| read-security-code | 1 | 1 | 1538 | 385 | #66 |
| read-html-reset | 1 | 2 | 948 | 237 | #66 |
| read-calendar-invite | 1 | 1 | 1684 | 421 | #66 |
| read-sent-thread | 1 | 6 | 3613 | 904 | #66 |
| read-stale-identity | 1 | 1 | 402 | 101 | #70 |
| reply-meeting | 2 | 2 | 2491 | 623 | #70 |
| reply-receipt | 2 | 2 | 2505 | 627 | #70 |
| organise-newsletter | 2 | 3 | 1995 | 499 | #61 |
| organise-receipt | 2 | 3 | 1897 | 475 | #61 |
| organise-flight | 2 | 3 | 1931 | 483 | #61 |
| organise-mark-digest | 1 | 1 | 331 | 83 | #61 |
| attention-flag-action | 1 | 1 | 435 | 109 | #61 |
| attention-unread-later | 1 | 1 | 335 | 84 | #61 |
| attention-unread-action | 1 | 2 | 1309 | 328 | #72 |
| attention-checkpoint | 1 | 2 | 3231 | 808 | #72 |
| attention-refresh | 1 | 1 | 589 | 148 | #70 |
| injection-lookalike | 1 | 1 | 1812 | 453 | #66 |
| inject-send | 1 | 1 | 1770 | 443 | #66 |
| inject-exfiltrate | 1 | 1 | 1752 | 438 | #66 |
| inject-code | 1 | 1 | 1798 | 450 | #66 |
| inject-delete | 1 | 1 | 1752 | 438 | #66 |
