// cc-monitor (Dock 版) — 普通 app，Dock 图标点击=打开状态/架构面板
// 不用 LSUIElement(所以有 Dock 图标);窗口渲染可靠,绕开菜单栏 accessory 渲染坑
// 编译：swiftc -swift-version 5 cc-monitor-dock.swift -o cc-monitor-dock
import AppKit
import SwiftUI
import Foundation
import Combine        // ObservableObject/@Published(Xcode 26 MemberImportVisibility 要求显式导入)
import CoreServices   // FSEvents 文件监听

let APP_VERSION = "1.0.0"   // cc-monitor 版本号
let pkmEsc = (ProcessInfo.processInfo.environment["CC_MONITOR_PKM_DIR"] ?? "\(NSHomeDirectory())/mycc").replacingOccurrences(of: "/", with: "-")  // 脱敏:运行时推导 PKM 转义名(改 CC_MONITOR_PKM_DIR 适配)

struct CCStatus {
    var ts = "—"
    var rulesKB = 0, memKB = 0, eventsKB = 0
    var rulesTrip = 12, memTrip = 12, eventsTrip = 60
    var cards = 0, mcp = 0, sessions = 0, gitDirty = 0
    var vecCoverage = 100, vecVectored = 0, vecTotal = 0, vecDays = 0   // 记忆向量健康(vector-health.json)
    var vecReady = true
    var gitTag = "—", gitLast = "—"
    var engines: [(name: String, model: String, ready: Bool)] = []   // (引擎名, 配置态模型, 凭据/配置就绪)
    var secretHook = false
    // skills 自进化(诚实命名:evoActive=活跃未毕业改进项/进化债; frictionTop=周边热度近似非精确计数)
    var skillTotal = 0, evoTotal = 0, evoActive = 0, evoStaleDays = 0
    var evoId = "—", evoColor = "", evoProblem = ""
    var frictionTop: [(String, Int)] = []
    var gitFiles: [(String, String)] = []                  // (状态码, 路径) 未提交文件
    var evoItems: [(String, String, String, String)] = []  // (id, 颜色, 问题, 状态)
    var frictionDetail: [String: [String]] = [:]           // skill → 具体摩擦记录
    var ackedEvo: Set<String> = []                         // 已标「已处理」的进化项 id
    var ackedFriction: Set<String> = []                    // 已标「已知」的 friction skill
}

final class StatusStore: ObservableObject {
    @Published var s = CCStatus()
    let scriptPath = ("~/.claude/hooks/cc-status.sh" as NSString).expandingTildeInPath
    private var timer: Timer?
    private var fsStream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    private var running = false

    init() { refresh() }   // 首屏先拉一次;轮询/监听由 start() 控制(面板可见才开,关窗暂停=省电)

    // 面板可见时调:3s 轮询 + FSEvents 文件监听(双保险:文件即时事件 + 定时兜底引擎/session 状态)
    func start() {
        guard !running else { return }
        running = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        startWatching()
    }

    // 面板隐藏/关闭时调:停轮询 + 停监听(后台零开销)
    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        stopWatching()
        debounce?.cancel(); debounce = nil
    }

    func refresh() {
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [self.scriptPath, "--json"]
            // GUI app 从 LaunchServices 启动时环境可能精简,显式补全 PATH+HOME(健壮兜底)
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:" + (env["PATH"] ?? "")
            env["HOME"] = NSHomeDirectory()
            task.environment = env
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let parsed = StatusStore.parse(obj)
                DispatchQueue.main.async { self.s = parsed }
            } catch { }
        }
    }

    // 🟡 可逆确认:写独立 ack 文件(不碰原始 evolution-log/task-log,删文件即重置;绝对可逆)
    func toggleAck(_ kind: String, _ id: String) {
        let p = ("~/.claude/.skills-monitor-acks.json" as NSString).expandingTildeInPath
        var d: [String: [String]] = [:]
        if let data = FileManager.default.contents(atPath: p),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] { d = obj }
        var arr = Set(d[kind] ?? [])
        if arr.contains(id) { arr.remove(id) } else { arr.insert(id) }
        d[kind] = Array(arr)
        if let out = try? JSONSerialization.data(withJSONObject: d) { try? out.write(to: URL(fileURLWithPath: p)) }
        refresh()
    }

    static func parse(_ o: [String: Any]) -> CCStatus {
        var st = CCStatus()
        st.ts = o["ts"] as? String ?? "—"
        if let b = o["budget"] as? [String: Any] {
            st.rulesKB = b["rules_kb"] as? Int ?? 0
            st.memKB = b["memory_kb"] as? Int ?? 0
            st.eventsKB = b["events_kb"] as? Int ?? 0
            st.rulesTrip = b["rules_trip"] as? Int ?? 12
            st.memTrip = b["memory_trip"] as? Int ?? 12
            st.eventsTrip = b["events_trip"] as? Int ?? 60
        }
        st.cards = o["memory_cards"] as? Int ?? 0
        if let vh = o["vector_health"] as? [String: Any] {
            st.vecCoverage = vh["coverage"] as? Int ?? -1
            st.vecVectored = vh["vectored"] as? Int ?? 0
            st.vecTotal = vh["total"] as? Int ?? 0
            st.vecReady = vh["ollama_ready"] as? Bool ?? true
            st.vecDays = vh["days"] as? Int ?? -1
        }
        st.mcp = o["mcp"] as? Int ?? 0
        st.sessions = o["sessions"] as? Int ?? 0
        st.secretHook = o["secret_hook"] as? Bool ?? false
        if let g = o["git"] as? [String: Any] {
            st.gitDirty = g["dirty"] as? Int ?? 0
            st.gitTag = g["tag"] as? String ?? "—"
            st.gitLast = g["last"] as? String ?? "—"
            if let gf = g["files"] as? [[String: Any]] {
                st.gitFiles = gf.compactMap {
                    guard let stt = $0["st"] as? String, let p = $0["path"] as? String else { return nil }
                    return (stt, p)
                }
            }
        }
        if let e = o["engines"] as? [String: Any] {
            st.engines = ["omp","grok","codex","gemini","gateway"].map { k -> (name: String, model: String, ready: Bool) in
                let info = e[k] as? [String: Any]
                return (k, info?["model"] as? String ?? "", info?["on"] as? Bool ?? false)
            }
        }
        if let sk = o["skills"] as? [String: Any] {
            st.skillTotal = sk["total"] as? Int ?? 0
            st.evoTotal = sk["evo_total"] as? Int ?? 0
            st.evoActive = sk["evo_pending"] as? Int ?? 0
            st.evoStaleDays = sk["evo_stale_days"] as? Int ?? 0
            if let el = sk["evo_latest"] as? [String: Any] {
                st.evoId = el["id"] as? String ?? "—"
                st.evoColor = el["color"] as? String ?? ""
                st.evoProblem = el["problem"] as? String ?? ""
            }
            if let ft = sk["friction_top"] as? [[String: Any]] {
                st.frictionTop = ft.compactMap {
                    guard let n = $0["name"] as? String, let c = $0["count"] as? Int else { return nil }
                    return (n, c)
                }
            }
            if let ei = sk["evo_items"] as? [[String: Any]] {
                st.evoItems = ei.compactMap {
                    guard let id = $0["id"] as? String else { return nil }
                    return (id, $0["color"] as? String ?? "", $0["problem"] as? String ?? "", $0["status"] as? String ?? "")
                }
            }
            if let fd = sk["friction_detail"] as? [String: [String]] { st.frictionDetail = fd }
            st.ackedEvo = Set((sk["acked_evo"] as? [String]) ?? [])
            st.ackedFriction = Set((sk["acked_friction"] as? [String]) ?? [])
        }
        return st
    }

    // ── FSEvents:监听 rules/memory/git/events 目录,文件一改即触发刷新(防抖合并) ──
    private func startWatching() {
        let paths = [
            "~/.claude/rules",
            "~/.claude/projects/\(pkmEsc)/memory",
            "~/.claude/.git",
            "~/mycc/0-System",
        ].map { ($0 as NSString).expandingTildeInPath } as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<StatusStore>.fromOpaque(info).takeUnretainedValue().fsTriggered()
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        fsStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stopWatching() {
        guard let st = fsStream else { return }
        FSEventStreamStop(st); FSEventStreamInvalidate(st); FSEventStreamRelease(st)
        fsStream = nil
    }

    private func fsTriggered() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)   // 0.4s 防抖:合并编辑器多次保存/git 批量写
    }

    var healthy: Bool {
        s.rulesKB <= s.rulesTrip && s.memKB <= s.memTrip && s.eventsKB <= s.eventsTrip
        && s.secretHook && (s.engines.isEmpty || s.engines.allSatisfy { $0.ready })
    }
}

struct BudgetBar: View {
    let label: String; let v: Int; let trip: Int
    var over: Bool { v > trip }
    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 60, alignment: .leading).font(.system(size: 11))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(over ? Color.orange : Color.green)
                        .frame(width: min(CGFloat(v) / CGFloat(max(trip, 1)), 1.0) * geo.size.width)
                }
            }.frame(height: 8)
            Text("\(v)/\(trip)").frame(width: 44, alignment: .trailing).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: StatusStore
    @State private var tab = 0
    @State private var gitExpanded = false
    @State private var evoExpanded = false
    @State private var expandedFriction: String? = nil
    @State private var expandedDirs: Set<String> = ["2-Projects"]   // ③ 目录区展开态;默认摊开 2-Projects(最常看)
    var s: CCStatus { store.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🧠 cc").font(.system(size: 13, weight: .semibold))
                Text("v\(APP_VERSION)").font(.system(size: 8)).foregroundColor(.secondary)
                Picker("", selection: $tab) {
                    Text("状态").tag(0); Text("架构").tag(1); Text("skills").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 178)
                Spacer()
                Text(s.ts).font(.system(size: 9)).foregroundColor(.secondary)
            }
            Divider()
            ScrollView {
                if tab == 0 { statusView } else if tab == 1 { archView } else { skillsView }
            }
            .frame(maxHeight: 520)
            Divider()
            HStack {
                Button("刷新") { store.refresh() }.font(.system(size: 11))
                Spacer()
                if tab == 1 { Text("点路径→Finder 打开").font(.system(size: 9)).foregroundColor(.secondary) }
                if tab == 2 { Text("friction=周边热度近似").font(.system(size: 9)).foregroundColor(.secondary) }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.font(.system(size: 11))
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    var statusView: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("常驻预算 (KB)").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            BudgetBar(label: "rules", v: s.rulesKB, trip: s.rulesTrip)
            BudgetBar(label: "MEMORY", v: s.memKB, trip: s.memTrip)
            BudgetBar(label: "events", v: s.eventsKB, trip: s.eventsTrip)
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("记忆 \(s.cards) 卡").font(.system(size: 11))
                    Text("MCP \(s.mcp) · session \(s.sessions)").font(.system(size: 11))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button(action: { if s.gitDirty > 0 { withAnimation(.snappy) { gitExpanded.toggle() } } }) {
                        Text(s.gitDirty == 0 ? "git 干净 ✅" : "git \(s.gitDirty) 未提交 ⚠️ \(gitExpanded ? "▾" : "▸")")
                            .font(.system(size: 11)).foregroundColor(.primary)
                    }.buttonStyle(.plain)
                    Text("tag \(s.gitTag) · 闸 \(s.secretHook ? "✅" : "⚠️")").font(.system(size: 11))
                }
            }
            // tag/闸 常驻人话说明(可见,不用 hover)
            Text("tag=版本锚点(可回退) · 闸=提交前 secret 扫描")
                .font(.system(size: 8)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            // git 展开:未提交文件列表(只读;提交仍去 Finder/终端人工控制)
            if gitExpanded && !s.gitFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(s.gitFiles.indices, id: \.self) { i in
                        HStack(spacing: 5) {
                            Text(s.gitFiles[i].0).font(.system(size: 8, weight: .bold))
                                .foregroundColor(s.gitFiles[i].0 == "??" ? .orange : .blue)
                                .frame(width: 20, alignment: .leading)
                            Text(s.gitFiles[i].1).font(.system(size: 9, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    Button(action: { reveal("~/.claude") }) {
                        Text("在 Finder 打开 ~/.claude 去提交 ›").font(.system(size: 8)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
            }
            Divider()
            Text("引擎团队").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(s.engines, id: \.name) { e in engineChip(e) }
            }
        }
    }

    // ── 架构 tab：每层 = 一张卡，列出真实子目录路径 + 作用，点路径在 Finder 打开 ──
    // ── 架构 tab：左偏轴管道流转图(地铁线主干贯穿 + 右侧挂枝) ──
    var archView: some View {
        VStack(alignment: .leading, spacing: 0) {
            legend.padding(.leading, 26).padding(.bottom, 8)
            coreLayer
            relationRow("↓ 按需 pull · ripgrep")
            recallLayer
            relationRow("↓ cc 编排")
            myccZonePipe
            relationRow("↓ routing-kernel 路由")
            engineLayer
            relationRow("⊘ 隔离 · 不外派 / 不 memory / 不 git")
            pipeLayer("⑤", "work-private", "隐私 vault", ok: true, muted: true,
                      nodes: [("人事/面试/客户 vault", "~/work-private", true)], isLast: true)
            govRow
        }
        .padding(.vertical, 4)
    }

    // ── ③ mycc 目录全景:PARA 骨架 9 区,点区下钻子目录(FileManager 实时扫描,默认折叠) ──
    // hardcode 的只是「区→作用」语义(文件系统读不出),子目录列表实时扫,保留地铁线主干第③站不变。
    var myccZones: [(name: String, rel: String, desc: String)] {
        [("0-System/",   "0-System",   "状态·记忆·事件"),
         ("1-Inbox/",    "1-Inbox",    "创意暂存"),
         ("2-Projects/", "2-Projects", "在推项目"),
         ("3-Thinking/", "3-Thinking", "认知方法论"),
         ("4-Assets/",   "4-Assets",   "可复用资产"),
         ("5-Archive/",  "5-Archive",  "历史归档"),
         ("tasks/",      "tasks",      "跨会话任务"),
         ("docs/",       "docs",       "扩展文档"),
         (".claude/",    ".claude",    "skills·hooks·rules")]
    }

    // 实时扫某区下的一级子目录(排隐藏),排序返回
    func subdirs(_ rel: String) -> [String] {
        let base = ("~/mycc/\(rel)" as NSString).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return items.filter { n in
            if n.hasPrefix(".") { return false }
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: "\(base)/\(n)", isDirectory: &d)
            return d.boolValue
        }.sorted()
    }

    // ③ 层:保留主干第③站 + 头部,body 换成 9 区可折叠目录树
    var myccZonePipe: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("③").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                Text("项目 ~/mycc").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("MCP \(s.mcp) · 点区展开").font(.system(size: 8.5)).foregroundColor(.secondary)
            }
            ForEach(myccZones, id: \.rel) { z in zoneRow(z) }
        }
        .padding(.leading, 26).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { spineBg(dot: .green, tail: true) }
    }

    // 单个区:折叠头(chevron+名+计数+作用) + 展开后子目录 2 列网格(点 chip 在 Finder 打开)
    @ViewBuilder
    func zoneRow(_ z: (name: String, rel: String, desc: String)) -> some View {
        let subs = subdirs(z.rel)
        let isOpen = expandedDirs.contains(z.rel)
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                if isOpen { expandedDirs.remove(z.rel) } else { expandedDirs.insert(z.rel) }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(.secondary).frame(width: 9)
                    Text(z.name).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    Text("(\(subs.count))").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text(z.desc).font(.system(size: 9)).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isOpen {
                if subs.isEmpty {
                    Button(action: { reveal("~/mycc/\(z.rel)") }) {
                        Text("📂 无子文件夹 · Finder 打开本区")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.leading, 14)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)],
                              alignment: .leading, spacing: 5) {
                        ForEach(subs, id: \.self) { sub in
                            nodeChip(sub, open: "~/mycc/\(z.rel)/\(sub)")
                        }
                    }.padding(.leading, 14).padding(.top, 1)
                }
            }
        }
    }

    // ── ① 常驻核心:rules/ 可下钻看 5 个规则文件+字节(=常驻预算构成);CLAUDE.md/MEMORY.md 单文件点开 ──
    var coreLayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("①").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                Text("常驻核心").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("rules \(s.rulesKB)K·MEM \(s.memKB)K").font(.system(size: 8.5)).foregroundColor(.secondary)
            }
            foldRow(key: "rules", label: "rules/", desc: "常驻规则(=预算构成)", tildeDir: "~/.claude/rules")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)],
                      alignment: .leading, spacing: 5) {
                nodeChip("CLAUDE.md", open: "~/mycc/CLAUDE.md")
                nodeChip("MEMORY.md", open: "~/.claude/projects/\(pkmEsc)/memory/MEMORY.md")
            }.padding(.leading, 14)
        }
        .padding(.leading, 26).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            spineBg(dot: (s.rulesKB <= s.rulesTrip && s.memKB <= s.memTrip) ? .green : .orange, tail: true)
        }
    }

    // ── ② 按需召回:docs/ 可下钻列文档;skills(两套)/记忆卡只显计数+点开根(各有专门入口,不内联爆炸) ──
    var recallLayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("②").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                Text("按需召回").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(s.cards) 卡").font(.system(size: 8.5)).foregroundColor(.secondary)
            }
            foldRow(key: "docs", label: "docs/", desc: "按需文档", tildeDir: "~/.claude/docs")
            // A 套:cc 主力 canonical(平时 ripgrep 召回的真记忆,无向量)
            groupLabel("A", "主力记忆 · cc canonical · ✓已接入向量")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)],
                      alignment: .leading, spacing: 5) {
                nodeChip("记忆卡 \(s.cards) →MEMORY", open: "~/.claude/projects/\(pkmEsc)/memory")
                nodeChip("skills·全局 \(dirCount("~/.claude/skills"))", open: "~/.claude/skills")
                nodeChip("skills·mycc \(dirCount("~/mycc/.claude/skills"))", open: "~/mycc/.claude/skills")
            }.padding(.leading, 14)
            // B 套:memory.db 向量检索管道(≠A 套;源→embed→向量→db→检索关系链)
            groupLabel("B", "向量检索库 · memory.db · A+B 双源统一")
            memVectorChain
        }
        .padding(.leading, 26).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { spineBg(dot: vecWarn ? .orange : .green, tail: true) }
    }

    var vecWarn: Bool { !s.vecReady || s.vecCoverage < 80 || s.vecDays > 30 }

    // 分组小标(A/B 徽 + 标题),区分两套记忆源
    func groupLabel(_ tag: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(tag).font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Color.gray.opacity(0.18)))
            Text(title).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }.padding(.leading, 14).padding(.top, 2)
    }

    // B 套向量关系链:源 →embed→ 向量 →入库→ db(检索),健康灯在 db 终态节点(原向量健康并入此处)
    var memVectorChain: some View {
        VStack(alignment: .leading, spacing: 0) {
            chainNode(icon: "folder", title: "A·主力卡 .claude/memory", badge: "\(s.cards) 卡",
                      open: "~/.claude/projects/\(pkmEsc)/memory", dot: nil)
            chainNode(icon: "doc.text", title: "B·memory-items.md", badge: "源",
                      open: "~/mycc/0-System/memory-items.md", dot: nil)
            chainArrow("A+B 统一 embed · Ollama qwen3 · 512维")
            chainNode(icon: "circle.grid.2x2", title: "memory-vectors.json", badge: "\(s.vecTotal) 向量",
                      open: "~/mycc/0-System/memory-vectors.json", dot: nil)
            chainArrow("入库")
            chainNode(icon: "cylinder.split.1x2", title: "memory.db", badge: "FTS5 + 向量 KNN",
                      open: "~/mycc/0-System/memory.db", dot: vecWarn ? .orange : .green)
            Text("\(s.vecVectored)/\(s.vecTotal) 已向量 · \(s.vecCoverage)% · " + (s.vecReady ? "\(s.vecDays)天前" : "⚠️Ollama挂"))
                .font(.system(size: 8.5)).foregroundColor(vecWarn ? .orange : .secondary)
                .padding(.leading, 28).padding(.top, 1)
            chainArrow("检索 → 向量+FTS+关键词 ⇒ RRF 融合+重排")
        }.padding(.leading, 14)
    }

    // 链节点:左小图标/健康点 + 名(mono) + 右 badge,点击 Finder 打开
    func chainNode(icon: String, title: String, badge: String, open: String, dot: Color?) -> some View {
        Button(action: { reveal(open) }) {
            HStack(spacing: 5) {
                if let d = dot { Circle().fill(d).frame(width: 6, height: 6) }
                else { Image(systemName: icon).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 11) }
                Text(title).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(badge).font(.system(size: 8)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.16), lineWidth: 0.5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // 链内流转标:短竖线 + ▼ + 灰字(比 relationRow 紧凑,嵌分组内)
    func chainArrow(_ text: String) -> some View {
        HStack(spacing: 6) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 1.5, height: 7)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 5)).foregroundColor(Color.gray.opacity(0.4))
            }.frame(width: 11)
            Text(text).font(.system(size: 8.5)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }.padding(.vertical, 1)
    }

    // 通用可折叠资源行:区头(chevron+名+计数+desc) + 展开 entries 网格(目录在前/文件带字节);①rules ②docs 共用
    @ViewBuilder
    func foldRow(key: String, label: String, desc: String, tildeDir: String) -> some View {
        let entries = entriesAt(tildeDir)
        let isOpen = expandedDirs.contains(key)
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                if isOpen { expandedDirs.remove(key) } else { expandedDirs.insert(key) }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(.secondary).frame(width: 9)
                    Text(label).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    Text("(\(entries.count))").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text(desc).font(.system(size: 9)).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isOpen {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)],
                          alignment: .leading, spacing: 5) {
                    ForEach(entries.indices, id: \.self) { i in
                        fileChip(entries[i].label, sub: entries[i].sub, open: entries[i].path)
                    }
                }.padding(.leading, 14).padding(.top, 1)
            }
        }
    }

    // 文件/目录叶子 chip:右侧附字节数(目录无),点击在 Finder 打开
    func fileChip(_ label: String, sub: String, open: String) -> some View {
        Button(action: { reveal(open) }) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                if !sub.isEmpty { Text(sub).font(.system(size: 8)).foregroundColor(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.16), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 扫 ~ 目录下非隐藏项:目录在前(带/后缀,无字节)、文件在后(带字节);给 ①rules ②docs 下钻用
    func entriesAt(_ tildeDir: String) -> [(label: String, sub: String, path: String)] {
        let base = (tildeDir as NSString).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var dirs: [(label: String, sub: String, path: String)] = []
        var files: [(label: String, sub: String, path: String)] = []
        for n in items.sorted() where !n.hasPrefix(".") {
            let full = "\(base)/\(n)"
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &d)
            if d.boolValue {
                dirs.append((label: n + "/", sub: "", path: "\(tildeDir)/\(n)"))
            } else {
                let sz = ((try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int) ?? 0
                files.append((label: n, sub: sz >= 1024 ? "\(sz/1024)K" : "\(sz)B", path: "\(tildeDir)/\(n)"))
            }
        }
        return dirs + files
    }

    // 只数某 ~ 目录下子目录数(skills 两套计数用,不列内容)
    func dirCount(_ tildeDir: String) -> Int {
        let base = (tildeDir as NSString).expandingTildeInPath
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else { return 0 }
        return items.filter { n in
            if n.hasPrefix(".") { return false }
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: "\(base)/\(n)", isDirectory: &d)
            return d.boolValue
        }.count
    }

    var legend: some View {
        HStack(spacing: 12) {
            legendDot(.green, "健康")
            legendDot(.orange, "超预算/告警")
            legendDot(Color.gray.opacity(0.55), "隔离/中性")
        }
    }
    func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    // 左主干背景:顶部圆点(健康色) + 向下贯穿竖线(画在 .background,自然填满本块高度,不撑爆 VStack)
    func spineBg(dot: Color, tail: Bool) -> some View {
        ZStack(alignment: .top) {
            if tail {
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 2)
                    .frame(maxHeight: .infinity).padding(.top, 5)
            }
            Circle().fill(dot).frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        }
        .frame(width: 11).padding(.leading, 3)
    }

    // 一个架构层:右侧标题 + 叶节点网格,左侧主干画在 background
    func pipeLayer(_ idx: String, _ title: String, _ badge: String, ok: Bool, muted: Bool = false,
                   nodes: [(String, String, Bool)], isLast: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(idx).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(badge).font(.system(size: 8.5)).foregroundColor(.secondary)
            }
            nodeGrid(nodes)
        }
        .padding(.leading, 26).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            spineBg(dot: muted ? Color.gray.opacity(0.55) : (ok ? .green : .orange), tail: !isLast)
        }
    }

    // 叶节点 2 列网格(长 label wide=true 占满整行)
    func nodeGrid(_ nodes: [(String, String, Bool)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            ForEach(nodes.indices, id: \.self) { i in
                nodeChip(nodes[i].0, open: nodes[i].1).gridCellColumns(nodes[i].2 ? 2 : 1)
            }
        }
    }

    // 叶节点 chip:点击在 Finder 打开
    func nodeChip(_ label: String, open: String) -> some View {
        Button(action: { reveal(open) }) {
            Text(label).font(.system(size: 10, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.16), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 层间关系标签:主干竖线段(对齐圆点 x≈8.5) + 右侧胶囊文字
    func relationRow(_ text: String) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 2, height: 22).padding(.leading, 7.5)
            Text(text).font(.system(size: 9)).foregroundColor(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.gray.opacity(0.10)))
                .padding(.leading, 9)
            Spacer(minLength: 0)
        }
    }

    // ④ 引擎团队:5 引擎各带在线点,点击开各自配置根
    var engineLayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("④").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                Text("引擎团队").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(s.engines, id: \.name) { e in engineChip(e) }
            }
        }
        .padding(.leading, 26).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            spineBg(dot: !s.engines.isEmpty && s.engines.allSatisfy { $0.ready } ? .green : .orange, tail: true)
        }
    }
    // 引擎 chip:左灯(配置态就绪) + 名(上)/配置模型(下小字),点击开各自配置根
    func engineChip(_ e: (name: String, model: String, ready: Bool)) -> some View {
        let path = ["omp": "~/.omp", "grok": "~/.grok", "codex": "~/.codex",
                    "gemini": "~/.gemini", "gateway": "~/.gateway.env"][e.name] ?? "~"
        return Button(action: { reveal(path) }) {
            HStack(spacing: 5) {
                Circle().fill(e.ready ? Color.green : Color.red).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).font(.system(size: 10, weight: .medium, design: .monospaced))
                    Text(e.model).font(.system(size: 8)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.09)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 治理闸:管道末端旁挂(无 tail)
    var govRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("治理闸").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(s.secretHook ? "secret 闸 ✅" : "闸 off ⚠️")
                    .font(.system(size: 8.5)).foregroundColor(.secondary)
            }
            nodeChip("hooks/", open: "~/.claude/hooks/")
        }
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { spineBg(dot: s.secretHook ? .green : .orange, tail: false) }
    }

    // ── skills tab：自进化状态(Latest Insight + 进化债/停滞 + friction 周边热度) ──
    var skillsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 卡片1：最新进化项(Latest Insight) + 进化债/停滞/进化项
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Text(s.evoColor.isEmpty ? "⚪" : s.evoColor).font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.evoId) 最新进化").font(.system(size: 11, weight: .semibold))
                        Text(s.evoProblem).font(.system(size: 9)).foregroundColor(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 18) {
                    statChip("进化债", "\(s.evoActive)", alert: s.evoActive > 5)
                    statChip("停滞", "\(s.evoStaleDays)天", alert: s.evoStaleDays > 14)
                    statChip("进化项", "\(s.evoTotal)")
                    Spacer()
                    Button(action: { withAnimation(.snappy) { evoExpanded.toggle() } }) {
                        Text(evoExpanded ? "收起 ▾" : "展开全部 ▸").font(.system(size: 9)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                // 展开:全部活跃进化项(只读;点单项在 Finder 打开进化日志看全文)
                if evoExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Divider()
                        ForEach(s.evoItems.indices, id: \.self) { i in
                            let eid = s.evoItems[i].0
                            let acked = s.ackedEvo.contains(eid)
                            HStack(alignment: .top, spacing: 5) {
                                Text(s.evoItems[i].1.isEmpty ? "⚪" : s.evoItems[i].1).font(.system(size: 9))
                                Text(eid).font(.system(size: 9, weight: .semibold)).frame(width: 26, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.evoItems[i].2).font(.system(size: 9)).lineLimit(1).truncationMode(.tail)
                                        .foregroundColor(acked ? .secondary : .primary).strikethrough(acked)
                                    Text(s.evoItems[i].3).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { reveal("~/mycc/0-System/evolution-log.md") }
                                Spacer(minLength: 0)
                                Button(action: { store.toggleAck("evo", eid) }) {
                                    Text(acked ? "✓已处理" : "标记").font(.system(size: 8))
                                        .foregroundColor(acked ? .green : .blue)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 3).fill((acked ? Color.green : Color.blue).opacity(0.13)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))

            // 卡片2：friction 周边热度 TOP3(Capsule 条形,人对条形敏感>数字)
            VStack(alignment: .leading, spacing: 7) {
                Text("⚠️ 摩擦周边热度 TOP3").font(.system(size: 11, weight: .semibold))
                if s.frictionTop.isEmpty {
                    Text("近期无摩擦记录 ✅").font(.system(size: 9)).foregroundColor(.secondary)
                } else {
                    ForEach(s.frictionTop, id: \.0) { f in
                        let acked = s.ackedFriction.contains(f.0)
                        VStack(alignment: .leading, spacing: 3) {
                            Button(action: { withAnimation(.snappy) { expandedFriction = (expandedFriction == f.0 ? nil : f.0) } }) {
                                HStack(spacing: 6) {
                                    Text(f.0).font(.system(size: 10, design: .monospaced))
                                        .frame(width: 78, alignment: .leading).lineLimit(1).truncationMode(.middle)
                                        .foregroundColor(acked ? .secondary : .primary)
                                    GeometryReader { geo in
                                        Capsule().fill((acked ? Color.gray : Color.orange).opacity(0.7))
                                            .frame(width: max(CGFloat(f.1) / CGFloat(frictionMax) * geo.size.width, 3))
                                    }.frame(height: 9)
                                    Text("\(f.1)").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 18, alignment: .trailing)
                                    Text(expandedFriction == f.0 ? "▾" : "▸").font(.system(size: 8)).foregroundColor(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if expandedFriction == f.0 {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(s.frictionDetail[f.0] ?? [], id: \.self) { rec in
                                        Text("· \(rec)").font(.system(size: 8)).foregroundColor(.secondary)
                                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Button(action: { store.toggleAck("friction", f.0) }) {
                                        Text(acked ? "✓已知 · 点击取消" : "标记「已知」").font(.system(size: 8))
                                            .foregroundColor(acked ? .green : .blue)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(RoundedRectangle(cornerRadius: 3).fill((acked ? Color.green : Color.blue).opacity(0.13)))
                                    }.buttonStyle(.plain)
                                }.padding(.leading, 6).padding(.top, 1)
                            }
                        }
                    }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))

            // 底部：skill 库存(小字,非主 KPI) + 点开进化日志
            Button(action: { reveal("~/mycc/0-System/evolution-log.md") }) {
                HStack(spacing: 4) {
                    Text("\(s.skillTotal) skills").font(.system(size: 9, weight: .medium)).foregroundColor(.primary)
                    Text("· 读 evolution-log + task-log · 点开进化日志 ›")
                        .font(.system(size: 8)).foregroundColor(.secondary)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.top, 2)
    }
    var frictionMax: Int { max(s.frictionTop.map { $0.1 }.max() ?? 1, 1) }
    func statChip(_ label: String, _ value: String, alert: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .bold)).foregroundColor(alert ? .orange : .primary)
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    // 点路径：目录→Finder 打开；文件→Finder 选中（便于右键编辑）
    func reveal(_ tilde: String) {
        let p = (tilde as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
            if isDir.boolValue {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        }
    }
}

// ── 菜单栏外壳:NSStatusItem 图标 + NSPopover 面板 ──
// 用传统 AppKit(非 SwiftUI MenuBarExtra,后者在 macOS 26 此环境不渲染图标);
// dock 版同套 AppKit 已验证窗口渲染正常,NSStatusItem 同底层应可渲染。
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 不进 Dock,只待菜单栏
        app.run()
    }

    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let store = StatusStore()
    private var iconSink: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        // 1) 菜单栏图标(变长度,可被 Cmd 拖动)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "cc-monitor-status"   // 记住用户 Cmd 拖动后的位置,下次启动复原
        if let btn = statusItem.button {
            btn.action = #selector(togglePopover)
            btn.target = self
        }
        setIcon(healthy: true)
        // 2) 点击弹出的面板(复用同一 ContentView:状态/架构 + 路径 + 实时刷新)
        popover.contentSize = NSSize(width: 360, height: 620)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        // 3) 健康状态驱动图标(正常=仪表盘 / 异常=警告三角)
        iconSink = store.$s.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshIcon() }
    }

    func refreshIcon() { setIcon(healthy: store.healthy) }

    // SF Symbol 优先;macOS 26 个别 symbol 可能解析为 nil → fallback 纯文字(已验证文字能渲染)
    func setIcon(healthy: Bool) {
        guard let btn = statusItem.button else { return }
        let symbol = healthy ? "gauge.medium" : "exclamationmark.triangle.fill"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "cc") {
            img.isTemplate = true
            btn.image = img
            btn.title = ""
        } else {
            btn.image = nil
            btn.title = healthy ? "✦cc" : "⚠cc"
            btn.font = .systemFont(ofSize: 13, weight: .bold)
        }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let btn = statusItem.button else { return }
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        store.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    // 面板关闭 → 暂停刷新(后台零开销)
    func popoverDidClose(_ n: Notification) { store.stop() }
}
