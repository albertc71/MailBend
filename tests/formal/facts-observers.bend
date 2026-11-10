import Base
import ../../src/facts.bend as Facts
import ../../src/json.bend as J

def spans(result: Facts.Extraction) -> List<&2, Facts.Span>:
  Facts.Extraction{items, limited} = result
  items

def span_within(cap: Nat, span: Facts.Span) -> Type:
  match span:
    case Facts.Span{+start, +end, line}:
      {end == Nat.add(start, 36n) : Nat} &
      ({Nat.is_lt(start, end) == True{} : Bool} &
       {Nat.is_le(end, cap) == True{} : Bool})
    case Facts.ZoomSpan{+start, +end, line}:
      {Nat.is_lt(start, end) == True{} : Bool} &
      ({Nat.is_le(end, Nat.add(start, 512n)) == True{} : Bool} &
       {Nat.is_le(end, cap) == True{} : Bool})

def spans_within(+cap: Nat, items: List<&2, Facts.Span>) -> Type:
  match items:
    case Nil{}:
      Unit
    case head <> tail:
      span_within(cap, head) & spans_within(cap, tail)

def emitted(+source: String, spans: List<&2, Facts.Span>, chain: J.Json) -> Type:
  match spans chain:
    case Nil{} J.JEnd{}:
      Unit
    case Facts.Span{+start, +end, line} <> rest J.JCons{+fact, tail}:
      {J.get(fact, "value") == Some{J.str(String.take(String.drop(source, start),
        Nat.sub(end, start)))} : Maybe<&2, J.Json>} &
      ({J.get(fact, "start") == Some{J.JNum{Nat.show(start)}} : Maybe<&2, J.Json>} &
      ({J.get(fact, "end") == Some{J.JNum{Nat.show(end)}} : Maybe<&2, J.Json>} &
      ({J.get(fact, "source") == Some{J.str("text")} : Maybe<&2, J.Json>} &
      ({J.get(fact, "untrusted") == Some{J.bool(True{})} : Maybe<&2, J.Json>} &
        emitted(source, rest, tail)))))
    case Facts.ZoomSpan{+start, +end, line} <> rest J.JCons{+fact, tail}:
      {J.get(fact, "value") == Some{J.str(String.take(String.drop(source, start),
        Nat.sub(end, start)))} : Maybe<&2, J.Json>} &
      ({J.get(fact, "start") == Some{J.JNum{Nat.show(start)}} : Maybe<&2, J.Json>} &
      ({J.get(fact, "end") == Some{J.JNum{Nat.show(end)}} : Maybe<&2, J.Json>} &
      ({J.get(fact, "source") == Some{J.str("text")} : Maybe<&2, J.Json>} &
      ({J.get(fact, "untrusted") == Some{J.bool(True{})} : Maybe<&2, J.Json>} &
        emitted(source, rest, tail)))))
    case _ _:
      Empty

def rendered(source: String, spans: List<&2, Facts.Span>, value: Maybe<&2, J.Json>) -> Type:
  match value:
    case Some{J.JArr{chain}}:
      emitted(source, spans, chain)
    case _:
      Empty

