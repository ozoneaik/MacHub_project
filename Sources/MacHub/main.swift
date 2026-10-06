import AppKit

// จุดเริ่มต้นของโปรแกรม
// MainActor.assumeIsolated = ยืนยันกับ compiler ว่าโค้ดนี้รันบน main thread (ซึ่งจริง)
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // .accessory = ไม่มีไอคอนใน Dock ไม่มีเมนูบาร์ของตัวเอง มีแค่ไอคอนบน status bar
    app.setActivationPolicy(.accessory)

    // เริ่ม event loop (บรรทัดนี้จะค้างอยู่จนกว่าแอปจะปิด)
    app.run()
}
