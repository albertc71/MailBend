# Redacted diagnostics and a separate local-only setup report.

import Base
import ./json.bend as J
import ./tools.bend as T
import ./policy.bend as Policy
import ./imap.bend as I
import ./ops.bend as Ops

type Check is Data:
  Check{checks: List<&2, J.Json>, suggestions: List<&2, J.Json>}

def guidance(stage: String) -> String:
  match stage:
    case "configuration":
      "Check documented switches, host, port, connection IP and DoH settings."
    case "credentials":
      "Configure one password source and account; OAuth is unsupported. Never share secrets."
    case "trust_store":
      "Check system CAs, SSL_CERT_FILE, SSL_CERT_DIR or MAILBEND_CA_FILE; " ++
      "verification is mandatory."
    case "helper":
      "Rebuild with scripts/install.sh; use an absolute executable MAILBEND_TLS_HELPER path."
    case "dns":
      "Check DNS or DoH connectivity and resolver configuration."
    case "connect":
      "Check the configured port, firewall and provider connectivity."
    case "tls":
      "Check the configured SMTP TLS mode and port; IMAP uses implicit verified TLS."
    case "authentication":
      "Check provider password-login support and credentials; SMTP needs AUTH PLAIN or LOGIN."
    case "folders":
      "Inspect mail_probe locally; resolve each missing or ambiguous role with an existing folder."
    case _:
      "Check provider availability and protocol support; retry within the diagnostic deadline."

def fact_guided(
  protocol: String, stage: String, status: String, reason: String, help: String
) -> J.Json:
  J.obj([J.kv("protocol", J.str(protocol)), J.kv("stage", J.str(stage)),
    J.kv("status", J.str(status)), J.kv("reason", J.str(reason)),
    J.kv("guidance", J.str(help))])

def fact(protocol: String, +stage: String, status: String, reason: String) -> J.Json:
  fact_guided(protocol, stage, status, reason, guidance(stage))

def platform_guidance(check: String) -> String:
  match check:
    case "openat2":
      "Linux 5.6+ and sandbox access to openat2 are required; no bypass is supported."
    case "attach_dir":
      "Set MAILBEND_ATTACH_DIR to a dedicated attachment directory when attachments are needed."
    case "download_tmpfile":
      "Use a separate dedicated download directory on a file system with O_TMPFILE support; " ++
        "a successful probe does not establish download permission."
    case "arch":
      "Use a matching Bend binary; the installer pins Linux x86_64, other builds are manual."
    case _:
      "Rebuild with scripts/install.sh; use an absolute executable MAILBEND_ATTACH_HELPER path."

def platform_fact(+check: String, status: String, detail: String) -> J.Json:
  fact_guided("local", "platform", status, check ++ "_" ++ detail, platform_guidance(check))

def platform_error(reason: String) -> J.Json:
  fact_guided("local", "platform", "failed", reason, platform_guidance("helper"))

def platform_line(line: String) -> J.Json:
  match line:
    case "openat2 ok":
      platform_fact("openat2", "ok", "ok")
    case "openat2 unsupported":
      platform_fact("openat2", "failed", "unsupported")
    case "attach_dir ok":
      platform_fact("attach_dir", "ok", "ok")
    case "attach_dir refused":
      platform_fact("attach_dir", "failed", "refused")
    case "attach_dir unset":
      platform_fact("attach_dir", "skipped", "unset")
    case "download_tmpfile ok":
      platform_fact("download_tmpfile", "ok", "ok")
    case "download_tmpfile unsupported":
      platform_fact("download_tmpfile", "failed", "unsupported")
    case "download_tmpfile refused":
      platform_fact("download_tmpfile", "failed", "refused")
    case "download_tmpfile unset":
      platform_fact("download_tmpfile", "skipped", "unset")
    case "arch x86_64":
      platform_fact("arch", "ok", "x86_64")
    case "arch aarch64":
      platform_fact("arch", "ok", "aarch64")
    case "arch other":
      platform_fact("arch", "ok", "other")
    case _:
      platform_error("invalid_diagnostic_response")

def platform_facts.if(
  open: String, attach: String, download: String, arch: String, valid: Bool
) -> List<&2, J.Json>:
  match valid:
    case True{}:
      [platform_line(open), platform_line(attach), platform_line(download), platform_line(arch)]
    case False{}:
      [platform_line("")]

def platform_facts.check(
  +open: String, +attach: String, +download: String, +arch: String
) -> List<&2, J.Json>:
  valid = List.contains(~String, ~String.eq, ["openat2 ok", "openat2 unsupported"], open) &&
    List.contains(~String, ~String.eq, ["attach_dir ok", "attach_dir refused",
      "attach_dir unset"], attach) &&
    List.contains(~String, ~String.eq, ["download_tmpfile ok", "download_tmpfile unsupported",
      "download_tmpfile refused", "download_tmpfile unset"], download) &&
    List.contains(~String, ~String.eq, ["arch x86_64", "arch aarch64", "arch other"], arch)
  platform_facts.if(open, attach, download, arch, valid)

def platform_facts(lines: List<&2, String>) -> List<&2, J.Json>:
  match lines:
    case open <> attach <> download <> arch <> Nil{}:
      platform_facts.check(open, attach, download, arch)
    case open <> attach <> download <> arch <> "" <> Nil{}:
      platform_facts.check(open, attach, download, arch)
    case _:
      [platform_line("")]

def platform_result(p: Policy.Proc) -> List<&2, J.Json>:
  match p:
    case Policy.ProcOk{0, out, err}:
      platform_facts(String.lines(out))
    case Policy.ProcRefused{msg}:
      [platform_error("unavailable")]
    case _:
      [platform_error("timeout_or_helper_failure")]

def platform_at(path: String, attach: String, download: String) -> IO(List<&2, J.Json>):
  match path:
    case SCon{'/', t}:
      do IO<List<&2, J.Json>>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run(SCon{'/', t}, ["check", attach, download], "", 4096, 30000)
        return platform_result(Policy.proc_of(r))
    case _:
      IO.pure(List<&2, J.Json>, platform_result(Policy.ProcRefused{""}))

def platform() -> IO(List<&2, J.Json>):
  do IO<List<&2, J.Json>>:
    path : String <- T.env_or("MAILBEND_ATTACH_HELPER", "")
    attach : String <- T.env_or("MAILBEND_ATTACH_DIR", "")
    download : String <- T.env_or("MAILBEND_DOWNLOAD_DIR", "")
    platform_at(path, attach, download)

def stages() -> List<&2, String>:
  ["configuration", "credentials", "trust_store", "dns", "connect", "tls",
    "greeting", "ehlo", "ehlo_tls", "authentication"]

# Tokens from the native helper are allow-listed, never echoed.
def trust_source(+lines: List<&2, String>) -> String:
  system = List.contains(~String, ~String.eq, lines, "trust_store ok system")
  env = List.contains(~String, ~String.eq, lines, "trust_store ok ssl_cert_env")
  file = List.contains(~String, ~String.eq, lines, "trust_store ok mailbend_ca_file")
  Bool.pick(String, system, "system",
    Bool.pick(String, env, "ssl_cert_env", Bool.pick(String, file, "mailbend_ca_file", "")))

def stage_fact(protocol: String, +stage: String, +lines: List<&2, String>) -> J.Json:
  +source = trust_source(lines)
  +trust = String.eq(stage, "trust_store")
  +ok = Bool.pick(Bool, trust, Bool.not(String.eq(source, "")),
    List.contains(~String, ~String.eq, lines, stage ++ " ok"))
  +bad = List.contains(~String, ~String.eq, lines, stage ++ " failed")
  skipped = List.contains(~String, ~String.eq, lines, stage ++ " skipped")
  +invalid = List.contains(~String, ~String.eq, lines, stage ++ " invalid")
  +tls = List.contains(~String, ~String.eq, lines, stage ++ " unsupported_tls")
  +auth = List.contains(~String, ~String.eq, lines, stage ++ " unsupported_auth")
  status = Bool.pick(String, ok, "ok",
    Bool.pick(String, bad || invalid || tls || auth, "failed", "skipped"))
  reason = Bool.pick(String, ok, Bool.pick(String, trust, source, "verified"),
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

def helper_at(path: String, mode: String, input: String) -> IO(Policy.Proc):
  match path:
    case SCon{'/', t}:
      do IO<Policy.Proc>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run(SCon{'/', t}, [mode], input, 1048576, 30000)
        return Policy.proc_of(r)
    case _:
      IO.pure(Policy.Proc, Policy.ProcRefused{""})

def helper(mode: String, input: String) -> IO(Policy.Proc):
  do IO<Policy.Proc>:
    path : String <- T.env_or("MAILBEND_TLS_HELPER", "")
    helper_at(path, mode, input)

def failed(xs: List<&2, J.Json>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      +status = Policy.str_arg(h, "status", "")
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
    Bool.not(String.eq(trust_source(lines), "")) &&
    (Bool.not(network) || List.contains(~String, ~String.eq, lines, "authentication ok"))
  transport_facts.if(protocol, checks, failed(checks) || complete)

def transport_result(protocol: String, network: Bool, p: Policy.Proc) -> List<&2, J.Json>:
  match p:
    case Policy.ProcOk{0, out, err}:
      transport_facts(protocol, out, network)
    case Policy.ProcRefused{msg}:
      [fact(protocol, "helper", "failed", "unavailable")]
    case _:
      [fact(protocol, "helper", "failed", "timeout_or_helper_failure")]

def transport(+protocol: String, +network: Bool) -> IO(List<&2, J.Json>):
  do IO<List<&2, J.Json>>:
    mode : String = Bool.pick(String, network, "diagnose-", "diagnose-config-") ++ protocol
    p : Policy.Proc <- helper(mode, "")
    return transport_result(protocol, network, p)

def role(name: String, value: Maybe<&2, String>) -> J.Json:
  +present = Maybe.is_some(&2, String, value)
  fact("imap", "folders", Bool.pick(String, present, "ok", "uncertain"),
    name ++ Bool.pick(String, present, "_resolved", "_unresolved"))

def folder_result(f: T.Fs()) -> List<&2, J.Json>:
  match f:
    case Fail{msg}:
      [fact("imap", "folders", "failed", "discovery_or_override_failed")]
    case Done{Policy.Folders{fs, drafts, trash, sent, junk, archive}}:
      [role("inbox", Policy.named_folder(fs, "INBOX")), role("drafts", drafts),
        role("trash", trash), role("sent", sent), role("junk", junk), role("archive", archive)]

def candidate_names(
  xs: List<&2, I.Folder>, +all: List<&2, I.Folder>, +variable: String
) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case I.Folder{+name, delimiter, attrs} <> t:
      List.filter.put(String, name, candidate_names(t, all, variable),
        String.is_empty(T.invalid_override(all, name, variable)))

def candidates.preferred(
  marked: List<&2, I.Folder>, fs: List<&2, I.Folder>, attr: String, a: String, b: String
) -> List<&2, I.Folder>:
  match marked:
    case Nil{}:
      Policy.role_candidates(fs, attr, a, b, False{})
    case _:
      marked

def suggestion(
  resolved: Maybe<&2, String>, role: String, +variable: String,
  +fs: List<&2, I.Folder>, +attr: String, +a: String, +b: String
) -> List<&2, J.Json>:
  match resolved:
    case Some{name}:
      []
    case None{}:
      possible = candidates.preferred(Policy.role_candidates(fs, attr, a, b, True{}), fs, attr, a, b)
      [J.obj([J.kv("role", J.str(role)), J.kv("variable", J.str(variable)),
        J.kv("candidates", J.strs(candidate_names(possible, fs, variable))),
        J.kv("status", J.str("suggestions_only"))])]

def folder_suggestions(f: T.Fs()) -> List<&2, J.Json>:
  match f:
    case Fail{msg}:
      []
    case Done{Policy.Folders{+fs, drafts, trash, sent, junk, archive}}:
      List.concat(&2, J.Json, [
        suggestion(drafts, "drafts", "MAILBEND_DRAFTS_FOLDER", fs,
          "\\Drafts", Policy.drafts_name(), Policy.drafts_name()),
        suggestion(trash, "trash", "MAILBEND_TRASH_FOLDER", fs,
          "\\Trash", Policy.trash_name(), Policy.deleted_messages_name()),
        suggestion(sent, "sent", "MAILBEND_SENT_FOLDER", fs,
          "\\Sent", Policy.sent_name(), Policy.sent_messages_name()),
        suggestion(junk, "junk", "MAILBEND_JUNK_FOLDER", fs,
          "\\Junk", Policy.junk_name(), Policy.junk_name()),
        suggestion(archive, "archive", "MAILBEND_ARCHIVE_FOLDER", fs,
          "\\Archive", Policy.archive_name(), Policy.archive_name())])

def folder_check(+f: T.Fs()) -> Check:
  Check{folder_result(f), folder_suggestions(f)}

def folders.roles(fs: List<&2, I.Folder>, advertised: Bool) -> IO(Check):
  match advertised:
    case False{}:
      do IO<Check>:
        f : T.Fs() <- T.folders_overrides(fs)
        return folder_check(f)
    case True{}:
      do IO<Check>:
        p : Policy.Proc <- helper("imap", I.script(Ops.plan_roles()))
        f : T.Fs() <- T.roles_of(T.imap_result(p), fs)
        return folder_check(f)

def folders.result(r: T.Run()) -> IO(Check):
  match r:
    case Fail{msg}:
      IO.pure(Check, Check{[fact("imap", "folders", "failed", "discovery_failed")], []})
    case Done{+lines}:
      folders.roles(T.merge_folders(I.folders(lines), []), I.has_cap(I.caps(lines), "SPECIAL-USE"))

def folders(checked: Bool) -> IO(Check):
  match checked:
    case False{}:
      IO.pure(Check, Check{[fact("imap", "folders", "skipped", "not_checked")], []})
    case True{}:
      do IO<Check>:
        p : Policy.Proc <- helper("imap", I.script(Ops.plan_probe()))
        folders.result(T.imap_result(p))

def auth_ok(xs: List<&2, J.Json>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      (String.eq(Policy.str_arg(h, "stage", ""), "authentication") &&
        String.eq(Policy.str_arg(h, "status", ""), "ok")) || auth_ok(t)

def report_json(checks: List<&2, J.Json>) -> J.Json:
  J.obj([J.kv("checks", J.arr(checks)), J.kv("redacted", J.bool(True{})),
    J.kv("scope", J.str("Setup checks only: no mailbox-write, recipient, send-quota or " ++
      "delivery guarantee; no sending permission is granted."))])

def result(c: Check) -> Policy.Out:
  Check{+checks, suggestions} = c
  +json = report_json(checks)
  Bool.pick(Policy.Out, failed(checks), Policy.Partial{json}, Policy.Ok{json})

def run.folders(i: List<&2, J.Json>, s: List<&2, J.Json>, f: Check) -> Check:
  Check{checks, suggestions} = f
  Check{List.append(&2, J.Json, i, List.append(&2, J.Json, s, checks)), suggestions}

def run.config(c: Policy.Config, imap: Bool, smtp: Bool) -> IO(Check):
  match c:
    case Policy.ConfigBad{msg}:
      skipped = List.append(&2, J.Json, stage_facts(stages(), "imap", []),
        stage_facts(stages(), "smtp", []))
      IO.pure(Check, Check{fact("local", "configuration", "failed",
        "invalid_switches_or_policy") <> skipped, []})
    case Policy.Config{ro, drafts, jev, images}:
      do IO<Check>:
        p : List<&2, J.Json> <- platform()
        +i : List<&2, J.Json> <- transport("imap", imap)
        s : List<&2, J.Json> <- transport("smtp", smtp)
        f : Check <- folders(auth_ok(i))
        return run.folders(List.append(&2, J.Json, p, i), s, f)

# Validate the send-copy switch without invoking sending or reserving quota.
def run.save_sent(c: Policy.Config, save: Policy.Flag, imap: Bool, smtp: Bool) -> IO(Check):
  match save:
    case Policy.FlagBad{msg}:
      run.config(Policy.ConfigBad{msg}, imap, smtp)
    case _:
      run.config(c, imap, smtp)

def run_checks(imap: Bool, smtp: Bool) -> IO(Check):
  do IO<Check>:
    c : Policy.Config <- T.config()
    save : Policy.Flag <- T.flag("MAILBEND_SAVE_SENT")
    run.save_sent(c, save, imap, smtp)

def run(imap: Bool, smtp: Bool) -> IO(Policy.Out):
  do IO<Policy.Out>:
    check : Check <- run_checks(imap, smtp)
    return result(check)

def setup_result(c: Check) -> Policy.Out:
  Check{+checks, suggestions} = c
  +json = J.obj([J.kv("local_only", J.bool(True{})),
    J.kv("diagnostics", report_json(checks)), J.kv("suggestions", J.arr(suggestions)),
    J.kv("scope", J.str("Private local output may contain folder names. Suggestions are not " ++
      "applied and do not choose among candidates. Empty candidates mean no safe match. " ++
      "Use mail_probe locally to inspect other existing folders; never create or guess one. " ++
      "Use diagnose --imap --smtp for shareable output."))])
  Bool.pick(Policy.Out, failed(checks), Policy.Partial{json}, Policy.Ok{json})

def setup() -> IO(Policy.Out):
  do IO<Policy.Out>:
    c : Check <- run_checks(True{}, True{})
    return setup_result(c)
