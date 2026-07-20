# DotAbyss Research Tool

用于整理《DotAbyss》浏览器客户端发送到本机的游戏资源和主数据，辅助攻略组研究角色、敌人、动作循环、攻击段数、Mana、Buff/Debuff 与基础伤害逻辑。

## 当前成果

- 61 名角色及基础属性。
- 普攻循环、可观察命中/投射物事件和时间轴。
- 151 个角色小技能；完整的 1–10 级描述、觉醒阶段、效果段、目标、触发场景、作用范围和解锁条件。
- FC 主数据及 59/61 个技能级初始选敌配置。
- 敌方时间轴与效果值解析脚本。
- 角色图片画廊。

详细覆盖率与技术边界见 [`small-skill-output/STATUS.md`](small-skill-output/STATUS.md)。

## 小技能数据

主查表文件是：

```text
small-skill-output/character-small-skills-long.csv
```

一行代表“角色 × 小技能 × 觉醒阶段 × 等级 × 效果段”。常用字段：

- `CharacterName`、`SkillName`、`Level`、`Description`
- `EffectAssetId`、`EffectValue`、`EffectTypeName`
- `RuntimeEffectCode`：效果代码
- `TargetCode`：对象代码
- `SituationCode`：触发场景代码
- `ScopeCode`：作用范围代码
- `ReleaseConditions`：解锁等级、条件类型和值

主数据的实际配置为：

- 稀有度 1：16 名角色，每名 2 个小技能
- 稀有度 2：16 名角色，每名 2 个小技能
- 稀有度 3：29 名角色，每名 3 个小技能

因此 151 个技能是完整数量，并非 61 × 3。

重新解析：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\parse-ability-effects.ps1 `
  -AssetsDirectory C:\path\to\ExportedProject\Assets

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\parse-small-skill-master.ps1 `
  -MasterFile C:\path\to\download-cache.dat
```

## FC 数据

技能级选敌信息位于：

```text
small-skill-output/character-fc-targets.csv
fc-target-output/fc-and-action-skill-targets.csv
```

`TargetType` 枚举：`0=AllBattlers`、`1=Opponent`、`2=Friend`、`3=Self`、`4=DeadFriend`。

注意：技能内部每个伤害/Buff 片段的二级对象和执行条件保存在 IL2CPP `SerializeReference` 嵌套字段中。现有导出没有恢复全部嵌套值，不能把技能级初始选敌误称为片段级完整条件。

## 其他解析器

```powershell
.\parse-timeline.ps1 -AssetFile C:\path\EnemyTimelineEffectValueAsset_x.asset
.\parse-normal-attacks.ps1 -ExportDirectory C:\path\to\ExportedProject
.\parse-fc-targets.ps1 -AssetsDirectory C:\path\to\ExportedProject\Assets\MonoBehaviour
```

## 安全与发布

- 仅研究你有权访问的账号和客户端数据。
- 工具不绕过登录、付费、加密或服务器权限控制。
- 不要提交 Cookie、Authorization、Token、Session、玩家 ID、浏览器配置、完整抓包或原始主数据缓存。
- 对外发布前检查 CSV/JSON 是否含昵称、账号标识或其他个人信息。
- `extract-master-response.ps1` 所需应用密钥必须通过 `-AppKeyBase64` 或本机环境变量 `DOTABYSS_APP_KEY_BASE64` 提供，不得写入仓库。
- AssetRipper 是免费开源软件，本项目没有所谓“付费版”依赖。

最近一次静态检查结果见 [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md)。

## 权利声明

MIT 许可证只覆盖本仓库原创的脚本、文档和辅助代码，不覆盖游戏名称、文本、
数值、图像或其他提取素材。游戏素材的权利归相应权利人所有，详情见
[`ASSET_NOTICE.md`](ASSET_NOTICE.md)。
