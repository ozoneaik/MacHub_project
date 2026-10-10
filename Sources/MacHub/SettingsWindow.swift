import AppKit
import ServiceManagement
import SwiftUI

/// หมวดในหน้าตั้งค่า — ใช้ไอคอนชุดเดียวกับเมนูบน status bar
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, temperature, battery, clipboard, colorPicker, cleaningLock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "ทั่วไป"
        case .temperature: "อุณหภูมิ & RAM"
        case .battery: "แบตเตอรี่"
        case .clipboard: "Clipboard"
        case .colorPicker: "เลือกสี"
        case .cleaningLock: "ล็อกคีย์บอร์ด"
        }
    }

    /// ชื่อ SF Symbol
    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .temperature: "thermometer.medium"
        case .battery: "battery.100.bolt"
        case .clipboard: "doc.on.clipboard.fill"
        case .colorPicker: "eyedropper.halffull"
        case .cleaningLock: "keyboard.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .temperature: .orange
        case .battery: .green
        case .clipboard: .blue
        case .colorPicker: .pink
        case .cleaningLock: .teal
        }
    }
}

/// สิ่งที่หน้าตั้งค่าต้องใช้จากส่วนอื่นของแอป
struct SettingsContext {
    let clipboard: ClipboardManager
    let colorPicker: ColorPickerController
    let battery: BatteryManager
    let isAccessibilityGranted: @MainActor () -> Bool
    let pickColor: @MainActor () -> Void
    let startCleaningLock: @MainActor () -> Void
    let showAbout: @MainActor () -> Void
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection? = .general
}

/// หน้าต่าง "ตั้งค่า MacHub"
@MainActor
final class SettingsWindowController: NSObject {
    private let context: SettingsContext
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(context: SettingsContext) {
        self.context = context
        super.init()
    }

    func show(_ section: SettingsSection? = nil) {
        if let section { navigation.selection = section }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ตั้งค่า MacHub"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 640, height: 420)
        window.contentView = NSHostingView(rootView: SettingsView(navigation: navigation, context: context))
        window.setContentSize(CGSize(width: 720, height: 560))
        window.center()
        return window
    }
}

// MARK: - หน้าตา

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    let context: SettingsContext

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                SectionIconLabel(section: section)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection ?? .general {
        case .general: GeneralSettingsView(context: context)
        case .temperature: TemperatureSettingsView()
        case .battery: BatterySettingsView(manager: context.battery)
        case .clipboard: ClipboardSettingsView(clipboard: context.clipboard)
        case .colorPicker: ColorPickerSettingsView(context: context)
        case .cleaningLock: CleaningLockSettingsView(context: context)
        }
    }
}

/// ไอคอนในกรอบสี่เหลี่ยมมนสีๆ แบบ System Settings
struct SectionIconLabel: View {
    let section: SettingsSection

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: section.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// หัวข้อด้านบนของแต่ละหน้า
private struct SectionHeader: View {
    let section: SettingsSection
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
}

// MARK: - ทั่วไป

private struct GeneralSettingsView: View {
    let context: SettingsContext

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityOK = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                SectionHeader(section: .general, subtitle: "การเริ่มต้นแอปและสิทธิ์ที่ต้องใช้")
            }

            Section("การเริ่มต้น") {
                Toggle("เปิดอัตโนมัติตอนเข้าเครื่อง", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
            }

            Section {
                HStack {
                    if accessibilityOK {
                        Label("ได้รับสิทธิ์ Accessibility แล้ว", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("ยังไม่ได้สิทธิ์ Accessibility", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("เปิด System Settings") { Permissions.openAccessibilitySettings() }
                }
                caption("ต้องใช้สำหรับปุ่มลัด (⌘⇧V, ⌘⌥C) และการล็อกคีย์บอร์ด")
            } header: {
                Text("สิทธิ์")
            }

            Section("ปุ่มลัด") {
                LabeledContent("เปิดประวัติ Clipboard", value: "⌘⇧V")
                LabeledContent("เลือกสีจากหน้าจอ", value: "⌘⌥C")
            }

            Section {
                Button("เกี่ยวกับผู้สร้าง…") { context.showAbout() }
            }
        }
        .formStyle(.grouped)
        .onAppear { accessibilityOK = context.isAccessibilityGranted() }
        .onReceive(refresh) { _ in
            accessibilityOK = context.isAccessibilityGranted()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacHub: ตั้งค่าเปิดอัตโนมัติไม่สำเร็จ: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - อุณหภูมิ & RAM

private struct TemperatureSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                SectionHeader(section: .temperature, subtitle: "สิ่งที่แสดงบน status bar")
            }
            Section {
                Toggle("แสดงอุณหภูมิจุดที่ร้อนที่สุด", isOn: $settings.showTemperatureInBar)
                Toggle("แสดง RAM ที่ใช้อยู่", isOn: $settings.showRAMInBar)
                caption("ปิดทั้งสองอย่าง = แสดงแค่ไอคอน · ไอคอนเปลี่ยนเป็นเปลวไฟเมื่อร้อนเกิน 85°C")
            } header: {
                Text("Status bar")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Clipboard

private struct ClipboardSettingsView: View {
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                SectionHeader(section: .clipboard, subtitle: "เก็บประวัติข้อความ รูป และไฟล์ที่ copy")
            }
            Section {
                Toggle("เปิดใช้ประวัติ Clipboard", isOn: $settings.clipboardEnabled)
                caption("ปุ่มลัด ⌘⇧V · ปิดแล้วจะหยุดเก็บประวัติและปุ่มลัดจะใช้ไม่ได้")
            }
            Section {
                Picker("จำนวนรายการสูงสุด", selection: $settings.clipboardMaxItems) {
                    ForEach(AppSettings.clipboardMaxItemsChoices, id: \.self) { Text("\($0) รายการ").tag($0) }
                }
                HStack {
                    Text("ตอนนี้มี \(clipboard.items.count) รายการ")
                    Spacer()
                    Button("ล้างประวัติ", role: .destructive) { clipboard.clear() }
                        .disabled(clipboard.items.isEmpty)
                }
            } header: {
                Text("ประวัติ")
            }
            .disabled(!settings.clipboardEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - เลือกสี

private struct ColorPickerSettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings = AppSettings.shared
    @State private var historyCount = 0

    var body: some View {
        Form {
            Section {
                SectionHeader(section: .colorPicker, subtitle: "ดูดสีจากหน้าจอ แล้ว copy เป็น HEX / RGB / HSL")
            }
            Section {
                Toggle("เปิดใช้การเลือกสี", isOn: $settings.colorPickerEnabled)
                caption("ปุ่มลัด ⌘⌥C")
            }
            Section {
                HStack {
                    Button("เลือกสีตอนนี้") { context.pickColor() }
                    Spacer()
                    Button("ล้างประวัติสี (\(historyCount))", role: .destructive) {
                        context.colorPicker.clearHistory()
                        historyCount = 0
                    }
                    .disabled(historyCount == 0)
                }
            }
            .disabled(!settings.colorPickerEnabled)
        }
        .formStyle(.grouped)
        .onAppear { historyCount = context.colorPicker.historyCount }
    }
}

// MARK: - ล็อกคีย์บอร์ด

private struct CleaningLockSettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                SectionHeader(section: .cleaningLock, subtitle: "ล็อกคีย์บอร์ดชั่วคราวเพื่อเช็ดทำความสะอาด")
            }
            Section {
                Toggle("เปิดใช้การล็อกคีย์บอร์ด", isOn: $settings.cleaningLockEnabled)
            }
            Section {
                Picker("ปลดล็อกอัตโนมัติหลัง", selection: $settings.cleaningLockDuration) {
                    ForEach(AppSettings.cleaningLockDurationChoices, id: \.self) {
                        Text(AppSettings.durationText($0)).tag($0)
                    }
                }
                caption("ปลดล็อกก่อนเวลาได้โดยเอาเมาส์กด \"เสร็จแล้ว\"")
                Button("เริ่มล็อกตอนนี้") { context.startCleaningLock() }
            }
            .disabled(!settings.cleaningLockEnabled)
        }
        .formStyle(.grouped)
    }
}
