#!/usr/bin/env python3
"""assets and TypeSafe-Danger-Zone-Images are accepted only together."""

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fake_typesafe", ROOT / "tests" / "fake_typesafe.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

QUESTIONS = {"u1_keep": {"type": "noul", "instructions": "About the email."}}
BASE = {
    "state": {"emails": [{"uid": 1, "text": "hello"}]},
    "model": mod.MODEL,
    "questions": QUESTIONS,
}
ASSETS = {
    **BASE,
    "assets": {
        "mbimg-01234567-89abcdef-00000000-ffffffff": {
            "type": "image",
            "format": "png",
            "data_base64": "YQ==",
        }
    },
}


def main():
    checks = [
        ("neither", mod.images_problem(BASE, None) is None),
        ("assets without header", mod.images_problem(ASSETS, None) is not None),
        ("header without assets", mod.images_problem(BASE, "true") is not None),
        ("assets with header", mod.images_problem(ASSETS, "true") is None),
    ]
    failed = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
