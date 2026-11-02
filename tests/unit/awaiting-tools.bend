# Completeness and result fields for bounded synthetic reads.

import Base
import ../../src/awaiting.bend as A
import ../../src/imap.bend as I
import ../../src/json.bend as J
import ../../src/ops.bend as Ops
import ../../src/tools.bend as Tools
import ../../src/thread.bend as T

def msg(uid: U32) -> I.Msg:
  I.Msg{uid, [], "01-Oct-2026 09:00:00 +0000", 0,
    "Message-ID: <sent@example.test>\r\n", "", I.VNil{}}

def complete(r: Tools.AwaitRead) -> String:
  Tools.AwaitRead{fs, yes, reason} = r
  Bool.show(yes)

def main() -> IO(Unit):
  +one : List<&2, Tools.Found> = [Tools.Found{"Sent", Some{7}, [], [msg(1)]}]
  do IO<Unit>:
    IO.print(complete(Tools.await_fetched(Done{one}, [Ops.FolderUids{"Sent", [1]}], 1n)))
    IO.print(complete(Tools.await_fetched(Done{one}, [Ops.FolderUids{"Sent", [1, 2]}], 2n)))
    IO.print(complete(Tools.await_fetched(Done{one}, [Ops.FolderUids{"Sent", [1]}], 2n)))
    IO.print(complete(Tools.await_fetched(Fail{"missing"}, [Ops.FolderUids{"Sent", [1]}], 1n)))
    IO.print(complete(Tools.await_fetched(Done{[]}, [Ops.FolderUids{"Sent", [1]}], 1n)))
    IO.print(String.join(Tools.thread_folders.put(["INBOX"], None{}), ","))
    IO.print(String.join(Tools.thread_folders.put(["INBOX"], Some{"Archive"}), ","))
    bad : T.Node = T.node("Sent", Some{7}, I.Msg{1, [], "31-Feb-2026 09:00:00 +0000", 0,
      "Message-ID: <sent@example.test>\r\n", "", I.VNil{}})
    IO.print(J.show(Maybe.default(&2, J.Json,
      J.get(Tools.await_item(bad, A.Unknown{}, 1791000000), "age_days"), J.JNull{})))

#|True
#|False
#|False
#|False
#|False
#|INBOX
#|INBOX,Archive
#|null
