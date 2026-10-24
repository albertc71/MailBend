---
name: verify-smtp-tls-ordering
description: Recheck the bounded SMTP transport model when changing TLS modes, negotiation, authentication ordering, or failure propagation.
---

# SMTP TLS ordering verification

Before authentication, SMTP must have completed verified TLS. Otherwise the account password could leave the machine without authenticated encryption.

Run `bend PROOF.bend --verdict` from the repository root, using the pinned Bend and Lean releases installed by `scripts/install-bend.sh` and `scripts/install-lean.sh`. For only this model, run `bend tests/formal/smtp-tls.bend --verdict`. Require exit zero and `ALL PROOFS CHECK`. Tests complement this proof: `bash tests/test-transport.sh` and `python3 tests/test-e2e.py` exercise the real native helper and Bend send gates.

## Coverage and correspondence

The model in `tests/formal/smtp-tls.bend` covers two modes and two TLS results, four complete traces with at most six events, plus their prefixes. It proves `auth_requires_verified_tls` and `handshake_failure_cannot_authenticate` for every model input. `safe` checks each event as it consumes the trace, so an early SMTP rejection that truncates a trace also cannot expose AUTH before verification.

- `implicit_trace` corresponds to `negotiate_tls` in `native/mailbend-tls/src/smtp/session.rs`: `Connection::start_tls` succeeds before greeting/EHLO, then `run` calls `authenticate`.
- `starttls_trace` corresponds to greeting/EHLO/STARTTLS, successful `Connection::start_tls`, second EHLO, then `run` calling `authenticate`.
- `Failed` ending a trace corresponds to Rust `?` returning an error before `authenticate` is reached.
- `Verified` abstracts `Connection::start_tls` in `native/mailbend-tls/src/connection.rs` and verified `tls::connect` in the native network crate. Treat this as atomic success or failure.
- Strict mode parsing is implemented by `SmtpTlsMode::from_env` in `native/mailbend-tls/src/settings.rs`; the model assumes this selects exactly one of its two modes.

This is an abstraction proof, not a proof of Rust, rustls, cryptography, certificates, sockets, timeouts, credentials, or provider compatibility. Greeting and EHLO failures are represented only by prefixes; authentication responses, envelopes, retries, concurrency and hostile TLS record details are outside this model. Synthetic tests check the implementation correspondence for successful modes, certificate/hostname failures, wrong endpoints, silent endpoints and recipient rejection. Existing Bend laws cover envelope and send-policy values separately.

## Mutation check and maintenance

Run `python3 tests/formal/check-smtp-tls.py` to reproduce the following checks without editing production code. On a scratch copy of the model, remove `Verified{}` from the successful implicit trace. The first property must fail. On another scratch copy, replace the failed implicit trace with `[Failed{}, Auth{}]`; both properties must fail. Restore the model and require both properties to pass. Never change the checker or a law to make the broken transition pass.

Review the correspondence above whenever any named Rust function or model changes. A model counterexample can mean either unsafe product ordering or an incorrect abstraction: inspect the actual source and real-helper tests before deciding which. Use `/maintain-formal-verification-skill` to update coverage after changes that did not recheck it.

Coverage baseline: `787d1a3` plus this SMTP mode change. Record the final reviewed commit in the PR verification evidence; move that reference forward only after source/model correspondence and mutation checks are repeated.