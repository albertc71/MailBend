import Base
import ../../src/json.bend as J
import ../../src/mime.bend as M
import ../../src/message-metadata.bend as Meta

def classification(list_id: String, auto: String, precedence: String) -> IO(Unit):
  IO.print(J.show(Meta.bulk_json(Meta.bulk(list_id, auto, precedence))))

def unsubscribe(headers: String) -> IO(Unit):
  IO.print(J.show(Meta.unsubscribe(M.headers(headers))))

def main() -> IO(Unit):
  do IO<Unit>:
    classification("", "", "")
    classification("list", "auto-generated", "bulk")
    classification("", "auto-replied", "bulk")
    classification("", "NO; x=1", "")
    classification("", "(reason) no (end); x=1", "")
    classification("", "auto-generated (machine); x=1", "")
    classification("", "x-custom", "")
    classification("", "bad value", "")
    classification("", "(unclosed", "")
    classification("", "\\auto", "")
    classification("", "", "BuLk")
    classification("", "", "list")
    classification("", "", "junk")
    classification("", "", "not-bulk")
    classification("", "no", "bulk")
    unsubscribe("List-Unsubscribe: \r\n")
    unsubscribe("List-Unsubscribe: <mailto:leave@example.test>, <https://example.test/u>\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n")
    unsubscribe("List-Unsubscribe: <HTTPS://example.test/a,b(c)> (ok), <mailto:leave@example.test>\r\n")
    unsubscribe("List-Unsubscribe: (nested (comment)) <https://example.test/u>, <https://example.test/v>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>\r\nList-Unsubscribe: <https://example.test/v>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n")
    unsubscribe("List-Unsubscribe: garbage <https://example.test/u>\r\n")
    unsubscribe("List-Unsubscribe: <mailto:leave@example.test>, junk, <https://example.test/u>\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u\r\n")
    unsubscribe("List-Unsubscribe: <javascript:bad>, <http://example.test/u>, <https://example.test/u>\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/\r\n u>\r\n")
    unsubscribe("List-Unsubscribe: <mailto:leave@example.test>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n")
    unsubscribe("List-Unsubscribe: <https:///>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://?x>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://#x>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test\\bad>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <http://example.test/v>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, junk, <https://example.test/v>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>,\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <https:///>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://>, <https://example.test/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <http:>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://:443/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://@/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <mailto:>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <1bad:item>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <bad!scheme:item>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://[::1]/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://user@host.test:443/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://bank.example@evil.test/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u@path>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    unsubscribe("List-Unsubscribe: <https://example.test/u>, <https://>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
    IO.print(J.show(J.obj(Meta.fields(M.headers(""), ["\\aNsWeReD", "$FORWARDED"]))))

#|null
#|"list"
#|"auto"
#|null
#|null
#|"auto"
#|"auto"
#|null
#|null
#|null
#|"precedence-bulk"
#|"precedence-bulk"
#|"precedence-bulk"
#|null
#|"precedence-bulk"
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":"mailto:leave@example.test","https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":true}
#|{"mailto":"mailto:leave@example.test","https":"HTTPS://example.test/a,b(c)","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":"mailto:leave@example.test","https":null,"one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":"mailto:leave@example.test","https":null,"one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"mailto":null,"https":"https://[::1]/u","one_click":true}
#|{"mailto":null,"https":"https://user@host.test:443/u","one_click":false}
#|{"mailto":null,"https":"https://bank.example@evil.test/u","one_click":false}
#|{"mailto":null,"https":"https://example.test/u@path","one_click":true}
#|{"mailto":null,"https":null,"one_click":false}
#|{"mailto":null,"https":"https://example.test/u","one_click":false}
#|{"list_id":null,"auto_submitted":null,"bulk":null,"unsubscribe":{"mailto":null,"https":null,"one_click":false},"answered":true,"forwarded":true}
