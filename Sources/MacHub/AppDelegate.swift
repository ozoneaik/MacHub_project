import AppKit
import Combine

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
    private let about = AboutWindowController()
    private let settings = AppSettings.shared
    private lazy var settingsWindow = SettingsWindowController(context: SettingsContext(
        clipboard: clipboard,
        colorPicker: colorPicker,
        battery: battery,
        isAccessibilityGranted: { [unowned self] in keyboard.isRunning },
        pickColor: { [unowned self] in pickColor() },
        startCleaningLock: { [unowned self] in startCleaningLock() },
        showAbout: { [unowned self] in about.show() }
    ))

    // status bar + เมนู
    private var statusItem: NSStatusItem!
    private let createBy = NSMenuItem(title: "สร้างโดย : ozoneaik", action: nil, keyEquivalent: "")
    private let hottestMenuItem = NSMenuItem(title: "จุดที่ร้อนที่สุด: --", action: nil, keyEquivalent: "")
    private let cpuMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let gpuMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let otherTempMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let allSensorsMenuItem = NSMenuItem(title: "เซ็นเซอร์ทั้งหมด", action: nil, keyEquivalent: "")
    private let ramMenuItem = NSMenuItem(title: "RAM: --", action: nil, keyEquivalent: "")
    private let batteryStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let batterySeparator = NSMenuItem.separator()
    private var clipboardMenuItem: NSMenuItem!
    private var colorPickerMenuItem: NSMenuItem!
    private var cleaningLockMenuItem: NSMenuItem!
    private let actionsSeparator = NSMenuItem.separator()
    private var accessibilityMenuItem: NSMenuItem!

    private var statsTimer: Timer?
    private var permissionTimer: Timer?
    private var settingsObserver: AnyCancellable?

    // MARK: - วงจรชีวิตแอป

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startStatsTimer()
        if settings.clipboardEnabled { clipboard.start() }
        setupKeyboard()
        observeSettings()
    }

    /// ค่าตั้งเปลี่ยน (จากหน้าตั้งค่า) → ปรับการทำงานทันที
    private func observeSettings() {
        // objectWillChange ยิงก่อนค่าเปลี่ยน → รอรอบถัดไปของ run loop แล้วค่อยอ่านค่าใหม่
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applySettings() }
            }
    }

    private func applySettings() {
        if settings.clipboardEnabled {
            clipboard.start()
            clipboard.trim()
        } else {
            clipboard.stop()
            clipboardPanel.hide()
        }
        refreshStats()
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
        for item in [hottestMenuItem, cpuMenuItem, gpuMenuItem, otherTempMenuItem, ramMenuItem, batteryStatusMenuItem] {
            item.isEnabled = false
        }
        setIcon(hottestMenuItem, "flame.fill")
        setIcon(cpuMenuItem, "cpu")
        setIcon(gpuMenuItem, "square.stack.3d.up.fill")
        setIcon(otherTempMenuItem, "thermometer.low")
        setIcon(allSensorsMenuItem, "list.bullet")
        setIcon(ramMenuItem, "memorychip")
        setIcon(batteryStatusMenuItem, SettingsSection.battery.icon)

        allSensorsMenuItem.submenu = NSMenu()
        menu.addItem(hottestMenuItem)
        menu.addItem(cpuMenuItem)
        menu.addItem(gpuMenuItem)
        menu.addItem(otherTempMenuItem)
        menu.addItem(allSensorsMenuItem)
        menu.addItem(.separator())
        menu.addItem(ramMenuItem)
        menu.addItem(.separator())
        menu.addItem(batteryStatusMenuItem)
        menu.addItem(batterySeparator)

        // ปุ่มใช้งานด่วน (ซ่อนเมื่อปิด feature ในหน้าตั้งค่า)
        clipboardMenuItem = makeItem("เปิดประวัติ Clipboard  (⌘⇧V)", #selector(openClipboard),
                                     icon: SettingsSection.clipboard.icon)
        colorPickerMenuItem = makeItem("เลือกสีจากหน้าจอ  (⌘⌥C)", #selector(pickColor),
                                       icon: SettingsSection.colorPicker.icon)
        cleaningLockMenuItem = makeItem("", #selector(startCleaningLock), icon: SettingsSection.cleaningLock.icon)
        menu.addItem(clipboardMenuItem)
        menu.addItem(colorPickerMenuItem)
        menu.addItem(cleaningLockMenuItem)
        menu.addItem(actionsSeparator)

        // แสดงเฉพาะตอนยังไม่ได้สิทธิ์ (กดแล้วไปหน้าตั้งค่า)
        accessibilityMenuItem = makeItem("ยังไม่ได้สิทธิ์ Accessibility", #selector(openGeneralSettings),
                                         icon: "exclamationmark.triangle.fill")
        menu.addItem(accessibilityMenuItem)
        menu.addItem(makeItem("ตั้งค่า…", #selector(openSettings), key: ",", icon: SettingsSection.general.icon))
        menu.addItem(makeItem("ออกจาก MacHub", #selector(quit), key: "q", icon: "power"))
        menu.addItem(.separator())
        let createByView = GradientTextView(text: createBy.title, fontSize: 32)
        createByView.onClick = { [weak self] in self?.about.show() }
        createBy.view = createByView
        menu.addItem(createBy)

        statusItem.menu = menu
        updateMenuStates()
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "", icon: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        setIcon(item, icon)
        return item
    }

    private func setIcon(_ item: NSMenuItem, _ symbol: String) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// ซ่อน/แสดงรายการในเมนูตามค่าตั้งและสิทธิ์
    private func updateMenuStates() {
        accessibilityMenuItem.isHidden = keyboard.isRunning

        clipboardMenuItem.isHidden = !settings.clipboardEnabled
        colorPickerMenuItem.isHidden = !settings.colorPickerEnabled
        cleaningLockMenuItem.isHidden = !settings.cleaningLockEnabled
        cleaningLockMenuItem.title =
            "ล็อกคีย์บอร์ดเพื่อทำความสะอาด (\(AppSettings.durationText(settings.cleaningLockDuration)))"
        actionsSeparator.isHidden = !settings.clipboardEnabled && !settings.colorPickerEnabled
            && !settings.cleaningLockEnabled

        batteryStatusMenuItem.isHidden = !settings.showBatteryInMenu
        batterySeparator.isHidden = !settings.showBatteryInMenu
    }

    // MARK: - แบต

    private func updateBatteryMenu() {
        battery.refresh()
        var title = battery.statusLine
        if battery.config.isLimitOn { title += " · จำกัด \(battery.config.limit)%" }
        batteryStatusMenuItem.title = title
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openGeneralSettings() {
        settingsWindow.show(.general)
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

        // ---- status bar: แสดงค่าของจุดที่ร้อนที่สุด เช่น " 45°C  9.4/16G" (เลือกได้ในหน้าตั้งค่า) ----
        var barParts: [String] = []
        if settings.showTemperatureInBar {
            barParts.append(hottest.map { String(format: "%.0f°C", $0.value) } ?? "--°C")
        }
        if settings.showRAMInBar {
            barParts.append(String(format: "%.1f/%.0fG", snapshot.ramUsedGB, snapshot.ramTotalGB))
        }
        statusItem.button?.title = barParts.isEmpty ? "" : " " + barParts.joined(separator: "  ")
        statusItem.button?.toolTip = hottest.map { "จุดที่ร้อนที่สุด: \($0.name) \(format($0.value))" }

        // ร้อนเกิน 85°C → เปลี่ยนไอคอนเป็นเปลวไฟ
        let symbol = (hottest?.value ?? 0) >= 85 ? "flame.fill" : "thermometer.medium"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacHub")

        // ---- เมนู: รายละเอียด ----
        hottestMenuItem.title = hottest.map { "จุดที่ร้อนที่สุด: \($0.name)  \(format($0.value))" }
            ?? "จุดที่ร้อนที่สุด: อ่านไม่ได้"

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

        // เมนูย่อย: รายการเซ็นเซอร์ทั้งหมด (จุดที่ร้อนที่สุดมีไอคอนเปลวไฟ)
        let submenu = allSensorsMenuItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        for sensor in snapshot.sensors {
            let item = NSMenuItem(title: "\(sensor.name)    \(format(sensor.value))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            if sensor.key == hottest?.key { setIcon(item, "flame.fill") }
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
            if isClipboardHotKey && self.settings.clipboardEnabled {
                self.clipboardPanel.toggle()
                return true
            }

            // 2) Cmd+Option+C → เลือกสีจากหน้าจอ
            let isColorPickerHotKey = keyCode == KeyCode.c
                && flags.contains(.maskCommand)
                && flags.contains(.maskAlternate)
                && !flags.contains(.maskShift)
                && !flags.contains(.maskControl)
            if isColorPickerHotKey && self.settings.colorPickerEnabled {
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

    @objc private func pickColor() {
        guard settings.colorPickerEnabled else { return }
        colorPicker.pick()
    }

    @objc private func startCleaningLock() {
        guard settings.cleaningLockEnabled else { return }
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
