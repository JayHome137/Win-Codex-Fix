<div align="center">

# 🧰 Win-Codex-Fix

**面向 Windows Codex Desktop 更新后故障的一次性、证据驱动热修 Skill。**

![Platform](https://img.shields.io/badge/platform-Windows_10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![Architecture](https://img.shields.io/badge/architecture-x64-555555)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)
![Target](https://img.shields.io/badge/target-Codex_Desktop-111827)
![Type](https://img.shields.io/badge/type-Agent_Skill-7C3AED)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

</div>

> [!IMPORTANT]
> 本项目只适用于 **Windows x64 的 Microsoft Store / AppX 版 Codex Desktop**。不支持 macOS、Linux、网页版 Codex、ARM64 或未知安装格式。

## 📌 项目介绍

Codex Desktop 更新后，AppX 已经升级，但本地 CLI mirror、bundled Browser/Chrome、`node_repl`、`cua_node` 或插件发现链接有时仍指向旧版本。

Win-Codex-Fix 以当前已注册的 AppX 为真源，先做快速验证，再只运行一个能够明确归因的修复路由。状态健康时立即结束；无法确认唯一 owner 时返回 `manual-required`，不会把多个补丁串起来。

## ✅ 适用环境

| 项目 | 支持情况 | 说明 |
| --- | --- | --- |
| 操作系统 | Windows 10 / 11 | 仅支持 x64 |
| 目标应用 | Codex Desktop | Microsoft Store / AppX 版本 |
| PowerShell | 5.1 / 7 | 推荐从 PowerShell 7（`pwsh.exe`）启动；内部兼容 Windows PowerShell 5.1 |
| Chrome / Edge | 可选关联组件 | 默认无需关闭；仅在输出证明文件被占用时处理对应进程 |
| Python 3 | 可选 | 只用于独立的 session index 修复，不是 `Auto` 热修的必需依赖 |
| Git | 可选 | 仅克隆和更新仓库时需要 |

运行前应使用安装 Codex Desktop 的同一 Windows 用户，并确认系统中能够找到 `OpenAI.Codex` AppX 包。

## 🎯 能修什么

- bundled Browser、Chrome 或 Computer Use 组件无法发现或启动；
- Code Mode 在 probe 前出现 `codex-code-mode-host.exe` 缺失、版本漂移或 IPC 初始化失败；
- 本地 CLI mirror 与当前 AppX 版本不一致；
- `node_repl`、`cua_node` 的运行时或资源路径漂移；
- Browser cache 的 `latest` / `.codex-plugin` 发现链接异常；
- Chrome 扩展 ID 更新后，legacy / v2 Native Host manifest 与 HKCU 映射仍指向旧身份或旧 AppX 资源；
- 已明确归属于旧临时 marketplace 的残留问题。

它不是通用重装器，也不会处理 macOS/Linux、账号登录、网络代理、服务端故障或无法归因的未知错误。

## 🚀 快速开始

克隆仓库：

```powershell
git clone https://github.com/JayHome137/Win-Codex-Fix.git
Set-Location .\Win-Codex-Fix
```

直接执行一次快速修复：

```powershell
pwsh.exe -NoProfile -NonInteractive -File .\scripts\Invoke-CodexDesktopQuickRepair.ps1 -Route Auto
```

`Auto` 的运行顺序固定为：同步 CLI mirror → Quick verifier → 最多一个匹配路由 → 对应层的最小验收。已经健康时不会修改其它组件，也不要求重启应用。

如果输出 `manual-required` 或 `selected route failed`，请保留现场并停止，不要手工串联多个路由。

## 🤝 共建与反馈

欢迎提交不同 Windows 版本、Codex/AppX 版本和浏览器组合下的反馈。**用户反馈是线索，不自动等同于已复现或已修复。** 无法准备 Windows 实机时，可以先提交 `user-reported`，由维护者用静态检查或最小 fixture 固化证据；行为性修复只有在真实 Windows 验证后才进入 `main` 和 `Auto`。

- 共建规则：[CONTRIBUTING.md](./CONTRIBUTING.md)
- Bug 反馈模板：[.github/ISSUE_TEMPLATE/bug-report.md](./.github/ISSUE_TEMPLATE/bug-report.md)

请只提交脱敏后的最小输出。不要上传 token、Cookie、密码、session、数据库、完整用户路径或未脱敏截图。

## 📦 安装为 Codex Skill

安装脚本会发布维护副本，并将 Skill 元数据复制到当前 Windows 用户的 Codex Skill 目录：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy\Install-FastRepair.ps1 `
  -StageRoot (Get-Location).Path `
  -ProjectRoot 'C:\Codex\projects\codex-desktop-repair'
```

未指定 `-InstalledSkillRoot` 时，默认安装到：

```text
%USERPROFILE%\.codex\skills\codex-desktop-bundled-repair
```

以后 Codex Desktop 更新后，可以直接让 Codex 使用 `codex-desktop-bundled-repair` Skill 执行一次 `Auto` 快速修复。更新本仓库后重新运行安装脚本，即可同步 Skill；安装过程本身不会关闭或重启 Codex、Chrome、Edge。

## ⚙️ 工作机制

```text
当前注册的 OpenAI.Codex AppX
              │
              ▼
       同步本地 CLI mirror
              │
              ▼
          Quick verifier
        ┌─────┴─────┐
      健康         已知 owner
       │              │
       ▼              ▼
     结束       单一路由最小修复
                      │
                      ▼
               Quick verifier
```

核心原则：

1. **AppX 是真源**：动态读取当前注册的最高版本，不依赖固定版本路径。
2. **先归因再修复**：只处理 verifier 能明确归属的 CLI、运行时、Browser discovery/cache、Chrome AppX bootstrap 或 marketplace 层。
3. **一次只走一条路**：路由成功或失败后都停止，不叠加无关 fallback。
4. **最小写入**：只修改目标层需要的 mirror、链接、manifest 或环境配置。
5. **可回滚提交**：Native Host 多文件更新会先保存原始字节与注册表默认值，任一步失败即恢复。
6. **写后复核**：立即检查哈希、长度、链接目标和关键资源是否与当前 AppX 一致。

## 🧭 修复路由

| 路由 | 用途 |
| --- | --- |
| `Auto` | 推荐入口；自动完成一次判断和最多一次修复 |
| `CliMirrorOnly` | 只同步当前 AppX 的 `codex.exe` 与 `codex-code-mode-host.exe` CLI 配对 |
| `RuntimeOnly` | 只修复 `cua_node` / `node_repl` 运行时 |
| `BrowserDiscoveryOnly` | 只修复 Browser 的 `latest` 和 `.codex-plugin` 链接 |
| `BrowserCacheOnly` | 只恢复当前 AppX Browser cache |
| `BrowserNativeHostOnly` | 只同步复数扩展 ID、legacy manifest、Chrome HKCU 映射与两份 v2 Native Host manifest；无需关闭 Codex、Chrome、Edge |
| `EdgeNativeHostOnly` | 仅在 Edge profile 已安装目标扩展且 Edge 专用 HKCU 注册表键缺失/漂移时补齐映射；不改 Chrome 或共享 manifest |
| `ChromeAppServerBootstrapOnly` | 处理 `nodePath` 等 app-server 路径错误；直接用当前 AppX Chrome 和官方 `installManifest.mjs` 重建 bootstrap 链 |
| `ChromeAppxBootstrapOnly` | `ChromeAppServerBootstrapOnly` 的兼容旧名 |
| `ComputerUseCacheOnly` | 不经过 marketplace，直接用当前 AppX 同步 Computer Use 插件 cache 与发现链接；不修改 `cua_node` 运行时 |
| `TmpRuntimeMarketplaceOnly` | 只刷新已确认落后于当前 AppX 的 `.tmp\bundled-marketplaces\openai-bundled` 主机临时副本；需要 Codex 稳定退出 |
| `Verify` | 只运行 Quick verifier，不写入 |

`ChromeAppServerBootstrapOnly`（旧名 `ChromeAppxBootstrapOnly`）只验证 Chrome app-server 链路本身：当前 AppX 文件集、cache 发现链接、官方 sidecar、legacy/v2 Native Host 和 HKCU 映射。Browser、Computer Use、CLI mirror 或 marketplace 的其它失败会单独报告，不会被伪装成“全部修复”。

`ComputerUseCacheOnly` 只验证 Computer Use 插件版本、实体文件和 `latest`/`.codex-plugin` 链接；`cua_node` 运行时漂移仍由 `RuntimeOnly` 单独负责。

显式路由只应在故障 owner 已经明确时使用。普通更新后优先运行一次 `Auto`。

## 🔥 热修与关闭规则

- 默认不关闭、不强杀、不 reload、不重启 Codex、Chrome 或 Edge。
- 大多数版本漂移可以在应用保持运行时完成热修。
- 只有输出明确返回 `pending-natural-exit`（或退出码 `20` / `30`）并指出目标文件被占用时，才需要关闭对应 owner。
- 如果当前路由不具备热修条件，必须明确提示“当前路由无法热修”，列出实际占用者、需要退出的对象和下一步；等待或失败不能描述为已修复。
- 获得明确授权后，`-ArmAfterExit` 只绑定当时实际占用的 PID；该 PID 自然退出后自动重跑同一路由并删除一次性任务。
- 普通关闭 Codex 不会误触发修复，也不会创建长期轮询任务。

## 📁 仓库内容

```text
SKILL.md                         Skill 触发条件与操作边界
CONTRIBUTING.md                  共建规则、证据等级与反馈处理流程
.github/ISSUE_TEMPLATE/           结构化 Bug 反馈模板
agents/openai.yaml               Codex 显示信息与默认提示
scripts/                         PowerShell、Python、VBS 实现
tests/                           Windows PowerShell 5.1 / 7 focused fixtures
deploy/Install-FastRepair.ps1    Windows 安装与更新脚本
docs/quick-repair.md             快速决策说明
BUNDLE-MANIFEST.sha256           发布文件 SHA-256 清单
LICENSE                          MIT 完整许可证文本
```

仓库只保留可复用代码和文档。机器路径、IP、账号、审计快照、同步记录、运行日志、`state/`、`archives/` 与用户数据都不属于公开发布包。

## 🔎 完整性校验

在 Git Bash、WSL 或其他提供 `sha256sum` 的环境中运行：

```bash
sha256sum --check BUNDLE-MANIFEST.sha256
```

也可以在 PowerShell 中单独查看文件哈希：

```powershell
Get-FileHash .\README.md, .\SKILL.md -Algorithm SHA256
```

## 📜 许可证

Copyright © 2026 JayHome137。

本项目以 **MIT License** 发布。你可以使用、研究、修改、合并、发布、分发、再许可和销售本项目及其衍生作品，但必须在副本或实质性部分中保留版权声明和许可声明。

完整条款见 [LICENSE](./LICENSE)。本项目不提供任何明示或暗示担保；厂商名称、产品名称与商标仍归各自权利人所有。

## ⚠️ 免责声明

本项目是针对 Codex Desktop 本地更新漂移的社区维护工具，并非 Microsoft、OpenAI、Google 或其他厂商的官方产品。修复前请阅读脚本输出；遇到未知 owner、AppX 缺失或写后验证失败时应停止并保留现场。
