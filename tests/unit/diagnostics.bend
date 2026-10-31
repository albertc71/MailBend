# Diagnostic contracts reject missing facts and never echo untrusted text.

import Base
import ../../src/diagnostics.bend as D
import ../../src/tools.bend as T
import ../../src/json.bend as J

def first_reason(xs: List<&2, J.Json>) -> String:
  match xs:
    case Nil{}:
      "missing"
    case h <> t:
      T.str_arg(h, "reason", "missing")

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(first_reason(D.transport_result("smtp", True{},
      T.ProcOk{0, "configuration ok\n", "private server text"})))
    IO.print(first_reason(D.transport_result("imap", False{},
      T.ProcRefused{"private path"})))
    IO.print(first_reason(D.transport_result("imap", True{},
      T.ProcFail{110, "private server text"})))
    IO.print(first_reason(D.transport_result("imap", False{},
      T.ProcOk{0, "configuration invalid\n", "private server text"})))
    IO.print(Bool.show(D.failed(D.transport_result("smtp", False{},
      T.ProcOk{0, "configuration ok\ncredentials ok\ntrust_store ok\n", ""}))))
    IO.print(Bool.show(D.failed(D.transport_result("smtp", True{},
      T.ProcOk{0, "configuration ok\ncredentials ok\ntrust_store ok\n", ""}))))
    IO.print(Bool.show(D.auth_ok(D.transport_result("imap", False{},
      T.ProcOk{0, "configuration ok\ncredentials ok\ntrust_store ok\n", ""}))))
    IO.print(T.str_arg(D.stage_fact("imap", "dns", ["dns skipped"]), "reason", ""))
    +clean : String = "configuration ok\ncredentials ok\ntrust_store ok\n"
    IO.print(Bool.show(String.eq(
      J.show(J.arr(D.transport_facts("imap", clean, False{}))),
      J.show(J.arr(D.transport_facts("imap", clean ++
        "private-server-marker secret AUTH payload\naccount@example.com\n", False{}))))))
    IO.print(Bool.show(D.failed(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir unset\ndownload_tmpfile unset\narch x86_64\n", "private stderr"}))))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "openat2 unsupported\nattach_dir refused\ndownload_tmpfile refused\narch other\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch aarch64\nprivate path\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch secret\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\nattach_dir ok\narch x86_64\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\narch x86_64\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "attach_dir ok\nopenat2 ok\ndownload_tmpfile ok\narch x86_64\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch x86_64\n\n", ""})))
    IO.print(first_reason(D.platform_result(T.ProcRefused{"private path"})))
    IO.print(first_reason(D.platform_result(T.ProcFail{110, "private error"})))
    IO.print(first_reason(D.platform_result(T.ProcOk{2,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch x86_64\n", "private error"})))
    IO.print(T.str_arg(D.platform_line("download_tmpfile unsupported"), "reason", ""))
    IO.print(T.str_arg(D.platform_line("arch aarch64"), "reason", ""))
    IO.print(Bool.show(D.failed(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch aarch64", ""}))))
    IO.print(Bool.show(D.failed(D.platform_result(T.ProcOk{0,
      "openat2 ok\nattach_dir ok\ndownload_tmpfile ok\narch other\n", ""}))))
    +architecture : J.Json = D.platform_line("arch other")
    IO.print(T.str_arg(architecture, "reason", "") ++ " " ++
      T.str_arg(architecture, "status", ""))

#|invalid_diagnostic_response
#|unavailable
#|timeout_or_helper_failure
#|invalid_configuration
#|False
#|True
#|False
#|skipped
#|True
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
