import Cocoa

// HDD Sleep Guard 菜单栏常驻程序（只做界面与控制）。
// 真正的自动停转由 launchd 拉起的后台守护进程完成，退出本程序不影响自动停转。
// 核心引擎定位顺序：包内自带 -> 安装时写入的 install_prefix.txt -> 环境变量 HDDGUARD_HOME -> 默认 ~/hdd-sleep-guard。

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    var lastStatus: [String: Any] = [:]
    var statusFile: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "externaldrive.fill",
                                accessibilityDescription: "HDD Sleep Guard")
            btn.toolTip = "HDD Sleep Guard"
        }
        let dd = runCore(["datadir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !dd.isEmpty { statusFile = dd + "/status.json" }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - 路径解析
    func bundledCore() -> String? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let p = res + "/daemon/hddguard_core.py"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func resolveCorePath() -> String {
        let fm = FileManager.default
        if let b = bundledCore() { return b }
        if let res = Bundle.main.resourcePath {
            let pf = res + "/install_prefix.txt"
            if let prefix = try? String(contentsOfFile: pf, encoding: .utf8) {
                let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "/daemon/hddguard_core.py"
                if fm.fileExists(atPath: p) { return p }
            }
        }
        if let env = ProcessInfo.processInfo.environment["HDDGUARD_HOME"] {
            let p = env + "/daemon/hddguard_core.py"
            if fm.fileExists(atPath: p) { return p }
        }
        return NSHomeDirectory() + "/hdd-sleep-guard/daemon/hddguard_core.py"
    }

    func resolveLogPath() -> String {
        if bundledCore() != nil {
            return NSHomeDirectory() + "/Library/Application Support/HDD Sleep Guard/hddguard.log"
        }
        let core = resolveCorePath()                              // .../PREFIX/daemon/hddguard_core.py
        let daemon = (core as NSString).deletingLastPathComponent // .../PREFIX/daemon
        let root = (daemon as NSString).deletingLastPathComponent // .../PREFIX
        return root + "/logs/hddguard.log"
    }

    func pythonPath() -> String {
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/python3"
    }

    @discardableResult
    func runCore(_ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath())
        proc.arguments = [resolveCorePath()] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func refresh() {
        // 优先读守护进程写的状态快照（不起 python，省功耗）；缺失或过期则回退到直接调核心
        if let sf = statusFile,
           let data = try? Data(contentsOf: URL(fileURLWithPath: sf)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ts = obj["ts"] as? Int ?? 0
            let poll = obj["poll_seconds"] as? Int ?? 60
            let age = Int(Date().timeIntervalSince1970) - ts
            if age >= 0 && age <= max(180, poll * 3) {
                lastStatus = obj
                statusItem.menu = buildMenu()
                return
            }
        }
        let out = runCore(["status", "--json"])
        if let data = out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lastStatus = obj
        }
        statusItem.menu = buildMenu()
    }

    func human(_ n: Int) -> String {
        var v = Double(n)
        for u in ["B", "KB", "MB", "GB", "TB"] {
            if v < 1024 { return String(format: "%.0f%@", v, u) }
            v /= 1024
        }
        return String(format: "%.0fPB", v)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let enabled = lastStatus["enabled"] as? Bool ?? true
        let idle = lastStatus["idle_minutes"] as? Int ?? 15

        add(menu, "HDD Sleep Guard", nil)
        add(menu, "自动停转\(enabled ? "已启用" : "已停用")，空闲 \(idle) 分钟", nil)
        menu.addItem(.separator())

        let disks = lastStatus["disks"] as? [[String: Any]] ?? []
        if disks.isEmpty {
            add(menu, "未发现外置机械硬盘", nil)
        } else {
            for d in disks {
                let bsd = d["bsd"] as? String ?? "?"
                let spinning = d["spinning"] as? Bool ?? true
                let idleM = d["idle_minutes"] as? Double ?? 0
                let size = human(d["size"] as? Int ?? 0)
                var title = "\(bsd)  \(size)  \(spinning ? "旋转中" : "已停转")  空闲 \(String(format: "%.0f", idleM)) 分"
                if let t = d["temp_c"] as? Int { title += "  \(t)°C" }
                let item = add(menu, title, nil)
                if !spinning {
                    item.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
                }
            }
        }
        menu.addItem(.separator())

        add(menu, "立即全部停转", #selector(sleepAll))
        add(menu, "唤醒全部", #selector(wakeAll))

        let thr = NSMenu()
        for m in [5, 10, 15, 30, 60] {
            let it = NSMenuItem(title: "\(m) 分钟", action: #selector(setIdle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m
            it.state = (m == idle) ? .on : .off
            thr.addItem(it)
        }
        let thrItem = NSMenuItem(title: "空闲阈值", action: nil, keyEquivalent: "")
        thrItem.submenu = thr
        menu.addItem(thrItem)

        add(menu, enabled ? "停用自动停转" : "启用自动停转", #selector(toggleEnabled))
        menu.addItem(.separator())
        add(menu, "刷新", #selector(refreshNow))
        add(menu, "查看日志", #selector(openLog))
        add(menu, "退出菜单图标（后台服务继续）", #selector(quit))
        return menu
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if action != nil { item.target = self }
        menu.addItem(item)
        return item
    }

    @objc func sleepAll() { _ = runCore(["sleep"]); refresh() }
    @objc func wakeAll() { _ = runCore(["wake"]); refresh() }
    @objc func setIdle(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? Int {
            _ = runCore(["set", "idle_minutes", String(m)])
        }
        refresh()
    }
    @objc func toggleEnabled() {
        let enabled = lastStatus["enabled"] as? Bool ?? true
        _ = runCore([enabled ? "disable" : "enable"])
        refresh()
    }
    @objc func refreshNow() { refresh() }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: resolveLogPath())) }
    @objc func quit() { NSApp.terminate(nil) }
}

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
