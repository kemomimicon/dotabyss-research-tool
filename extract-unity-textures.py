#!/usr/bin/env python3
"""Export Texture2D objects from one bundle or a directory of bundles."""

from __future__ import annotations

import argparse
from pathlib import Path

import UnityPy


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    bundles = sorted(args.source.glob("*.bundle")) if args.source.is_dir() else [args.source]
    exported = 0
    for bundle in bundles:
        for obj in UnityPy.load(str(bundle)).objects:
            if obj.type.name != "Texture2D":
                continue
            texture = obj.read()
            texture.image.save(args.output / f"{texture.m_Name}.png")
            exported += 1
    print(f"Exported {exported} textures from {len(bundles)} bundle(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
