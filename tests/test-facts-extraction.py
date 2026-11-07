#!/usr/bin/env python3
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LINK = "https://meet.google.com/abc-defg-hij"
GRAMMAR = re.compile(r"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}", re.ASCII)


def invariant(source, result):
    facts = result["facts"]
    assert len(facts) <= 16, result
    assert result["facts_scan"]["scope"] == "returned_text", result
    previous = -1
    for fact in facts:
        start, end = fact["start"], fact["end"]
        assert 0 <= start < end <= min(len(source), 65536), (source, fact)
        assert end - start == 36 and start > previous, fact
        assert source[start:end] == fact["value"], (source, fact)
        assert GRAMMAR.fullmatch(fact["value"]), fact
        assert fact["line"] == source[:start].count("\n") + 1, (source, fact)
        assert fact["source"] == "text" and fact["kind"] == "meeting_link" and fact["untrusted"] is True, fact
        previous = start


def main():
    randomizer = random.Random(75)
    alphabet = "abcXYZ09 /\\:?%#@._-<>[]{}()\"'\r\n\t é😀ı\u2028"
    positives = []
    for _ in range(64):
        prefix = "".join(randomizer.choice(alphabet) for _ in range(randomizer.randrange(80)))
        suffix = "".join(randomizer.choice(alphabet) for _ in range(randomizer.randrange(80)))
        groups = ["".join(randomizer.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(width))
                  for width in (3, 4, 3)]
        link = "https://meet.google.com/" + "-".join(groups)
        positives.append((prefix + "\n" + link + "\n" + suffix, len(prefix) + 1))
    negatives = [left + LINK + right for left in ("x", "/", "@", "é", "😀")
                 for right in ("", ".evil", "/x", "?x", "#x", "%20", "@x", "\\x", "é", "x")]
    altered = [LINK[:index] + character + LINK[index + 1:]
               for index in range(len(LINK)) for character in ("X", "é", "/", "-")]
    cap_sources = [" " * 65500 + LINK, " " * 65499 + LINK + "\n",
                   (LINK + "\n") * 16, (LINK + "\n") * 17]
    sources = [source for source, _ in positives] + negatives + altered + cap_sources
    with tempfile.TemporaryDirectory(prefix="mailbend-facts-extraction-") as temporary:
        binary = str(Path(temporary) / "facts-probe")
        built = subprocess.run(["bend", "tests/facts-probe.bend", "-o", binary], cwd=ROOT,
                               env=dict(os.environ, BEND_NO_TELEMETRY="1"), capture_output=True,
                               text=True, timeout=120)
        assert built.returncode == 0, built.stdout + built.stderr
        outputs = []
        for offset in range(0, len(sources), 32):
            batch = sources[offset:offset + 32]
            run = subprocess.run([binary, "complete", *batch], capture_output=True, text=True, timeout=30)
            assert run.returncode == 0, run.stdout + run.stderr
            outputs += [json.loads(line) for line in run.stdout.splitlines()]
        assert len(outputs) == len(sources), len(outputs)
        for source, result in zip(sources, outputs):
            invariant(source, result)
        for (_, start), result in zip(positives, outputs):
            assert len(result["facts"]) == 1 and result["facts"][0]["start"] == start, result
        for result in outputs[len(positives):len(positives) + len(negatives)]:
            assert result["facts"] == [], result
        assert [len(result["facts"]) for result in outputs[-4:]] == [0, 1, 16, 16], outputs[-4:]
        assert outputs[-3]["facts"][0]["start"] == 65499 and outputs[-3]["facts"][0]["end"] == 65535, outputs[-3]
        assert all(result["facts_scan"]["limited"] for result in outputs[-4:]), outputs[-4:]
        run = subprocess.run([binary, "prefix", LINK, LINK + " ", "é😀 " + LINK + "\n"],
                             capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        prefix_results = [json.loads(line) for line in run.stdout.splitlines()]
        for source, result in zip((LINK, LINK + " ", "é😀 " + LINK + "\n"), prefix_results):
            invariant(source, result)
        assert [len(result["facts"]) for result in prefix_results] == [0, 1, 1], prefix_results
        assert all(result["facts_scan"]["limited"] for result in prefix_results), prefix_results
    print(f"PASS {len(sources)} deterministic extraction inputs and 3 prefix cases")


if __name__ == "__main__":
    main()
