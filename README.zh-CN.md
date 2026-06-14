# cc-monitor

> 一个 macOS 菜单栏状态监视器，实时显示 [Claude Code](https://docs.claude.com/claude-code) 的常驻上下文预算、记忆、git、引擎团队、skill 健康度。

[English](README.md) · **简体中文**

![cc-monitor — 状态 / 架构 / skills 三个 tab](docs/screenshot.png)

<sub>↑ 高保真界面复刻（数据全脱敏），从左到右：状态 / 架构 / skills 三个 tab。</sub>

## 它显示什么

菜单栏一个原生图标（健康时是仪表盘，超预算时变 ⚠️）。点击展开三个 tab 面板：

- **状态** — 常驻上下文预算条（rules / MEMORY / events，绿=健康，橙=超软绊线）、记忆卡数、MCP & session 数、git 未提交/tag、引擎团队在线灯。
- **架构** — 认知架构的"地铁线"视图（常驻核心 → 按需召回 → 项目区 → 引擎团队 → 隐私墙），每个节点可点击在 Finder 打开真实路径。按需召回层画出 `记忆 → embedding → sqlite 向量检索` 的完整链路 + 实时健康度。
- **skills** — skill 自进化状态（最新洞察、进化债、停滞天数、friction 热度 top3），支持可逆确认。

通过 **FSEvents** 实时更新（文件一改即刷新）+ 3 秒轮询兜底，**面板关闭时自动暂停**（零后台开销）。

## 工作原理

```
菜单栏 app (Swift / AppKit / SwiftUI)
        │  spawns
        ▼
cc-status.sh --json   ← 数据采集器（纯本地探测，不联网）
        │  reads
        ▼
~/.claude/{rules, projects/<转义路径>/memory, .git}  +  你的 PKM 目录
```

Swift app 只是一个轻量查看器；**所有数据来自 `cc-status.sh`** —— 一个可独立运行的 bash 脚本（`cc-status.sh` 人类可读，`cc-status.sh --json` 给 GUI 消费）。把它拷贝/软链到 `~/.claude/hooks/cc-status.sh`。

## 兼容性 —— 请先读这里

这是一个**围绕作者的 PKM（个人知识管理）体系构建的参考实现**。文件缺失时优雅降级。

| 层 | 任意 Claude Code 用户可用？ |
|---|---|
| 常驻预算条（rules/MEMORY/events） | ✅ 是 |
| git 状态 / tag / secret-hook | ✅ 若 `~/.claude` 是 git 仓 |
| 引擎灯（grok / codex / gemini） | ✅ 若你用这些 CLI |
| 记忆向量链、skill 自进化、PARA 架构 | ⚠️ 假设 `mycc` 式 PKM 结构，否则显示 "N/A" |

**适配方法：** 设环境变量 `CC_MONITOR_PKM_DIR` 指向你自己的 PKM 根目录（默认 `~/mycc`）。PKM 特有文件（`vector-health.json`、`evolution-log.md`、`task-log.md` 等）都是可选的 —— 缺失的会显示为未配置。

## 构建运行

```bash
bash build-menubar.sh
# ⚠️ 必须你【自己】启动（双击 .app / 加为登录项）。
# 自动化/脚本 open 的 GUI app 会进入不可见会话，菜单栏图标你看不到。
open cc-monitor.app
```

需要 Xcode（免费个人 Apple ID 即可本地签名，无需付费账号）。在 Xcode → target → Signing & Capabilities 里填你自己的签名 team（仓库里留空）。

**开机自启：** 系统设置 → 通用 → 登录项 → **+** → 选 `cc-monitor.app`。

## 三个真实的坑（macOS 26，踩了一晚上才定位）

1. **不可见会话** — 用 `open`/自动化启动的 app 进入不可见 GUI 会话，菜单栏图标不显示。手动启动或用登录项。
2. **App 沙盒** — Xcode 默认 `ENABLE_APP_SANDBOX=YES` 会挡死 `Process` 跑 `cc-status.sh` + 读 `~/.claude`（症状：面板全 0）。必须设为 **NO**（仓库里已设好）。
3. **Debug dylib** — Xcode Debug 构建把代码塞进路径绑定的 `.debug.dylib`（移动即废）。`build-menubar.sh` 用 `-configuration Release` 构建。

另外：SwiftUI `MenuBarExtra` 在此环境不渲染图标 → 改用 AppKit `NSStatusItem`；个别 SF Symbol 解析为 nil → 加文字 fallback。

## 技术栈

- **Swift** + **AppKit**（`NSStatusItem` + `NSPopover`）+ **SwiftUI**（`NSHostingController`）
- **FSEvents** 实时文件监听
- **bash** + **python3** 数据采集器（`cc-status.sh`）
- macOS 13+（在 macOS 26 上开发）

## 许可

[MIT](LICENSE)。
