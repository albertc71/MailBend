# SMTP evidence is independent of process exit and never inferred from server text.

import Base
import ../../src/policy.bend as Policy
import ../../src/json.bend as J
import ../../main.bend as Main

def outcome(o: Policy.Out) -> String:
  J.show(Main.result_json(o))

def field(o: Policy.Out, name: String) -> String:
  Policy.str_arg(Main.result_json(o), name, "")

def phase(p: String, code: U32) -> Policy.Out:
  Policy.smtp_code(code, "250 queued\r\n", "mailbend-smtp: before_data\nmailbend-smtp: " ++ p ++ "\n")

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(field(phase("before_data", 137), "smtp_outcome"))
    IO.print(field(phase("data_started", 137), "smtp_outcome"))
    IO.print(field(phase("data_rejected", 137), "smtp_outcome"))
    IO.print(outcome(phase("data_accepted", 137)))
    IO.print(field(Policy.smtp_code(0, "250 accepted\nmailbend-smtp: data_accepted\n", ""),
      "smtp_outcome"))
    IO.print(field(Policy.smtp_code(5, "550 rejected\n", ""), "smtp_outcome"))
    IO.print(field(Policy.smtp_result(Policy.ProcFail{110, "interrupted"}), "smtp_outcome"))
    IO.print(field(Policy.smtp_result(Policy.ProcRefused{"not executable"}), "smtp_outcome"))
    IO.print(Bool.show(Main.is_error(phase("data_rejected", 5))))
    IO.print(Bool.show(Main.is_error(phase("data_started", 6))))
    IO.print(Policy.smtp_phase(["mailbend-smtp: before_data", "mailbend-smtp: data_started",
      "mailbend-smtp: data_accepted", "mailbend-tls: cleanup failed"], ""))

#|not_sent
#|unknown
#|not_sent
#|"250 queued"
#|unknown
#|unknown
#|unknown
#|not_sent
#|True
#|True
#|data_accepted
