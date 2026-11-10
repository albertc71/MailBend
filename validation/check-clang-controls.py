import pathlib
import subprocess
import sys
import tempfile

BASE = "1258173135c13b24e3207e6fc15b69e87b3e1a79"
SOURCE = pathlib.Path("source").resolve()
NAME = "test_clang_disappearing_during_proofs_does_not_publish_helpers"


def run_case(label, test, installer, failed=False):
    with tempfile.TemporaryDirectory(prefix="clang-decision-") as directory:
        root = pathlib.Path(directory)
        (root / "tests").mkdir()
        (root / "scripts").mkdir()
        (root / "tests/test-install.py").write_bytes(test)
        (root / "scripts/install.sh").write_bytes(installer)
        proc = subprocess.run(
            ["timeout", "--kill-after=5s", "120s", sys.executable, "-I",
             str(root / "tests/test-install.py")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=135,
        )
        output = proc.stdout.decode("utf-8", errors="strict")
        print(f"BEGIN {label} status={proc.returncode}", flush=True)
        print(output, end="", flush=True)
        assert "Ran 18 tests in " in output, label
        if failed:
            assert proc.returncode == 1, label
            assert "FAILED (failures=1)" in output, label
            assert "ERROR:" not in output, label
            assert f"FAIL: {NAME} " in output, label
            assert "(shell='/bin/bash')" in output, label
            assert "AssertionError: 0 == 0" in output, label
        else:
            assert proc.returncode == 0 and output.rstrip().endswith("OK"), label
        print(f"PASS {label}", flush=True)


assert pathlib.Path("/bin/sh").resolve() == pathlib.Path("/usr/bin/dash"), "expected dash /bin/sh"
assert pathlib.Path("/bin/bash").is_file(), "bash is required, not skipped"
installer = (SOURCE / "scripts/install.sh").read_bytes()
baseline = subprocess.check_output(
    ["git", "-C", str(SOURCE), "show", f"{BASE}:tests/test-install.py"], timeout=15)
candidate = (SOURCE / "tests/test-install.py").read_bytes()
needle = b'if [ "$has_clang" = 1 ]; then'
assert installer.count(needle) == 1, "mutation target must be unique"
mutant = installer.replace(needle, b"if command -v clang >/dev/null 2>&1; then")
run_case("baseline-healthy-sh", baseline, installer)
run_case("baseline-reprobe-survives-sh", baseline, mutant)
run_case("candidate-healthy-sh-and-bash", candidate, installer)
run_case("candidate-reprobe-rejected-by-bash", candidate, mutant, failed=True)
run_case("candidate-restored-sh-and-bash", candidate, installer)
