# Tail-safe fixtures and comparisons isolate the decoder from Base's recursive helpers.
import Base
import ../../src/mime.bend as M

def repeat(+chunk: String, n: Nat, out: String) -> String:
  match n:
    case 0n:
      out
    case 1n+p:
      repeat(chunk, p, chunk ++ out)

def equal(a: String, b: String, ok: Bool) -> Bool:
  match a b:
    case SNil{} SNil{}:
      ok
    case SCon{x, xs} SCon{y, ys}:
      equal(xs, ys, ok && Char.is_eq(x, y))
    case _ _:
      False{}

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(equal(M.decode_header(repeat("a", 40000n, "")), repeat("a", 40000n, ""), True{})))
    IO.print(M.decode_header("=?latin1" ++ repeat("a", 20000n, "?Q?caf=E9?=")))
    IO.print(M.decode_header("=?latin1*e" ++ repeat("a", 20000n, "?Q?caf=E9?=")))
    IO.print(M.decode_header("=?latin1" ++ repeat("*", 20000n, "?Q?caf=E9?=")))
    IO.print(M.decode_header("=?latin1?" ++ repeat("B", 20000n, "?caf=E9?=")))
    IO.print(Bool.show(equal(M.decode_header("=?latin1?Q?" ++ repeat("=E9", 12000n, "?=")), repeat("é", 12000n, ""), True{})))
    IO.print(Bool.show(equal(M.decode_header(repeat("=?UTF-8?B?YQ==?= ", 8000n, "=?UTF-8?B?Yg==?=")), repeat("a", 8000n, "b"), True{})))
    IO.print(Bool.show(equal(M.decode_header(repeat("x\t", 20000n, "z")), repeat("x ", 20000n, "z"), True{})))
    IO.print(M.decode_header(" =?latin1?Q?caf=E9?=  =?latin1?Q?cr=E8me?=\t "))
    IO.print(Bool.show(equal(M.decode_header("=?latin1?Q?" ++ repeat("?", 20000n, "?=")), "=?latin1?Q?" ++ repeat("?", 20000n, "?="), True{})))

#|True
#|caf�
#|café
#|caf�
#|café
#|True
#|True
#|True
#| café  crème  
#|True
