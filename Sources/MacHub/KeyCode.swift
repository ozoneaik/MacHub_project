import CoreGraphics

/// รหัสปุ่มคีย์บอร์ด (virtual key code) ที่แอปนี้ใช้
/// ค่าพวกนี้เป็นค่าคงที่ของ macOS ไม่ขึ้นกับภาษาของคีย์บอร์ด
enum KeyCode {
    static let escape: CGKeyCode = 53
    static let returnKey: CGKeyCode = 36
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126
    static let c: CGKeyCode = 8
    static let v: CGKeyCode = 9
}
