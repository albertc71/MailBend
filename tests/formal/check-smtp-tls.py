#!/usr/bin/env python3
"""Check the SMTP model and prove both guarded transition mutations are rejected."""
from pathlib import Path
import subprocess
import tempfile

MODEL = Path(__file__).with_name("smtp-tls.bend")


def verdict(path):
    return subprocess.run(["bend", str(path), "--verdict"], capture_output=True, text=True)


def main():
    source = MODEL.read_text(encoding="utf-8")
    baseline = verdict(MODEL)
    assert baseline.returncode == 0 and "ALL PROOFS CHECK" in baseline.stdout, baseline.stdout + baseline.stderr
    mutations = [
        ("unverified-auth", "[Verified{}, Greeting{}, Ehlo{}, Auth{}]", "[Greeting{}, Ehlo{}, Auth{}]"),
        ("auth-after-failure", "[Failed{}]", "[Failed{}, Auth{}]"),
    ]
    with tempfile.TemporaryDirectory(prefix="smtp-tls-model-") as scratch:
        for name, original, broken in mutations:
            assert source.count(original) == 1
            path = Path(scratch, name + ".bend")
            path.write_text(source.replace(original, broken), encoding="utf-8")
            result = verdict(path)
            assert result.returncode != 0 and "SOME PROOFS FAIL" in result.stdout + result.stderr, result.stdout + result.stderr
            print(f"PASS rejected broken transition: {name}")
    restored = verdict(MODEL)
    assert restored.returncode == 0 and "ALL PROOFS CHECK" in restored.stdout, restored.stdout + restored.stderr
    print("PASS original model: ALL PROOFS CHECK")


if __name__ == "__main__":
    main()