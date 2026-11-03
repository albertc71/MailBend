# A supplied immutable schema survives repeated requests and protocol changes.
# Using the global generated schema instead would change every expected reply.
import Base
import ../../main.bend as Main
import ../../src/json.bend as J

def main() -> IO(Unit):
  do IO<Unit>:
    +schema : J.Json = J.arr([
      J.obj([J.kv("name", J.str("mail_probe")),
        J.kv("outputSchema", J.obj([J.kv("type", J.str("object"))]))]),
      J.obj([J.kv("name", J.str("not_an_offered_tool"))])])
    +legacy : Maybe<&2, String> = Some{"2025-06-18"}
    next : Maybe<&2, String> <- Main.handle_line(schema, legacy,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")
    ignored : Maybe<&2, String> <- Main.handle_line(schema, next,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
    ignored : Maybe<&2, String> <- Main.handle_line(schema, Some{"2024-11-05"},
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}")
    ignored : Maybe<&2, String> <- Main.handle_line(schema, legacy,
      "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}")
    return Unit{}
#|{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"mail_probe","outputSchema":{"type":"object"}}]}}
#|{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"mail_probe","outputSchema":{"type":"object"}}]}}
#|{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"mail_probe"}]}}
#|{"jsonrpc":"2.0","id":4,"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mailbend","version":"0.1.0"}},"ttlMs":300000,"cacheScope":"private","tools":[{"name":"mail_probe","outputSchema":{"type":"object"}}]}}
