# Surveys remain addressable through the final message of a classify call.
import Base
import ../../src/tools.bend as T
import ../../src/image.bend as Image

def surveys(n: Nat, +uid: U32) -> List<&2, T.Survey>:
  match n:
    case 0n:
      []
    case 1n+rest:
      T.Survey{uid, [Image.Skipped{[2], "anim.gif", Image.Format{}}]} <>
        surveys(rest, (uid + 1 : U32))

def found(m: Maybe<&2, List<&2, Image.Fate>>) -> String:
  match m:
    case None{}:
      "missing"
    case Some{Image.Skipped{section, name, Image.Format{}} <> Nil{}}:
      "format"
    case _:
      "unexpected"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("empty " ++ found(T.lookup_survey(1, [])))
    IO.print("first " ++ found(T.lookup_survey(1, surveys(3n, 1))))
    IO.print("last-three " ++ found(T.lookup_survey(3, surveys(3n, 1))))
    IO.print("last-fifty " ++ found(T.lookup_survey(50, surveys(50n, 1))))
    IO.print("absent " ++ found(T.lookup_survey(51, surveys(50n, 1))))

#|empty missing
#|first format
#|last-three format
#|last-fifty format
#|absent missing
