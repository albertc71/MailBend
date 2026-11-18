#!/usr/bin/env python3
"""Check the SMTP model and prove guarded transition mutations are rejected."""
from pathlib import Path
import subprocess
import tempfile

MODEL = Path(__file__).with_name("smtp-tls.bend")


def verdict(path):
    return subprocess.run(["bend", str(path), "--verdict"], capture_output=True, text=True)


def main():
    model_bytes = MODEL.read_bytes()
    source = model_bytes.decode("utf-8")
    baseline = verdict(MODEL)
    assert baseline.returncode == 0 and "ALL PROOFS CHECK" in baseline.stdout, baseline.stdout + baseline.stderr
    print("PASS original model: ALL PROOFS CHECK")
    mutations = [
        ("unverified-auth", "[Verified{}, Greeting{}, Ehlo{}, Auth{}]", "[Greeting{}, Ehlo{}, Auth{}]",
         "auth_requires_verified_tls"),
        ("greeting-before-tls", "[Verified{}, Greeting{}, Ehlo{}, Auth{}]",
         "[Greeting{}, Verified{}, Ehlo{}, Auth{}]", "implicit_smtp_requires_verified_tls"),
        ("auth-after-failure", "[Failed{}]", "[Failed{}, Auth{}]", "auth_requires_verified_tls"),
    ]
    with tempfile.TemporaryDirectory(prefix="smtp-tls-model-") as scratch:
        for name, original, broken, property_name in mutations:
            assert source.count(original) == 1
            path = Path(scratch, name + ".bend")
            path.write_text(source.replace(original, broken), encoding="utf-8")
            result = verdict(path)
            output = result.stdout + result.stderr
            assert result.returncode != 0 and "SOME PROOFS FAIL" in output, output
            assert f"Location: {property_name}" in output, output
            print(f"PASS rejected broken transition: {name}")
    assert MODEL.read_bytes() == model_bytes, "the mutation checks changed the model"
    print("PASS original model unchanged")


if __name__ == "__main__":
    main()