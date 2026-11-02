#!/usr/bin/env python3
"""Choose a measured CPU candidate; the scale harness checks the full profile."""
import pathlib
import sys

BASELINES = {
    "AMD EPYC 9V45 96-Core Processor": "scale-baseline.json",
    "AMD EPYC 7763 64-Core Processor": "scale-baseline-epyc7763.json",
}


def select_baseline(cpu):
    if cpu not in BASELINES:
        raise ValueError(f"no reviewed scale baseline for CPU: {cpu}")
    return pathlib.Path(__file__).with_name(BASELINES[cpu])


if __name__ == "__main__":
    info = pathlib.Path("/proc/cpuinfo").read_text()
    cpu = next((line.split(":", 1)[1].strip() for line in info.splitlines()
                if line.startswith("model name")), "unknown")
    try:
        print(select_baseline(cpu))
    except ValueError as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
