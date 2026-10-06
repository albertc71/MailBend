# The generated MCP tool list: each tool's name, true hints, required
# arguments and typed parameters with their enums, then the length and a
# rolling hash of the whole JSON text, so any changed byte shows.

import Base
import ../../src/json.bend as J
import ../../src/schema.bend as Schema

def text_or(m: Maybe<&2, String>) -> String:
  Maybe.default(&2, String, m, "?")

def items_of(m: Maybe<&2, J.Json>) -> List<&2, J.Json>:
  Maybe.default(&2, List<&2, J.Json>, J.as_list(m), [])

def texts(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case h <> t:
      text_or(J.as_str(Some{h})) <> texts(t)

# The items joined by sep, or "-" when there are none.
def listed(xs: List<&2, String>, sep: String) -> String:
  match xs:
    case Nil{}:
      "-"
    case _:
      String.join(xs, sep)

def hint_names() -> List<&2, String>:
  ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]

def hints.put(set: Maybe<&2, Bool>, name: String, rest: List<&2, String>)
  -> List<&2, String>:
  match set:
    case Some{True{}}:
      name <> rest
    case _:
      rest

# The names of the annotations that are true.
def hints(+a: J.Json, names: List<&2, String>) -> List<&2, String>:
  match names:
    case Nil{}:
      []
    case +h <> t:
      hints.put(J.as_bool(J.get(a, h)), h, hints(a, t))

def enum_suffix(m: Maybe<&2, List<&2, J.Json>>) -> String:
  match m:
    case Some{xs}:
      "[" ++ String.join(texts(xs), "|") ++ "]"
    case None{}:
      ""

# One property as name:type, with its enum values when it has any.
def param(p: J.Json) -> String:
  match p:
    case J.JKv{k, +v}:
      kind = text_or(J.as_str(J.get(v, "type")))
      k ++ ":" ++ kind ++ enum_suffix(J.as_list(J.get(v, "enum")))
    case _:
      "?"

def params(items: J.Json) -> List<&2, String>:
  match items:
    case J.JCons{h, t}:
      param(h) <> params(t)
    case _:
      []

def properties(m: Maybe<&2, J.Json>) -> J.Json:
  match m:
    case Some{J.JObj{items}}:
      items
    case _:
      J.JEnd{}

def tool_line(+t: J.Json) -> String:
  +input = Maybe.default(&2, J.Json, J.get(t, "inputSchema"), J.JNull{})
  annotations = Maybe.default(&2, J.Json, J.get(t, "annotations"), J.JNull{})
  String.join([
    text_or(J.as_str(J.get(t, "name"))),
    listed(hints(annotations, hint_names()), ","),
    "required " ++ listed(texts(items_of(J.get(input, "required"))), ","),
    listed(params(properties(J.get(input, "properties"))), " ")], " | ")

def tool_lines(ts: List<&2, J.Json>) -> List<&2, String>:
  match ts:
    case Nil{}:
      []
    case h <> t:
      tool_line(h) <> tool_lines(t)

# h * 31 + c over every character, wrapping at 2^32.
def text_hash(s: String, h: U32) -> U32:
  match s:
    case SNil{}:
      h
    case SCon{c, t}:
      text_hash(t, ((h * 31 : U32) + Char.to_u32(c) : U32))

def main() -> IO(Unit):
  +text = Schema.tool_defs()
  +tools = items_of(J.parse(text))
  do IO<Unit>:
    IO.print(Nat.show(List.length(&2, J.Json, tools)) ++ " tools")
    IO.print(String.join(tool_lines(tools), "\n"))
    IO.print(Nat.show(String.length(text)) ++ " characters")
    IO.print("hash " ++ U32.show(text_hash(text, 0)))

#|19 tools
#|mail_probe | readOnlyHint,idempotentHint | required - | -
#|mail_list_folders | readOnlyHint,idempotentHint | required - | -
#|mail_search | readOnlyHint,idempotentHint | required - | folder:string from:string to:string cc:string subject:string body:string text:string since:string before:string unseen:boolean seen:boolean flagged:boolean limit:integer
#|mail_get | readOnlyHint,idempotentHint | required uid | folder:string uid:integer max_bytes:integer
#|mail_get_new | readOnlyHint,idempotentHint | required - | folder:string since_uid:integer uidvalidity:integer limit:integer
#|mail_mark_read | idempotentHint | required uids,uidvalidity | folder:string uids:array uidvalidity:integer
#|mail_mark_unread | idempotentHint | required uids,uidvalidity | folder:string uids:array uidvalidity:integer
#|mail_flag | idempotentHint | required uids,uidvalidity | folder:string uids:array uidvalidity:integer colour:string[red|orange|yellow|green|blue|purple|grey]
#|mail_unflag | idempotentHint | required uids,uidvalidity | folder:string uids:array uidvalidity:integer
#|mail_move | - | required uids,destination,uidvalidity | folder:string uids:array destination:string uidvalidity:integer
#|mail_label | - | required uids,label,uidvalidity | folder:string uids:array label:string uidvalidity:integer
#|mail_trash | - | required uids,uidvalidity | folder:string uids:array uidvalidity:integer
#|mail_delete | destructiveHint | required uids,uidvalidity,confirm | folder:string uids:array uidvalidity:integer confirm:string[permanently-delete]
#|mail_create_folder | - | required name | name:string
#|mail_rename_folder | - | required from,to | from:string to:string
#|mail_save_draft | - | required - | to:array cc:array bcc:array subject:string body:string in_reply_to:string references:string attachments:array
#|mail_send | openWorldHint | required - | to:array cc:array bcc:array subject:string body:string in_reply_to:string references:string attachments:array
#|mail_reply | openWorldHint | required uid,uidvalidity,body | folder:string uid:integer uidvalidity:integer body:string reply_all:boolean bcc:array attachments:array as_draft:boolean
#|mail_forward | openWorldHint | required uid,uidvalidity,to | folder:string uid:integer uidvalidity:integer to:array cc:array bcc:array body:string attachments:array as_draft:boolean
#|22189 characters
#|hash 3084779543
