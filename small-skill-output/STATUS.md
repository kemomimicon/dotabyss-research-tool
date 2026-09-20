# 角色小技能与 FC 数据状态

更新时间：2026-09-19（WebGL 资源版本 9533）

## 已完成

- 主数据角色：72 名。
- 小技能：184 个。其中稀有度 1 的 16 名角色和稀有度 2 的 16 名角色各有 2 个；稀有度 3 的 40 名角色各有 3 个。这是主数据的实际配置，不是漏抓。
- 已导出全部小技能的 1–10 级描述、觉醒阶段、效果值、效果类型和解锁条件。
- 运行时效果：8,150 个“技能等级 × 效果段”记录，目标代码关联率 100%。
- 直接按 Unity PathID 解析了两个目录中的 716 个效果资源和 2,344 条子资源引用：主技能目录 559 个/1,716 条，NetherCode 目录 157 个/628 条。数值 ID 重复时也不会互相覆盖，且未发现缺失引用；嵌套条件和参数保存在 `ParametersJson`。
- 客户端效果包含 `Effect`、`Target`、`Situation`、`Scope`；服务端结算效果明确标为 `ServerSide / MasterData`。
- FC：72 个角色均已关联主数据；63 个已恢复技能级初始选敌信息。

## 主要输出

- `character-small-skills-long.csv/json`：面向查表的完整小技能长表。
- `m_character_abilities.csv/json`：角色与小技能的关联。
- `m_abilities.csv/json`：一个技能拆分出的效果段。
- `m_ability_details.csv/json`：各觉醒阶段、各等级的描述。
- `m_ability_releases.csv/json`：技能解锁条件代码。
- `ability-effect-assets.csv/json`：运行时效果、对象、触发场景与范围的宽表。
- `ability-effect-subassets.csv/json`：运行时子资源及完整参数。
- `nether-code-ability-effect-assets.csv/json`、`nether-code-ability-effect-subassets.csv/json`：与主技能目录隔离的 NetherCode 效果，避免相同数值 ID 冲突。
- `character-fc-targets.csv/json`：FC 主数据与技能级初始选敌信息。
- `small-skill-coverage.json`：覆盖率摘要。

## 已知边界

- `メリッサ` 的额外掉落效果（效果 20288）由服务端主数据结算，没有客户端 Target 资源，已显式标成 `ServerSide / MasterData / Server:Support`，不是缺失。
- 9 个 FC 的 `UnitSkillAsset` 尚未出现在现有角色资源导出中，因此技能级选敌字段仍为空；名单可由 `character-fc-targets.csv` 的空 `TargetTypeName` 筛出。
- 小技能 `AbilitySubAsset` 的 `SerializeReference` 嵌套字段现已由 UnityPy 完整保留。FC 内部片段仍依赖各角色 `UnitSkillAsset`，未捕获的资源不会凭空推断。
- 原始 `download-cache.dat`、浏览器配置和抓包不应发布到 GitHub；公开时只提交脚本、脱敏后的 CSV/JSON 和文档。
