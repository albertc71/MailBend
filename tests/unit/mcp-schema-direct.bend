# Generated selection must match the original parsed/filter path, including
# schema order, duplicates, unknown names and safely escaped untrusted IDs.
import Base
import ../../main.bend as Main
import ../../src/json.bend as J
import ../../src/schema.bend as Schema
import ../../src/tools.bend as T
import ../../src/ops.bend as Ops
import ../../src/mcp-protocol.bend as MCP

def equal(a: String, b: String, ok: Bool) -> Bool:
  match a b:
    case SNil{} SNil{}:
      ok
    case SCon{x, xs} SCon{y, ys}:
      equal(xs, ys, ok && Char.is_eq(x, y))
    case _ _:
      False{}

def same(+names: List<&2, String>) -> Bool:
  original = Maybe.default(&2, J.Json, J.parse(Schema.tool_defs()), J.arr([]))
  selected = Maybe.default(&2, J.Json, J.parse(Schema.tool_defs_for(names)), J.JNull{})
  equal(J.show(selected), J.show(T.offered_in(original, names)), True{})

# Pin the entire envelope to the original response helpers, not just tools.
# One hostile ID is enough here: both paths use the same J.show encoder, and
# the runtime regression covers the remaining ID types independently.
def envelope(+parsed: J.Json, ro: Bool, drafts: Bool, jev: Bool) -> Bool:
  +names = Ops.listed_names(Ops.all_ops(), ro, drafts, jev)
  +id = J.str("quote\"\\\nline")
  original = Main.rpc_result(id, MCP.cacheable_result(False{},
    J.obj([J.kv("tools", Main.tools_for(True{}, T.offered_in(parsed, names)))]), Main.version()))
  equal(Main.listed_result(id, names), original, True{})

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(same([])))
    IO.print(Bool.show(same(["mail_probe", "mail_get"])))
    IO.print(Bool.show(same(["mail_get", "unknown", "mail_probe", "mail_get"])))
    IO.print(Bool.show(same(["mail_probe"])))
    IO.print(Bool.show(same(["unknown\"}\\\n"])))
    IO.print(Bool.show(same(["mail_probe",
      "mail_list_folders",
      "mail_search",
      "mail_get",
      "mail_get_new",
      "mail_brief",
      "mail_refresh",
      "mail_get_thread",
      "mail_awaiting_reply",
      "mail_contacts",
      "mail_correspondents",
      "mail_classify",
      "mail_triage",
      "mail_get_attachment",
      "mail_mark_read",
      "mail_mark_unread",
      "mail_flag",
      "mail_unflag",
      "mail_move",
      "mail_label",
      "mail_trash",
      "mail_delete",
      "mail_create_folder",
      "mail_rename_folder",
      "mail_save_draft",
      "mail_send",
      "mail_reply",
      "mail_forward"])))
    +parsed : J.Json = Maybe.default(&2, J.Json, J.parse(Schema.tool_defs()), J.arr([]))
    IO.print(Bool.show(envelope(parsed, False{}, False{}, False{})))
    IO.print(Bool.show(envelope(parsed, False{}, False{}, True{})))
    IO.print(Bool.show(envelope(parsed, False{}, True{}, False{})))
    IO.print(Bool.show(envelope(parsed, False{}, True{}, True{})))
    IO.print(Bool.show(envelope(parsed, True{}, False{}, False{})))
    IO.print(Bool.show(envelope(parsed, True{}, False{}, True{})))
    IO.print(Bool.show(envelope(parsed, True{}, True{}, False{})))
    IO.print(Bool.show(envelope(parsed, True{}, True{}, True{})))
    IO.print(Main.listed_result(J.str("quote\"\\\nline"), []))
    IO.print(Main.listed_result(J.JNull{}, []))
    return Unit{}
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
#|True
#|True
#|True
#|{"jsonrpc":"2.0","id":"quote\"\\\nline","result":{"tools":[]}}
#|{"jsonrpc":"2.0","id":null,"result":{"tools":[]}}
