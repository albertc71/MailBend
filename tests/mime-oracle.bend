# Export production MIME reads and named composition inputs for Python's oracle.

import Base
import ../src/mime.bend as M
import ../src/codec.bend as C
import ../src/json.bend as J
import ./composition-cases.bend as V

def headers(hs: List<&2, M.Hdr>) -> List<&2, J.Json>:
  match hs:
    case Nil{}:
      []
    case M.Hdr{name, value} <> rest:
      J.obj([J.kv("name", J.str(name)), J.kv("value", J.str(M.decode_header(value)))])
        <> headers(rest)

def decoded_text(text: Bool, ct: String, bytes: String) -> String:
  match text:
    case True{}:
      M.leaf.text(ct, bytes)
    case False{}:
      ""

def leaf(k: M.PartKind, hs: List<&2, M.Hdr>, +bytes: String) -> J.Json:
  M.PartKind{+ct, +typ, name, _} = k
  J.obj([
    J.kv("content_type", J.str(typ)), J.kv("filename", J.str(name)),
    J.kv("disposition", J.str(M.main_value(M.header(hs, "content-disposition")))),
    J.kv("charset", J.str(M.param(ct, "charset"))),
    J.kv("text", J.str(decoded_text(String.starts_with(typ, "text/"), ct, bytes))),
    J.kv("data", J.str(C.b64_encode(bytes, False{})))
  ])

def leaves(ls: List<&2, M.Leaf>) -> List<&2, J.Json>:
  match ls:
    case Nil{}:
      []
    case M.Leaf{+hs, body} <> rest:
      leaf(M.part_kind(hs), hs, M.leaf_bytes(hs, body)) <> leaves(rest)

def parsed(+raw: String) -> J.Json:
  +hs = M.headers(M.head_of(M.split(raw)))
  +ct = M.header(hs, "content-type")
  J.obj([
    J.kv("content_type", J.str(Bool.pick(String, String.is_empty(ct), "text/plain", M.main_value(ct)))),
    J.kv("disposition", J.str(M.main_value(M.header(hs, "content-disposition")))),
    J.kv("charset", J.str(M.param(ct, "charset"))),
    J.kv("boundary", J.str(M.param(ct, "boundary"))),
    J.kv("headers", J.arr(headers(hs))),
    J.kv("parts", J.arr(leaves(M.message_leaves(raw))))
  ])

def attachments(xs: List<&2, M.Attach>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      []
    case M.Attach{name, typ, data} <> rest:
      J.obj([J.kv("filename", J.str(name)), J.kv("content_type", J.str(typ)),
        J.kv("data", J.str(C.b64_encode(data, False{})))]) <> attachments(rest)

def input(d: M.Draft) -> J.Json:
  M.Draft{from, to, cc, bcc, subject, text, date, msgid, irt, refs, atts} = d
  J.obj([
    J.kv("from", J.str(from)), J.kv("to", J.strs(to)), J.kv("cc", J.strs(cc)),
    J.kv("bcc", J.strs(bcc)), J.kv("subject", J.str(subject)), J.kv("text", J.str(text)),
    J.kv("date", J.str(date)), J.kv("message_id", J.str(msgid)),
    J.kv("in_reply_to", J.str(irt)), J.kv("references", J.str(refs)),
    J.kv("attachments", J.arr(attachments(atts)))
  ])

def cases(xs: List<&2, V.Case>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +c <> rest:
      +raw = V.wire(c)
      do IO<Unit>:
        IO.print(J.show(J.obj([
          J.kv("name", J.str(V.name(c))), J.kv("input", input(V.draft(c))),
          J.kv("wire", J.str(C.b64_encode(raw, False{}))), J.kv("parsed", parsed(raw))
        ])))
        cases(rest)

def lines(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case h <> rest:
      do IO<Unit>:
        IO.print(J.show(parsed(C.b64_decode(h))))
        lines(rest)

def read.last(s: String) -> IO(Unit):
  match s:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case SCon{c, t}:
      lines([SCon{c, t}])

type Stream is Type:
  ReadChunk{file: File, pending: List<&2, String>}
  ReadResult{pending: List<&2, String>, pair: File & Result<&1, &1, U32 & String, String>}
  Pieces{file: File, pending: List<&2, String>, parts: List<&2, String>}

@unsafe
def read(state: Stream) -> IO(Unit):
  match state:
    case ReadChunk{f, pending}:
      do IO<Unit>:
        pair : File & Result<&1, &1, U32 & String, String> <- File.read(f, 65536)
        read(ReadResult{pending, pair})
    case ReadResult{pending, pair}:
      (f, result) = pair
      match result:
        case Fail{error}:
          (code, message) = error
          do IO<Unit>:
            File.close(f)
            IO.die(Unit, code, message)
        case Done{SNil{}}:
          do IO<Unit>:
            File.close(f)
            read.last(String.concat(List.reverse(&2, String, pending)))
        case Done{SCon{c, tail}}:
          read(Pieces{f, pending, String.split(SCon{c, tail}, '\n')})
    case Pieces{f, pending, Nil{}}:
      read(ReadChunk{f, pending})
    case Pieces{f, pending, part <> Nil{}}:
      read(ReadChunk{f, part <> pending})
    case Pieces{f, pending, part <> rest}:
      do IO<Unit>:
        lines([String.concat(List.reverse(&2, String, part <> pending))])
        read(Pieces{f, [], rest})

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> "--cases" <> Nil{}:
      cases(V.all())
    case _:
      do IO<Unit>:
        opened : Result<&1, &1, U32 & String, File> <- File.open("/dev/stdin", "r")
        f : File <- IO.try(File, IO.pure(Result<&1, &1, U32 & String, File>, opened))
        read(ReadChunk{f, []})

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
