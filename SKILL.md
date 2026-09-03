---
name: codex-desktop-bundled-repair
description: Windows Codex Desktop 更新后的快速、一次性热修。按验证结果只调用一个既有修复路由；不默认关闭或重启 Codex、Chrome、Edge，也不启动长时间轮询。Code Mode IPC/CLI mirror 问题只处理当前 AppX 的 CLI 与 code-mode host 配对。
---

# Codex Desktop 快速热修

从维护项目的 `scripts` 目录运行 `Invoke-CodexDesktopQuickRepair.ps1 -Route Auto`。

每次更新只执行一次 `Auto`：同步当前 AppX 的 CLI mirror 配对（`codex.exe` 与 `codex-code-mode-host.exe`），运行一次 Quick verifier；若失败，按输出选择一个已知路由，并在该路由后做对应的最小校验。一个路由失败就停止，不串联其它层，也不重复运行。

已知路由：

- `CliMirrorOnly`：只修复当前 AppX 的 CLI/code-mode host 配对。退出 `30` 表示配对中的目标文件被使用，等待自然退出后重跑同一路由。
- `RuntimeOnly`：只修复 `cua_node`/`node_repl` 运行时。
- `BrowserDiscoveryOnly`：只修复 Browser `latest` 与 `.codex-plugin` 发现链接。
- `BrowserCacheOnly`：只恢复当前 AppX Browser cache。
- `BrowserNativeHostOnly`：以当前 AppX 的复数扩展 ID 为真源，只修复 legacy manifest、Chrome HKCU 映射和两份 v2 manifest；默认热修，不关闭 Codex、Chrome 或 Edge。写入前保留同一事务的回滚副本，任一步失败即恢复。
- `EdgeNativeHostOnly`：仅在当前 Edge profile 确实安装了目标扩展、且 Edge 专用 HKCU NativeMessagingHosts 键缺失或漂移时，单独补齐 Edge 注册表映射；不改 Chrome 键、共享 manifest、缓存、runtime 或进程。
- `ChromeAppServerBootstrapOnly`：处理 `nodePath`、`resourcesPath`、`nodeModuleDirs`、`nodeReplPath` 或 `node_repl` 报错；从当前 AppX 重建 Chrome app-server bootstrap 链。`ChromeAppxBootstrapOnly` 是同一路由的兼容旧名；不触碰 Browser/Computer Use cache，不关闭 Codex、Chrome 或 Edge。
- `ComputerUseCacheOnly`：绕过 marketplace，直接从当前 AppX 同步 Computer Use 插件 cache 与发现链接；不修改 `cua_node` 运行时、配置或其它插件。
- `UiCapabilityDiagnosticOnly`：当 Quick 全绿但 UI 仍缺少 In-app Browser/Computer Use 时，读取本地能力开关并区分本地配置与服务端/账户 feature gate；只读，不伪造能力。
- `TmpRuntimeMarketplaceOnly`：只刷新已确认落后于当前 AppX 的 `.tmp\bundled-marketplaces\openai-bundled` 主机临时副本；需要 Codex Desktop 稳定退出，完成后再启动一次让新插件生效。
- `Verify`：只运行一次 Quick verifier。

当 Quick 已全绿、但 In-app Browser 或 Computer Use 仍不显示时，先运行 `UiCapabilityDiagnosticOnly`，不要重复缓存、marketplace 或 full repair。`feature-gate-or-policy`、`runtime-gate-unresolved` 或退出码 `10` 表示问题超出本地文件修复范围；只有 `local-capability-ready` 才值得让用户重新创建任务并观察真实 UI。探针不会修改配置、Statsig/账户开关或进程。

不要手工把多个路由串在一起。`Auto` 遇到上述 app-server 路径或 `node_repl` 错误时选择 `ChromeAppServerBootstrapOnly`；无法识别唯一 owner 时返回 `manual-required`，不猜测、不升级为全量修复。

## Code Mode IPC 边界

当 Code Mode 在 probe 启动前报告 `codex-code-mode-host.exe` 缺失、版本漂移或 IPC 初始化失败，先把它归类为 CLI mirror 配对问题，不推断为 Browser、Chrome、`node_repl` 或 marketplace 故障。使用外部 PowerShell 执行一次：

```powershell
pwsh.exe -NoProfile -NonInteractive -File '.\scripts\Repair-CodexDesktopBundled.ps1' -CliMirrorOnly
```

该路由只从最高版本的当前 AppX 同步 `codex.exe` 与 `codex-code-mode-host.exe`，逐个校验长度和 SHA-256，并在写入前后保持同一配对事务。返回 `0` 后创建新任务重试；返回 `30` 时等待实际占用者自然退出，再重跑相同命令。任何其它退出码都是 `source/mirror-failed`，应停止并保留现场。不要为了 Code Mode IPC 错误关闭、杀掉或重启 Codex、Chrome、Edge，也不要串联其它路由。

## 关闭/重启规则

默认不关闭、不杀、不 reload、不重启任何应用。只有返回 `pending-natural-exit`（或退出码 `20`/`30`），并明确指出目标文件被进程占用时，才在当前会话询问一次是否授权退出 Codex 后自动续修。得到明确授权后，使用同一路由加 `-ArmAfterExit`；它只记录当前占用者并建立一次性续跑，等待该特定进程的退出事件后自动重跑一次并自清理。未授权时不会创建任务；普通关闭 Codex 不会触发。Chrome/Edge 默认不需要关闭。

当选定路由没有可用的热修条件，或进程保护返回 `pending-natural-exit`、`20`、`30` 时，必须明确提示“当前路由无法热修”，同时说明实际占用者、需要退出的对象和下一步。不得把等待、跳过写入或失败输出描述成已修复，也不得自动切换到其它路由。若目标进程已经自然退出，直接重跑同一路由，不创建无主的续跑任务。

## 边界

本包只包含当前正式入口、其直接依赖和快速验证脚本。它不包含账号、审计快照或运行日志；项目根目录和 Skill 安装目录均由安装参数或 Windows 用户环境推导。公开仓库中的路径示例使用占位符；实际 Windows 项目路径以本机安装参数为准。
