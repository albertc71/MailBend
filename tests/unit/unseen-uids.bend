import Base
import ../../src/tools.bend as Tools

def strings(us: List<&2, U32>) -> List<&2, String>:
  match us:
    case Nil{}:
      []
    case u <> t:
      U32.show(u) <> strings(t)

def show(us: List<&2, U32>) -> String:
  "[" ++ String.join(strings(us), ",") ++ "]"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("empty " ++ show(Tools.unseen([], [])))
    IO.print("empty with seen " ++ show(Tools.unseen([], [7, 7, 9])))
    IO.print("already seen " ++ show(Tools.unseen([7, 9, 7], [7, 9])))
    IO.print("repeated initial seen " ++ show(Tools.unseen(
      [9, 3, 7, 1, 3, 8, 9, 1], [7, 7, 9, 7, 9])))
    IO.print("nonadjacent duplicates " ++ show(Tools.unseen(
      [4, 2, 4, 3, 2, 1, 3], [])))
    IO.print("first occurrence order " ++ show(Tools.unseen([90, 1, 70, 4], [])))
    IO.print("decimal prefixes " ++ show(Tools.unseen(
      [1, 10, 100, 1000, 11, 110, 1, 10, 1000, 110, 11], [100])))
    IO.print("u32 boundaries " ++ show(Tools.unseen(
      [4294967295, 0, 1, 4294967295, 0, 4294967294], [])))
    IO.print("seen u32 boundaries " ++ show(Tools.unseen(
      [0, 4294967295, 1, 4294967294, 0, 1], [4294967295, 0, 4294967295])))
    IO.print("duplicate bursts " ++ show(Tools.unseen(
      [401, 408, 408, 403, 411, 401, 403, 404, 404, 410, 409, 408,
       402, 411, 410, 405, 405, 404, 406, 409, 407, 406, 405, 412,
       412, 408, 403, 413, 411, 413, 404, 402, 410, 414, 414, 401,
       409, 405, 406, 407, 412, 413, 414, 408, 403, 411, 404, 410],
      [401, 402, 401])))

#|empty []
#|empty with seen []
#|already seen []
#|repeated initial seen [3,1,8]
#|nonadjacent duplicates [4,2,3,1]
#|first occurrence order [90,1,70,4]
#|decimal prefixes [1,10,1000,11,110]
#|u32 boundaries [4294967295,0,1,4294967294]
#|seen u32 boundaries [1,4294967294]
#|duplicate bursts [408,403,411,404,410,409,405,406,407,412,413,414]
