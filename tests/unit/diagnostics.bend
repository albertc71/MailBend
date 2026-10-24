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

#|invalid_diagnostic_response
#|unavailable
#|timeout_or_helper_failure
#|invalid_configuration
#|False
#|True
#|False
#|skipped
#|True
