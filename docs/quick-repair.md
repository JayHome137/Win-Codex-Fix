# 快速决策

1. 在 Codex 外的 PowerShell 7 执行维护项目中的 `scripts\Invoke-CodexDesktopQuickRepair.ps1 -Route Auto` 一次。
2. 输出 `current state is already healthy`：结束，不重启。
3. 输出 `pending-natural-exit`：先取得明确授权，再对同一路由加 `-ArmAfterExit`；不要手动重复执行。
4. 输出 `repair and quick verification passed`：结束；Codex、Chrome、Edge 保持当前状态。
5. 输出 `manual-required` 或 `selected route failed`：停止并保留现场，不叠加其它修复。

一次性续跑示例（仅在明确授权后执行）：

```powershell
$root = 'C:\Codex\projects\codex-desktop-repair'
pwsh.exe -NoProfile -NonInteractive -File "$root\scripts\Invoke-CodexDesktopQuickRepair.ps1" -Route BrowserCacheOnly -ArmAfterExit
```

续跑会绑定当前实际占用者，等待退出事件，自动执行一次同一路由并删除自身任务；未授权时不会创建任务。

显式 route 仅在错误 owner 已明确时使用：`CliMirrorOnly`、`RuntimeOnly`、`BrowserDiscoveryOnly`、`BrowserCacheOnly`、`TmpRuntimeMarketplaceOnly`、`Verify`。
