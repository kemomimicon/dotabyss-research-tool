# Character timeline dataset

This directory contains normalized timeline-effect data extracted from DotAbyss Unity assets.

## Coverage

- 107 character assets were present in WebGL resource version 9533.
- 106 contain timeline values; `108701000G` is an empty asset in this build.
- 28,879 raw effect values were extracted.
- 2,110 character / skill type / skill level rows are present in the summary.
- Two skill sections are normally available: `actionSkillValues` and `chainSkillValues`.
- Skill levels are the catalog keys `1` through `10`, not hit numbers.
- `EffectIndex` represents the order of repeated values for one effect key. For damage fields this often corresponds to separate hit/effect entries, but it should remain raw until verified against animation timing.

## Files

- `all-characters-summary.csv`: compact research table, one row per character, skill type and skill level.
- `all-characters-long.csv`: normalized raw table, one row per effect value.
- `CharacterTimelineEffectValueAsset_<ID>.csv/json`: per-character data.
- `../parse-character-timeline.ps1`: parser for AssetRipper YAML exports.
- `../extract-character-timelines-unitypy.py`: direct bundle parser that avoids the YAML export step.

## Important columns

- `CharacterId`: internal resource ID; names require a separate master-data mapping.
- `SkillType`: `actionSkillValues` or `chainSkillValues`.
- `SkillLevel`: raw catalog level key, normally 1–10.
- `DamageEventCount`: count of `DAMAGE.DAMAGE_PERCENT` entries.
- `DamagePercentValues`: raw per-effect percentage values, separated by `|`.
- `DamagePercentRawSum`: arithmetic sum of those raw values; it is a convenience statistic, not a proven final damage multiplier.
- `AllKeys`: every effect key present in that skill/level, useful for locating healing, abnormal status, projectiles, drains and conditional impact branches.

## Interpretation limits

These assets expose effect parameters, not complete combat results. Final damage can additionally depend on attack, defence, resistance, elemental advantage, quest modifiers and randomness. API-derived unit stats are still encrypted and are not included here. Probability and duration fields are preserved in their native scale until their denominators/units are verified.
