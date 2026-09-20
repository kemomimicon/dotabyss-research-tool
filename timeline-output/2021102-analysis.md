# Enemy 2021102 timeline analysis

Source: `EnemyTimelineEffectValueAsset_2021102_0` through `_3`, captured from the Easy battle and exported with AssetRipper.

## Structure

- 8 actions: `Attack001`, `Attack002`, `Inferno`, `FireRain`, `FlameCure`, `AssaultSkill`, `AssaultSkillFailure`, `ModeChange`.
- Each asset contains 10 variants. The observed parameter values are identical across all 10 variants; `VariantIndex` is not a hit number.
- Configurations `_0` and `_1` are parameter-identical. `_2` and `_3` add/strengthen mechanics.

## Main damage/effect parameters

| Action | Parameter | `_0` / `_1` | `_2` | `_3` |
|---|---:|---:|---:|---:|
| Attack001 projectile landing | Damage percent | 100 | 100 | 100 |
| Attack001 projectile landing | Hit count | 1 | 1 | 1 |
| Attack001 projectile landing | Target count | 1 | 1 | 1 |
| Attack001 projectile landing | Abnormal apply value | 300 | 300 | 300 |
| Attack001 projectile landing | Abnormal duration | 20 | 20 | 20 |
| Attack002 | Damage percent | 180 | 200 | 220 |
| Attack002 | Hit count | 1 | 1 | 1 |
| Inferno | Damage percent | 250 | 275 | 300 |
| Inferno | Hit count | 1 | 1 | 1 |
| Inferno | Abnormal apply value | 500 | 600 | 700 |
| Inferno | Abnormal duration | 40 | 40 | 40 |
| FireRain | Damage percent | 150 | 165 | 180 |
| FireRain | Hit count | 1 | 1 | 1 |
| FireRain | Target count | 4 | 4 | 4 |
| AssaultSkill | Damage percent | 200 | 200 | 200 |
| AssaultSkill | HP-ratio percent | 5 | 5 | 5 |
| AssaultSkill | Damage limit | 0 | 0 | 0 |
| AssaultSkill | Hit count | 1 | 1 | 1 |
| AssaultSkill | Abnormal apply value | 2000 | 2000 | 2000 |
| AssaultSkill | Abnormal duration | 60 | 60 | 60 |
| ModeChange | Abnormal apply value | 800 | 800 | 1000 |
| ModeChange | Abnormal duration | 60 | 60 | 60 |
| ModeChange | `DAMAGEDOWN.FIXED_PERCENT` | absent | 150 | 300 |
| ModeChange | `DAMAGEDOWN.DURATION` | absent | 0.02 | 0.02 |

## Interpretation cautions

- `DAMAGE_PERCENT` values strongly resemble percentage multipliers, but the final damage equation still contains attack, defence, resistance, quest, random and elemental modifier stages.
- `APPLY_PROBABILITY` appears to use a scaled integer rather than a literal percentage. Do not publish `2000` as “2000%” until its denominator is verified experimentally or from recovered code.
- Durations may be seconds, ticks, timeline units or another game-specific unit. Preserve raw values in research data.
- `ModeChange`'s `DAMAGEDOWN` name suggests a damage-taken modifier, but whether 150/300 means 15%/30%, 150%/300%, or another scale is not yet proven.
- The Easy battle used enemy resource ID `2021102` and stage resource `2003`. This is visually the same boss as the previously investigated main-story boss, but its numeric configuration must not be assumed identical to enemy `2031101`.

The complete raw normalized tables are the adjacent CSV/JSON files for configurations `_0` through `_3`.
