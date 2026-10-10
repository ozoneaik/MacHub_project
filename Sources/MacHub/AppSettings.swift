import Foundation

/// ค่าตั้งของแอปทั้งหมด (เก็บใน UserDefaults) — แก้ได้จากหน้า "ตั้งค่า" เท่านั้น
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // อุณหภูมิ / RAM บน status bar
    @Published var showTemperatureInBar: Bool { didSet { save(showTemperatureInBar, "showTemperatureInBar") } }
    @Published var showRAMInBar: Bool { didSet { save(showRAMInBar, "showRAMInBar") } }

    // แบต
    @Published var showBatteryInMenu: Bool { didSet { save(showBatteryInMenu, "showBatteryInMenu") } }

    // Clipboard
    @Published var clipboardEnabled: Bool { didSet { save(clipboardEnabled, "clipboardEnabled") } }
    @Published var clipboardMaxItems: Int { didSet { save(clipboardMaxItems, "clipboardMaxItems") } }

    // เลือกสี
    @Published var colorPickerEnabled: Bool { didSet { save(colorPickerEnabled, "colorPickerEnabled") } }

    // ล็อกคีย์บอร์ด (วินาที)
    @Published var cleaningLockEnabled: Bool { didSet { save(cleaningLockEnabled, "cleaningLockEnabled") } }
    @Published var cleaningLockDuration: Int { didSet { save(cleaningLockDuration, "cleaningLockDuration") } }

    static let clipboardMaxItemsChoices = [20, 50, 100, 200]
    static let cleaningLockDurationChoices = [60, 120, 180, 300]

    private init() {
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }

        showTemperatureInBar = bool("showTemperatureInBar", true)
        showRAMInBar = bool("showRAMInBar", true)
        showBatteryInMenu = bool("showBatteryInMenu", true)
        clipboardEnabled = bool("clipboardEnabled", true)
        clipboardMaxItems = int("clipboardMaxItems", 50)
        colorPickerEnabled = bool("colorPickerEnabled", true)
        cleaningLockEnabled = bool("cleaningLockEnabled", true)
        cleaningLockDuration = int("cleaningLockDuration", 120)
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// เช่น 120 → "2 นาที"
    static func durationText(_ seconds: Int) -> String {
        "\(seconds / 60) นาที"
    }
}
