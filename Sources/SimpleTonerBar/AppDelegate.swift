
import AppKit
import ServiceManagement

enum PollSchedule: Int, CaseIterable {
    case twiceDaily = 0
    case everyHour = 1
    case every6Hours = 2
    case onceDaily = 3

    var label: String {
        switch self {
        case .twiceDaily: return "Twice Daily (10am, 7pm)"
        case .everyHour: return "Every Hour"
        case .every6Hours: return "Every 6 Hours"
        case .onceDaily: return "Once Daily (10am)"
        }
    }

    var scheduledTimes: [(hour: Int, minute: Int)]? {
        switch self {
        case .twiceDaily: return [(10, 0), (19, 0)]
        case .onceDaily: return [(10, 0)]
        case .everyHour: return nil
        case .every6Hours: return nil
        }
    }

    var intervalSeconds: TimeInterval? {
        switch self {
        case .everyHour: return 3600
        case .every6Hours: return 21600
        default: return nil
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    let monitor = TonerMonitor()
    var lastUpdated: Date?
    let discovery = PrinterDiscovery()
    var pollTimers: [Timer] = []
    var printerIP: String = ""

    var currentSchedule: PollSchedule {
        get {
            PollSchedule(rawValue: UserDefaults.standard.integer(forKey: "pollSchedule")) ?? .twiceDaily
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "pollSchedule")
            if !printerIP.isEmpty {
                startRefreshLoop()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        moveToApplicationsIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Searching…"
        statusItem.button?.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: nil)

        discovery.onPrinterFound = { [weak self] printer in
            guard let self else { return }
            self.printerIP = printer.host
            self.discovery.stopDiscovery()
            self.startRefreshLoop()
        }
        discovery.startDiscovery()
    }

    private func moveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return }

        let applicationsPath = "/Applications"
        guard !bundlePath.hasPrefix(applicationsPath) else { return }

        if UserDefaults.standard.bool(forKey: "declinedMoveToApplications") { return }

        let appName = (bundlePath as NSString).lastPathComponent
        let destinationPath = "\(applicationsPath)/\(appName)"

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "SimpleTonerBar is not in your Applications folder. Would you like to move it there?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destinationPath) {
                    try fileManager.removeItem(atPath: destinationPath)
                }
                try fileManager.moveItem(atPath: bundlePath, toPath: destinationPath)
                NSWorkspace.shared.open(URL(fileURLWithPath: destinationPath))
                NSApplication.shared.terminate(nil)
            } catch {
                let errorAlert = NSAlert(error: error)
                errorAlert.runModal()
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
        default:
            break
        }
    }

    func startRefreshLoop() {
        cancelTimers()
        refresh()
        scheduleNextPolls()
    }

    private func cancelTimers() {
        pollTimers.forEach { $0.invalidate() }
        pollTimers.removeAll()
    }

    private func scheduleNextPolls() {
        cancelTimers()
        let schedule = currentSchedule

        if let interval = schedule.intervalSeconds {
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimers.append(timer)
        } else if let times = schedule.scheduledTimes {
            let calendar = Calendar.current
            let now = Date()

            for time in times {
                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.hour = time.hour
                components.minute = time.minute
                components.second = 0

                guard var fireDate = calendar.date(from: components) else { continue }
                if fireDate <= now {
                    fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate)!
                }

                let interval = fireDate.timeIntervalSince(now)
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    self?.refresh()
                    self?.scheduleNextPolls()
                }
                RunLoop.main.add(timer, forMode: .common)
                pollTimers.append(timer)
            }
        }
    }

    func refresh() {
        monitor.fetch(host: printerIP) { status in
            DispatchQueue.main.async {
                self.lastUpdated = Date()
                self.updateUI(status: status)
            }
        }
    }

    func updateUI(status: PrinterStatus) {
        if !status.isOnline {
            statusItem.button?.title = "Offline"
            statusItem.button?.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
            return
        }

        statusItem.button?.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: nil)
        statusItem.button?.title = ""

        let attributed = NSMutableAttributedString()
        let font = NSFont.menuBarFont(ofSize: 0)
        attributed.append(NSAttributedString(string: " ", attributes: [.font: font]))
        for (i, supply) in status.supplies.enumerated() {
            guard let p = supply.percent else { continue }
            if i > 0 {
                attributed.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            let circleAttachment = NSTextAttachment()
            circleAttachment.image = colorCircleImage(colorForSupply(supply), size: 8)
            circleAttachment.bounds = CGRect(x: 0, y: 1, width: 8, height: 8)
            attributed.append(NSAttributedString(attachment: circleAttachment))
            attributed.append(NSAttributedString(string: "\(p)", attributes: [.font: font]))
        }
        statusItem.button?.attributedTitle = attributed

        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        let updated = formatter.string(from: lastUpdated ?? Date())

        statusItem.button?.toolTip =
        "IP: \(printerIP) | Pages: \(status.pageCount ?? 0) | Updated: \(updated)"

        buildMenu(status: status)
    }

    private func colorForSupply(_ supply: TonerSupply) -> NSColor {
        let lower = supply.name.lowercased()
        if lower.contains("black") { return .black }
        if lower.contains("cyan") { return .cyan }
        if lower.contains("magenta") { return .magenta }
        if lower.contains("yellow") { return .yellow }
        return .gray
    }

    private func colorCircleImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func buildMenu(status: PrinterStatus) {
        let menu = NSMenu()

        for supply in status.supplies {
            let percent = supply.percent ?? 0
            var title = "\(supply.name): \(percent)%"
            if let lvl = supply.level, let max = supply.maxCapacity, max > 0 {
                title += " (\(lvl)/\(max))"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = colorCircleImage(colorForSupply(supply))
            menu.addItem(item)
        }

        if !status.paperTrays.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for tray in status.paperTrays {
                var title = tray.name
                if let p = tray.percent {
                    title += ": \(p)%"
                }
                if let lvl = tray.level, let max = tray.maxCapacity, max > 0 {
                    title += " (\(lvl)/\(max))"
                }
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }

        if let pages = status.pageCount {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Total Pages: \(pages)", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        if let updated = lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: updated, relativeTo: Date())

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            let absolute = dateFormatter.string(from: updated)

            let item = NSMenuItem(title: "Last polled: \(relative) (\(absolute))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let scheduleItem = NSMenuItem(title: "Poll Schedule", action: nil, keyEquivalent: "")
        let scheduleMenu = NSMenu()
        for schedule in PollSchedule.allCases {
            let item = NSMenuItem(title: schedule.label, action: #selector(changePollSchedule(_:)), keyEquivalent: "")
            item.target = self
            item.tag = schedule.rawValue
            item.state = schedule == currentSchedule ? .on : .off
            scheduleMenu.addItem(item)
        }
        scheduleItem.submenu = scheduleMenu
        menu.addItem(scheduleItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About SimpleTonerBar", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func openAbout() {
        let alert = NSAlert()
        alert.messageText = "SimpleTonerBar"
        alert.informativeText = "A macOS menu bar utility that auto-discovers printers and displays toner levels via SNMP.\n\nhttps://github.com/baldwinsung/SimpleTonerBar"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/baldwinsung/SimpleTonerBar")!)
        }
    }

    @objc func manualRefresh() {
        refresh()
    }

    @objc func changePollSchedule(_ sender: NSMenuItem) {
        guard let schedule = PollSchedule(rawValue: sender.tag) else { return }
        currentSchedule = schedule
    }

    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
