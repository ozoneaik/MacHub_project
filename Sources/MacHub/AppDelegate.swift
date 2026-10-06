import AppKit
import ServiceManagement

/// ศูนย์กลางของแอป: สร้าง status bar และเชื่อมทุกส่วนเข้าด้วยกัน
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // ส่วนประกอบหลัก
    private let monitor = SystemMonitor()
    private let clipboard = ClipboardManager()
    private lazy var clipboardPanel = ClipboardPanelController(manager: clipboard)
    private let keyboard = KeyboardInterceptor()
    private lazy var cleaningLock = CleaningLock(keyboard: keyboard)
    private let colorPicker = ColorPickerController()
    private let battery = BatteryManager()
    private lazy var batterySettings = BatterySettingsWindowController(manager: battery)

    // status bar + เมนู
    private var statusItem: NSStatusItem!
    private let hottestMenuItem = NSMenuItem(title: "จุดที่ร้อนที่สุด: --", action: nil, keyEquivalent: "")
    private let cpuMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let gpuMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let otherTempMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let allSensorsMenuItem = NSMenuItem(title: "เซ็นเซอร์ทั้งหมด", action: nil, keyEquivalent: "")
    private let ramMenuItem = NSMenuItem(title: "RAM: --", action: nil, keyEquivalent: "")
    private let batteryStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var accessibilityMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    private var statsTimer: Timer?
    private var permissionTimer: Timer?

    // MARK: - วงจรชีวิตแอป

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startStatsTimer()
        clipboard.start()
        setupKeyboard()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "MacHub")
            button.imagePosition = .imageLeading
            // ตัวเลขความกว้างเท่ากัน เวลาเลขเปลี่ยนจะได้ไม่กระตุก
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = " --"
        }

        let menu = NSMenu()
        // บรรทัดข้อมูล (ไม่ต้องคลิกได้)
        for item in [hottestMenuItem, cpuMenuItem, gpuMenuItem, otherTempMenuItem, ramMenuItem] {
            item.isEnabled = false
        }
        allSensorsMenuItem.submenu = NSMenu()

        menu.addItem(hottestMenuItem)
        menu.addItem(cpuMenuItem)
        menu.addItem(gpuMenuItem)
        menu.addItem(otherTempMenuItem)
        menu.addItem(allSensorsMenuItem)
        menu.addItem(.separator())
        menu.addItem(ramMenuItem)
        menu.addItem(.separator())

        batteryStatusMenuItem.isEnabled = false
        menu.addItem(batteryStatusMenuItem)
        menu.addItem(makeItem("ตั้งค่าแบต…", #selector(openBatterySettings)))
        menu.addItem(.separator())

        menu.addItem(makeItem("เปิดประวัติ Clipboard  (⌘⇧V)", #selector(openClipboard)))
        menu.addItem(makeItem("ล้างประวัติ Clipboard", #selector(clearClipboard)))
        menu.addItem(makeItem("เลือกสีจากหน้าจอ  (⌘⌥C)", #selector(pickColor)))
        menu.addItem(makeItem("ล็อกคีย์บอร์ดเพื่อทำความสะอาด (2 นาที)", #selector(startCleaningLock)))
        menu.addItem(.separator())

        accessibilityMenuItem = makeItem("", #selector(openAccessibility))
        launchAtLoginMenuItem = makeItem("เปิดอัตโนมัติตอนเข้าเครื่อง", #selector(toggleLaunchAtLogin))
        menu.addItem(accessibilityMenuItem)
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("ออกจาก MacHub", #selector(quit), key: "q"))

        statusItem.menu = menu
        updateMenuStates()
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// อัปเดตเครื่องหมาย ✓ / ⚠️ ในเมนู
    private func updateMenuStates() {
        let axOK = keyboard.isRunning
        accessibilityMenuItem.title = axOK
            ? "✓ สิทธิ์ Accessibility"
            : "⚠️ ยังไม่ได้สิทธิ์ Accessibility (คลิกเพื่อเปิด)"

        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - แบต

    private func updateBatteryMenu() {
        battery.refresh()
        var title = "🔋 " + battery.statusLine
        if battery.config.isLimitOn { title += " · จำกัด \(battery.config.limit)%" }
        batteryStatusMenuItem.title = title
    }

    @objc private func openBatterySettings() {
        batterySettings.show()
    }

    // MARK: - อุณหภูมิ / RAM

    private func startStatsTimer() {
        refreshStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStats()
            }
        }
    }

    private func refreshStats() {
        let snapshot = monitor.read()
        let hottest = snapshot.hottest

        // ---- status bar: แสดงค่าของจุดที่ร้อนที่สุด เช่น " 45°C  9.4/16G" ----
        let hottestText = hottest.map { String(format: "%.0f°C", $0.value) } ?? "--°C"
        let ramText = String(format: "%.1f/%.0fG", snapshot.ramUsedGB, snapshot.ramTotalGB)
        statusItem.button?.title = " \(hottestText)  \(ramText)"
        statusItem.button?.toolTip = hottest.map { "จุดที่ร้อนที่สุด: \($0.name) \(format($0.value))" }

        // ร้อนเกิน 85°C → เปลี่ยนไอคอนเป็นเปลวไฟ
        let symbol = (hottest?.value ?? 0) >= 85 ? "flame.fill" : "thermometer.medium"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacHub")

        // ---- เมนู: รายละเอียด ----
        hottestMenuItem.title = hottest.map { "🔥 จุดที่ร้อนที่สุด: \($0.name)  \(format($0.value))" }
            ?? "🔥 จุดที่ร้อนที่สุด: อ่านไม่ได้"

        cpuMenuItem.title = summaryLine("CPU", snapshot: snapshot) { $0.isCPU }
        gpuMenuItem.title = summaryLine("GPU", snapshot: snapshot) { $0 == .gpu }
        cpuMenuItem.isHidden = snapshot.hottest(where: { $0.isCPU }) == nil
        gpuMenuItem.isHidden = snapshot.hottest(where: { $0 == .gpu }) == nil

        // แบต / SSD / Wi-Fi รวมในบรรทัดเดียว
        let extras: [(String, SensorCategory)] = [("แบต", .battery), ("SSD", .ssd), ("Wi-Fi", .wifi)]
        let extraParts = extras.compactMap { label, category in
            snapshot.hottest(where: { $0 == category }).map { "\(label) \(format($0.value))" }
        }
        otherTempMenuItem.title = extraParts.joined(separator: "   ")
        otherTempMenuItem.isHidden = extraParts.isEmpty

        // เมนูย่อย: รายการเซ็นเซอร์ทั้งหมด (จุดที่ร้อนที่สุดมี 🔥 นำหน้า)
        let submenu = allSensorsMenuItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        for sensor in snapshot.sensors {
            let mark = sensor.key == hottest?.key ? "🔥 " : ""
            let item = NSMenuItem(title: "\(mark)\(sensor.name)    \(format(sensor.value))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        allSensorsMenuItem.isHidden = snapshot.sensors.isEmpty

        let ramPercent = snapshot.ramTotalGB > 0 ? snapshot.ramUsedGB / snapshot.ramTotalGB * 100 : 0
        ramMenuItem.title = String(
            format: "RAM: ใช้ %.2f GB จาก %.0f GB (%.0f%%)",
            snapshot.ramUsedGB, snapshot.ramTotalGB, ramPercent
        )

        updateBatteryMenu()

        // เช็คสถานะสิทธิ์ไปด้วย (เผื่อผู้ใช้เพิ่งไปกดอนุญาต)
        updateMenuStates()
    }

    /// เช่น "CPU  เฉลี่ย 43.6°C · สูงสุด 44.9°C"
    private func summaryLine(_ label: String, snapshot: SystemMonitor.Snapshot,
                             where include: (SensorCategory) -> Bool) -> String {
        guard let average = snapshot.average(where: include),
              let hottest = snapshot.hottest(where: include) else { return "" }
        return "\(label)  เฉลี่ย \(format(average)) · สูงสุด \(format(hottest.value))"
    }

    private func format(_ celsius: Double) -> String {
        String(format: "%.1f°C", celsius)
    }

    // MARK: - คีย์บอร์ด

    private func setupKeyboard() {
        keyboard.onKeyDown = { [weak self] keyCode, flags in
            guard let self else { return false }

            // 1) Cmd+Shift+V → เปิด/ปิดประวัติ clipboard
            let isClipboardHotKey = keyCode == KeyCode.v
                && flags.contains(.maskCommand)
                && flags.contains(.maskShift)
                && !flags.contains(.maskControl)
                && !flags.contains(.maskAlternate)
            if isClipboardHotKey {
                self.clipboardPanel.toggle()
                return true
            }

            // 2) Cmd+Option+C → เลือกสีจากหน้าจอ
            let isColorPickerHotKey = keyCode == KeyCode.c
                && flags.contains(.maskCommand)
                && flags.contains(.maskAlternate)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskControl)
            if isColorPickerHotKey {
                self.colorPicker.pick()
                return true
            }

            // 3) ถ้าหน้าต่าง clipboard เปิดอยู่ ให้มันจัดการ ↑ ↓ ⏎ esc
            return self.clipboardPanel.isVisible && self.clipboardPanel.handleKey(keyCode)
        }

        startKeyboardWhenAllowed()
    }

    /// เริ่มดักคีย์บอร์ด ถ้ายังไม่ได้สิทธิ์จะลองใหม่ทุก 2 วินาทีจนกว่าผู้ใช้จะอนุญาต
    private func startKeyboardWhenAllowed() {
        if Permissions.isAccessibilityTrusted(prompt: true) && keyboard.start() {
            updateMenuStates()
            return
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Permissions.isAccessibilityTrusted(prompt: false) && self.keyboard.start() {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                }
                self.updateMenuStates()
            }
        }
    }

    // MARK: - เมนู actions

    @objc private func openClipboard() {
        clipboardPanel.show()
    }

    @objc private func clearClipboard() {
        clipboard.clear()
    }

    @objc private func pickColor() {
        colorPicker.pick()
    }

    @objc private func startCleaningLock() {
        // ล็อกได้ต้องดักคีย์บอร์ดได้ก่อน
        guard keyboard.isRunning else {
            let alert = NSAlert()
            alert.messageText = "ยังล็อกคีย์บอร์ดไม่ได้"
            alert.informativeText = "ต้องอนุญาตสิทธิ์ Accessibility ให้ MacHub ก่อน"
            alert.addButton(withTitle: "เปิด System Settings")
            alert.addButton(withTitle: "ยกเลิก")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { Permissions.openAccessibilitySettings() }
            return
        }
        cleaningLock.start()
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MacHub: ตั้งค่าเปิดอัตโนมัติไม่สำเร็จ: \(error)")
        }
        updateMenuStates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
