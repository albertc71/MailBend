# The send boundary keeps local scan results and bypasses it only when off.

import Base
import ../../src/tools.bend as T
import ../../src/jev.bend as Jev
import ../../src/json.bend as J
import ../../src/mime.bend as M
import ../../src/policy.bend as P

def fake_password() -> String:
  "Password: " ++ "hunter" ++ "22"

def fake_token(prefix: String, count: Nat) -> String:
  prefix ++ String.repeat("a1B2c3D4", count)

def fake_key(+kind: String) -> String:
  "-----BEGIN RSA " ++ kind ++ " KEY-----\n" ++
    "MIIEowIBAAKCAQEA" ++ String.repeat("fake", 5n) ++
    "\n-----END RSA " ++ kind ++ " KEY-----\n"

def fields(+j: J.Json) -> String:
  P.str_arg(j, "secret_scan", "absent") ++ " " ++
    P.str_arg(j, "smtp_outcome", "absent") ++ " " ++
    Bool.show(Maybe.is_some(&2, J.Json, J.get(j, "jev")))

def show(o: P.Out) -> String:
  match o:
    case P.Ok{+j}:
      "preview " ++ Bool.show(P.bool_arg(j, "dry_run", False{})) ++ " " ++ fields(j)
    case P.Err{m}:
      m
    case P.Partial{j}:
      "blocked " ++ fields(j)

def send(scan: String, text: String, atts: List<&2, M.Attach>, jev: Jev.Switch) -> IO(Unit):
  w : T.Want = T.Want{["reader@example.com"], [], [], "Fixture", text, "", "", atts,
    False{}, True{}, Jev.Fresh{}, jev}
  do IO<Unit>:
    o : P.Out <- T.send_with(T.sending_of("", "", "", "", "", "", scan), w,
      "sender@example.com", T.Stamp{"Thu, 05 Nov 2026 00:00:00 +0000", "fixture"})
    IO.print(show(o))

def main() -> IO(Unit):
  do IO<Unit>:
    send("1", fake_password(), [], Jev.Off{})
    send("true", fake_password(), [], Jev.Off{})
    send("1", "hello", [], Jev.Off{})
    send("", fake_password(), [], Jev.Off{})
    send("0", fake_password(), [], Jev.Off{})
    send("false", fake_password(), [], Jev.Off{})
    send("yes", "hello", [], Jev.Off{})
    send(" false ", "hello", [], Jev.Off{})
    send("1", "hello", [M.Attach{"private.txt", "text/plain", fake_password()}], Jev.Off{})
    send("1", "hello", [M.Attach{"wide.txt", "text/plain; charset=utf-16", "x"}], Jev.Off{})
    send("0", fake_password(), [], Jev.On{Jev.Headers{}})
    send("1", fake_token("gh" ++ "p_", 4n), [], Jev.Off{})
    send("1", fake_key("PRIVATE"), [], Jev.Off{})
    send("1", "gh" ++ "p_" ++ String.repeat("x", 15n), [], Jev.Off{})
    send("1", fake_token("gh" ++ "q_", 4n), [], Jev.Off{})
    send("1", fake_key("PUBLIC"), [], Jev.Off{})
    send("1", "Password: " ++ "required", [], Jev.Off{})

#|blocked found not_sent False
#|blocked found not_sent False
#|preview True clean absent False
#|preview True absent absent False
#|preview True absent absent False
#|preview True absent absent False
#|configuration error: MAILBEND_SECRET_SCAN must be 1, true, 0, false or empty
#|configuration error: MAILBEND_SECRET_SCAN must be 1, true, 0, false or empty
#|blocked found not_sent False
#|blocked incomplete not_sent False
#|blocked found not_sent True
#|blocked found not_sent False
#|blocked found not_sent False
#|preview True clean absent False
#|preview True clean absent False
#|preview True clean absent False
#|preview True clean absent False
