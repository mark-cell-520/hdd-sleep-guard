import Cocoa

// HDD Sleep Guard 菜单栏常驻程序（只做界面与控制）。
// 真正的自动停转由 launchd 拉起的后台守护进程完成，退出本程序不影响自动停转。
// 安装前缀由 install.sh 在编译前把 __PREFIX__ 替换为实际路径。

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    let installPrefix = "__PREFIX__"
    let pythonPath = "/usr/bin/python3"
    var corePath: String { return installPrefix + "/daemon/hddguard_core.py" }
    var logPath: String { return installPrefix + "/logs/hddguard.log" }
    var lastStatus: [String: Any] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "externaldrive.fill",
                                accessibilityDescription: "HDD Sleep Guard")
            btn.toolTip = "HDD Sleep Guard"
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @discardableResult
    func runCore(_ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [corePath] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func refresh() {
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
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func quit() { NSApp.terminate(nil) }
}

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
