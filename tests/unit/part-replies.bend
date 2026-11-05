# Selected reads preserve UID, metadata and first-response semantics in a shared reply.

import Base
import ../../src/imap.bend as I
import ../../src/sections.bend as P
import ../../src/tools.bend as T

def part(size: U32) -> P.Part:
  P.Part{[1], "image/png", "", "base64", size}

def metadata(uid: U32, size: U32) -> String:
  "* 1 FETCH (UID " ++ U32.show(uid) ++
    " BODYSTRUCTURE (\"IMAGE\" \"PNG\" NIL NIL NIL \"BASE64\" " ++ U32.show(size) ++ "))\r\n"

def literal(uid: U32, origin: U32, +s: String) -> String:
  "* 1 FETCH (UID " ++ U32.show(uid) ++ " BODY[1]<" ++ U32.show(origin) ++ "> {" ++
    Nat.show(String.length(s)) ++ "}\r\n" ++ s ++ ")\r\n"

def reply(s: String) -> T.Run():
  Done{I.frame("* OK [UIDVALIDITY 42] current\r\n" ++ s)}

def shown(r: Result<&2, &2, String, String>) -> String:
  match r:
    case Done{s}:
      "bytes[" ++ s ++ "]"
    case Fail{why}:
      why

def read(r: T.Run(), uid: U32, size: U32) -> String:
  shown(T.part_prepared(T.part_prepare(r, 42), uid, part(size), 100))

def shared() -> String:
  metadata(8, 4) ++ literal(8, 0, "WFla") ++ metadata(7, 4) ++ literal(7, 0, "QUJD")

def multiple(+r: Result<&2, &2, String, T.PartReply>) -> IO(Unit):
  do IO<Unit>:
    IO.print("cached first " ++ shown(T.part_prepared(r, 7, part(4), 100)))
    IO.print("cached second " ++ shown(T.part_prepared(r, 7,
      P.Part{[2], "image/png", "", "base64", 4}, 100)))

def sections() -> T.Run():
  reply("* 1 FETCH (UID 7 BODYSTRUCTURE ((\"IMAGE\" \"PNG\" NIL NIL NIL \"BASE64\" 4)" ++
    "(\"IMAGE\" \"PNG\" NIL NIL NIL \"BASE64\" 4) \"MIXED\")" ++
    " BODY[2]<0> {4}\r\nREVG BODY[1]<0> {4}\r\nQUJD)\r\n")

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("shared seven " ++ read(reply(shared()), 7, 4))
    IO.print("shared eight " ++ read(reply(shared()), 8, 4))
    IO.print("absent " ++ read(reply(shared()), 9, 4))
    IO.print("split " ++ read(reply(metadata(7, 4) ++ literal(8, 0, "WFla") ++
      literal(7, 0, "QUJD")), 7, 4))
    IO.print("first literal " ++ read(reply(metadata(7, 4) ++ literal(7, 0, "QUJD") ++
      literal(7, 0, "WFla")), 7, 4))
    IO.print("origin " ++ read(reply(metadata(7, 4) ++ literal(7, 1, "QUJD")), 7, 4))
    IO.print("metadata " ++ read(reply(metadata(7, 8) ++ metadata(7, 4) ++
      literal(7, 0, "QUJD")), 7, 4))
    IO.print("malformed " ++ read(reply("* 1 FETCH (UID 7 BODYSTRUCTURE ())\r\n" ++
      shared()), 7, 4))
    IO.print("unrelated malformed " ++ read(reply("* 1 FETCH (UID 9 BODYSTRUCTURE ())\r\n" ++
      shared()), 7, 4))
    IO.print("section prefix " ++ read(reply(metadata(7, 4) ++
      "xx1 FETCH (UID 7 BODY[1]<0> \"QUJD\")\r\n"), 7, 4))
    IO.print("metadata prefix " ++ read(reply(
      "xx1 FETCH (UID 7 BODYSTRUCTURE (\"IMAGE\" \"PNG\" NIL NIL NIL \"BASE64\" 4))\r\n" ++
      literal(7, 0, "QUJD")), 7, 4))
    IO.print("nil then valid " ++ read(reply(metadata(7, 4) ++
      "* 1 FETCH (UID 7 BODY[1]<0> NIL)\r\n" ++ literal(7, 0, "QUJD")), 7, 4))
    IO.print("first identity " ++ read(reply("* OK [UIDVALIDITY 99] later\r\n" ++
      shared()), 7, 4))
    IO.print("transport " ++ read(Fail{"cut literal"}, 7, 4))
    IO.print("stale " ++ Bool.show(String.eq(read(Done{I.frame(
      "* OK [UIDVALIDITY 99] current\r\n" ++ shared())}, 7, 4), T.stale_msg())))
    IO.print("empty " ++ read(reply(metadata(7, 0) ++ literal(7, 0, "")), 7, 0))
    multiple(T.part_prepare(sections(), 42))
    IO.print("legacy " ++ shown(T.part_bytes(reply(shared()), 8, 42, part(4), 100)))

#|shared seven bytes[ABC]
#|shared eight bytes[XYZ]
#|absent no BODYSTRUCTURE for the requested UID
#|split bytes[ABC]
#|first literal bytes[ABC]
#|origin missing selected section or unexpected partial origin
#|metadata MIME section metadata changed between sessions
#|malformed malformed or unsupported BODYSTRUCTURE
#|unrelated malformed bytes[ABC]
#|section prefix bytes[ABC]
#|metadata prefix no BODYSTRUCTURE for the requested UID
#|nil then valid bytes[ABC]
#|first identity bytes[ABC]
#|transport cut literal
#|stale True
#|empty bytes[]
#|cached first bytes[ABC]
#|cached second bytes[DEF]
#|legacy bytes[XYZ]
