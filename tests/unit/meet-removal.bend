import Base
import ../../src/json.bend as J
import ../../src/tools.bend as T

def check(text: String) -> IO(Unit):
  IO.print(T.call_problem("mail_get", Maybe.default(&2, J.Json, J.parse(text), J.JNull{})))

def main() -> IO(Unit):
  do IO<Unit>:
    check("{\"uid\":1}")
    check("{\"uid\":1,\"facts\":true}")
    check("{\"uid\":1,\"facts\":false}")
    check("{\"uid\":1,\"facts\":null}")
    check("{\"uid\":1,\"facts\":\"yes\"}")
    check("{\"uid\":1,\"section\":\"1\",\"uidvalidity\":9,\"nested_message\":true}")
    check("{\"uid\":1,\"nested_message\":false,\"projection\":\"text\"}")

#|
#|unknown argument "facts" for mail_get
#|unknown argument "facts" for mail_get
#|unknown argument "facts" for mail_get
#|unknown argument "facts" for mail_get
#|
#|
