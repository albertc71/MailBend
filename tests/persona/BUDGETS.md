# Persona replay budgets

Measured local modern MCP replies, not an LLM evaluation. Tokens are an estimate of ceil(result UTF-8 bytes / 4), not tokenizer counts. Bytes include the complete result envelope and both content representations. No timing or model-efficiency claim.

| Task | Tool calls | IMAP logins | Result bytes | Estimated tokens | Budget issue |
| --- | ---: | ---: | ---: | ---: | --- |
| find-flight | 2 | 3 | 2231 | 558 | #66 |
| find-hotel | 2 | 3 | 2229 | 558 | #66 |
| find-receipt | 2 | 3 | 2165 | 542 | #66 |
| find-archive-contract | 2 | 3 | 2303 | 576 | #66 |
| read-security-code | 1 | 1 | 1230 | 308 | #66 |
| read-html-reset | 1 | 2 | 948 | 237 | #66 |
| read-calendar-invite | 1 | 1 | 1376 | 344 | #66 |
| read-sent-thread | 1 | 6 | 2689 | 673 | #66 |
| read-stale-identity | 1 | 1 | 402 | 101 | #70 |
| reply-meeting | 2 | 2 | 2183 | 546 | #70 |
| reply-receipt | 2 | 2 | 2197 | 550 | #70 |
| organise-newsletter | 2 | 3 | 1609 | 403 | #61 |
| organise-receipt | 2 | 3 | 1589 | 398 | #61 |
| organise-flight | 2 | 3 | 1623 | 406 | #61 |
| organise-mark-digest | 1 | 1 | 331 | 83 | #61 |
| attention-flag-action | 1 | 1 | 435 | 109 | #61 |
| attention-unread-later | 1 | 1 | 335 | 84 | #61 |
| attention-unread-action | 1 | 2 | 1001 | 251 | #72 |
| attention-checkpoint | 1 | 2 | 2307 | 577 | #72 |
| attention-refresh | 1 | 1 | 589 | 148 | #70 |
| injection-lookalike | 1 | 1 | 1504 | 376 | #66 |
| inject-send | 1 | 1 | 1462 | 366 | #66 |
| inject-exfiltrate | 1 | 1 | 1444 | 361 | #66 |
| inject-code | 1 | 1 | 1490 | 373 | #66 |
| inject-delete | 1 | 1 | 1444 | 361 | #66 |
