# Fixed refusal evidence: exact markers, no server text, unchanged send outcomes.

import Base
import ../../src/policy.bend as P
import ../../src/diagnostics.bend as D
import ../../src/json.bend as J

def tokens() -> List<&2, String>:
  ["credentials", "temporary", "limit", "in_use", "expired", "contact_admin",
    "greeting_refused", "unknown"]

def marker_cases(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +token <> rest:
      +line = "mailbend-auth: " ++ token
      String.eq(P.auth_reason("mailbend-auth: ", ["mailbend-tls: fixed", line]), token) &&
        String.eq(P.auth_reason("mailbend-auth: ", [line, line]), token) &&
        String.eq(P.auth_reason("mailbend-auth: ", ["x" ++ line]), "") &&
        String.eq(P.auth_reason("mailbend-auth: ", [line ++ "x"]), "") &&
        String.eq(P.auth_reason("mailbend-auth: ", [line ++ " private"]), "") &&
        String.eq(P.auth_reason("mailbend-auth: ", [" " ++ line]), "") &&
        String.eq(P.auth_reason("mailbend-auth: ", [line ++ " "]), "") &&
        marker_cases(rest)

def guidance_cases(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +token <> rest:
      +guidance = P.auth_guidance(token)
      +line = "mailbend-auth: " ++ token ++ "\nmailbend-tls: private-server-marker\n"
      Bool.not(String.eq(guidance, "")) &&
        String.eq(P.helper_error(4, line), guidance) &&
        String.eq(P.helper_error(6, line), guidance) &&
        Bool.not(String.contains(guidance, "private-server-marker")) &&
        guidance_cases(rest)

def diagnostic_cases(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +token <> rest:
      +fact = D.stage_fact("imap", "authentication", ["authentication " ++ token])
      +greeting = D.stage_fact("smtp", "greeting", ["greeting " ++ token])
      String.eq(P.str_arg(fact, "reason", ""), token) &&
        String.eq(P.str_arg(fact, "status", ""), "failed") &&
        String.eq(P.str_arg(fact, "guidance", ""), P.auth_guidance(token)) &&
        String.eq(P.str_arg(greeting, "reason", ""), token) &&
        String.eq(P.str_arg(greeting, "status", ""), "failed") &&
        diagnostic_cases(rest)

def outcome_field(result: P.Out, key: String) -> String:
  match result:
    case P.Partial{value}:
      P.str_arg(value, key, "")
    case P.Ok{value}:
      "accepted"
    case P.Err{message}:
      "error"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(marker_cases(tokens())))
    IO.print(Bool.show(guidance_cases(tokens())))
    IO.print(Bool.show(diagnostic_cases(tokens())))
    IO.print(P.auth_reason("mailbend-auth: ",
      ["mailbend-auth: temporary", "mailbend-auth: credentials"]))
    IO.print(P.auth_reason("mailbend-auth: ",
      ["mailbend-auth: credentials", "mailbend-auth: temporary"]))
    IO.print(Bool.show(String.eq(P.auth_reason("mailbend-auth: ",
      ["mailbend-auth: private-server-marker", "MAILBEND-AUTH: temporary"]), "")))
    IO.print(P.str_arg(D.stage_fact("smtp", "authentication",
      ["authentication temporary private-server-marker"]), "reason", ""))
    IO.print(P.str_arg(D.stage_fact("smtp", "authentication",
      ["authentication temporary", "authentication credentials"]), "reason", ""))
    IO.print(P.str_arg(D.stage_fact("smtp", "authentication",
      ["authentication ok", "authentication temporary"]), "reason", ""))
    IO.print(P.str_arg(D.stage_fact("smtp", "authentication",
      ["authentication ok", "authentication temporary"]), "status", ""))
    +err : String = "mailbend-auth: temporary\nmailbend-tls: fixed\n"
    IO.print(Bool.show(String.eq(P.helper_error(2, err),
      P.helper_cause(2) ++ P.helper_msg(err))))
    IO.print(Bool.show(String.eq(P.helper_error(5, err),
      P.helper_cause(5) ++ P.helper_msg(err))))
    IO.print(outcome_field(P.smtp_code(4, "", "mailbend-smtp: before_data\n" ++ err),
      "smtp_outcome"))
    IO.print(outcome_field(P.smtp_code(6, "", "mailbend-smtp: data_started\n" ++ err),
      "smtp_outcome"))
    IO.print(outcome_field(P.smtp_code(6, "", "mailbend-smtp: data_accepted\n" ++ err),
      "smtp_outcome"))
    IO.print(outcome_field(P.smtp_code(4, "", err), "smtp_outcome"))

#|True
#|True
#|True
#|unknown
#|unknown
#|True
#|not_checked
#|unknown
#|unknown
#|failed
#|True
#|True
#|not_sent
#|unknown
#|accepted
#|unknown
