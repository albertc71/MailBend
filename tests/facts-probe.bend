import Base
import ../src/facts.bend as Facts
import ../src/json.bend as J

def emit(inputs: List<String>, +ending: Facts.SourceEnd) -> IO(Unit):
  match inputs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case source <> rest:
      do IO<Unit>:
        IO.print(J.show(J.obj(Facts.fields(source, ending))))
        emit(rest, ending)

def run(args: List<String>) -> IO(Unit):
  match args:
    case program <> mode <> inputs:
      emit(inputs, Bool.pick(Facts.SourceEnd, String.eq(mode, "complete"),
        Facts.Complete{}, Facts.Prefix{}))
    case _:
      IO.die(Unit, 2, "usage: facts-probe complete|prefix text...")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
