# Shareable setup diagnostics. Only explicit flags authorize network checks.
# No server text, addresses, folder names, credentials or helper errors escape.

import Base
import ./json.bend as J
import ./tools.bend as T
import ./imap.bend as I
import ./ops.bend as Ops

def guidance(stage: String) -> String:
  match stage:
    case "configuration":
      "Check documented switches, host, port, connection IP and DoH settings."
    case "credentials":
      "Configure one password source and account; OAuth is unsupported. Never share secrets."
    case "trust_store":
      "Check system CA certificates or the configured test CA file; verification is mandatory."
    case "helper":
      "Rebuild with scripts/install.sh; use an absolute executable MAILBEND_TLS_HELPER path."
    case "dns":
      "Check DNS or DoH connectivity and resolver configuration."
    case "connect":
      "Check the configured port, firewall and provider connectivity."
    case "tls":
      "IMAP requires implicit verified TLS; SMTP requires STARTTLS, not implicit TLS."
    case "authentication":
      "Check provider password-login support and credentials; SMTP needs AUTH PLAIN or LOGIN."
    case "folders":
      "Inspect mail_probe locally; resolve each missing or ambiguous role with an existing folder."
    case _:
      "Check provider availability and protocol support; retry within the diagnostic deadline."

def fact(protocol: String, +stage: String, status: String, reason: String) -> J.Json:
  J.obj([J.kv("protocol", J.str(protocol)), J.kv("stage", J.str(stage)),
    J.kv("status", J.str(status)), J.kv("reason", J.str(reason)),
    J.kv("guidance", J.str(guidance(stage)))])

def stages() -> List<&2, String>:
  ["configuration", "credentials", "trust_store", "dns", "connect", "tls",
    "greeting", "ehlo", "ehlo_tls", "authentication"]

# Tokens from the native helper are allow-listed, never echoed.
def stage_fact(protocol: String, +stage: String, +lines: List<&2, String>) -> J.Json:
  +ok = List.contains(~String, ~String.eq, lines, stage ++ " ok")
  +bad = List.contains(~String, ~String.eq, lines, stage ++ " failed")
  skipped = List.contains(~String, ~String.eq, lines, stage ++ " skipped")
  +invalid = List.contains(~String, ~String.eq, lines, stage ++ " invalid")
  +tls = List.contains(~String, ~String.eq, lines, stage ++ " unsupported_tls")
  +auth = List.contains(~String, ~String.eq, lines, stage ++ " unsupported_auth")
  status = Bool.pick(String, ok, "ok",
    Bool.pick(String, bad || invalid || tls || auth, "failed", "skipped"))
  reason = Bool.pick(String, ok, "verified",
    Bool.pick(String, invalid, "invalid_configuration",
    Bool.pick(String, tls, "unsupported_tls",
    Bool.pick(String, auth, "unsupported_auth",
    Bool.pick(String, bad, "failed",
    Bool.pick(String, skipped, "skipped", "not_checked"))))))
  fact(protocol, stage, status, reason)

def stage_facts(
  xs: List<&2, String>, +protocol: String, +lines: List<&2, String>
) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case s <> t:
      stage_fact(protocol, s, lines) <> stage_facts(t, protocol, lines)

def helper_at(path: String, mode: String, input: String) -> IO(T.Proc):
  match path:
    case SCon{'/', t}:
      do IO<T.Proc>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run(SCon{'/', t}, [mode], input, 1048576, 30000)
        return T.proc_of(r)
    case _:
      IO.pure(T.Proc, T.ProcRefused{""})

def helper(mode: String, input: String) -> IO(T.Proc):
  do IO<T.Proc>:
    path : String <- T.env_or("MAILBEND_TLS_HELPER", "")
    helper_at(path, mode, input)

def failed(xs: List<&2, J.Json>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      +status = T.str_arg(h, "status", "")
      String.eq(status, "failed") || String.eq(status, "uncertain") || failed(t)

def transport_facts.if(
  protocol: String, checks: List<&2, J.Json>, valid: Bool
) -> List<&2, J.Json>:
  match valid:
    case True{}:
      checks
    case False{}:
      [fact(protocol, "helper", "failed", "invalid_diagnostic_response")]

def transport_facts(+protocol: String, out: String, network: Bool) -> List<&2, J.Json>:
  +lines = String.split(out, '\n')
  +checks = stage_facts(stages(), protocol, lines)
  complete = List.contains(~String, ~String.eq, lines, "configuration ok") &&
    List.contains(~String, ~String.eq, lines, "credentials ok") &&
    List.contains(~String, ~String.eq, lines, "trust_store ok") &&
    (Bool.not(network) || List.contains(~String, ~String.eq, lines, "authentication ok"))
  transport_facts.if(protocol, checks, failed(checks) || complete)

def transport_result(protocol: String, network: Bool, p: T.Proc) -> List<&2, J.Json>:
  match p:
    case T.ProcOk{0, out, err}:
      transport_facts(protocol, out, network)
    case T.ProcRefused{msg}:
      [fact(protocol, "helper", "failed", "unavailable")]
    case _:
      [fact(protocol, "helper", "failed", "timeout_or_helper_failure")]

def transport(+protocol: String, +network: Bool) -> IO(List<&2, J.Json>):
  do IO<List<&2, J.Json>>:
    mode : String = Bool.pick(String, network, "diagnose-", "diagnose-config-") ++ protocol
    p : T.Proc <- helper(mode, "")
    return transport_result(protocol, network, p)

def role(name: String, value: Maybe<&2, String>) -> J.Json:
  +present = Maybe.is_some(&2, String, value)
  fact("imap", "folders", Bool.pick(String, present, "ok", "uncertain"),
    name ++ Bool.pick(String, present, "_resolved", "_unresolved"))

def folder_result(f: T.Fs()) -> List<&2, J.Json>:
  match f:
    case Fail{msg}:
      [fact("imap", "folders", "failed", "discovery_or_override_failed")]
    case Done{T.Folders{fs, drafts, trash, sent, junk, archive}}:
      [role("inbox", T.named_folder(fs, "INBOX")), role("drafts", drafts),
        role("trash", trash), role("sent", sent), role("junk", junk), role("archive", archive)]

def folders.roles(fs: List<&2, I.Folder>, advertised: Bool) -> IO(List<&2, J.Json>):
  match advertised:
    case False{}:
      do IO<List<&2, J.Json>>:
        f : T.Fs() <- T.folders_overrides(fs)
        return folder_result(f)
    case True{}:
      do IO<List<&2, J.Json>>:
        p : T.Proc <- helper("imap", I.script(Ops.plan_roles()))
        f : T.Fs() <- T.roles_of(T.imap_result(p), fs)
        return folder_result(f)

def folders.result(r: T.Run()) -> IO(List<&2, J.Json>):
  match r:
    case Fail{msg}:
      IO.pure(List<&2, J.Json>, [fact("imap", "folders", "failed", "discovery_failed")])
    case Done{+lines}:
      folders.roles(T.merge_folders(I.folders(lines), []), I.has_cap(I.caps(lines), "SPECIAL-USE"))

def folders(checked: Bool) -> IO(List<&2, J.Json>):
  match checked:
    case False{}:
      IO.pure(List<&2, J.Json>, [fact("imap", "folders", "skipped", "not_checked")])
    case True{}:
      do IO<List<&2, J.Json>>:
        p : T.Proc <- helper("imap", I.script(Ops.plan_probe()))
        folders.result(T.imap_result(p))

def auth_ok(xs: List<&2, J.Json>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      (String.eq(T.str_arg(h, "stage", ""), "authentication") &&
        String.eq(T.str_arg(h, "status", ""), "ok")) || auth_ok(t)

def result(+checks: List<&2, J.Json>) -> T.Out:
  +json = J.obj([J.kv("checks", J.arr(checks)), J.kv("redacted", J.bool(True{})),
    J.kv("scope", J.str("Setup checks only: no mailbox-write, recipient, send-quota or " ++
      "delivery guarantee; no sending permission is granted."))])
  Bool.pick(T.Out, failed(checks), T.Partial{json}, T.Ok{json})

def run.config(c: T.Config, imap: Bool, smtp: Bool) -> IO(T.Out):
  match c:
    case T.ConfigBad{msg}:
      skipped = List.append(&2, J.Json, stage_facts(stages(), "imap", []),
        stage_facts(stages(), "smtp", []))
      T.pure_out(result(fact("local", "configuration", "failed",
        "invalid_switches_or_policy") <> skipped))
    case T.Config{ro, drafts, jev}:
      do IO<T.Out>:
        +i : List<&2, J.Json> <- transport("imap", imap)
        s : List<&2, J.Json> <- transport("smtp", smtp)
        f : List<&2, J.Json> <- folders(auth_ok(i))
        return result(List.append(&2, J.Json, i, List.append(&2, J.Json, s, f)))

# Validate the send-copy switch without invoking sending or reserving quota.
def run.save_sent(c: T.Config, save: T.Flag, imap: Bool, smtp: Bool) -> IO(T.Out):
  match save:
    case T.FlagBad{msg}:
      run.config(T.ConfigBad{msg}, imap, smtp)
    case _:
      run.config(c, imap, smtp)

def run(imap: Bool, smtp: Bool) -> IO(T.Out):
  do IO<T.Out>:
    c : T.Config <- T.config()
    save : T.Flag <- T.flag("MAILBEND_SAVE_SENT")
    run.save_sent(c, save, imap, smtp)
