#!/usr/bin/env python3
"""Export all-ages character stands and composite their default face."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

import UnityPy
from PIL import Image


ID_RE = re.compile(r"(\d{9}G)", re.IGNORECASE)
FACE_PREFERENCE = ("Normal", "Unique01", "Happy", "Closed")


def vector_xy(value) -> tuple[float, float]:
    return float(value.x), float(value.y)


def game_object_layout(environment) -> dict[str, dict[str, tuple[float, float]]]:
    layout: dict[str, dict[str, tuple[float, float]]] = {}
    for obj in environment.objects:
        if obj.type.name != "GameObject":
            continue
        game_object = obj.read()
        for entry in game_object.m_Component:
            component = entry.component
            if component.type.name != "RectTransform":
                continue
            transform = component.read()
            layout[game_object.m_Name] = {
                "position": vector_xy(transform.m_AnchoredPosition),
                "size": vector_xy(transform.m_SizeDelta),
            }
            break
    return layout


def composite_default_face(environment) -> tuple[Image.Image, str, str]:
    sprites = {}
    for obj in environment.objects:
        if obj.type.name == "Sprite":
            sprite = obj.read()
            sprites[sprite.m_Name] = sprite.image.convert("RGBA")
    if "Body" not in sprites:
        raise ValueError("Body sprite was not found")

    body = sprites["Body"].copy()
    face_name = next((name for name in FACE_PREFERENCE if name in sprites), "")
    if not face_name:
        face_name = next((name for name in sorted(sprites) if name != "Body"), "")
    if not face_name:
        return body, "", "body-only"

    layout = game_object_layout(environment)
    if "Body" not in layout or "FaceContent" not in layout:
        raise ValueError("Body or FaceContent layout was not found")
    body_width, body_height = layout["Body"]["size"]
    face_width, face_height = layout["FaceContent"]["size"]
    face_x, face_y = layout["FaceContent"]["position"]
    if body_width <= 0 or body_height <= 0 or face_width <= 0 or face_height <= 0:
        raise ValueError("Invalid prefab layout dimensions")

    scale = min(body.width / body_width, body.height / body_height)
    face = sprites[face_name]
    face_scale = min(face_width * scale / face.width, face_height * scale / face.height)
    rendered = face.resize(
        (max(1, round(face.width * face_scale)), max(1, round(face.height * face_scale))),
        Image.Resampling.LANCZOS,
    )
    center_x = body.width / 2 + face_x * scale
    center_y = body.height / 2 - face_y * scale
    destination = (round(center_x - rendered.width / 2), round(center_y - rendered.height / 2))
    body.alpha_composite(rendered, destination)
    return body, face_name, "composited"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Directory containing <character-id>.bundle files")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    rows = []
    failures = 0
    bundles = sorted(args.source.glob("*.bundle"))
    for bundle in bundles:
        match = ID_RE.search(bundle.stem)
        character_id = match.group(1).upper() if match else bundle.stem
        output_name = f"{character_id}.png"
        row = {"CharacterId": character_id, "Bundle": bundle.name, "Output": output_name}
        try:
            image, face_name, status = composite_default_face(UnityPy.load(str(bundle)))
            image.save(args.output / output_name)
            row.update(
                Status=status,
                DefaultFace=face_name,
                Width=image.width,
                Height=image.height,
                Error="",
            )
        except Exception as error:  # keep a complete per-bundle report
            failures += 1
            row.update(Status="error", DefaultFace="", Width="", Height="", Error=str(error))
        rows.append(row)

    fields = ("CharacterId", "Bundle", "Output", "Status", "DefaultFace", "Width", "Height", "Error")
    with (args.output / "manifest.csv").open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Exported {len(rows) - failures}/{len(rows)} all-ages character stands; failures={failures}.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
