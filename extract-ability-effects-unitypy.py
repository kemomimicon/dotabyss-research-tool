#!/usr/bin/env python3
"""Extract passive ability runtime data directly from a Unity asset bundle.

Unlike filename-based exports, this keeps Unity PathID references intact.  That is
important for DotAbyss because many AbilitySubAsset objects share the same name.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

import UnityPy


ASSET_RE = re.compile(r"^AbilityEffectAsset_(\d+)$")
SUBASSET_RE = re.compile(r"^AbilitySubAsset_([^_]+)_(.+)$")
BOILERPLATE = {"m_GameObject", "m_Enabled", "m_Script", "m_Name"}
MAIN_CATALOG = "AbilityEffectAssetCatalog"
NETHER_CATALOG = "NetherCodeAbilityEffectAssetCatalog"


def compact_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def write_csv(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fields, extrasaction="ignore", quoting=csv.QUOTE_ALL
        )
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path, help="Unity bundle containing AbilityEffectAsset objects")
    parser.add_argument("output", type=Path, help="Output directory")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    environment = UnityPy.load(str(args.bundle))

    objects: dict[int, dict[str, object]] = {}
    read_errors: list[dict[str, object]] = []
    for obj in environment.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        try:
            tree = obj.read_typetree()
        except Exception as exc:  # Preserve failures in a machine-readable report.
            read_errors.append({"PathId": obj.path_id, "Error": str(exc)})
            continue
        objects[obj.path_id] = tree

    membership: dict[int, tuple[str, int]] = {}
    for tree in objects.values():
        catalog_name = str(tree.get("m_Name", ""))
        if catalog_name not in {MAIN_CATALOG, NETHER_CATALOG}:
            continue
        catalog = tree.get("_assets", {})
        keys = catalog.get("m_Keys", []) if isinstance(catalog, dict) else []
        values = catalog.get("m_Values", []) if isinstance(catalog, dict) else []
        for key, value in zip(keys, values):
            if isinstance(value, dict):
                membership[int(value.get("m_PathID", 0))] = (catalog_name, int(key))

    all_asset_rows: list[dict[str, object]] = []
    all_subasset_rows: list[dict[str, object]] = []
    for path_id, (catalog_name, catalog_id) in membership.items():
        tree = objects.get(path_id, {})
        name = str(tree.get("m_Name", ""))
        match = ASSET_RE.match(name)
        if not match:
            continue

        asset_id = str(catalog_id)
        codes: dict[str, list[str]] = {
            "AbilityEffect": [],
            "AbilityTarget": [],
            "AbilitySituation": [],
            "AbilityScope": [],
        }
        refs = tree.get("_subAssets", [])
        if not isinstance(refs, list):
            refs = []

        for index, ref in enumerate(refs, 1):
            ref_path_id = int(ref.get("m_PathID", 0)) if isinstance(ref, dict) else 0
            child = objects.get(ref_path_id)
            child_name = str(child.get("m_Name", "")) if child else ""
            child_match = SUBASSET_RE.match(child_name)
            category = child_match.group(1) if child_match else "MissingReference"
            code = child_match.group(2) if child_match else ""
            if category in codes and code not in codes[category]:
                codes[category].append(code)
            parameters = (
                {key: value for key, value in child.items() if key not in BOILERPLATE}
                if child
                else {}
            )
            all_subasset_rows.append(
                {
                    "Catalog": catalog_name,
                    "AbilityEffectAssetId": asset_id,
                    "SubAssetIndex": index,
                    "Category": category,
                    "Code": code,
                    "AssetName": child_name,
                    "Guid": "",
                    "PathId": ref_path_id,
                    "ParametersJson": compact_json(parameters),
                    "SourcePath": f"{args.bundle.name}#PathID={ref_path_id}",
                }
            )

        all_asset_rows.append(
            {
                "Catalog": catalog_name,
                "AbilityEffectAssetId": asset_id,
                "EffectCode": "|".join(codes["AbilityEffect"]),
                "TargetCode": "|".join(codes["AbilityTarget"]),
                "SituationCode": "|".join(codes["AbilitySituation"]),
                "ScopeCode": "|".join(codes["AbilityScope"]),
                "SubAssetCount": len(refs),
                "PathId": path_id,
            }
        )

    all_asset_rows.sort(key=lambda row: (str(row["Catalog"]), int(str(row["AbilityEffectAssetId"]))))
    all_subasset_rows.sort(
        key=lambda row: (str(row["Catalog"]), int(str(row["AbilityEffectAssetId"])), int(str(row["SubAssetIndex"])))
    )
    asset_rows = [row for row in all_asset_rows if row["Catalog"] == MAIN_CATALOG]
    subasset_rows = [row for row in all_subasset_rows if row["Catalog"] == MAIN_CATALOG]
    nether_asset_rows = [row for row in all_asset_rows if row["Catalog"] == NETHER_CATALOG]
    nether_subasset_rows = [row for row in all_subasset_rows if row["Catalog"] == NETHER_CATALOG]

    asset_fields = [
        "Catalog", "AbilityEffectAssetId", "EffectCode", "TargetCode", "SituationCode",
        "ScopeCode", "SubAssetCount", "PathId",
    ]
    subasset_fields = [
        "Catalog", "AbilityEffectAssetId", "SubAssetIndex", "Category", "Code", "AssetName",
        "Guid", "PathId", "ParametersJson", "SourcePath",
    ]
    write_csv(args.output / "ability-effect-assets.csv", asset_rows, asset_fields)
    write_csv(args.output / "ability-effect-subassets.csv", subasset_rows, subasset_fields)
    (args.output / "ability-effect-assets.json").write_text(
        json.dumps(asset_rows, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "ability-effect-subassets.json").write_text(
        json.dumps(subasset_rows, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    write_csv(args.output / "nether-code-ability-effect-assets.csv", nether_asset_rows, asset_fields)
    write_csv(args.output / "nether-code-ability-effect-subassets.csv", nether_subasset_rows, subasset_fields)
    (args.output / "nether-code-ability-effect-assets.json").write_text(
        json.dumps(nether_asset_rows, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "nether-code-ability-effect-subassets.json").write_text(
        json.dumps(nether_subasset_rows, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "ability-effect-extraction-report.json").write_text(
        json.dumps(
            {
                "Bundle": args.bundle.name,
                "MonoBehavioursRead": len(objects),
                "ReadErrors": read_errors,
                "AbilityEffectAssets": len(all_asset_rows),
                "MainCatalogAssets": len(asset_rows),
                "MainCatalogSubAssetReferences": len(subasset_rows),
                "NetherCodeCatalogAssets": len(nether_asset_rows),
                "NetherCodeCatalogSubAssetReferences": len(nether_subasset_rows),
                "MissingReferences": sum(
                    row["Category"] == "MissingReference" for row in all_subasset_rows
                ),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(compact_json({
        "AbilityEffectAssets": len(all_asset_rows),
        "MainCatalogAssets": len(asset_rows),
        "NetherCodeCatalogAssets": len(nether_asset_rows),
        "SubAssets": len(all_subasset_rows),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
