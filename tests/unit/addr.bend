# Header address lists: quotes, comments, escapes and groups.
import Base
import ../../src/tools.bend as T

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("[" ++ String.join(T.addr_list("undisclosed-recipients:;"), "|") ++ "]")
    IO.print(String.join(T.addr_list("Team: A <a@x.com>, b@y.com; c@z.com"), "|"))
    IO.print(String.join(T.addr_list("\"Doe, J\" <j@x.com>, k@y.com (K, Jr)"), "|"))
    IO.print(String.join(T.addr_list("<@route.example:u@x.com>, \"a: b\" <v@y.com>"), "|"))

#|[]
#|A <a@x.com>|b@y.com|c@z.com
#|"Doe, J" <j@x.com>|k@y.com (K, Jr)
#|<@route.example:u@x.com>|"a: b" <v@y.com>
