# Every known tool must retain an actual input schema, not equal missing values.
# Reference lookup is the original aggregate parse; selected lookup is production.
import Base
import ../../src/json.bend as J
import ../../src/tools.bend as T
import ../../src/schema.bend as Schema
import ../../src/ops.bend as Ops
import ../../src/policy.bend as Policy

def json(s: String) -> J.Json:
  Maybe.default(&2, J.Json, J.parse(s), J.JNull{})

def equal(a: String, b: String, ok: Bool) -> Bool:
  match a b:
    case SNil{} SNil{}:
      ok
    case SCon{x, xs} SCon{y, ys}:
      equal(xs, ys, ok && Char.is_eq(x, y))
    case _ _:
      False{}

def same(a: Maybe<&2, J.Json>, b: Maybe<&2, J.Json>) -> Bool:
  match a b:
    case Some{x} Some{y}:
      equal(J.show(x), J.show(y), True{})
    case _ _:
      False{}

def old(+all: J.Json, name: String) -> Maybe<&2, J.Json>:
  T.input_of(T.tool_named(all, name))

def check(ops: List<&2, Ops.Op>, +all: J.Json) -> List<&2, Bool>:
  match ops:
    case Nil{}:
      []
    case h <> t:
      +name = Ops.name(h)
      same(T.tool_input(name), old(all, name)) <> check(t, all)

def all_true(xs: List<&2, Bool>, n: U32) -> U32:
  match xs:
    case Nil{}:
      n
    case h <> t:
      all_true(t, (n + Bool.pick(U32, h, 1, 0) : U32))

def check_args(+all: J.Json, +name: String, +args: String, valid: Bool) -> Bool:
  +actual = T.schema_problem(T.tool_input(name), json(args), name)
  expected = T.schema_problem(old(all, name), json(args), name)
  equal(actual, expected, True{}) && Bool.pick(Bool, valid, String.is_empty(actual), Bool.not(String.is_empty(actual)))

def unknown_refused(o: Policy.Out) -> Bool:
  match o:
    case Policy.Err{m}:
      String.eq(m, "unknown tool: unknown")
    case _:
      False{}

def main() -> IO(Unit):
  do IO<Unit>:
    +all : J.Json = T.array_items(J.parse(Schema.tool_defs()))
    IO.print(U32.show(all_true(check(Ops.all_ops(), all), 0)))
    IO.print(Bool.show(Maybe.is_none(&2, J.Json, T.tool_input("unknown\"}\n"))))
    IO.print(Bool.show(check_args(all, "mail_get", "{\"uid\":3}", True{})))
    IO.print(Bool.show(check_args(all, "mail_get", "{}", False{})))
    IO.print(Bool.show(check_args(all, "mail_get", "{\"uid\":\"3\"}", False{})))
    IO.print(Bool.show(check_args(all, "mail_get", "{\"uid\":3,\"bogus\":1}", False{})))
    IO.print(Bool.show(check_args(all, "mail_get", "[]", False{})))
    IO.print(Bool.show(check_args(all, "mail_delete", "{\"uids\":[3],\"uidvalidity\":7,\"confirm\":\"permanently-delete\",\"dry_run\":false,\"dry_run\":true}", False{})))
    IO.print(Bool.show(check_args(all, "mail_reply", "{\"uid\":3,\"uidvalidity\":7,\"body\":\"x\",\"as_draft\":\"true\"}", False{})))
    IO.print(Bool.show(check_args(all, "mail_delete", "{\"uids\":[3],\"uidvalidity\":7,\"confirm\":true}", False{})))
    IO.print(Bool.show(check_args(all, "mail_send", "{\"to\":\"x@example.test\",\"subject\":\"x\",\"body\":\"x\",\"attachments\":[{\"path\":7}]}", False{})))
    unknown : Policy.Out <- T.call("unknown", J.obj([]))
    IO.print(Bool.show(unknown_refused(unknown)))
    return Unit{}
#|28
#|True
#|True
#|True
#|True
#|True
#|True
#|True
#|True
#|True
#|True
#|True
