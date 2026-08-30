# 共建与反馈规则

本仓库允许先收集真实用户反馈，再用静态检查、可控 fixture 和最小范围的 Windows 现场验证逐步确认。用户反馈是重要线索，但不自动等同于“已复现”或“已修复”。

## 先看结论

- `main` 只放已经完成足够验证的修复路由、测试和文档。
- 无法在真实 Windows Codex/AppX 环境验证的改动，可以留在候选分支、fixture 或只读诊断中，但必须明确标注状态。
- 不同用户、版本和浏览器组合不可能全部在实机覆盖；缺少实机条件时，先保留证据和最小复现，不夸大结论。
- 反馈、日志和截图必须脱敏，仓库不接收 token、Cookie、密码、会话数据库或机器专属数据。

## 证据等级

| 标记 | 含义 | 可以得出的结论 |
| --- | --- | --- |
| `user-reported` | 用户在实际环境观察到问题，并提供了脱敏描述或输出 | 证明问题线索真实存在；不能单独证明修复成功 |
| `static/contract-verified` | 代码路径、调用关系、PowerShell AST 或契约检查通过 | 可以作为候选实现；不能声称真实环境已恢复 |
| `fixture-verified` | 用可控 fixture 覆盖了分类、漂移、回滚或写后校验 | 可以合并测试和诊断辅助代码；不能单独把路由标为稳定 |
| `windows-live-verified` | 在真实 Windows Codex/AppX 环境完成写前证据、最小写入、写后验收和最小运行验证 | 修复路由才可以进入 `main`，并允许 `Auto` 选择 |

验证范围不足时，保留较低等级，不向上跳级。

## 发布状态

- **`main / stable`**：行为性修复至少有一次 `windows-live-verified`，并在文档中写明版本、范围和未覆盖部分。
- **候选分支**：可以包含用户反馈对应的实现、fixture 和 focused tests，但未完成现场验证前不进入 `main`，也不由 `Auto` 自动调用。
- **`diagnostic-only`**：只读探针或分类逻辑，只能用于收集证据，不得描述为修复。
- **`known-unverified`**：记录问题、假设、当前证据和下一步；不能使用“已解决”等措辞。

文档、测试或注释类改动可以独立合并，但不能借此把未验证的行为性修复标成稳定。

## 反馈处理流程

1. **提交 Issue**：使用 [Bug 反馈模板](.github/ISSUE_TEMPLATE/bug-report.md)，不要求每个字段都能在本地复现；无法复现时明确填写 `user-reported`。
2. **脱敏与归类**：维护者先删除敏感信息，再把反馈归类为新 Bug、已知 Bug 的新证据、环境差异、旧代码残留或暂时无法复现。
3. **建立最小证据**：能抽象时先添加最小 fixture、静态检查或契约断言；不要为了“跑通”而串联无关路由或增加长期轮询。
4. **候选验证**：实现保持单一路由、最小写入和失败可回滚；在候选分支记录证据等级及未验证范围。
5. **现场升级**：有条件时在真实 Windows 环境执行对应 focused verification。只有达到 `windows-live-verified`，才把行为性修复合并到 `main`。
6. **回写结果**：在 Issue/PR 中写明实际验证了什么、没有验证什么，以及用户下一步应执行的最小命令或路由。

## Issue 至少应提供

- Codex Desktop / AppX 版本、Windows 版本与架构；
- 触发时间，以及更新前后发生了什么变化；
- 完整错误文本（可脱敏）；
- 已执行的路由、退出码和关键结果；
- Chrome、Edge、Codex 是否正在运行，是否存在文件占用提示；
- 脱敏后的最小输出或截图；
- 期望结果与实际结果。

不要提交以下内容：

- token、密码、Cookie、Authorization 头或私钥；
- 用户目录中的完整路径、session、数据库、账号信息或机器识别信息；
- 未脱敏的完整日志、诊断压缩包或屏幕截图。

可以用 `<USERPROFILE>`、`<VERSION>`、`<REDACTED>` 等占位符替换敏感部分。若不确定是否敏感，先删掉再提交。

## Pull request 要求

- 一个 PR 只处理一个可归因的问题或一项文档规则；
- 说明修改的入口、证据等级、验证命令和结果；
- 没有 Windows 实机时，明确写 `known-unverified` 或 `fixture-verified`，不要写“已修复”；
- 不引入与问题无关的 fallback、闸门、轮询、备份或重启逻辑；
- 失败路径必须停止并保留现场，不能用连续补丁掩盖 owner 不明的问题。

## English summary

User reports are welcome, but a report is evidence of a symptom—not proof that a fix works. We use four evidence levels: `user-reported`, `static/contract-verified`, `fixture-verified`, and `windows-live-verified`. Behavior-changing repair routes enter `main` only after the last level is reached; otherwise they stay on a candidate branch or remain diagnostic-only/known-unverified. Every issue or pull request must state the affected Codex/AppX and Windows versions, trigger, redacted output, route/exit status, process-ownership details, and the exact verification scope. Never upload secrets, cookies, session data, private paths, or raw machine logs.
