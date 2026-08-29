---
name: codex-desktop-bundled-repair
description: Windows Codex Desktop 更新后的快速、一次性热修。按验证结果只调用一个既有修复路由；不默认关闭或重启 Codex、Chrome、Edge，也不启动长时间轮询。
---

# Codex Desktop 快速热修

从维护项目的 `scripts` 目录运行 `Invoke-CodexDesktopQuickRepair.ps1 -Route Auto`。

每次更新只执行一次 `Auto`：同步当前 AppX 的 CLI mirror，运行一次 Quick verifier；若失败，按输出选择一个已知路由，并在该路由后再校验一次。一个路由失败就停止，不串联其它层，也不重复运行。

已知路由：

- `CliMirrorOnly`：只修复 CLI mirror。退出 `30` 表示目标文件被使用，等待自然退出后重跑同一路由。
- `RuntimeOnly`：只修复 `cua_node`/`node_repl` 运行时。
- `BrowserDiscoveryOnly`：只修复 Browser `latest` 与 `.codex-plugin` 发现链接。
- `BrowserCacheOnly`：只恢复当前 AppX Browser cache。
- `BrowserNativeHostOnly`：只修复当前 Chrome 扩展身份对应的 legacy manifest、Chrome HKCU 映射和两份 v2 manifest；支持 `extension-ids.json` 的复数 ID，默认热修，不关闭 Codex、Chrome 或 Edge。
- `TmpRuntimeMarketplaceOnly`：只修复已确认的旧临时 marketplace 所有权问题。
- `Verify`：只运行一次 Quick verifier。

不要手工把多个路由串在一起。`Auto` 无法从 verifier 输出识别唯一 owner 时返回 `manual-required`，不猜测、不升级为全量修复。

## 关闭/重启规则

默认不关闭、不杀、不 reload、不重启任何应用。只有返回 `pending-natural-exit`（或退出码 `20`/`30`），并明确指出目标文件被进程占用时，才在当前会话询问一次是否授权退出 Codex 后自动续修。得到明确授权后，使用同一路由加 `-ArmAfterExit`；它只记录当前占用者并建立一次性续跑，等待该特定进程的退出事件后自动重跑一次并自清理。未授权时不会创建任务；普通关闭 Codex 不会触发。Chrome/Edge 默认不需要关闭。

## 边界

本包只包含当前正式入口、其直接依赖和快速验证脚本。它不包含机器专属路径、IP、账号、审计快照或运行日志；项目根目录和 Skill 安装目录均由安装参数或 Windows 用户环境推导。
