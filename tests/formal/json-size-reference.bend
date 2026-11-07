# Original recursive serializer, retained only as a compatibility specification.

import Base
import ../../src/json.bend as J

def quote(s: String) -> String:
  "\"" ++ J.esc(s) ++ "\""

def sep(t: J.Json) -> String:
  match t:
    case J.JEnd{}:
      ""
    case _:
      ","

def show(j: J.Json) -> String:
  match j:
    case J.JNull{}:
      "null"
    case J.JBool{b}:
      Bool.pick(String, b, "true", "false")
    case J.JNum{raw}:
      raw
    case J.JStr{s}:
      quote(s)
    case J.JArr{items}:
      "[" ++ show(items) ++ "]"
    case J.JObj{items}:
      "{" ++ show(items) ++ "}"
    case J.JCons{h, +t}:
      show(h) ++ sep(t) ++ show(t)
    case J.JEnd{}:
      ""
    case J.JKv{k, v}:
      quote(k) ++ ":" ++ show(v)
