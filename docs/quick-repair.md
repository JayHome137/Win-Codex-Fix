# 快速决策

1. 在 Codex 外的 PowerShell 7 执行维护项目中的 `scripts\Invoke-CodexDesktopQuickRepair.ps1 -Route Auto` 一次。
2. 输出 `current state is already healthy`：结束，不重启。
3. 输出 `pending-natural-exit`：必须提示“当前路由无法热修”并指出实际占用者；先取得明确授权，再对同一路由加 `-ArmAfterExit`；不要手动重复执行。
4. 输出 `repair and quick verification passed`：结束；Codex、Chrome、Edge 保持当前状态。
5. 输出 `manual-required` 或 `selected route failed`：停止并保留现场，不叠加其它修复。

一次性续跑示例（仅在明确授权后执行）：

```powershell
$root = 'C:\Codex\projects\codex-desktop-repair'
pwsh.exe -NoProfile -NonInteractive -File "$root\scripts\Invoke-CodexDesktopQuickRepair.ps1" -Route BrowserCacheOnly -ArmAfterExit
```

续跑会绑定当前实际占用者，等待退出事件，自动执行一次同一路由并删除自身任务；未授权时不会创建任务。

如果占用者已经自然退出，直接重跑同一路由，不使用 `-ArmAfterExit`。任何 `manual-required`、`selected route failed` 或无法确认唯一 owner 的结果，都要明确提示未完成并停止。

显式 route 仅在错误 owner 已明确时使用：`CliMirrorOnly`、`RuntimeOnly`、`BrowserDiscoveryOnly`、`BrowserCacheOnly`、`BrowserNativeHostOnly`、`EdgeNativeHostOnly`、`ChromeAppServerBootstrapOnly`、`ComputerUseCacheOnly`、`TmpRuntimeMarketplaceOnly`、`Verify`。`ChromeAppxBootstrapOnly` 保留为兼容旧名。`TmpRuntimeMarketplaceOnly` 只在 Codex 稳定退出后刷新落后的 `.tmp\\bundled-marketplaces\\openai-bundled` 主机副本。

`CliMirrorOnly` 同步当前 AppX 的 `codex.exe` 与 `codex-code-mode-host.exe` 配对；Code Mode IPC 报错若发生在 probe 启动前，优先只走这条路由。

`BrowserNativeHostOnly` 是热修路由：从当前 AppX 读取扩展 ID，只同步 legacy manifest、Google Chrome HKCU 映射和两份 v2 manifest，不关闭或重启 Codex、Chrome、Edge，也不修改 cache、junction、runtime、CLI mirror、配置或任务。实际写入前保留回滚副本，任一步失败即恢复原状态。

`EdgeNativeHostOnly` 是独立的 Edge 注册表路径修复：仅在当前 Edge 用户配置中确实存在目标扩展、而 `HKCU\Software\Microsoft\Edge\NativeMessagingHosts` 缺失或指向错误时，将共享 native-host manifest 路径写入 Edge 键。它不改 Chrome 键、manifest、cache、junction、runtime、CLI mirror 或进程；写前保留注册表回滚副本。

`ChromeAppServerBootstrapOnly` 是另一条独立路径（旧名 `ChromeAppxBootstrapOnly`）：直接使用当前 AppX Chrome 文件和其自带的 `installManifest.mjs`，重建 Chrome app-server bootstrap 链，不调用 marketplace add/remove，也不触碰 Browser/Computer Use cache。成功后只验证这条 Chrome 链路；其它层的失败不会被伪装成整体修复。

`ComputerUseCacheOnly` 是独立的 AppX 直同步路径：只同步当前 Computer Use 插件实体目录和 `latest`/`.codex-plugin` 链接，不修改 `cua_node` 运行时、`config.toml` 或 marketplace。
