# Claude Code's client-side prompt. This module performs no IO.

import Base
import ./codec.bend as C
import ./json.bend as J
import ./mime.bend as M
import ./ops.bend as Ops
import ./policy.bend as Policy

type Decision is Data:
  Quiet{}
  Ask{reason: String}

def input_cap() -> U32:
  65536

def reason_cap() -> Nat:
  1024n

def clean(s: String) -> String:
  String.take(M.drop_hidden(s), reason_cap())

def uncertain() -> Decision:
  Ask{"MailBend could not inspect this tool call. Check its arguments before continuing."}

def tool_name.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{'_', SCon{'_', _}}:
      acc
    case SCon{c, t}:
      tool_name.go(t, SCon{c, acc})

def tool_name(s: String) -> String:
  tool_name.go(String.reverse(s), "")

def field.put(value: Maybe<&2, J.Json>) -> String:
  match value:
    case None{}:
      "(not supplied)"
    case Some{j}:
      String.take(M.drop_hidden(J.show(j)), 160n)

def field(args: J.Json, key: String) -> String:
  field.put(J.get(args, key))

def attachment_count(value: Maybe<&2, J.Json>) -> String:
  match value:
    case None{}:
      "0"
    case Some{J.JArr{items}}:
      Nat.show(List.length(&2, J.Json, J.unchain(items)))
    case _:
      "(invalid)"

def context(op: Ops.Op) -> String:
  match op:
    case Ops.OReply{}:
      " Recipients come from the original message. Use dry_run to inspect actual recipients."
    case Ops.ODelete{}:
      " Permanent deletion. The confirmation word is only a mistake guard."
    case _:
      ""

def summary(+op: Ops.Op, +args: J.Json) -> String:
  clean("MailBend " ++ Ops.name(op) ++ "." ++ context(op) ++
    " to=" ++ field(args, "to") ++ "; cc=" ++ field(args, "cc") ++
    "; bcc=" ++ field(args, "bcc") ++ "; subject=" ++ field(args, "subject") ++
    "; attachments=" ++ attachment_count(J.get(args, "attachments")) ++
    "; reply_all=" ++ Bool.pick(String, Policy.bool_arg(args, "reply_all", False{}),
      "true", "false"))

def choose(dry: Bool, changes: Bool, reason: String) -> Decision:
  match dry changes:
    case False{} True{}:
      Ask{reason}
    case _ _:
      Quiet{}

def call(+op: Ops.Op, +args: J.Json) -> Decision:
  choose(Policy.bool_arg(args, "dry_run", False{}),
    Policy.sends(op, args) || Ops.is_destructive(op), summary(op, args))

def event.call(op: Maybe<&2, Ops.Op>, args: J.Json) -> Decision:
  match op:
    case None{}:
      uncertain()
    case Some{o}:
      call(o, args)

def event.fields(name: Maybe<&2, String>, args: Maybe<&2, J.Json>) -> Decision:
  match name args:
    case Some{n} Some{J.JObj{items}}:
      event.call(Ops.from_name(tool_name(n)), J.JObj{items})
    case _ _:
      uncertain()

def event.kind(kind: Maybe<&2, String>, +event: J.Json) -> Decision:
  match kind:
    case Some{"PreToolUse"}:
      event.fields(J.as_str(J.get(event, "tool_name")), J.get(event, "tool_input"))
    case _:
      uncertain()

def event(+j: J.Json) -> Decision:
  event.kind(J.as_str(J.get(j, "hook_event_name")), j)

def parsed(j: Maybe<&2, J.Json>) -> Decision:
  match j:
    case None{}:
      uncertain()
    case Some{value}:
      event(value)

def raw.if(over: Bool, raw: String) -> Decision:
  match over:
    case True{}:
      uncertain()
    case False{}:
      parsed(J.parse(raw))

def raw(+text: String) -> Decision:
  raw.if(U32.is_gt(C.byte_len(text), input_cap()), text)

def response(d: Decision) -> J.Json:
  match d:
    case Quiet{}:
      J.obj([])
    case Ask{reason}:
      J.obj([J.kv("hookSpecificOutput", J.obj([
        J.kv("hookEventName", J.str("PreToolUse")),
        J.kv("permissionDecision", J.str("ask")),
        J.kv("permissionDecisionReason", J.str(clean(reason)))
      ]))])

def output(+d: Decision) -> String:
  match d:
    case Quiet{}:
      ""
    case Ask{_}:
      J.show(response(d))
