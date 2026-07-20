# Initial DotAbyss technical findings

Date: 2026-07-12

## Confirmed architecture

- Browser client: Unity WebGL with IL2CPP.
- Official resource/API host: `api.abyss-prod.dotabyss.dmmgames.com`.
- Addressables build observed at version directory `resources/webgl/normal/aas/5653/aa/`.
- Core build files: `WebGL.loader.js`, `WebGL.framework.js.br`, `WebGL.wasm.br`, and `WebGL.data.br`.
- API responses use `application/octet-stream` and appear encrypted or randomized; repeated endpoint responses do not share a stable plaintext prefix.
- Battle assets and calculations are substantially client-side. A battle sample loaded enemy/unit, timeline, shield, stage, sound, cut-in, and UI bundles while only a small number of server endpoints were involved.

## Captured API routes

- `/api/idle-exploration`
- `/api/quest/top`
- `/api/main-story/update-sequence`
- `/api/main-story/start-battle`
- `/api/main-story/clear`

Raw captures are intentionally excluded from Git because they may contain account-specific state.

## Extracted IL2CPP inputs

The decompressed `WebGL.data` uses the `UnityWebData1.0` archive format and contains:

- `data.unity3d` — 47,425,152 bytes
- `RuntimeInitializeOnLoads.json` — 9,312 bytes
- `ScriptingAssemblies.json` — 7,273 bytes
- `boot.config` — 114 bytes
- `Il2CppData/Metadata/global-metadata.dat` — 29,692,536 bytes
- `Resources/unity default resources` — 1,632,004 bytes

The paired decompressed WebAssembly binary is 74,114,239 bytes. The metadata lists the main game assembly as `Project.dll`; it also includes `MessagePack`, `Absl.Cryptography`, `Absl.CryptedPrefsIO`, Arbor/behavior-tree assemblies, and Unity Addressables.

## Relevant names recovered from metadata

Early string indexing found names including:

- `AbilityAppendSkillAbilityEffectId`
- `BuffSourceType`
- `SkillActionSourceType`
- `ManaGem`
- `StageEnemy`
- `DefensiveUnit`
- `AllCharacterTimelineEffectValueCatalog`
- `AllEnemyTimelineEffectValueCatalog`
- `AbilityEffectAssetCatalog`
- `Popup_EnemyDetail`
- `Popup_List_SpecialEffect`
- `Popup_List_SupplyBuff`

These names strongly suggest that attack timing and effect magnitudes are represented in client metadata/assets and can be mapped once IL2CPP method/type reconstruction is complete.

## Next analysis steps

1. Run a WASM-capable IL2CPP analysis tool against `WebGL.wasm` and `global-metadata.dat`.
2. Export `Project.dll` type/method/field mappings and search for damage, Mana, status, timeline, and enemy calculations.
3. Parse relevant Unity AssetBundles and associate numeric records with recovered types.
4. Compare calculated values against multiple battle samples to identify random ranges and rounding rules.
5. Publish only scripts, schemas, derived tables, and documented formulas—never raw authenticated captures.

## Cpp2IL result

Cpp2IL `2022.1.0-pre-release.21` successfully identified Unity `6000.3.8f1`, IL2CPP metadata version 39, the WASM code registration at `0x6CCD28`, the metadata registration at `0x4D5B14`, and mapped 208,675 method definitions.

The recovered type index confirms the damage pipeline:

1. `AttackCalculator.Calculate`
2. `DefenceCalculator.Calculate`
3. `UnitDamageCalculator.Calculate`

`UnitDamageCalculator` then exposes these named modifiers:

- `DamageModifier`
- `ElementResistanceModifier`
- `QuestModifier`
- `RandomModifier`
- `WeaknessElementAdvantageModifier`

Related calculators include fixed damage, current/max HP ratio damage, barriers, Mana Gem attack/damage/power multipliers, unit power multipliers, and stack-linked power multipliers.

Relevant effect classes include `AbilityChargeMana`, `AbilityEffectStageFieldManaGainDown`, `AbilityGraduallyBuffDeBuff`, `AbilityBuffApply`, `AbilityHpLinkedBuff`, and `AbilityStackLinkedBuff`. Buff parameter references explicitly use `Permille` naming, indicating many percentage-like effects are stored in thousandths.

### Current limitation

Cpp2IL can recover types and signatures for this build, but its IL recovery and WASM mapping outputs fail on parts of Unity 6.3 metadata version 39. Generated method bodies are placeholders, so numeric constants, operation order, random range, and rounding behavior are **not yet verified**. These must be recovered by a newer WASM analysis path or inferred from assets plus controlled battle samples.

## Normal-attack extraction

The 2026-07-15 AssetRipper export contains 90 playable-character prefabs. `parse-normal-attacks.ps1` follows each prefab's `_actionNormal` reference and recursively walks its attack timeline, including nested `ActionSkill` group tracks.

- 64/64 standard combat normal attacks have an observed hit or projectile-launch event.
- Melee timing comes from `Hit Damage Skill Track` and represents direct hit time.
- Ranged timing comes from `Fire Skill Track` and represents projectile launch time, not landing time.
- Healing normals, mining actions, and units without `_actionNormal` remain classified separately rather than being counted as zero-damage attacks.
- Character `101501000G` uses a nested `ActionSkill`; recursive traversal recovers one direct hit at 0.95 seconds.

Output files:

- `normal-attack-output/normal-attacks-summary.csv`
- `normal-attack-output/normal-attacks-summary.json`
- `character-gallery/gallery.html` (normal-attack data joined to character images)

### Damage-ratio limitation

The exported `HitDamageSkillClip` and `DamageSkillClip` assets do not contain their nested `parameter`/`damage` values. The AssetRipper log identifies the input as the `Unknown` scripting backend at `ScriptContentLevel: Level2`, even though Cpp2IL recovered the corresponding `Project.dll` type definitions. Therefore segment counts and timings are verified, but exact per-segment attack ratios must not be claimed from this export. A later import that successfully binds the recovered assemblies, or controlled in-game damage samples, is required to recover/fit those ratios.
