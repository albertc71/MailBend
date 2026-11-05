# Pure modern MCP metadata checks and response envelopes.

import Base
import ../../src/json.bend as J
import ../../src/mcp-protocol.bend as MCP

def parsed(s: String) -> J.Json:
  Maybe.default(&2, J.Json, J.parse(s), J.JNull{})

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(J.show(MCP.versions()))
    IO.print("latest legacy structured " ++ Bool.show(MCP.is_structured(MCP.latest_legacy_version())))
    IO.print("November 2025 structured " ++ Bool.show(MCP.is_structured("2025-11-25")))
    IO.print("June 2025 structured " ++ Bool.show(MCP.is_structured("2025-06-18")))
    IO.print("March 2025 structured " ++ Bool.show(MCP.is_structured("2025-03-26")))
    IO.print("November 2024 structured " ++ Bool.show(MCP.is_structured("2024-11-05")))
    IO.print("modern structured " ++ Bool.show(MCP.is_structured(MCP.modern_version())))
    IO.print("unknown structured " ++ Bool.show(MCP.is_structured("2099-01-01")))
    IO.print("empty structured " ++ Bool.show(MCP.is_structured("")))
    IO.print("valid metadata " ++ Bool.show(MCP.metadata_ok(parsed("{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}"))))
    IO.print("missing capabilities " ++ Bool.show(MCP.metadata_ok(parsed("{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}"))))
    IO.print("null version " ++ Bool.show(MCP.metadata_ok(parsed("{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":null,\"io.modelcontextprotocol/clientCapabilities\":{}}}"))))
    IO.print("null version selects modern " ++ Bool.show(MCP.is_modern_marked(parsed("{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":null}}"))))
    IO.print("legacy progress metadata " ++ Bool.show(MCP.is_modern_marked(parsed("{\"_meta\":{\"progressToken\":\"a\"}}"))))
    IO.print("null id " ++ Bool.show(MCP.id_ok(J.JNull{})))
    IO.print("negative integer id " ++ Bool.show(MCP.id_ok(J.JNum{"-12"})))
    IO.print("fractional id " ++ Bool.show(MCP.id_ok(J.JNum{"1.5"})))
    IO.print("decimal integer id " ++ Bool.show(MCP.id_ok(J.JNum{"1.0"})))
    IO.print("exponent integer id " ++ Bool.show(MCP.id_ok(J.JNum{"1.5e1"})))
    IO.print("negative exponent integer id " ++ Bool.show(MCP.id_ok(J.JNum{"10e-1"})))
    IO.print("negative exponent fraction id " ++ Bool.show(MCP.id_ok(J.JNum{"10e-2"})))
    IO.print("huge exponent integer id " ++ Bool.show(MCP.id_ok(J.JNum{"1e999999999999"})))
    IO.print("huge negative exponent fraction id " ++ Bool.show(MCP.id_ok(J.JNum{"1e-999999999999"})))
    IO.print(J.show(MCP.result(False{}, J.obj([]), "1")))
    IO.print(J.show(MCP.result(True{}, J.obj([]), "1")))
    IO.print(J.show(MCP.cacheable_result(False{}, J.obj([]), "1")))
    IO.print(J.show(MCP.cacheable_result(True{}, J.obj([]), "1")))

#|["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"]
#|latest legacy structured True
#|November 2025 structured True
#|June 2025 structured True
#|March 2025 structured False
#|November 2024 structured False
#|modern structured False
#|unknown structured False
#|empty structured False
#|valid metadata True
#|missing capabilities False
#|null version False
#|null version selects modern True
#|legacy progress metadata False
#|null id False
#|negative integer id True
#|fractional id False
#|decimal integer id True
#|exponent integer id True
#|negative exponent integer id True
#|negative exponent fraction id False
#|huge exponent integer id True
#|huge negative exponent fraction id False
#|{}
#|{"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mailbend","version":"1"}}}
#|{}
#|{"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mailbend","version":"1","title":"MailBend","description":"Read and manage mail over IMAP and SMTP with bounded plans and safety gates.","websiteUrl":"https://github.com/albertc71/MailBend"}},"ttlMs":300000,"cacheScope":"private"}
