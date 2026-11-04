#!/usr/bin/env python3
"""Reject every proven public claim's seeded bug with the unchanged root proofs."""

import importlib.util
from pathlib import Path
import sys

from mutation_runner import run_mutations

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("claim_checks", ROOT / "tools/check-claims.py")
claims = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claims)


def main():
    _, manifest = claims.validate(ROOT)
    mutations = [claim["mutation"] for claim in manifest["claims"] if claim["status"] == "proven"]
    run_mutations(ROOT, mutations)


if __name__ == "__main__":
    main()
