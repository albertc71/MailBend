#!/usr/bin/env python3
"""Reject fixed folder-status mutations with the production proofs and tests.

The source mode runs five mutations. The native mode runs one. Each child
has a 120-second deadline and a 1-MiB combined-output ceiling. All mutations
stay in one temporary source copy; compiler children are confined to their
own process group and cleaned up on every exit path.
"""
import argparse
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
UNIT = "tests/unit/folder-status.bend"
NATIVE_TEST = "imap::script::tests::capabilities_are_a_finite_conjunction_after_capability_only"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run(root, args, env=None):
    with selectors.DefaultSelector() as selector:
        process = subprocess.Popen(args, cwd=root, env={**os.environ, "BEND_NO_TELEMETRY": "1", **(env or {})},
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 120
            data = bytearray()
            while selector.get_map():
                require(time.monotonic() < deadline, ("child timeout", args))
                for key, _ in selector.select(timeout=min(0.05, max(0, deadline - time.monotonic()))):
                    block = os.read(key.fd, min(65536, 1048577 - len(data)))
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        data.extend(block)
                        require(len(data) <= 1048576, ("child output limit", args))
            code = process.wait(timeout=max(0, deadline - time.monotonic()))
            return code, data.decode("utf-8", errors="replace")
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            process.stdout.close()


def replace_once(path, before, after):
    source = path.read_text(encoding="utf-8")
    require(source.count(before) == 1, f"mutation target moved: {path}: {before}")
    path.write_text(source.replace(before, after), encoding="utf-8")
    return source


def section(source, first, last):
    require(source.count(first) == source.count(last) == 1, "proof section markers moved")
    return source.split(first, 1)[1].split(last, 1)[0]


def bend_controls(root):
    shutil.copytree(ROOT / "src", root / "src")
    (root / "tests/unit").mkdir(parents=True)
    shutil.copy2(ROOT / UNIT, root / UNIT)
    law_start = "# LAW: folder status commands and their finite capability gate have no mail effect.\n"
    law_end = "# LAW: the scan before a folder change writes nothing\n"
    laws = section((ROOT / "LAWS.bend").read_text(), law_start, law_end)
    proof_start = "def Laws.folder_status_effects(name, modseq, required):\n"
    proof_end = "def Laws.folder_scan_writes_nothing():\n"
    proofs = proof_start + section((ROOT / "PROOF.bend").read_text(), proof_start, proof_end)
    imports = "import Base\nimport ./src/imap.bend as I\nimport ./src/ops.bend as Ops\n"
    (root / "LAWS.bend").write_text(imports + laws)
    (root / "PROOF.bend").write_text(imports + "import ./LAWS.bend as Laws\n" + proofs)
    code, output = run(root, ["bend", "PROOF.bend"])
    require(code == 0 and "ALL PROOFS CHECK" in output, ("baseline proof", output))
    mutations = [
        ("effect", "src/imap.bend", "    case CStatus{m, modseq}:\n      ENone{}",
         "    case CStatus{m, modseq}:\n      ESelect{}", "folder_status_effects"),
        ("plan", "src/ops.bend", "    case True{} False{}:\n      [I.CapListStatus{}]",
         "    case True{} False{}:\n      []", "folder_status_fast_exact"),
        ("renderer", "src/imap.bend", '"STATUS " ++ mailbox(m) ++ " (" ++ status_items(modseq)',
         '"EXAMINE " ++ mailbox(m) ++ " (" ++ status_items(modseq)', "folder_status_render_exact"),
    ]
    for label, relative, before, after, observer in mutations:
        path = root / relative
        original = replace_once(path, before, after)
        try:
            code, output = run(root, ["bend", "PROOF.bend"])
            require(code != 0 and (f"Location: {observer}" in output or f"Location: Laws.{observer}" in output)
                    and "expected" in output.lower() and "observed" in output.lower(), (label, output))
            print(f"PASS {label} mutation rejected at {observer}")
        finally:
            path.write_text(original)
    code, output = run(root, ["bend", "PROOF.bend"])
    require(code == 0 and "ALL PROOFS CHECK" in output, ("restored proof", output))
    expected = "".join(line[2:] + "\n" for line in (ROOT / UNIT).read_text().splitlines() if line.startswith("#|"))
    code, output = run(root, ["bend", UNIT])
    require(code == 0 and output == expected, ("baseline evidence", output))
    evidence = [
        ("identity", "    case True{} False{}:\n      Unknown{InvalidResponse{}}",
         "    case True{} False{}:\n      matched(matching(rs, name))", "wrong-name not_returned\n"),
        ("failure", "U32.is_eq(code, 0) || U32.is_eq(code, 5)", "True{}",
         "lost incomplete_status A:0,0,1,7,unsupported;B:not_attempted;\n"),
    ]
    path = root / "src/folder-status.bend"
    for label, before, after, wrong in evidence:
        original = replace_once(path, before, after)
        try:
            code, output = run(root, ["bend", UNIT])
            require(code == 0 and output != expected and wrong in output, (label, output))
            print(f"PASS {label} mutation ran and produced the specified wrong evidence")
        finally:
            path.write_text(original)
    code, output = run(root, ["bend", UNIT])
    require(code == 0 and output == expected, ("restored evidence", output))


def native_control(root):
    shutil.copytree(ROOT / "native", root / "native",
                    ignore=shutil.ignore_patterns("target", ".git", "__pycache__"))
    args = ["cargo", "test", "--locked", "--offline", "-p", "mailbend-tls", NATIVE_TEST, "--", "--exact"]
    env = {"CARGO_TARGET_DIR": str(root / "target")}
    code, output = run(root / "native", args, env)
    require(code == 0 and f"test {NATIVE_TEST} ... ok" in output, ("native baseline", output))
    path = root / "native/mailbend-tls/src/imap/script.rs"
    original = replace_once(path, "required.split(|&b| b == b' ').all(|want| {",
                            "required.split(|&b| b == b' ').any(|want| {")
    try:
        code, output = run(root / "native", args, env)
        require(code != 0 and f"test {NATIVE_TEST} ... FAILED" in output
                and "test result: FAILED" in output and "assertion failed" in output,
                ("native conjunction mutant did not fail its semantic assertion", output))
        print("PASS native conjunction mutation compiled and failed its missing-capability assertion")
    finally:
        path.write_text(original)
    code, output = run(root / "native", args, env)
    require(code == 0 and f"test {NATIVE_TEST} ... ok" in output, ("native restored", output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mailbend-folder-status-mutations-") as directory:
        (native_control if args.native else bend_controls)(Path(directory))
    print("PASS mutations restored and temporary sources removed")


if __name__ == "__main__":
    main()
