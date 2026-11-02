# Synthetic quota replies, strict parsing and exact numeric boundaries.

import Base
import ../../src/imap.bend as I
import ../../src/ops.bend as Ops

def show(s: I.Storage) -> String:
  match s:
    case I.StorageUnknown{}:
      "unknown"
    case I.StorageKnown{+u, +l, +p}:
      U32.show(u) ++ "/" ++ U32.show(l) ++ "/" ++ U32.show(p) ++ " " ++
        I.storage_level(I.StorageKnown{u, l, p})

def atom(n: Nat, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      atom(p, SCon{'a', acc})

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("legacy empty root: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("quoted mailbox: " ++ show(I.storage(I.frame("* QUOTAROOT \"inbox\" \"shared root\"\r\n* QUOTA \"shared root\" (MESSAGE 1 2 storage 901 1000)\r\na1 OK done\r\n"))))
    IO.print("reordered: " ++ show(I.storage(I.frame("* QUOTA root (STORAGE 90 100)\r\n* QUOTAROOT inbox root\r\na1 OK done\r\n"))))
    IO.print("full: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 100 100)\r\na1 OK done\r\n"))))
    IO.print("overfull: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 150 100)\r\na1 OK done\r\n"))))
    IO.print("zero used: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 0 100)\r\na1 OK done\r\n"))))
    IO.print("zero limit: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 0 0)\r\na1 OK done\r\n"))))
    IO.print("max both: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 4294967295 4294967295)\r\na1 OK done\r\n"))))
    IO.print("max remainder: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 4294967295 4294967294)\r\na1 OK done\r\n"))))
    IO.print("large percent: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 42949672 1)\r\na1 OK done\r\n"))))
    IO.print("percent overflow: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 42949673 1)\r\na1 OK done\r\n"))))
    IO.print("usage overflow: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 4294967296 100)\r\na1 OK done\r\n"))))
    IO.print("limit overflow: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 4294967296)\r\na1 OK done\r\n"))))
    IO.print("negative: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE -1 100)\r\na1 OK done\r\n"))))
    IO.print("fraction: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 1.5 100)\r\na1 OK done\r\n"))))
    IO.print("quoted number: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE \"95\" 100)\r\na1 OK done\r\n"))))
    IO.print("literal roots: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX {4}\r\nroot\r\n* QUOTA {4}\r\nroot (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("escaped root: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"a\\\"b\"\r\n* QUOTA \"a\\\"b\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("missing: " ++ show(I.storage(I.frame("a1 OK done\r\n"))))
    IO.print("missing quota: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\na1 OK done\r\n"))))
    IO.print("missing root: " ++ show(I.storage(I.frame("* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("multi root: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\" other\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("wrong mailbox: " ++ show(I.storage(I.frame("* QUOTAROOT Other \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("root mismatch: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA other (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("case sensitive root: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX Root\r\n* QUOTA root (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("duplicate root: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\n* QUOTAROOT INBOX \"\"\r\na1 OK done\r\n"))))
    IO.print("duplicate quota: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("duplicate storage: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100 STORAGE 1 2)\r\na1 OK done\r\n"))))
    IO.print("missing storage: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (MESSAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("missing close: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100\r\na1 OK done\r\n"))))
    IO.print("extra close: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100))\r\na1 OK done\r\n"))))
    IO.print("nested list: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" ((STORAGE 95 100))\r\na1 OK done\r\n"))))
    IO.print("unclosed quote: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("invalid escape: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"a\\qb\"\r\n* QUOTA \"a\\qb\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("missing resource value: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95)\r\na1 OK done\r\n"))))
    IO.print("trailing resource: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100 MESSAGE)\r\na1 OK done\r\n"))))
    IO.print("garbage: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100) garbage\r\na1 OK done\r\n"))))
    IO.print("quoted resource: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (\"STORAGE\" 95 100)\r\na1 OK done\r\n"))))
    IO.print("nil root: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX NIL\r\n* QUOTA NIL (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("adjacent string: " ++ show(I.storage(I.frame("* QUOTAROOT \"INBOX\"\"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("adjacent list: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\"(STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("overbound: " ++ show(I.storage([I.RLine{"* QUOTA " ++ String.repeat("a", 4097n), []}, I.RLine{"a1 OK done", []}])))
    IO.print("unsolicited late: " ++ show(I.storage(I.frame("a1 OK done\r\n* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("failed command: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 NO refused\r\n"))))
    IO.print("missing completion: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\n"))))
    IO.print("wrong completion: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na2 OK done\r\n"))))
    IO.print("cap QUOTA: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 QUOTA\r\na1 OK done\r\n"))))
    IO.print("cap QUOTA=RES-STORAGE: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 QUOTA=RES-STORAGE\r\na1 OK done\r\n"))))
    IO.print("cap QUOTA=RES-MESSAGE: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 QUOTA=RES-MESSAGE\r\na1 OK done\r\n"))))
    IO.print("cap QUOTASET: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 QUOTASET\r\na1 OK done\r\n"))))
    IO.print("cap XQUOTA: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 XQUOTA\r\na1 OK done\r\n"))))
    IO.print("cap QUOTA=RES-STORAGE-X: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 QUOTA=RES-STORAGE-X\r\na1 OK done\r\n"))))
    IO.print("cap : " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY IMAP4rev1 \r\na1 OK done\r\n"))))
    IO.print("failed caps: " ++ Bool.show(I.quota_advertised(I.frame("* CAPABILITY QUOTA\r\na1 NO fail\r\n"))))
    IO.print("late caps: " ++ Bool.show(I.quota_advertised(I.frame("a1 OK done\r\n* CAPABILITY QUOTA\r\na2 OK done\r\n"))))
    IO.print("actual code: " ++ Bool.show(I.overquota(I.frame("a2 NO [OVERQUOTA] private\r\n"))))
    IO.print("prose: " ++ Bool.show(I.overquota(I.frame("a2 NO quota says [OVERQUOTA]\r\n"))))
    IO.print("malformed code: " ++ Bool.show(I.overquota(I.frame("a2 NO [OVERQUOTA private\r\n"))))
    IO.print("success code: " ++ Bool.show(I.overquota(I.frame("a2 OK [OVERQUOTA] private\r\n"))))
    IO.print("later refusal: " ++ Bool.show(I.overquota(I.frame("a1 NO first\r\na2 NO [OVERQUOTA] second\r\n"))))
    IO.print("large atom: " ++ show(I.storage([I.RLine{"* " ++ atom(1048576n, ""), []}, I.RLine{"a1 OK done", []}])))
    IO.print("too many lines: " ++ show(I.storage(I.frame(String.repeat("* OK note\r\n", 65n) ++ "* QUOTAROOT INBOX \"\"\r\n* QUOTA \"\" (STORAGE 95 100)\r\na1 OK done\r\n"))))
    IO.print("missing literal: " ++ Bool.show(Maybe.is_none(&2, List<&2, I.Value>, I.quota_tokens(SCon{I.lit_mark(), SNil{}}, []))))
    IO.print("unused literal: " ++ Bool.show(Maybe.is_none(&2, List<&2, I.Value>, I.quota_tokens("root", ["unused"]))))
    IO.print("NUL roots: " ++ show(I.storage(I.frame("* QUOTAROOT INBOX {1}\r\n" ++ SCon{Char.from_u32(0), "\r\n* QUOTA {1}\r\n"} ++ SCon{Char.from_u32(0), " (STORAGE 95 100)\r\na1 OK done\r\n"}))))
    IO.print(String.trim(I.script(Ops.plan_quota())))

#|legacy empty root: 95/100/95 above_90_percent
#|quoted mailbox: 901/1000/90 above_90_percent
#|reordered: 90/100/90 ok
#|full: 100/100/100 full
#|overfull: 150/100/150 full
#|zero used: 0/100/0 ok
#|zero limit: unknown
#|max both: 4294967295/4294967295/100 full
#|max remainder: 4294967295/4294967294/100 full
#|large percent: 42949672/1/4294967200 full
#|percent overflow: unknown
#|usage overflow: unknown
#|limit overflow: unknown
#|negative: unknown
#|fraction: unknown
#|quoted number: unknown
#|literal roots: 95/100/95 above_90_percent
#|escaped root: 95/100/95 above_90_percent
#|missing: unknown
#|missing quota: unknown
#|missing root: unknown
#|multi root: unknown
#|wrong mailbox: unknown
#|root mismatch: unknown
#|case sensitive root: unknown
#|duplicate root: unknown
#|duplicate quota: unknown
#|duplicate storage: unknown
#|missing storage: unknown
#|missing close: unknown
#|extra close: unknown
#|nested list: unknown
#|unclosed quote: unknown
#|invalid escape: unknown
#|missing resource value: unknown
#|trailing resource: unknown
#|garbage: unknown
#|quoted resource: unknown
#|nil root: unknown
#|adjacent string: unknown
#|adjacent list: unknown
#|overbound: unknown
#|unsolicited late: unknown
#|failed command: unknown
#|missing completion: unknown
#|wrong completion: unknown
#|cap QUOTA: True
#|cap QUOTA=RES-STORAGE: True
#|cap QUOTA=RES-MESSAGE: False
#|cap QUOTASET: False
#|cap XQUOTA: False
#|cap QUOTA=RES-STORAGE-X: False
#|cap : False
#|failed caps: False
#|late caps: False
#|actual code: True
#|prose: False
#|malformed code: False
#|success code: False
#|later refusal: False
#|large atom: unknown
#|too many lines: unknown
#|missing literal: True
#|unused literal: True
#|NUL roots: unknown
#|a1 GETQUOTAROOT "INBOX"
