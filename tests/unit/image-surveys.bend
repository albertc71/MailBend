# Surveys remain addressable through the final message of a classify call,
# and a refused request's surveys report its stills refused.
import Base
import ../../src/json.bend as J
import ../../src/tools.bend as T
import ../../src/image.bend as Image

def surveys(n: Nat, +uid: U32) -> List<&2, T.Survey>:
  match n:
    case 0n:
      []
    case 1n+rest:
      T.Survey{uid, [Image.NoteSkipped{[2], "anim.gif", Image.Format{}}]} <>
        surveys(rest, (uid + 1 : U32))

def found(m: Maybe<&2, List<&2, Image.Note>>) -> String:
  match m:
    case None{}:
      "missing"
    case Some{Image.NoteSkipped{section, name, Image.Format{}} <> Nil{}}:
      "format"
    case _:
      "unexpected"

def used() -> List<&2, T.Survey>:
  [T.Survey{3, [Image.NoteUsed{[2], "scan.png", Image.Png{}, 308, Image.Pixels{280, 280}, 0},
    Image.NoteSkipped{[3], "anim.gif", Image.Format{}}]}]

def shown(+ss: List<&2, T.Survey>) -> String:
  match ss:
    case T.Survey{u, ns} <> Nil{}:
      J.show(J.arr(T.note_jsons(ns))) ++ " " ++ Bool.show(T.any_survey(ss, False{}))
    case _:
      "unexpected"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("empty " ++ found(T.lookup_survey(1, [])))
    IO.print("first " ++ found(T.lookup_survey(1, surveys(3n, 1))))
    IO.print("last-three " ++ found(T.lookup_survey(3, surveys(3n, 1))))
    IO.print("last-fifty " ++ found(T.lookup_survey(50, surveys(50n, 1))))
    IO.print("absent " ++ found(T.lookup_survey(51, surveys(50n, 1))))
    IO.print("used " ++ shown(used()))
    IO.print("refused " ++ shown(T.refused_surveys(used())))

#|empty missing
#|first format
#|last-three format
#|last-fifty format
#|absent missing
#|used [{"section":"2","name":"scan.png","fate":"used","format":"png","bytes":308,"width":280,"height":280,"metadata_removed_bytes":0},{"section":"3","name":"anim.gif","fate":"skipped","reason":"format"}] True
#|refused [{"section":"2","name":"scan.png","fate":"skipped","reason":"refused"},{"section":"3","name":"anim.gif","fate":"skipped","reason":"format"}] False
