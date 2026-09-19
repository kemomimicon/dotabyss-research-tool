#!/usr/bin/env python3
"""Extract every character action/chain effect table from its Unity catalog bundle."""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import defaultdict
from decimal import Decimal, InvalidOperation
from pathlib import Path

import UnityPy


NAME_RE = re.compile(r"^CharacterTimelineEffectValueAsset_([0-9A-Za-z]+)$")
LONG_FIELDS = ["CharacterId", "SkillType", "SkillLevel", "EffectIndex", "Key", "TypeName", "Value"]
SUMMARY_FIELDS = [
    "CharacterId", "SkillType", "SkillLevel", "DamageEventCount",
    "DamagePercentValues", "DamagePercentRawSum", "FirstDamagePercent",
    "HitCountValues", "TargetCountValues", "AllKeys",
]


def write_csv(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(
            stream, fieldnames=fields, extrasaction="ignore", quoting=csv.QUOTE_ALL
        )
        writer.writeheader()
        writer.writerows(rows)


def decimal_sum(values: list[str]) -> str:
    try:
        result = sum((Decimal(value) for value in values), Decimal(0))
    except InvalidOperation:
        return ""
    text = format(result, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    all_rows: list[dict[str, object]] = []
    asset_count = 0
    empty_assets: list[str] = []
    for obj in UnityPy.load(str(args.bundle)).objects:
        if obj.type.name != "MonoBehaviour":
            continue
        tree = obj.read_typetree()
        match = NAME_RE.match(str(tree.get("m_Name", "")))
        if not match:
            continue
        asset_count += 1
        character_id = match.group(1)
        asset_rows: list[dict[str, object]] = []
        for field, skill_type in (
            ("_actionSkillValues", "actionSkillValues"),
            ("_chainSkillValues", "chainSkillValues"),
        ):
            section = tree.get(field) or {}
            levels = section.get("m_Keys") or []
            level_values = section.get("m_Values") or []
            for position, level_data in enumerate(level_values):
                level = levels[position] if position < len(levels) else position + 1
                for effect in (level_data or {}).get("m_Values", []):
                    key = effect.get("Key", "")
                    for effect_index, value in enumerate(effect.get("Values", []), 1):
                        asset_rows.append(
                            {
                                "CharacterId": character_id,
                                "SkillType": skill_type,
                                "SkillLevel": level,
                                "EffectIndex": effect_index,
                                "Key": key,
                                "TypeName": value.get("TypeName", ""),
                                "Value": value.get("JsonValue", ""),
                            }
                        )
        if not asset_rows:
            empty_assets.append(character_id)
        base = f"CharacterTimelineEffectValueAsset_{character_id}"
        write_csv(args.output / f"{base}.csv", asset_rows, LONG_FIELDS)
        (args.output / f"{base}.json").write_text(
            json.dumps(asset_rows, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        all_rows.extend(asset_rows)

    # Python's stable sort keeps the effect/key order found in the asset while
    # making the cross-character aggregate deterministic.
    all_rows.sort(
        key=lambda row: (
            str(row["CharacterId"]), str(row["SkillType"]), int(row["SkillLevel"])
        )
    )
    write_csv(args.output / "all-characters-long.csv", all_rows, LONG_FIELDS)

    groups: dict[tuple[str, str, int], list[dict[str, object]]] = defaultdict(list)
    for row in all_rows:
        groups[(str(row["CharacterId"]), str(row["SkillType"]), int(row["SkillLevel"]))].append(row)
    summary: list[dict[str, object]] = []
    for (character_id, skill_type, level), rows in sorted(groups.items()):
        by_key: dict[str, list[str]] = defaultdict(list)
        for row in rows:
            by_key[str(row["Key"])].append(str(row["Value"]))
        damage = by_key.get("DAMAGE.DAMAGE_PERCENT", [])
        first_damage = by_key.get("DAMAGE.DAMAGE_FIRST_PERCENT", [])
        target_counts = [
            value
            for key, values in by_key.items()
            if key.endswith("TARGET_COUNT")
            for value in values
        ]
        summary.append(
            {
                "CharacterId": character_id,
                "SkillType": skill_type,
                "SkillLevel": level,
                "DamageEventCount": len(damage),
                "DamagePercentValues": "|".join(damage),
                "DamagePercentRawSum": decimal_sum(damage),
                "FirstDamagePercent": "|".join(first_damage),
                "HitCountValues": "|".join(by_key.get("DAMAGE.HIT_COUNT", [])),
                "TargetCountValues": "|".join(target_counts),
                "AllKeys": "|".join(sorted(by_key)),
            }
        )
    write_csv(args.output / "all-characters-summary.csv", summary, SUMMARY_FIELDS)
    report = {
        "CharacterAssets": asset_count,
        "CharactersWithValues": asset_count - len(empty_assets),
        "EmptyAssets": empty_assets,
        "RawEffectValues": len(all_rows),
        "SummaryRows": len(summary),
    }
    (args.output / "extraction-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
