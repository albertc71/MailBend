# Every ordinary annotation outcome retains the nested-scope limitation,
# and a whole read showing attached-message summaries says Jev did not see them.

import Base
import ../../src/json.bend as J
import ../../src/jev.bend as Jev
import ../../src/tools.bend as T
import ../../src/policy.bend as P

def facts() -> Jev.Facts:
  Jev.Facts{7, [], [], "", 23, Jev.Unknown{}, Jev.Partial{}}

def annotation(c: Jev.Content) -> T.Annotation:
  T.Annotation{J.chain([J.kv("content_encoding", J.str("message")),
    J.kv("content", J.str("retained"))]), False{}, c,
    [Jev.Fetched{facts(), Jev.MessageText{"placeholder", Jev.Partial{}}, 0}]}

def attached(summary: Bool) -> J.Json:
  +base : List<&2, J.Json> = [J.kv("filename", J.str("")), J.kv("content_type", J.str("message/rfc822")),
    J.kv("size", J.num(9))]
  J.obj(Bool.pick(List<&2, J.Json>, summary,
    List.append(&2, J.Json, base, [J.kv("message", J.obj([J.kv("subject", J.str("inner"))]))]),
    base))

def whole(+summary: Bool, c: Jev.Content) -> T.Annotation:
  T.Annotation{J.chain([J.kv("content", J.str(Bool.pick(String, summary, "summarized", "plain"))),
    J.kv("attachments", J.arr([J.obj([J.kv("filename", J.str("a.bin"))]), attached(summary)]))]),
    False{}, c, [Jev.Fetched{facts(), Jev.MessageText{"placeholder", Jev.Partial{}}, 0}]}

def show(o: P.Out) -> String:
  match o:
    case P.Ok{+j}:
      +a = Maybe.default(&2, J.Json, J.get(j, "jev"), J.JNull{})
      J.show(J.arr([Maybe.default(&2, J.Json, J.get(j, "content"), J.JNull{}),
        Maybe.default(&2, J.Json, J.get(a, "status"), J.JNull{}),
        Maybe.default(&2, J.Json, J.get(a, "coverage"), J.JNull{}),
        Maybe.default(&2, J.Json, J.get(a, "reasons"), J.JNull{})]))
    case _:
      "error"

def main() -> IO(Unit):
  do IO<Unit>:
    folder : P.Out <- T.annotate.folders(Fail{"folder failure"}, annotation(Jev.Headers{}))
    IO.print(show(T.nested_coverage(folder, Jev.On{Jev.Headers{}})))
    option : P.Out <- T.annotate.run("option failure", [],
      Jev.options_for(Jev.Annotating{}, []), annotation(Jev.Body{}))
    IO.print(show(T.nested_coverage(option, Jev.On{Jev.Body{}})))
    IO.print(show(T.nested_coverage(T.annotation_answered(Fail{"transport failure"}, "none",
      annotation(Jev.Body{})), Jev.On{Jev.Body{}})))
    IO.print(show(T.nested_coverage(T.annotation_answered(
      Done{T.Progress{[Jev.Skipped{facts()}], []}}, "none", annotation(Jev.Headers{})),
      Jev.On{Jev.Headers{}})))
    IO.print(show(T.nested_coverage(T.annotation_answered(Fail{"transport failure"}, "none",
      whole(True{}, Jev.Headers{})), Jev.On{Jev.Headers{}})))
    IO.print(show(T.nested_coverage(T.annotation_answered(Fail{"transport failure"}, "none",
      whole(True{}, Jev.Body{})), Jev.On{Jev.Body{}})))
    IO.print(show(T.nested_coverage(T.annotation_answered(Fail{"transport failure"}, "none",
      whole(False{}, Jev.Body{})), Jev.On{Jev.Body{}})))
    IO.print(show(T.nested_coverage(P.Ok{J.obj([J.kv("content", J.str("summarized")),
      J.kv("attachments", J.arr([attached(True{})]))])}, Jev.Off{})))

#|["retained","unchecked","headers_only",["folder failure","Only parent header facts were eligible for checking; nested headers and text were not included."]]
#|["retained","unchecked","partial",["option failure","Nested message text was not included in the Jev request."]]
#|["retained","unchecked","partial",["transport failure","Nested message text was not included in the Jev request."]]
#|["retained","unchecked","headers_only",["its header fields alone exceed what one TypeSafe request may hold","Only parent header facts were eligible for checking; nested headers and text were not included."]]
#|["summarized","unchecked","headers_only",["transport failure","Attached-message summaries were not included in the Jev request."]]
#|["summarized","unchecked","partial",["transport failure","Attached-message summaries were not included in the Jev request."]]
#|["plain","unchecked",null,["transport failure"]]
#|["summarized",null,null,null]
