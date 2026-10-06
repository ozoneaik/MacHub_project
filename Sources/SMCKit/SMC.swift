import Foundation
import IOKit

// MARK: - SMC (System Management Controller)

/// คุยกับชิป SMC ผ่าน IOKit เพื่ออ่าน/เขียนค่า
/// - อ่าน: ใช้ได้ทุกแอป (MacHub ใช้อ่านอุณหภูมิ)
/// - เขียน: ต้องเป็น root เท่านั้น (ตัวช่วยจำกัดการชาร์จใช้)
/// โครงสร้างข้อมูลด้านล่างต้องตรงกับที่ kernel ใช้แบบ byte ต่อ byte (ขนาด 80 bytes)
public final class SMC {
    public struct KeyInfo {
        public let size: UInt32
        public let type: String  // เช่น "flt " (float), "sp78" (fixed point)
    }

    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfoData()
        var padding: UInt16 = 0      // ช่องว่างให้ layout ตรงกับ struct ภาษา C
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0         // คำสั่งที่ต้องการ
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    // คำสั่งของ SMC
    private let commandReadKey: UInt8 = 5
    private let commandWriteKey: UInt8 = 6
    private let commandKeyFromIndex: UInt8 = 8
    private let commandKeyInfo: UInt8 = 9
    private let kernelSelector: UInt32 = 2   // kSMCHandleYPCEvent

    private var connection: io_connect_t = 0

    /// เปิดการเชื่อมต่อกับ SMC (คืน nil ถ้าไม่สำเร็จ)
    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// จำนวน key ทั้งหมดใน SMC (อ่านจาก key พิเศษ "#KEY")
    public func keyCount() -> Int {
        let code = Self.code(from: "#KEY")
        guard let info = keyInfo(code), let bytes = readBytes(code, size: info.size), bytes.count >= 4 else { return 0 }
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    /// ชื่อ key ลำดับที่ index
    public func key(at index: Int) -> UInt32? {
        var input = Param()
        input.data8 = commandKeyFromIndex
        input.data32 = UInt32(index)
        return call(input)?.key
    }

    /// ขนาดและชนิดข้อมูลของ key
    public func keyInfo(_ code: UInt32) -> KeyInfo? {
        var input = Param()
        input.key = code
        input.data8 = commandKeyInfo
        guard let output = call(input) else { return nil }
        return KeyInfo(size: output.keyInfo.dataSize, type: Self.string(from: output.keyInfo.dataType))
    }

    /// อ่านค่าแล้วแปลงเป็นตัวเลข
    public func readValue(_ code: UInt32, info: KeyInfo) -> Double? {
        guard let bytes = readBytes(code, size: info.size) else { return nil }

        switch info.type {
        case "flt " where bytes.count >= 4:
            // float 4 bytes แบบ little-endian (Apple Silicon)
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count >= 2:
            // fixed point: 8 bit จำนวนเต็ม + 8 bit ทศนิยม (Mac รุ่น Intel)
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256
        default:
            return nil
        }
    }

    public func readBytes(_ code: UInt32, size: UInt32) -> [UInt8]? {
        var input = Param()
        input.key = code
        input.keyInfo.dataSize = size
        input.data8 = commandReadKey
        guard let output = call(input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(size, 32)))) }
    }

    /// เขียนค่าลง key (ต้องเป็น root) คืน true ถ้าสำเร็จ
    /// จำนวน byte ต้องเท่ากับขนาดของ key
    @discardableResult
    public func writeBytes(_ code: UInt32, _ bytes: [UInt8]) -> Bool {
        guard let info = keyInfo(code), Int(info.size) == bytes.count, bytes.count <= 32 else { return false }
        var input = Param()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = commandWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return call(input) != nil
    }

    /// ส่งคำสั่งไปที่ SMC แล้วรับผลกลับมา
    private func call(_ input: Param) -> Param? {
        var input = input
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(
            connection, kernelSelector,
            &input, MemoryLayout<Param>.stride,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // แปลงชื่อ key 4 ตัวอักษร ↔ ตัวเลข UInt32 (เช่น "Tp0D" ↔ 0x54703044)
    public static func code(from string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func string(from code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
