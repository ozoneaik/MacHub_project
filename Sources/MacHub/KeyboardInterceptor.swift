import AppKit
import CoreGraphics

/// ดักจับการกดปุ่มคีย์บอร์ดทั้งระบบด้วย CGEventTap
/// (ต้องได้สิทธิ์ Accessibility ก่อน ไม่งั้น tapCreate จะคืนค่า nil)
@MainActor
final class KeyboardInterceptor {
    /// เรียกเมื่อมีการกดปุ่ม คืนค่า true = "กลืน" event ไม่ให้แอปอื่นเห็น
    var onKeyDown: (@MainActor (CGKeyCode, CGEventFlags) -> Bool)?
    /// true = กลืนทุกปุ่ม รวมปุ่มเสียง/ความสว่าง (ใช้ตอนล็อกเพื่อทำความสะอาดคีย์บอร์ด)
    var isLocked = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// เริ่มดักคีย์บอร์ด คืนค่า false ถ้ายังไม่ได้สิทธิ์ Accessibility
    func start() -> Bool {
        if tap != nil { return true }

        // กดปุ่ม, ปล่อยปุ่ม, modifier เปลี่ยน และปุ่มพิเศษ (เสียง/ความสว่าง/เล่นเพลง)
        let mask: CGEventMask =
            (1 << CGEventMask(CGEventType.keyDown.rawValue)) |
            (1 << CGEventMask(CGEventType.keyUp.rawValue)) |
            (1 << CGEventMask(CGEventType.flagsChanged.rawValue)) |
            (1 << CGEventMask(systemDefinedEventType))

        // ส่ง self ไปเป็น pointer เพราะ callback แบบ C ไม่สามารถจับตัวแปรได้
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,       // ดักระดับ session ของผู้ใช้
            place: .headInsertEventTap,     // ดักก่อนคนอื่น
            options: .defaultTap,           // แก้ไข/กลืน event ได้
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: selfPointer
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // ระบบปิด tap ชั่วคราว (เช่น ตอบช้าเกินไป) → เปิดกลับ
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case _ where isLocked:
            return true  // ล็อกอยู่ → กลืนทุกปุ่ม

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            return onKeyDown?(keyCode, event.flags) ?? false

        default:
            return false
        }
    }
}

/// NX_SYSDEFINED: event ของปุ่มพิเศษ เช่น เสียง ความสว่าง เล่น/หยุดเพลง (CGEventType ไม่มีชื่อให้)
private let systemDefinedEventType: UInt32 = 14

/// ฟังก์ชันที่ระบบเรียกทุกครั้งที่มีการกดคีย์ (ต้องเป็นฟังก์ชันแบบ C จึงจับตัวแปรภายนอกไม่ได้
/// เลยส่ง KeyboardInterceptor มาทาง userInfo แทน)
private let keyboardTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<KeyboardInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

    // callback นี้รันบน main run loop จึงเรียกโค้ด MainActor ได้
    let shouldSwallow = MainActor.assumeIsolated {
        interceptor.handle(type: type, event: event)
    }

    // คืน nil = กลืน event (แอปอื่นไม่เห็น), คืน event = ปล่อยผ่านตามปกติ
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
