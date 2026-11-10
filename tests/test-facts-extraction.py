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
ZOOM = "https://zoom.us/j/123456789"
ZOOM_GRAMMAR = re.compile(
    r"https://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)?zoom\.us/j/[0-9]{9,11}"
    r"(?:\?(?:[A-Za-z0-9._~=&+-]|%[A-Fa-f0-9]{2})+)?", re.ASCII)


def invariant(source, result):
    facts = result["facts"]
    assert len(facts) <= 16, result
    assert result["facts_scan"]["scope"] == "returned_text", result
    previous = -1
    for fact in facts:
        start, end = fact["start"], fact["end"]
        assert 0 <= start < end <= min(len(source), 65536), (source, fact)
        assert start > previous, fact
        assert source[start:end] == fact["value"], (source, fact)
        assert (GRAMMAR.fullmatch(fact["value"]) and end - start == 36 or
                ZOOM_GRAMMAR.fullmatch(fact["value"]) and 0 < end - start <= 512), fact
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
        zoom_cases(binary, randomizer)
    print(f"PASS {len(sources)} deterministic extraction inputs and 3 prefix cases")


def zoom_cases(binary, randomizer):
    positives = [ZOOM, "https://us02web.zoom.us/j/12345678901?pwd=Ab_C-0.1",
                 "https://example-org.zoom.us/j/1234567890?pwd=A%2fb%2BC&from=calendar",
                 ZOOM + "?pwd=synthetic.", ZOOM + "?x=1&x=2&empty=&opaque+value",
                 "https://a.zoom.us/j/123456789", "https://" + "a" * 63 + ".zoom.us/j/123456789",
                 ZOOM + "?" + "x" * (512 - len(ZOOM) - 1),
                 ZOOM + "?" + "x" * (512 - len(ZOOM) - 4) + "%2F"]
    for _ in range(64):
        host = randomizer.choice(["zoom.us", "us02web.zoom.us", "synthetic-org.zoom.us"])
        meeting = "".join(randomizer.choice("0123456789") for _ in range(randomizer.randrange(9, 12)))
        query = "".join(randomizer.choice(["a", "Z", "9", ".", "_", "-", "~", "=", "&", "+", "%2F"])
                        for _ in range(randomizer.randrange(1, 40)))
        positives.append(f"https://{host}/j/{meeting}?{query}")
    sources = ["é😀 \n(" + link + ")" for link in positives]
    negatives = [ZOOM + tail for tail in [".", ",", ";", "/", "/join", "#x", "?", "?x=%",
                 "?x=%2", "?x=%GG", "?x=é", "?x=\\evil", "?x=a#fragment", "?x=a/b",
                 "?x=a?b", "?x=a:b", "?x=a@b", "?" + "x" * (512 - len(ZOOM))]]
    negatives += ["https://" + host + "/j/123456789" for host in ["zoom.us.evil.invalid",
                  "evilzoom.us", "zoom.us@evil.invalid", "zoom.us:443", "a.b.zoom.us", ".zoom.us",
                  "-a.zoom.us", "a-.zoom.us", "a" * 64 + ".zoom.us", "ZOOM.us", "zооm.us",
                  "a_b.zoom.us", "%7Aoom.us"]]
    negatives += ["https://zoom.us/j/" + meeting for meeting in ["12345678", "123456789012", "１２３４５６７８９"]]
    negatives += [prefix + ZOOM for prefix in ["x", "é", "😀", "/", "https://evil.invalid/"]]
    negatives += [ZOOM.replace("https:", "http:"), ZOOM.replace("/j/", "/my/"), ZOOM + "é"]
    negatives += [ZOOM.replace("https:", "HTTPS:"), ZOOM.replace("/j/", "/%6A/"),
                  ZOOM + "\u00a0", ZOOM + "\u2028", ZOOM + "\x01", "\u00a0" + ZOOM]
    negatives += [ZOOM + "?" + "x" * (511 - len(ZOOM) - 1) + "%2F"]
    sources += negatives
    outputs = []
    for offset in range(0, len(sources), 32):
        batch = sources[offset:offset + 32]
        run = subprocess.run([binary, "complete", *batch], capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        outputs.extend(json.loads(line) for line in run.stdout.splitlines())
    assert len(outputs) == len(sources), len(outputs)
    for source, result in zip(sources, outputs):
        invariant(source, result)
    for link, result in zip(positives, outputs):
        assert result["facts"] == [{"kind": "meeting_link", "value": link, "source": "text",
                                    "start": 5, "end": 5 + len(link), "line": 2, "untrusted": True}], result
    assert all(result["facts"] == [] for result in outputs[len(positives):]), outputs[len(positives):]
    prefix_sources = [ZOOM, ZOOM + "?pwd=a%2", ZOOM + "?pwd=abc", ZOOM + " ", ZOOM + "?pwd=abc)"]
    run = subprocess.run([binary, "prefix", *prefix_sources], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr
    results = [json.loads(line) for line in run.stdout.splitlines()]
    assert len(results) == len(prefix_sources), results
    assert [len(result["facts"]) for result in results] == [0, 0, 0, 1, 1], results
    assert all(result["facts_scan"]["limited"] for result in results), results
    for source, result in zip(prefix_sources, results):
        invariant(source, result)
    edge_sources = [" " * (65536 - len(ZOOM)) + ZOOM,
                    " " * (65535 - len(ZOOM)) + ZOOM,
                    " " * (65535 - len(ZOOM)) + ZOOM + " ",
                    " " * (65536 - len(ZOOM)) + ZOOM + "?pwd=hidden",
                    (ZOOM + "\n" + LINK + "\n") * 9]
    run = subprocess.run([binary, "complete", *edge_sources], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr
    results = [json.loads(line) for line in run.stdout.splitlines()]
    assert len(results) == len(edge_sources), results
    assert [len(result["facts"]) for result in results] == [0, 1, 1, 0, 16], results
    assert [result["facts_scan"]["limited"] for result in results] == [True, False, True, True, True], results
    for source, result in zip(edge_sources, results):
        invariant(source, result)
    boundary_sources = [left + ZOOM + right for left in ["", " ", "\t", "\r", "\n", "(", "[", "{", "<", "\"", "'"]
                        for right in ["", " ", "\t", "\r", "\n", ")", "]", "}", ">", "\"", "'"]]
    boundary_sources += [ZOOM + "?" + "x" * (width - len(ZOOM) - 1) for width in (511, 512)]
    boundary_sources += [ZOOM + "?pwd=A%2fb.1" + closing for closing in [")", "]", "}", ">", "\"", "'"]]
    for offset in range(0, len(boundary_sources), 32):
        batch = boundary_sources[offset:offset + 32]
        run = subprocess.run([binary, "complete", *batch], capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        results = [json.loads(line) for line in run.stdout.splitlines()]
        assert len(results) == len(batch), results
        for source, result in zip(batch, results):
            invariant(source, result)
            assert len(result["facts"]) == 1, (source, result)
    recovery_sources = [bad + "\n" + ZOOM for bad in [ZOOM + "?pwd=%GG", ZOOM + "?" + "x" * 513]]
    run = subprocess.run([binary, "complete", *recovery_sources], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr
    results = [json.loads(line) for line in run.stdout.splitlines()]
    assert len(results) == len(recovery_sources), results
    for source, result in zip(recovery_sources, results):
        invariant(source, result)
        assert len(result["facts"]) == 1 and result["facts"][0]["start"] == source.rfind(ZOOM), result
    max_url = ZOOM + "?" + "x" * (512 - len(ZOOM) - 1)
    maximum_sources = [" " * (65535 - len(max_url)) + max_url,
                       " " * (65536 - len(max_url)) + max_url,
                       " " * (65535 - len(max_url)) + max_url + " "]
    for mode, counts, flags in [("complete", [1, 0, 1], [False, True, True]),
                                ("prefix", [0, 0, 1], [True, True, True])]:
        run = subprocess.run([binary, mode, *maximum_sources], capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, run.stdout + run.stderr
        results = [json.loads(line) for line in run.stdout.splitlines()]
        assert len(results) == len(maximum_sources), results
        assert [len(result["facts"]) for result in results] == counts, results
        assert [result["facts_scan"]["limited"] for result in results] == flags, results
        for source, result in zip(maximum_sources, results):
            invariant(source, result)
    print(f"PASS {len(sources)} Zoom inputs, {len(prefix_sources)} prefixes and {len(edge_sources)} bounds")


if __name__ == "__main__":
    main()

