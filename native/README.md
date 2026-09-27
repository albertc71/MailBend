# Native boundary

This directory is reserved for the minimal Linux TLS bridge needed by Bend.

It must not contain mail policy or MCP logic. Those belong in Bend.

The bridge will expose only byte-stream primitives needed for:
- implicit TLS IMAP on port 993
- STARTTLS SMTP on port 587

OpenSSL peer/hostname verification is mandatory.
