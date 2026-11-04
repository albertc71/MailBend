#!/usr/bin/env python3
"""Generate the complete, source-linked catalogue of LAWS.bend declarations."""

import argparse
from pathlib import Path
import sys

from law_catalogue import ROOT, catalogue, generated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        generated(args.root / "docs/LAWS.md", catalogue(args.root), args.check)
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
