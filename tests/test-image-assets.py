#!/usr/bin/env python3
"""The fake TypeSafe's image rules: assets and TypeSafe-Danger-Zone-Images
are accepted only together, every asset must be referenced, and every
image must decode."""

import base64
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tests" / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load("fake_typesafe", "fake_typesafe.py")
images = load("image_fixtures", "image_fixtures.py")

REF = "mbimg-01234567-89abcdef-00000000-ffffffff"
QUESTIONS = {"u1_keep": {"type": "noul", "instructions": "About the email."}}
BASE = {
    "state": {"emails": [{"uid": 1, "text": "hello"}]},
    "model": mod.MODEL,
    "questions": QUESTIONS,
}


def with_asset(fmt, data, referenced=True):
    state = {"emails": [{"uid": 1, "text": "hello", "images": [REF] if referenced else []}]}
    asset = {"type": "image", "format": fmt, "data_base64": base64.b64encode(data).decode("ascii")}
    return {**BASE, "state": state, "assets": {REF: asset}}


ASSETS = with_asset("png", images.png(280, 280))


def main():
    jpeg_header_only = bytes([255, 216, 255, 225, 0, 8, 0, 1, 0, 2, 0, 3, 255, 192, 0, 11, 8, 1, 24,
                              6, 32, 1, 1, 17, 0, 255, 217])
    checks = [
        ("neither", mod.images_problem(BASE, None) is None),
        ("assets without header", mod.images_problem(ASSETS, None) is not None),
        ("header without assets", mod.images_problem(BASE, "true") is not None),
        ("assets with header", mod.images_problem(ASSETS, "true") is None),
        ("a referenced PNG that decodes", mod.assets_problem(ASSETS) is None),
        ("a referenced JPEG with a frame and a scan", mod.assets_problem(with_asset("jpeg", images.jpeg(280, 280))) is None),
        ("an asset never referenced", "not referenced" in (mod.assets_problem(
            with_asset("png", images.png(280, 280), referenced=False)) or "")),
        ("a PNG with a bad CRC and no deflate stream", "damaged" in (mod.assets_problem(
            with_asset("png", images.damaged_png())) or "")),
        ("a PNG whose image data stops early", "damaged" in (mod.assets_problem(
            with_asset("png", images.png(280, 280)[:-40])) or "")),
        ("a JPEG with no scan", "damaged" in (mod.assets_problem(with_asset("jpeg", jpeg_header_only)) or "")),
        ("a JPEG without EOI", "damaged" in (mod.assets_problem(
            with_asset("jpeg", images.jpeg(280, 280)[:-2])) or "")),
        ("a PNG declared as JPEG", "damaged" in (mod.assets_problem(
            with_asset("jpeg", images.png(280, 280))) or "")),
    ]
    failed = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
