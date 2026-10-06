# Header address lists: quotes, comments, escapes and groups; and the
# address checks and encodings MIME composition applies to them.

import Base
import ../../src/tools.bend as T
import ../../src/mime.bend as M

# Line breaks made visible, so folded headers fit on one expected line.
def visible(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\r', t}:
      "\\r" ++ visible(t)
    case SCon{'\n', t}:
      "\\n" ++ visible(t)
    case SCon{c, t}:
      SCon{c, visible(t)}

def specs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      "[" ++ M.addr_spec(x) ++ "]" ++ specs(t)

def oks(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      Bool.show(M.addr_ok(x)) ++ " " ++ oks(t)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("[" ++ String.join(T.addr_list("undisclosed-recipients:;"), "|") ++ "]")
    IO.print(String.join(T.addr_list("Team: A <a@x.com>, b@y.com; c@z.com"), "|"))
    IO.print(String.join(T.addr_list("\"Doe, J\" <j@x.com>, k@y.com (K, Jr)"), "|"))
    IO.print(String.join(T.addr_list("<@route.example:u@x.com>, \"a: b\" <v@y.com>"), "|"))
    IO.print("[" ++ String.join(T.addr_list(""), "|") ++ "] [" ++ String.join(T.addr_list(" , ,"), "|") ++ "] [" ++ String.join(T.addr_list("a@x (c, d), \"q\\\" ,\" <b@y>"), "|") ++ "]")
    IO.print(specs(["Name <a@b>", " a@b (c) ", "\"x\" <a@b> trailing", "<a@b", "a (b (c) d) e@f", "\"(x)\" y@z", "a) b@c", "", "x <a> <b@c>"]))
    IO.print(oks(["", "@a", "a@", "a b@c", "<a@b>", "a@b (c)", "Name <a@b>\u{7F}", "A <a@b>, c@d", "a@b\t", "a@b@c", "a@b.c", "ü@b.c"]))
    IO.print(Bool.show(M.all_addrs_ok([])) ++ " " ++ Bool.show(M.all_addrs_ok(["a@b", "c@d"])) ++ " " ++ Bool.show(M.all_addrs_ok(["a@b", "x"])))
    IO.print(Bool.show(M.no_ctl("abc")) ++ " " ++ Bool.show(M.no_ctl("")) ++ " " ++ Bool.show(M.no_ctl("a\tb")) ++ " " ++ Bool.show(M.no_ctl("a\u{7F}")) ++ " " ++ Bool.show(M.no_ctl("é")) ++ " " ++ Bool.show(M.no_ctl("a\u{0}")))
    IO.print(M.encode_addr("a@b") ++ " | " ++ M.encode_addr("<a@b>") ++ " | " ++ M.encode_addr("José <j@x.com>") ++ " | " ++ M.encode_addr("\"Q \\\"x\\\"\" <q@x>") ++ " | " ++ M.encode_addr("Back\\slash <b@x>") ++ " | " ++ M.encode_addr("Name <a@b> (c)"))
    IO.print(visible(M.encode_addr(String.repeat("n", 201n) ++ " <a@b>")) ++ " | " ++ Nat.show(String.length(M.encode_addr(String.repeat("n", 200n) ++ " <a@b>"))))

#|[]
#|A <a@x.com>|b@y.com|c@z.com
#|"Doe, J" <j@x.com>|k@y.com (K, Jr)
#|<@route.example:u@x.com>|"a: b" <v@y.com>
#|[] [] [a@x (c, d)|"q\" ," <b@y>]
#|[a@b][a@b][a@b][a@b][a  e@f]["(x)" y@z][a) b@c][][b@c]
#|False False False False True True False True False False True False 
#|True True False
#|True True False False True False
#|a@b | a@b | =?UTF-8?B?Sm9zw6k=?= <j@x.com> | "Q \"x\"" <q@x> | "Back\\slash" <b@x> | "Name" <a@b>
#|=?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5ubm5u?=\r\n =?UTF-8?B?bm5ubm5ubm5ubm5ubm5ubm5ubm5u?= <a@b> | 208
