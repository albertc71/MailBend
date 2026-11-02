# Tail-safe fixtures isolate visible header sanitization and its 998-code-point limit.
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
    IO.print(Bool.show(equal(M.header_line(repeat("a", 20000n, "")), repeat("a", 998n, ""), True{})))
    IO.print(M.header_line.text(repeat("\r\n\t", 20000n, "visible")))
    IO.print(M.header_line.text(repeat("\u{202e}\u{2069}", 20000n, "visible")))
    IO.print(M.header_line.text(repeat(" ", 20000n, "")))
    IO.print(Bool.show(equal(M.header_line.text(repeat("é", 20000n, "")), repeat("é", 998n, ""), True{})))
    IO.print(Bool.show(equal(M.header_line(M.header(M.headers("Subject: " ++ repeat("a", 20000n, "")), "subject")), repeat("a", 998n, ""), True{})))
    IO.print(Bool.show(equal(M.header_line.text(repeat("x", 997n, " y")), repeat("x", 997n, " "), True{})))
    IO.print(M.header_line.text("\u{a0}x\u{a0}"))
    IO.print(M.header_line.text(" \u{202e}A\u{85}B\u{2028}C\u{2029}D\u{2069} "))

#|True
#|visible
#|visible
#|
#|True
#|True
#|True
#| x 
#|A B C D
