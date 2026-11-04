import Base
import ../../src/hook.bend as H
import ../../src/json.bend as J
import ../../src/ops.bend as Ops


def label(d: H.Decision) -> String:
  match d:
    case H.Quiet{}:
      "quiet"
    case H.Ask{_}:
      "ask"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(H.tool_name("mcp__mailbend__mail_send"))
    IO.print(H.tool_name("mcp__mailbend___mail_send"))
    IO.print(H.tool_name("mail_send"))
    IO.print(label(H.call(Ops.OReply{}, J.obj([J.kv("as_draft", J.bool(True{}))]))))
    IO.print(label(H.call(Ops.OSend{}, J.obj([]))))
    IO.print(label(H.call(Ops.OSend{}, J.obj([J.kv("dry_run", J.str("true"))]))))
    IO.print(label(H.call(Ops.ODelete{}, J.obj([J.kv("dry_run", J.bool(True{}))]))))
    IO.print(label(H.raw("not JSON")))
    IO.print(H.clean("safe\n\r\t\u{202E}subject\u{2066}\u{2069}"))

#|mail_send
#|mail_send
#|mail_send
#|quiet
#|ask
#|ask
#|quiet
#|ask
#|safesubject
