# Use MailBend with agent frameworks

## OpenAI Agents SDK

The [Python recipe](../examples/frameworks/openai_agents.py) connects the SDK to
`scripts/mailbend mcp`. It uses native SDK interruptions to ask a person before
each `mail_send`, `mail_reply`, `mail_forward`, or `mail_delete` call. Replies and
forwards also require inspection of the original; their draft mode is rejected
because its preview does not show recipients. No product code or required CI
dependencies change.

This recipe targets `openai-agents==0.24.0` and `mcp==1.30.0`. It uses the released
[MCP approval policy](https://github.com/openai/openai-agents-python/blob/v0.24.0/src/agents/mcp/server.py),
[RunState approval methods](https://github.com/openai/openai-agents-python/blob/v0.24.0/src/agents/run_state.py),
and [ScriptedModel testing API](https://github.com/openai/openai-agents-python/blob/v0.24.0/docs/testing.md).
Other versions need their own verification.

### Run the recipe

1. Build MailBend with `scripts/install.sh`. Complete the
   [password-file setup](../README.md#configuration) first. The file must be an
   absolute path, owned by you, with mode `600`, outside any attachment directory.
2. Install the optional dependencies into a separate Python 3.12 virtual
   environment. The complete, hash-checked lock targets Linux x86-64/Python 3.12.

   ```sh
   python3.12 -m venv .venv-frameworks
   .venv-frameworks/bin/python -m pip install --require-hashes --only-binary=:all: \
     -r examples/frameworks/requirements-openai.txt
   ```

3. Set `OPENAI_API_KEY` using your usual secure credential setup. Choose an OpenAI
   model available to your account. The next command makes model API calls and
   can transmit returned mail content to OpenAI. Use only an account and messages
   you are authorized to share with that service. SDK tracing is disabled.

   ```sh
   export MAILBEND_EMAIL='you@example.test'
   export MAILBEND_PASSWORD_FILE='/absolute/path/to/mailbend-password'
   export MAILBEND_READ_ONLY=1
   export MAILBEND_DRAFTS_ONLY=1
   .venv-frameworks/bin/python examples/frameworks/openai_agents.py \
     --model YOUR_MODEL 'Find the five most recent messages in INBOX.'
   ```

Both safety switches default to `1` when absent or empty. Explicit `0` remains
an intentional opt-out. In the default mode the exposed tools
are `mail_probe`, `mail_search`, and `mail_get`. Setting `MAILBEND_READ_ONLY=0`
allows writes, including permanent deletion. `MAILBEND_DRAFTS_ONLY=1` blocks
sending, not deletion. To permit sends, you must deliberately set both switches
to `0`. This changes server permissions; a prompt alone cannot change them.

For a write-enabled session, review the full displayed tool name and JSON
arguments. Type exactly `yes` to approve that one call. Empty input, EOF, or any
other response rejects it. The recipe never grants sticky approval. A changed
call or a new call with identical arguments requires another decision.
Mail content, model output, Jev, `dry_run`, and the `permanently-delete` argument
cannot provide human approval. Permanent deletion cannot be undone.

The recipe escapes control characters and non-ASCII characters in approval
prompts and final output. JSON escapes preserve the text for inspection without
letting mail control the terminal. Review every recipient, message identity,
body, and destructive operation before approving it. A send or delete with an
uncertain result must be checked before any retry. MCP automatic retries are off.
The MCP request timeout is 120 seconds. This is a wait limit, not a cancellation
guarantee or proof that a timed-out write did not happen.

For `mail_reply` and `mail_forward`, the recipe first calls the same operation
with `dry_run=true`, without changing any other arguments. This reads the
original without changing flags or sending mail. The prompt shows the resolved
SMTP envelope recipients, including reply-all recipients, and the original's
folder, UID and UIDVALIDITY. A forward's recipients already come from its
arguments; its attached original still needs review. The preview has a 30-second
wait limit and a 64-KiB preview-response limit. Errors, malformed or oversized previews,
and previews without a resolved SMTP envelope reject the pending call.

The preview deliberately redacts the composed message: it is not complete-content
approval. Before deciding, inspect that exact original in a trusted mail client,
including its full headers, body and attachments. A reply quotes original text;
a forward attaches the whole original message. If you cannot identify the
original exactly or inspect what it includes, reject and handle it in your mail
client. Type `inspected-original` only after that inspection, then `yes` to approve
the one pending call. Either decision can reject. Inspection and approval must
both be repeated for a changed call or a new call with identical arguments.

Draft reply/forward previews contain redacted IMAP APPEND commands rather than
resolved recipients, so this recipe rejects them without prompting or saving.
Use your trusted mail client for those drafts. The preview is not a reservation
or an atomic commitment: execution rereads the original and repeats server
checks. UIDVALIDITY protects against a replaced mailbox, but this client does
not compare message bytes between preview and execution. Reject if the original
or mailbox changes during inspection; never treat an old preview as authority
for a retry.

### Understand the boundary

The fixed tool allowlist contains the three read tools and the four guarded
tools. A callable approval policy trusts only the independently reviewed
`mail_probe`, `mail_search`, and `mail_get` read set. Any other exposed tool
requires approval, and the loop rejects unsupported tool names. Changing the
exposure list alone cannot exempt a new write. Changing the trusted read set
itself still needs review and a behavioral test; a name is not proof of safety.
The allowlist and approval loop protect this Runner integration. They are not
a MailBend permission boundary. Direct `server.call_tool` calls and other MCP
clients bypass this SDK approval policy. The sole automatic call here is the
fixed reply/forward `dry_run=true` preview; do not dispatch writes that way.

Only the settings named in `MAIL_SETTINGS` in the recipe reach the child process.
They cover account identity, the password-file path, IMAP and SMTP endpoints,
TLS mode, connection addresses, DNS, timeout, the two safety switches, draft and
sent folders, sent-copy behavior, recipient limits, daily send limits, state
directory, and the test trust store. Custom providers need the matching
`MAILBEND_IMAP_HOST`, `MAILBEND_IMAP_PORT`, `MAILBEND_SMTP_HOST`,
`MAILBEND_SMTP_PORT`, and, when applicable, `MAILBEND_SMTP_TLS_MODE` settings.
`MAILBEND_CA_FILE` is only for local tests, never production.

The MCP transport also inherits its standard operating-system variables such as
`HOME` and `PATH`. The recipe does not copy the full environment.
`MAILBEND_APP_PASSWORD`, OpenAI credentials, helper-path overrides, attachment
directories, and TypeSafe credentials are not passed to MailBend. Only the TLS
helper reads the password file. The recipe forces `MAILBEND_TYPESAFE=0`, so Jev
does not make a second model request. This is not a recipe for TypeSafe or
attachment access.

### Verify without a model or provider account

Run the lightweight SDK workflow smoke first. It uses a stub MCP process, not
MailBend, and needs no API key. Both SDK smokes are manual checks, not part of
required CI; passing normal CI does not verify this optional integration.

```sh
.venv-frameworks/bin/python tests/test-framework-openai.py
```

After building this checkout, run the full smoke.

```sh
.venv-frameworks/bin/python tests/test-framework-openai.py --real
```

The full smoke uses this checkout's public launcher and
`tests/fake_mail_server.py` on loopback with a throwaway trusted test CA and a
synthetic password file. It explicitly disables both safety switches only in
that isolated fixture. `ScriptedModel` drives the real SDK Runner without an
API request. No live provider account, model service, or TypeSafe service is used.

The smoke checks tool discovery, `mail_probe`, pauses and rejection for all four
guarded tools, absent and empty safety settings, a newly exposed write, invalid
approval input, EOF, safe display, failed previews, and fresh inspection/approval
for changed and new calls. Rejection before preview leaves the command log and
mail state unchanged. Original-message previews add only read-only IMAP traffic
and leave mail state unchanged. Approved synthetic sends, a reply-all, a forward
and a deletion prove that the observers detect effects. This does not evaluate model judgment, prompt-injection
resistance, provider compatibility, or every combination of mail arguments.

The lock was generated with `uv 0.13.5` from
[`requirements-openai.in`](../examples/frameworks/requirements-openai.in) using
the command recorded at the top of
[`requirements-openai.txt`](../examples/frameworks/requirements-openai.txt).
Regeneration resolves current transitive versions and requires review of the
new lock, a clean hash-checked installation and both smokes. Other Python or
platform targets need their own lock and verification. Hashes verify downloaded
artifacts against the lock; they do not establish that a dependency is safe.

## Other frameworks

Claude Agent SDK, LangChain, Google ADK, and CrewAI recipes remain pending
verification. The OpenAI recipe does not establish that their approval or MCP
interfaces work. Track the remaining work in
[#125](https://github.com/albertc71/MailBend/issues/125).
