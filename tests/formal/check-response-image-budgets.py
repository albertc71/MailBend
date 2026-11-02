#!/usr/bin/env python3
"""Require the universal budget proofs to reject broken production accounting and IO wiring."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENTRY = "tests/formal/budget-complete.bend"
MUTATIONS = (
    (
        "prefix-keeps-over-budget-scalar",
        "src/response.bend",
        '    case False{}:\n      Prefix{"", left}',
        '    case False{}:\n      Prefix{SCon{c, tail}, left}',
        "prefix_conserves.put",
    ),
    (
        "image-admission-ignores-count",
        "src/image.bend",
        "admit.count(U32.is_zero(count), still, count, bytes)",
        "admit.count(False{}, still, count, bytes)",
        "admit_conserves",
    ),
    (
        "bind-admission-resets-room",
        "src/image.bend",
        "BMint{4n, corpus, still, room, rest, acc}",
        "BMint{4n, corpus, still, room_new(), rest, acc}",
        "bind_admit_conserved",
    ),
    (
        "bind-exhaustion-refunds-room",
        "src/image.bend",
        "BWalk{rest, corpus, room, skipped_ref(still) <> acc}",
        "BWalk{rest, corpus, room_new(), skipped_ref(still) <> acc}",
        "bind_next_conserved",
    ),
    (
        "io-walk-resets-room",
        "src/image.bend",
        "bind_run(f, bind_next(BWalk{v <> rest, corpus, room, acc}, None{}))",
        "bind_run(f, bind_next(BWalk{v <> rest, corpus, room_new(), acc}, None{}))",
        "bind_run_walk",
    ),
    (
        "serialized-utf8-omits-width",
        "src/codec.bend",
        "utf8_len.go(t, (acc + utf8_width(u(c)) : U32))",
        "utf8_len.go(t, acc)",
        "single",
    ),
    (
        "io-seed-doubles-count",
        "src/image.bend",
        "bind_run(bind_fuel(List.length(&2, Verdict, vs)), BWalk{vs, corpus, room_new(), []})",
        "bind_run(bind_fuel(List.length(&2, Verdict, vs)), BWalk{vs, corpus, Room{8, image_request_cap()}, []})",
        "bind_io_initial",
    ),
    (
        "io-zero-fuel-returns-accumulator",
        "src/image.bend",
        "    case 0n _:\n      IO.pure(List<&2, Fate>, [])",
        "    case 0n BWalk{vs, corpus, room, acc}:\n      IO.pure(List<&2, Fate>, acc)\n    case 0n _:\n      IO.pure(List<&2, Fate>, [])",
        "bind_run_zero",
    ),
    (
        "io-result-drops-reversal",
        "src/image.bend",
        "IO.pure(List<&2, Fate>, List.reverse(&2, Fate, acc))",
        "IO.pure(List<&2, Fate>, acc)",
        "bind_run_done",
    ),
)


def check(root):
    return subprocess.run(
        ["bend", ENTRY, "--check-only"],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=300,
        env=dict(os.environ, BEND_NO_TELEMETRY="1"),
    )


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def fingerprint():
    paths = sorted((ROOT / "src").glob("*.bend"))
    paths += sorted((ROOT / "tests/formal").glob("budget-*.bend"))
    paths += sorted((ROOT / "tests/formal").glob("scalar-*.bend"))
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def main():
    before = fingerprint()
    generated = subprocess.run(["python3", str(ROOT / "tests/formal/gen-scalar-atom-trie.py"), "--check"],
                               capture_output=True, text=True, timeout=30)
    require(generated.returncode == 0, ("scalar atom generator", generated.stdout, generated.stderr))
    original = check(ROOT)
    require(original.returncode == 0 and "ALL PROOFS CHECK" in original.stdout,
            ("baseline", original.stdout, original.stderr))
    print("PASS universal budget proofs: ALL PROOFS CHECK")
    for name, path, old, new, proof in MUTATIONS:
        with tempfile.TemporaryDirectory(prefix="mailbend-budget-mutation-") as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "src", root / "src")
            (root / "tests/formal").mkdir(parents=True)
            for source in list((ROOT / "tests/formal").glob("budget-*.bend")) + list((ROOT / "tests/formal").glob("scalar-*.bend")):
                shutil.copy2(source, root / "tests/formal" / source.name)
            target = root / path
            source = target.read_text(encoding="utf-8")
            require(source.count(old) == 1, (name, "mutation target not found once"))
            target.write_text(source.replace(old, new), encoding="utf-8")
            result = check(root)
            output = result.stdout + result.stderr
            location = re.search(r"^Location: (\S+)", output, re.MULTILINE)
            require(result.returncode != 0 and "SOME PROOFS FAIL" in output,
                    (name, "mutant not rejected by the checker", output))
            require(location is not None and proof == location.group(1),
                    (name, "failure did not reach the expected universal proof", output))
            print(f"PASS rejected {name}: universal proof {location.group(1)} fails")
    require(before == fingerprint(), "checkout changed")
    print("PASS checkout unchanged")


if __name__ == "__main__":
    main()
