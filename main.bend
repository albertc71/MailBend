import Base
import ./src/codec.bend as C
import ./src/json.bend as J
import ./src/tools.bend as T
import ./src/schema.bend as Schema

# MailBend: iCloud (IMAP/SMTP) mail tools for AI agents.
#
#   mailbend mcp                   MCP server on stdin/stdout (JSON-RPC lines)
#   mailbend tools                 print the tool list as JSON
#   mailbend call <tool> [json]    run one tool and print its JSON result

def version() -> String:
  "0.1.0"

def tools_json() -> J.Json:
  Maybe.default(&2, J.Json, J.parse(Schema.tool_defs()), J.arr([]))

def result_json(+o: T.Out) -> J.Json:
  match o:
    case T.Ok{j}:
      j
    case T.Err{m}:
      J.obj([J.kv("error", J.str(m))])

def is_error(+o: T.Out) -> Bool:
  match o:
    case T.Ok{j}:
      False{}
    case T.Err{m}:
      True{}

# ---- MCP ------------------------------------------------------------------------------

def rpc_result(+id: J.Json, +result: J.Json) -> String:
  J.show(J.obj([J.kv("jsonrpc", J.str("2.0")), J.kv("id", id), J.kv("result", result)]))

def rpc_error(+id: J.Json, +code: String, +msg: String) -> String:
  J.show(J.obj([J.kv("jsonrpc", J.str("2.0")), J.kv("id", id), J.kv("error", J.obj([J.kv("code", J.JNum{code}), J.kv("message", J.str(msg))]))]))

def known_version(+v: String) -> Bool:
  String.eq(v, "2025-06-18") || String.eq(v, "2025-03-26") || String.eq(v, "2024-11-05")

def initialize_result(+params: J.Json) -> J.Json:
  +asked = T.str_arg(params, "protocolVersion", "")
  J.obj([
    J.kv("protocolVersion", J.str(Bool.pick(String, known_version(asked), asked, "2025-06-18"))),
    J.kv("capabilities", J.obj([J.kv("tools", J.obj([J.kv("listChanged", J.bool(False{}))]))])),
    J.kv("serverInfo", J.obj([J.kv("name", J.str("mailbend")), J.kv("version", J.str(version()))])),
    J.kv("instructions", J.str("iCloud mail over IMAP/SMTP. Start with mail_probe. Read tools (mail_search, mail_get, mail_get_new) never mark mail as read. mail_trash is recoverable; mail_delete is permanent and needs confirm = \"permanently-delete\"."))])

def call_result(+o: T.Out) -> J.Json:
  J.obj([J.kv("content", J.arr([J.obj([J.kv("type", J.str("text")), J.kv("text", J.str(J.show(result_json(o))))])])), J.kv("isError", J.bool(is_error(o)))])

def args_of(+m: Maybe<&2, J.Json>) -> J.Json:
  match m:
    case Some{J.JObj{items}}:
      J.JObj{items}
    case _:
      J.obj([])

def send_call(+id: J.Json, +params: J.Json) -> IO(Unit):
  do IO<Unit>:
    o : T.Out <- T.call(T.str_arg(params, "name", ""), args_of(J.get(params, "arguments")))
    IO.print(rpc_result(id, call_result(o)))

def respond_as(+is_call: Bool, +id: J.Json, +method: String, +params: J.Json) -> IO(Unit):
  match is_call:
    case True{}:
      send_call(id, params)
    case False{}:
      IO.print(Bool.pick(String, String.eq(method, "initialize"), rpc_result(id, initialize_result(params)),
        Bool.pick(String, String.eq(method, "tools/list"), rpc_result(id, J.obj([J.kv("tools", tools_json())])),
          Bool.pick(String, String.eq(method, "ping"), rpc_result(id, J.obj([])),
            rpc_error(id, "-32601", "method not found: " ++ method)))))

def respond(+id: J.Json, +method: String, +params: J.Json) -> IO(Unit):
  respond_as(String.eq(method, "tools/call"), id, method, params)

# A request carries an id; a notification (no id) gets no answer.
def request(+req: J.Json, +id: Maybe<&2, J.Json>) -> IO(Unit):
  match id:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{i}:
      respond(i, T.str_arg(req, "method", ""), args_of(J.get(req, "params")))

# A JSON-RPC id is a string, a number or null.
def id_ok(+id: Maybe<&2, J.Json>) -> Bool:
  match id:
    case Some{J.JStr{s}}:
      True{}
    case Some{J.JNum{n}}:
      True{}
    case Some{J.JNull{}}:
      True{}
    case None{}:
      True{}
    case _:
      False{}

def id_or_null(+id: Maybe<&2, J.Json>) -> J.Json:
  match id:
    case Some{J.JStr{s}}:
      J.JStr{s}
    case Some{J.JNum{n}}:
      J.JNum{n}
    case _:
      J.JNull{}

def is_some_str(+m: Maybe<&2, String>) -> Bool:
  match m:
    case Some{s}:
      True{}
    case None{}:
      False{}

# A request is an object with "jsonrpc": "2.0", a string "method" and a
# valid id (if any).
def envelope_ok(+req: J.Json) -> Bool:
  String.eq(Maybe.default(&2, String, J.as_str(J.get(req, "jsonrpc")), ""), "2.0") && is_some_str(J.as_str(J.get(req, "method"))) && id_ok(J.get(req, "id"))

def checked(+ok: Bool, +req: J.Json) -> IO(Unit):
  match ok:
    case True{}:
      request(req, J.get(req, "id"))
    case False{}:
      IO.print(rpc_error(id_or_null(J.get(req, "id")), "-32600", "invalid request: expected a JSON-RPC 2.0 object with a string method"))

def message(+m: Maybe<&2, J.Json>) -> IO(Unit):
  match m:
    case None{}:
      IO.print(rpc_error(J.JNull{}, "-32700", "parse error"))
    case Some{+req}:
      checked(envelope_ok(req), req)

# Whether a line holds only JSON whitespace (space, tab, CR, LF).
def is_blank(+s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      J.is_ws(c) && is_blank(t)

def handle_text(+blank: Bool, +text: String) -> IO(Unit):
  match blank:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      message(J.parse(text))

# A complete line of UTF-8 bytes (decoded only once whole, so a read that
# ends inside a multi-byte character cannot corrupt it).
def handle_line(+line: String) -> IO(Unit):
  handle_text(is_blank(C.utf8_decode(line)), C.utf8_decode(line))

def handle_lines(+ls: List<&2, String>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{l, t}:
      do IO<Unit>:
        handle_line(l)
        handle_lines(t)

def init_lines(+ls: List<&2, String>) -> List<&2, String>:
  List.take(&2, String, ls, Nat.sub(List.length(&2, String, ls), 1n))

def rest_line(+ls: List<&2, String>) -> String:
  Maybe.default(&2, String, List.last(&2, String, ls), "")

# The longest request line accepted, in bytes. A longer one gets an error
# and ends the session, so a client cannot grow the server without bound.
def line_cap() -> U32:
  8388608

def too_long() -> String:
  rpc_error(J.JNull{}, "-32600", "request line longer than 8 MiB; closing")

# The unfinished line is kept as its chunks (newest first) and its length,
# so a long line is joined once instead of copied on every read.
def pending(+parts: List<&2, String>) -> String:
  String.concat(List.reverse(&2, String, parts))

def str_len(+s: String) -> U32:
  U32.from_nat(String.length(s))

# Reads stdin (as bytes) until it closes, answering each complete line. The
# loop is bounded by the client, not by a measure, hence @unsafe (as in
# Bend's own server demos).
@unsafe
def serve(f: File, +parts: List<&2, String>, +n: U32) -> IO(Unit):
  do IO<Unit>:
    m : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
    serve_chunk(m, parts, n)

# `rest` holds the pieces of the chunk after its first newline, if any.
@unsafe
def serve_rest(f: File, +rest: List<&2, String>, +parts: List<&2, String>, +n: U32) -> IO(Unit):
  match rest:
    case Nil{}:
      serve(f, parts, n)
    case Con{h, t}:
      do IO<Unit>:
        handle_line(pending(parts))
        handle_lines(init_lines(rest))
        serve(f, [rest_line(rest)], str_len(rest_line(rest)))

@unsafe
def serve_piece(over: Bool, f: File, +rest: List<&2, String>, +parts: List<&2, String>, +n: U32) -> IO(Unit):
  match over:
    case True{}:
      do IO<Unit>:
        IO.print(too_long())
        File.close(f)
    case False{}:
      serve_rest(f, rest, parts, n)

@unsafe
def serve_pieces(f: File, +pieces: List<&2, String>, +parts: List<&2, String>, +n: U32) -> IO(Unit):
  match pieces:
    case Nil{}:
      serve(f, parts, n)
    case Con{+p, rest}:
      serve_piece(U32.is_gt((n + str_len(p) : U32), line_cap()), f, rest, p <> parts, (n + str_len(p) : U32))

@unsafe
def serve_chunk(m: File & Result<&1, &1, U32 & String, List<&2, U32>>, +parts: List<&2, String>, +n: U32) -> IO(Unit):
  (f, r) = m
  match r:
    case Fail{e}:
      File.close(f)
    case Done{+xs}:
      match xs:
        case Nil{}:
          do IO<Unit>:
            handle_line(pending(parts))
            File.close(f)
        case Con{h, t}:
          serve_pieces(f, String.split(T.bytes_str(xs), '\n'), parts, n)

def mcp() -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open("/dev/stdin", "r"))
    serve(f, [], 0)

# ---- CLI ------------------------------------------------------------------------------

def usage() -> String:
  "usage: mailbend mcp | mailbend tools | mailbend call <tool> [json-arguments]"

# The JSON result always goes to stdout; a failed tool also exits with 1.
def print_out(+o: T.Out) -> IO(Unit):
  match o:
    case T.Ok{j}:
      IO.print(J.show(j))
    case T.Err{m}:
      do IO<Unit>:
        IO.print(J.show(result_json(o)))
        IO.die(Unit, 1, "mailbend: the tool failed")

def call_parsed(+name: String, +parsed: Maybe<&2, J.Json>) -> IO(Unit):
  match parsed:
    case Some{args}:
      do IO<Unit>:
        o : T.Out <- T.call(name, args)
        print_out(o)
    case None{}:
      IO.die(Unit, 2, "the arguments are not valid JSON")

def call_cli(+name: String, +raw: String) -> IO(Unit):
  call_parsed(name, J.parse(raw))

def share(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      h <> share(t)

def cli(+args: List<&2, String>) -> IO(Unit):
  match args:
    case Con{"mcp", Nil{}}:
      mcp()
    case Con{"tools", Nil{}}:
      IO.print(J.show(tools_json()))
    case Con{"call", Con{name, Nil{}}}:
      call_cli(name, "{}")
    case Con{"call", Con{name, Con{raw, Nil{}}}}:
      call_cli(name, raw)
    case Con{"version", Nil{}}:
      IO.print("mailbend " ++ version())
    case _:
      IO.die(Unit, 2, usage())

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    cli(share(args))
