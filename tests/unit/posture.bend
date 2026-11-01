# Offline posture derives capability facts from the existing refusal gate.

import Base
import ../../src/tools.bend as T
import ../../src/diagnostics.bend as D
import ../../src/jev.bend as Jev
import ../../src/json.bend as J

def show_endpoint(r: Result<&2, &2, String, T.PostureEndpoint>) -> String:
  match r:
    case Done{e}:
      J.show(T.posture_endpoint(e))
    case Fail{m}:
      "rejected"

def show_optional(r: Result<&2, &2, String, Maybe<&2, T.PostureEndpoint>>) -> String:
  match r:
    case Done{e}:
      J.show(T.posture_optional(e))
    case Fail{m}:
      "rejected"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(T.posture_send_allowed(False{}, False{}, False{})))
    IO.print(Bool.show(T.posture_send_allowed(True{}, False{}, True{})))
    IO.print(Bool.show(T.posture_send_allowed(False{}, True{}, True{})))
    IO.print(Bool.show(T.posture_state_change(True{})))
    IO.print(Bool.show(T.posture_body(Jev.Off{})))
    IO.print(Bool.show(T.posture_body(Jev.On{Jev.Headers{}})))
    IO.print(Bool.show(T.posture_body(Jev.On{Jev.Body{}})))
    IO.print(Bool.show(T.posture_images(Jev.ImagesOn{})))
    IO.print(show_endpoint(D.posture_endpoint("smtp", "smtp.test", "587")))
    IO.print(show_endpoint(D.posture_endpoint("smtp", "person@example.test", "587")))
    IO.print(show_endpoint(D.posture_endpoint("smtp", "smtp.test", "65536")))
    IO.print(show_optional(D.posture_doh("https://dns.test:8443/private?secret=x")))
    IO.print(show_optional(D.posture_doh("http://dns.test/private")))
    IO.print(show_optional(D.posture_proxy("http://user:secret@proxy.test:3128/")))
    IO.print(show_optional(D.posture_proxy("https://proxy.test")))
    IO.print(Bool.show(D.posture_proxied(Some{T.PostureEndpoint{"proxy.test", 1080}},
      "api.typesafe.ai", ".typesafe.ai")))
    IO.print(Bool.show(D.posture_proxied(Some{T.PostureEndpoint{"proxy.test", 1080}},
      "api.typesafe.ai.", "typesafe.ai.")))
    IO.print(Bool.show(D.posture_proxied(Some{T.PostureEndpoint{"proxy.test", 1080}},
      "nottypesafe.ai", "typesafe.ai")))
    IO.print(T.posture_trust_token(T.posture_trust_source(True{}, True{}, True{})))
    IO.print(T.posture_trust_token(T.posture_trust_source(False{}, True{}, False{})))
    IO.print(T.posture_trust_token(T.posture_trust_source(False{}, False{}, False{})))
    IO.print(Bool.show(D.posture_trust_dirs(String.split(":::" , ':'))))
    IO.print(Bool.show(D.posture_trust_dirs(String.split(": :" , ':'))))

#|True
#|False
#|False
#|False
#|False
#|False
#|True
#|True
#|{"host":"smtp.test","port":587}
#|rejected
#|rejected
#|{"host":"dns.test","port":8443}
#|rejected
#|{"host":"proxy.test","port":3128}
#|rejected
#|False
#|False
#|True

#|mailbend_ca_file
#|ssl_cert_env
#|system
#|False
#|True
