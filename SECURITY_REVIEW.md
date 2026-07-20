# 发布前敏感信息检查

检查日期：2026-07-19

## 检查范围

- PowerShell、Markdown、HTML、JavaScript、CSS、CSV 与 JSON 文件
- 认证请求头、Cookie、Bearer/JWT、访问与刷新令牌、会话值、密码、API 密钥
- DMM/玩家/账号标识、邮箱、本机用户名与绝对路径
- 浏览器配置、网络抓包、运行日志和原始主数据缓存

## 处理结果

- 已移除 `extract-master-response.ps1` 中硬编码的 Base64 应用密钥。
- 应用密钥现在只能通过 `-AppKeyBase64` 参数或本机环境变量
  `DOTABYSS_APP_KEY_BASE64` 提供。
- 已移除 `parse-fc-targets.ps1` 中的本机 D 盘绝对路径，改用项目相对路径。
- 已将整个 `master-data-output/`、所有 `*.dat`、浏览器配置、抓包和日志加入
  `.gitignore`。

## 最终静态扫描

以下项目在准备发布的文件中均为 0：

- 硬编码 Base64 应用密钥
- JWT/Bearer 令牌
- 认证或 Cookie 固定值
- Token、Session、玩家或账号查询参数
- 本机用户名与绝对工作目录

脚本中的 `sessionId` 仅为运行时 Chrome DevTools Protocol 会话变量，不是 DMM
账号会话凭据。

## 禁止提交

- `.edge-research-profile/`
- `captures/`
- `master-data-output/`
- `*.log`
- `*.dat`
- 任何手工保存的 Cookie、请求头或浏览器导出文件

如果这些文件曾在未来的 Git 仓库中被强制添加或提交过，单独修改 `.gitignore`
并不能清除历史记录；发布前应再次检查暂存文件列表与 Git 历史。
