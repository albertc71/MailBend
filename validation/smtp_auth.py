"""Finite observations of the SMTP refusal classifier's literal regression test."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile

BASE = "496dcf5e6644484b2598bcf6e2a2a0a1dfc0f465"
PRODUCT = "8d3e4e9250a28923d38b075de0b6ffe66c92b25b"
TREE = "8e457cf6fdf738a04e1c626253e1800358926dd4"
SOURCE = Path("native/mailbend-tls/src/exit.rs")
HASH = "949da1b398c1a0d8031e004162bca956a1cd37c044c9a69950013a23e372b85a"
BASE_HASH = "24c0fab739c313662e505b8c8979f47dffadfa34ffdd02accfe642ffea0bd26d"
TEST = "exit::tests::smtp_refusal_reasons_preserve_exceptions_and_range_boundaries"
ADDITIONS = [".github/workflows/smtp-auth-validation.yml", "validation/smtp_auth.py"]


def require(condition, detail):
    if not condition:
        raise RuntimeError(detail)


def git(*args):
    return subprocess.check_output(["git", *args], timeout=30).decode().strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def admit():
    require(git("show", "-s", "--format=%P", "HEAD") == PRODUCT, "validation parent")
    require(git("show", "-s", "--format=%P", PRODUCT) == BASE, "product parent")
    require(git("rev-parse", PRODUCT + "^{tree}") == TREE, "product tree")
    require(git("diff", "--name-only", PRODUCT, "HEAD").splitlines() == ADDITIONS,
            "validation additions")
    require(git("diff", "--name-only", BASE, PRODUCT).splitlines() ==
            [str(SOURCE), "tests/posture-egress-inventory.json"], "product paths")
    require(git("rev-parse", "HEAD:.github/workflows/ci.yml") ==
            "e79fd8ac6813c4bc03f4051d1716b219a4d61d8b", "ordinary CI unchanged")
    subprocess.run(["git", "diff", "--exit-code", "HEAD"], check=True, timeout=30)
    candidate = SOURCE.read_bytes()
    baseline = subprocess.check_output(["git", "show", BASE + ":" + str(SOURCE)], timeout=30)
    require(digest(candidate) == HASH and digest(baseline) == BASE_HASH, "source hashes")
    require(candidate.startswith(baseline), "production prefix")
    print(f"ADMITTED validation={git('rev-parse', 'HEAD')} product={PRODUCT} tree={TREE}", flush=True)
    return candidate, baseline


def run(label, seconds=90):
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(
            ["timeout", "--signal=TERM", "--kill-after=5s", str(seconds) + "s",
             "cargo", "test", "--locked", "-p", "mailbend-tls", "--lib", TEST,
             "--", "--exact", "--nocapture"], cwd="native", stdout=output,
            stderr=subprocess.STDOUT, check=False, timeout=seconds + 15)
        require(output.tell() <= 1048576, label + " output exceeds 1 MiB")
        output.seek(0)
        text = output.read().decode("utf-8")
    print(f"BEGIN {label} exit={result.returncode}\n{text}END {label}", flush=True)
    return result.returncode, text


def green(label):
    code, text = run(label)
    require(code == 0 and f"test {TEST} ... ok" in text and
            "test result: ok. 1 passed; 0 failed; 0 ignored;" in text,
            label + " did not run and pass exactly the named test")


MUTANTS = [
    ("remove-432", "            432 => Self::Unknown,\n", "", 432, "Temporary", "Unknown"),
    ("exception-431", "432 => Self::Unknown", "431..=432 => Self::Unknown", 431, "Unknown", "Temporary"),
    ("exception-433", "432 => Self::Unknown", "432..=433 => Self::Unknown", 433, "Unknown", "Temporary"),
    ("temporary-399", "400..=499", "399..=499", 399, "Temporary", "Unknown"),
    ("temporary-401", "400..=499", "401..=499", 400, "Unknown", "Temporary"),
    ("temporary-498", "400..=499", "400..=498", 499, "Unknown", "Temporary"),
    ("temporary-500", "400..=499", "400..=500", 500, "Temporary", "Unknown"),
    ("remove-535", "            535 => Self::Credentials,\n", "", 535, "Unknown", "Credentials"),
    ("credentials-534", "535 => Self::Credentials", "534..=535 => Self::Credentials", 534, "Credentials", "Unknown"),
    ("credentials-536", "535 => Self::Credentials", "535..=536 => Self::Credentials", 536, "Credentials", "Unknown"),
]


candidate, baseline = admit()
if sys.argv[1:] == ["--admit-only"]:
    sys.exit(0)
require(not sys.argv[1:], "unexpected arguments")
try:
    SOURCE.write_bytes(baseline)
    code, text = run("baseline-missing-test", seconds=300)
    require(code == 0 and "test result: ok. 0 passed; 0 failed; 0 ignored;" in text
            and f"test {TEST} ..." not in text, "baseline did not show missing direct test")
    SOURCE.write_bytes(candidate)
    green("candidate-pristine")
    original = candidate.decode("utf-8")
    for name, before, after, reply, actual, expected in MUTANTS:
        require(original.count(before) == 1, name + " replacement count")
        SOURCE.write_text(original.replace(before, after), encoding="utf-8")
        code, text = run(name)
        require(code == 101 and f"test {TEST} ... FAILED" in text and
                "test result: FAILED. 0 passed; 1 failed; 0 ignored;" in text,
                name + " did not fail the named assertion")
        require(f"assertion `left == right` failed: SMTP reply {reply}" in text and
                re.search(r"left:\s+" + actual + r"\s+right:\s+" + expected, text),
                name + " failed for an unexpected reason")
        print(f"KILLED {name} reply={reply} actual={actual} expected={expected}", flush=True)
        SOURCE.write_bytes(candidate)
finally:
    SOURCE.write_bytes(candidate)
    require(digest(SOURCE.read_bytes()) == HASH, "source restoration hash")
    subprocess.run(["git", "diff", "--exit-code", "HEAD"], check=True, timeout=30)
    print("RESTORED " + HASH, flush=True)
green("candidate-restored")
print("PASS ten assertion-sensitive mutants and restored named test", flush=True)
