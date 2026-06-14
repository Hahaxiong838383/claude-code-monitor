#!/usr/bin/env bash
# 构建 cc-monitor 菜单栏版(AppKit NSStatusItem) — 真签名 Release 自包含 app。
#
# 这是踩了一晚上坑后固化的正确姿势。三个真根因(都已在 pbxproj/源码解决):
#   1) 启动会话:自动化 open/open_application 启动的 GUI app 进"不可见会话",
#      菜单栏图标用户看不到 → 必须用户【手动】open 或登录项启动(本人 GUI 会话)。
#   2) App Sandbox:Xcode 26 新建 macOS app 默认 ENABLE_APP_SANDBOX=YES,
#      沙盒挡死 Process 跑 cc-status.sh + 读 ~/.claude + 把 /tmp 重定向进容器
#      → pbxproj 已设 ENABLE_APP_SANDBOX=NO + ENABLE_USER_SCRIPT_SANDBOXING=NO。
#   3) Debug dylib:Xcode 26 Debug 把代码塞进 cc-monitor.debug.dylib(路径绑定不可移动)
#      → 必须用 -configuration Release(自包含,代码直接在主程序)。
# 另:SwiftUI MenuBarExtra 在此环境不渲染图标(故用 AppKit NSStatusItem);
#     gauge.medium 等 SF Symbol 可能 nil → 源码已加纯文字 fallback。
set -euo pipefail
cd "$(dirname "$0")"
PROJ=xcode/cc-monitor
SRC=cc-monitor-menubar.swift
DST_APP="$PWD/cc-monitor.app"

echo "→ 同步源码到 Xcode 工程入口(单一真相源 = $SRC)"
cp "$SRC" "$PROJ/cc-monitor/cc_monitorApp.swift"

echo "→ Release 构建(真签名;pbxproj 已固化 sandbox=NO + LSUIElement)"
xcodebuild -project "$PROJ/cc-monitor.xcodeproj" -scheme cc-monitor -configuration Release \
  -derivedDataPath "$PROJ/build" -allowProvisioningUpdates clean build >/dev/null

A="$PROJ/build/Build/Products/Release/cc-monitor.app"
echo "→ 自检"
echo "   app-sandbox: $(codesign -d --entitlements :- "$A" 2>/dev/null | grep -c app-sandbox) (应0)"
echo "   LSUIElement: $(plutil -extract LSUIElement raw "$A/Contents/Info.plist") (应true)"
echo "   签名: $(codesign -dvv "$A" 2>&1 | grep -m1 Authority | sed 's/Authority=//')"

echo "→ 安装到项目根 + 注册 LaunchServices"
rm -rf "$DST_APP"; ditto "$A" "$DST_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DST_APP"

echo "→ 退出旧进程(运行中进程内存=旧二进制,不会自动加载新文件;不退则 open 只激活旧进程=看到旧版)"
pkill -f 'cc-monitor\.app/Contents/MacOS/cc-monitor' 2>/dev/null && echo "   已 kill 旧进程,open 即加载最新" || echo "   无旧进程在跑"

echo ""
echo "✅ 完成: $DST_APP"
echo "   ⚠️ 启动必须【你自己】跑(不能让 cc/自动化代跑,否则进不可见会话看不到图标):"
echo "        open '$DST_APP'"
echo "   开机自启: 系统设置 → 通用 → 登录项 → + → 选 cc-monitor.app(登录项=你的会话,稳)"
echo "   图标位置: 按住 Cmd 拖动图标到顺手处(autosaveName 会记住,不能代码强制最右)"
