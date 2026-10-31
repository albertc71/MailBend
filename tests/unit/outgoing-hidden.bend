# Hidden Unicode counts, flag validity and the outgoing refusal boundary.

import Base
import ../../src/mime.bend as M
import ../../src/codec.bend as C
import ../../src/tools.bend as T
import ../../src/jev.bend as Jev
import ../../src/unicode_tags.bend as Tag

def tag_text(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{c, t}:
      SCon{C.chr((917504 + C.u(c) : U32)), tag_text(t)}

def flag(s: String) -> String:
  "\u{1F3F4}" ++ tag_text(s) ++ "\u{E007F}"

def count_line.of(h: M.Hidden) -> String:
  M.Hidden{tag, bidi, zw} = h
  U32.show(tag) ++ "/" ++ U32.show(bidi) ++ "/" ++ U32.show(zw)

def count_line(s: String) -> String:
  count_line.of(M.hidden_count(s))

def flag_line(+id: String) -> String:
  +s = flag(id)
  id ++ " " ++ U32.show(M.refused_tags(s)) ++ " " ++ count_line(s)
    ++ " " ++ Bool.show(String.eq(M.strip_tags(s), s))

def want(text: String, draft: Bool) -> T.Want:
  T.Want{["reader@example.com"], [], [], "Visible", text, "", "", [], draft, False{},
    Jev.Fresh{}, Jev.Off{}}

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(count_line("\u{E0000}\u{E0002}\u{E001F}\u{E0080}"))
    IO.print(count_line("العربية 日本語 café 👩\u{200D}💻"))
    IO.print(count_line("\u{E0001}\u{E0020}\u{E007F}\u{202A}\u{202E}\u{2066}\u{206F}"))
    IO.print(count_line("\u{061C}\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{2060}\u{FEFF}"))
    IO.print(flag_line("gbeng"))
    IO.print(flag_line("gbsct"))
    IO.print(flag_line("gbwls"))
    IO.print(flag_line("usca"))
    IO.print(flag_line("gbukm"))
    IO.print(flag_line("001"))
    IO.print(flag_line("419"))
    IO.print(flag_line("840"))
    IO.print(flag_line("steal"))
    IO.print(flag_line("gbengsecret"))
    IO.print(U32.show(M.refused_tags("\u{E0001}\u{E0020}\u{E007F}")))
    IO.print(U32.show(M.refused_tags("\u{1F3F4}\u{E007F}")))
    IO.print(U32.show(M.refused_tags("\u{1F3F4}" ++ tag_text("gbeng"))))
    IO.print(U32.show(M.refused_tags(flag("gbeng") ++ "\u{E0061}")))
    IO.print(U32.show(M.refused_tags("\u{1F3F4}" ++ tag_text(String.repeat("a", 31n))
      ++ "\u{E007F}")))
    IO.print(Bool.show(String.eq(
      M.strip_tags("a\u{E0061}b\u{E007F}👩\u{200D}💻\u{202E}"), "ab👩\u{200D}💻\u{202E}")))
    IO.print(Bool.show(String.is_empty(T.check_want(want(flag("gbeng"), False{}),
      "sender@example.com"))))
    IO.print(Bool.show(String.eq(T.strip_name_tags(
      "\"\u{1F3F4}\\\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}\" <a@example.com>"),
      "\"\u{1F3F4}\\\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}\" <a@example.com>")))
    IO.print(T.strip_name_tags("\"Al\u{E0061}ice\" <a@example.com>"))
    IO.print(T.check_want(want("body\u{E0061}", False{}), "sender@example.com"))
    IO.print(T.check_want(want("body\u{E0061}", True{}), "sender@example.com"))

#|0/0/0
#|0/0/1
#|3/4/0
#|0/3/7
#|gbeng 0 6/0/0 True
#|gbsct 0 6/0/0 True
#|gbwls 0 6/0/0 True
#|usca 0 5/0/0 True
#|gbukm 0 6/0/0 True
#|001 0 4/0/0 True
#|419 0 4/0/0 True
#|840 4 4/0/0 False
#|steal 6 6/0/0 False
#|gbengsecret 12 12/0/0 False
#|3
#|1
#|5
#|1
#|32
#|True
#|True
#|True
#|"Alice" <a@example.com>
#|hidden Unicode tag characters in body; nothing was sent or saved
#|hidden Unicode tag characters in body; nothing was sent or saved
