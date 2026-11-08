# Private, draft-only #124 experiment. The checked-in template cannot capture.

import Base
import ../src/codec.bend as C
import ../src/mime.bend as M

def prepared() -> Bool:
  False{} # @PREPARED@

def context_path() -> String:
  "@CONTEXT_PATH@"

def context_token() -> String:
  "@CONTEXT_TOKEN@"

def capture_path() -> String:
  "@CAPTURE_PATH@"

def refused() -> IO(String):
  IO.die(String, 97, "mime-observation: synthetic harness required")

def failed() -> IO(String):
  IO.die(String, 98, "mime-observation: private observation failed")

def body_ok(s: String, n: Nat) -> Bool:
  match s n:
    case SNil{} 0n:
      True{}
    case SCon{'x', tail} 1n+rest:
      body_ok(tail, rest)
    case _ _:
      False{}

def header_names(hs: List<&2, M.Hdr>) -> List<&2, String>:
  match hs:
    case Nil{}:
      []
    case M.Hdr{name, _} <> rest:
      name <> header_names(rest)

def synthetic(+raw: String) -> Bool:
  +split = M.split(raw)
  +hs = M.headers(M.head_of(split))
  String.eq(String.join(header_names(hs), ","),
    "from,to,subject,date,message-id,mime-version,content-type,content-transfer-encoding") &&
    String.eq(M.header(hs, "from"), "tester@example.com") &&
    String.eq(M.header(hs, "to"), "a@example.com") &&
    String.eq(M.decode_header(M.header(hs, "subject")), "Unicode é 雪") &&
    String.eq(M.header(hs, "mime-version"), "1.0") &&
    String.eq(M.header(hs, "content-type"), "text/plain; charset=utf-8") &&
    String.eq(M.header(hs, "content-transfer-encoding"), "quoted-printable") &&
    body_ok(M.leaf_bytes(hs, M.body_of(split)), 1048576n)

def written(raw: String, result: Result<&1, &1, U32 & String, Unit>) -> IO(String):
  match result:
    case Done{_}:
      IO.pure(String, raw)
    case Fail{_}:
      failed()

def append.bounded(ok: Bool, file: File, +raw: String) -> IO(String):
  match ok:
    case False{}:
      do IO<String>:
        File.close(file)
        failed()
    case True{}:
      record = "MB124 draft " ++ U32.show(C.byte_len(raw)) ++ "\n" ++ raw ++ "\nEND\n"
      do IO<String>:
        pair : File & Result<&1, &1, U32 & String, Unit> <- File.write(file, record)
        (f, result) = pair
        File.close(f)
        written(raw, result)

def append.sized(file: File, raw: String,
  result: Result<&1, &1, U32 & String, U32>) -> IO(String):
  match result:
    case Fail{_}:
      do IO<String>:
        File.close(file)
        failed()
    case Done{size}:
      append.bounded(U32.is_le(size, 2621400), file, raw)

def append.opened(raw: String, result: Result<&1, &1, U32 & String, File>) -> IO(String):
  match result:
    case Fail{_}:
      failed()
    case Done{file}:
      do IO<String>:
        pair : File & Result<&1, &1, U32 & String, U32> <- File.size(file)
        (f, size) = pair
        append.sized(f, raw, size)

def append.eligible(ok: Bool, raw: String) -> IO(String):
  match ok:
    case False{}:
      refused()
    case True{}:
      do IO<String>:
        opened : Result<&1, &1, U32 & String, File> <- File.open(capture_path(), "a")
        append.opened(raw, opened)

def observe.bounded(ok: Bool, +raw: String) -> IO(String):
  match ok:
    case False{}:
      refused()
    case True{}:
      append.eligible(synthetic(raw), raw)

def context.checked(ok: Bool, +raw: String) -> IO(String):
  match ok:
    case False{}:
      refused()
    case True{}:
      observe.bounded(U32.is_le(C.byte_len(raw), 1572864), raw)

def context.read(raw: String, result: Result<&1, &1, U32 & String, String>) -> IO(String):
  match result:
    case Fail{_}:
      refused()
    case Done{token}:
      context.checked(String.eq(token, context_token()), raw)

def context.opened(raw: String, result: Result<&1, &1, U32 & String, File>) -> IO(String):
  match result:
    case Fail{_}:
      refused()
    case Done{file}:
      do IO<String>:
        pair : File & Result<&1, &1, U32 & String, String> <- File.read(file, 256)
        (f, result) = pair
        File.close(f)
        context.read(raw, result)

def observe.prepared(ok: Bool, raw: String) -> IO(String):
  match ok:
    case False{}:
      refused()
    case True{}:
      do IO<String>:
        opened : Result<&1, &1, U32 & String, File> <- File.open(context_path(), "r")
        context.opened(raw, opened)

def observe(raw: String) -> IO(String):
  observe.prepared(prepared(), raw)
