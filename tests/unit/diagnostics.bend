# Diagnostic contracts reject missing facts and never echo untrusted text.

import Base
import ../../src/diagnostics.bend as D
import ../../src/policy.bend as Policy
import ../../src/json.bend as J

def first_reason(xs: List<&2, J.Json>) -> String:
  match xs:
    case Nil{}:
      "missing"
    case h <> t:
      Policy.str_arg(h, "reason", "missing")

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(first_reason(D.transport_result("smtp", True{},
      Policy.ProcOk{0, "configuration ok\n", "private server text"})))
    IO.print(first_reason(D.transport_result("imap", False{},
      Policy.ProcRefused{"private path"})))
    IO.print(first_reason(D.transport_result("imap", True{},
      Policy.ProcFail{110, "private server text"})))
    IO.print(first_reason(D.transport_result("imap", False{},
      Policy.ProcOk{0, "configuration invalid\n", "private server text"})))
    IO.print(Bool.show(D.failed(D.transport_result("smtp", False{},
      Policy.ProcOk{0, "configuration ok\ncredentials ok\ntrust_store ok system\n", ""}))))
    IO.print(Bool.show(D.failed(D.transport_result("smtp", True{},
      Policy.ProcOk{0, "configuration ok\ncredentials ok\ntrust_store ok system\n", ""}))))
    IO.print(Bool.show(D.auth_ok(D.transport_result("imap", False{},
      Policy.ProcOk{0, "configuration ok\ncredentials ok\ntrust_store ok system\n", ""}))))
    IO.print(Policy.str_arg(D.stage_fact("imap", "dns", ["dns skipped"]), "reason", ""))
    +clean : String = "configuration ok\ncredentials ok\ntrust_store ok system\n"
    IO.print(Bool.show(String.eq(
      J.show(J.arr(D.transport_facts("imap", clean, False{}))),
      J.show(J.arr(D.transport_facts("imap", clean ++
        "private-server-marker secret AUTH payload\naccount@example.com\n", False{}))))))
    IO.print(Policy.str_arg(D.stage_fact("imap", "trust_store",
      ["trust_store ok system"]), "reason", ""))
    IO.print(Policy.str_arg(D.stage_fact("imap", "trust_store",
      ["trust_store ok ssl_cert_env"]), "reason", ""))
    IO.print(Policy.str_arg(D.stage_fact("imap", "trust_store",
      ["trust_store ok mailbend_ca_file"]), "reason", ""))
    IO.print(first_reason(D.transport_facts("imap",
      "configuration ok\ncredentials ok\ntrust_store ok\n", False{})))
    IO.print(first_reason(D.transport_facts("imap",
      "configuration ok\ncredentials ok\ntrust_store ok unknown\n", False{})))
    IO.print(first_reason(D.transport_facts("imap",
      "configuration ok\ncredentials ok\ntrust_store ok system /private/path\n", False{})))
    IO.print(Bool.show(D.failed(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir unset\ndownload_tmpfile unset\narch x86_64\n", "private stderr"}))))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "openat2 unsupported\nattach_dir refused\ndownload_tmpfile refused\narch other\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch aarch64\nprivate path\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch secret\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\nattach_dir ok\narch x86_64\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\narch x86_64\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "attach_dir ok\nopenat2 ok\ndownload_tmpfile ok\narch x86_64\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch x86_64\n\n", ""})))
    IO.print(first_reason(D.platform_result(Policy.ProcRefused{"private path"})))
    IO.print(first_reason(D.platform_result(Policy.ProcFail{110, "private error"})))
    IO.print(first_reason(D.platform_result(Policy.ProcOk{2,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch x86_64\n", "private error"})))
    IO.print(Policy.str_arg(D.platform_line("download_tmpfile unsupported"), "reason", ""))
    IO.print(Policy.str_arg(D.platform_line("arch aarch64"), "reason", ""))
    IO.print(Bool.show(D.failed(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch aarch64", ""}))))
    IO.print(Bool.show(D.failed(D.platform_result(Policy.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch other\n", ""}))))
    +architecture : J.Json = D.platform_line("arch other")
    IO.print(Policy.str_arg(architecture, "reason", "") ++ " " ++
      Policy.str_arg(architecture, "status", ""))

#|invalid_diagnostic_response
#|unavailable
#|timeout_or_helper_failure
#|invalid_configuration
#|False
#|True
#|False
#|skipped
#|True
#|system
#|ssl_cert_env
#|mailbend_ca_file
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|False
#|openat2_unsupported
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|invalid_diagnostic_response
#|unavailable
#|timeout_or_helper_failure
#|timeout_or_helper_failure
#|download_tmpfile_unsupported
#|arch_aarch64
#|False
#|False
#|arch_other ok
