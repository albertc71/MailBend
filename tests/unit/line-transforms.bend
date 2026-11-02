import Base
import ../../src/mime.bend as M
import ../../src/smtp.bend as S

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(String.eq(M.lf_lines(""), "")))
    IO.print(Bool.show(String.eq(M.lf_lines("\r\n"), "\n")))
    IO.print(Bool.show(String.eq(M.lf_lines("a\r\nb\nc\rd\r"), "a\nb\nc\rd\r")))
    IO.print(Bool.show(String.eq(M.lf_lines("\r\r\n\n\r"), "\r\n\n\r")))
    IO.print(Bool.show(String.eq(M.lf_lines("é\r\n🦀\u{0}x"), "é\n🦀\u{0}x")))

    IO.print(Bool.show(String.eq(S.dot_stuff(".a\r.b\u{0}é\n.c", False{}), ".a\r.b\u{0}é\n..c")))

#|True
#|True
#|True
#|True
#|True
#|True
