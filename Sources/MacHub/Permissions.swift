import AppKit
import ApplicationServices

/// ตรวจและขอสิทธิ์ที่แอปต้องใช้
@MainActor
enum Permissions {
    /// Accessibility: ใช้ดักคีย์ลัด (⌘⇧V, ⌘⌥C) และล็อกคีย์บอร์ดตอนทำความสะอาด
    /// prompt = true จะเด้งหน้าต่างของระบบขึ้นมาถามผู้ใช้
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// เปิดหน้า System Settings ตรงหัวข้อที่ต้องการ
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
