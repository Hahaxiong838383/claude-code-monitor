# 在 Xcode 里构建 cc-monitor（拿到稳定菜单栏图标）

> CLT/swiftc 命令行构建的未签名 app 在 macOS 26 上**菜单栏图标不渲染**（实测 NSStatusItem + MenuBarExtra 都不行，但窗口正常）。
> 正式 Xcode 构建（自动签名 + 正确 app bundle）能解决。源码 `cc-monitor.swift` 已是最终版（MenuBarExtra + 状态/架构双 tab），直接用。

## 前提
App Store 搜 **Xcode** 装好（约 7–15G）。免费个人 Apple ID 即可签名本地运行，**不需要付费开发者账号**。

## 步骤（装完 Xcode 后，约 5 分钟）

1. Xcode → **File → New → Project → macOS → App → Next**
2. 填：
   - Product Name: `cc-monitor`
   - Team: 选你的 Apple ID（没有就 **Add Account** 登个人 ID）
   - Interface: **SwiftUI** · Language: **Swift**
   - → 存到任意位置（如 `~/mycc/2-Projects/cc-monitor/xcode/`）
3. 左侧文件树：**删掉自动生成的 `ContentView.swift`**（右键 → Delete → Move to Trash）
4. 打开 `cc_monitorApp.swift`（或 `<名字>App.swift`）→ **全选删光** → 把本目录 [`cc-monitor.swift`](cc-monitor.swift) 的**全部内容粘进去**
5. 点项目 → TARGETS `cc-monitor` → **Signing & Capabilities**：
   - 勾 **Automatically manage signing**，Team 选你的 Apple ID
   - ⚠️ **删掉 "App Sandbox"**（点它右上角 ×）——**关键**！不删的话 app 跑不了 `cc-status.sh`、读不到 `~/.claude`，面板会全 0
6. 点项目 → TARGETS → **Info** → 加一行：`Application is agent (UIElement)` = **YES**（只在菜单栏、不进 Dock）
7. **Cmd + R** 运行 → 菜单栏出现仪表盘图标，点它弹状态/架构面板 ✅

## 装好后设开机自启
构建出的 `.app` 在 Xcode → Product → Show Build Folder in Finder → `Products/Debug/cc-monitor.app`。
把它拖到 **系统设置 → 通用 → 登录项**；或告诉我那个 `.app` 路径，我帮你换掉现有登录项（现在登录项指向的是不显示图标的 CLT 版）。

## 不用动的部分
- 数据层 `~/.claude/hooks/cc-status.sh` 不变，Xcode 版照样调它（所以才必须删 App Sandbox）
- 源码逻辑不用改，直接粘

## 卡住了
任何一步对不上（按钮名/找不到选项），把截图发我，我对着你的 Xcode 版本给具体位置。
