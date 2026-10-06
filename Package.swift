// swift-tools-version:5.9
// ไฟล์นี้บอก Swift Package Manager ว่าโปรเจกต์ชื่ออะไร รองรับ macOS เวอร์ชันไหน และ source อยู่ที่ไหน
import PackageDescription

let package = Package(
    name: "MacHub",
    // ต้องการ macOS 14 (Sonoma) ขึ้นไป
    platforms: [.macOS(.v14)],
    targets: [
        // โค้ดคุยกับชิป SMC ใช้ร่วมกันระหว่างแอปกับตัวช่วย
        .target(
            name: "SMCKit",
            path: "Sources/SMCKit"
        ),
        // แอปหลัก
        .executableTarget(
            name: "MacHub",
            dependencies: ["SMCKit"],
            path: "Sources/MacHub"
        ),
        // ตัวช่วยจำกัดการชาร์จ (รันด้วยสิทธิ์ root ผ่าน sudo)
        .executableTarget(
            name: "MacHubChargeHelper",
            dependencies: ["SMCKit"],
            path: "Sources/MacHubChargeHelper"
        ),
    ]
)
