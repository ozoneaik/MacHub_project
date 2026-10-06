import Foundation
import Darwin
import IOKit
import SMCKit

// MARK: - ข้อมูลอุณหภูมิ

/// กลุ่มของ sensor (ใช้ตั้งชื่อและสรุปค่า)
enum SensorCategory: CaseIterable {
    case cpuPerformance, cpuEfficiency, gpu, battery, ssd, wifi, other

    var name: String {
        switch self {
        case .cpuPerformance: return "CPU performance core"
        case .cpuEfficiency: return "CPU efficiency core"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .ssd: return "NAND"
        case .wifi: return "Airport"
        case .other: return "Sensor"
        }
    }

    var isCPU: Bool { self == .cpuPerformance || self == .cpuEfficiency }
}

/// sensor 1 ตัว ณ เวลาที่อ่าน
struct TemperatureSensor {
    let key: String          // ชื่อ key ใน SMC เช่น "Tp0D"
    let name: String         // ชื่อที่แสดง เช่น "CPU performance core 4"
    let category: SensorCategory
    let value: Double        // องศาเซลเซียส
}

// MARK: - SystemMonitor

/// อ่านค่า RAM และอุณหภูมิทุกจุดของเครื่อง
@MainActor
final class SystemMonitor {
    struct Snapshot {
        var sensors: [TemperatureSensor]
        var ramUsedGB: Double
        var ramTotalGB: Double

        /// จุดที่ร้อนที่สุด ณ ตอนนี้
        var hottest: TemperatureSensor? {
            sensors.max { $0.value < $1.value }
        }

        /// ค่าเฉลี่ย / ค่าสูงสุดของกลุ่ม sensor ที่ต้องการ
        func average(where include: (SensorCategory) -> Bool) -> Double? {
            let values = sensors.filter { include($0.category) }.map(\.value)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        func hottest(where include: (SensorCategory) -> Bool) -> TemperatureSensor? {
            sensors.filter { include($0.category) }.max { $0.value < $1.value }
        }
    }

    private let temperatureReader = TemperatureReader()
    private let bytesPerGB = 1_073_741_824.0

    /// อ่านค่าทั้งหมด ณ ตอนนี้
    func read() -> Snapshot {
        Snapshot(
            sensors: temperatureReader.readAll(),
            ramUsedGB: readUsedRAMGB(),
            ramTotalGB: Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB
        )
    }

    /// คำนวณ RAM ที่ใช้ ให้ตรงกับ "Memory Used" ใน Activity Monitor
    /// สูตร: App Memory + Wired + Compressed
    private func readUsedRAMGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = Double(getpagesize())  // Apple Silicon = 16 KB ต่อ page
        let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let wiredPages = Double(stats.wire_count)
        let compressedPages = Double(stats.compressor_page_count)

        return (appPages + wiredPages + compressedPages) * pageSize / bytesPerGB
    }
}

// MARK: - TemperatureReader

/// อ่านอุณหภูมิทุก sensor
/// 1) ใช้ SMC เป็นหลัก (แหล่งเดียวกับแอป Stats → ค่าตรงกัน มีแยกทุก core)
/// 2) ถ้า SMC ใช้ไม่ได้ ค่อยถอยไปใช้ HID sensor
final class TemperatureReader {
    private let smc = SMC()
    private var smcSensors: [SMCSensor] = []
    private let hidReader = HIDTemperatureReader()

    /// sensor ใน SMC ที่ค้นพบตอนเริ่มแอป
    private struct SMCSensor {
        let key: String
        let code: UInt32
        let info: SMC.KeyInfo
        let name: String
        let category: SensorCategory
    }

    init() {
        discoverSMCSensors()
    }

    func readAll() -> [TemperatureSensor] {
        if let smc, !smcSensors.isEmpty {
            return smcSensors.compactMap { sensor in
                guard let value = smc.readValue(sensor.code, info: sensor.info), isValid(value) else { return nil }
                return TemperatureSensor(key: sensor.key, name: sensor.name, category: sensor.category, value: value)
            }
        }
        return hidReader.readAll()
    }

    /// ไล่ดู key ทั้งหมดใน SMC (ราว 1–2 พันตัว) ทำครั้งเดียวตอนเปิดแอป
    /// เก็บเฉพาะ key อุณหภูมิที่รู้จักและอ่านค่าได้จริง
    private func discoverSMCSensors() {
        guard let smc else { return }

        var found: [(key: String, code: UInt32, info: SMC.KeyInfo, category: SensorCategory)] = []

        for index in 0..<smc.keyCount() {
            guard let code = smc.key(at: index) else { continue }
            let key = SMC.string(from: code)
            guard let category = Self.category(forKey: key),
                  let info = smc.keyInfo(code),
                  info.type == "flt " || info.type == "sp78",
                  let value = smc.readValue(code, info: info),
                  isValid(value)
            else { continue }
            found.append((key: key, code: code, info: info, category: category))
        }

        // ตั้งชื่อเป็นลำดับในแต่ละกลุ่ม เช่น "GPU 1", "GPU 2"
        var result: [SMCSensor] = []
        for category in SensorCategory.allCases {
            let inCategory = found.filter { $0.category == category }.sorted { $0.key < $1.key }
            for (offset, item) in inCategory.enumerated() {
                let name = inCategory.count == 1 ? category.name : "\(category.name) \(offset + 1)"
                result.append(SMCSensor(key: item.key, code: item.code, info: item.info, name: name, category: category))
            }
        }
        smcSensors = result
    }

    /// แยกกลุ่มจาก 2 ตัวอักษรแรกของ key (ตามที่ Apple ตั้งชื่อใน SMC)
    private static func category(forKey key: String) -> SensorCategory? {
        switch key.prefix(2) {
        case "Tp": return .cpuPerformance
        case "Te": return .cpuEfficiency
        case "Tg": return .gpu
        case "TB": return .battery
        case "TH": return .ssd
        case "TW": return .wifi
        default: return nil  // key อื่นๆ ไม่รู้ว่าวัดอะไร → ข้าม
        }
    }

    private func isValid(_ value: Double) -> Bool {
        value > 5 && value < 130
    }
}

// MARK: - HID (สำรอง)

/// อ่านอุณหภูมิจาก HID sensor (วิธีเดิม) ใช้เมื่อ SMC อ่านไม่ได้
/// ฟังก์ชันเหล่านี้เป็น API ภายในของ IOKit จึงโหลดตอนรันด้วย dlsym
final class HIDTemperatureReader {
    private typealias ClientCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ClientSetMatching = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
    private typealias ClientCopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias ServiceCopyProperty = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias ServiceCopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias EventGetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private let temperatureEventType: Int64 = 15  // kIOHIDEventTypeTemperature

    private var client: UnsafeMutableRawPointer?
    private var copyServices: ClientCopyServices?
    private var copyProperty: ServiceCopyProperty?
    private var copyEvent: ServiceCopyEvent?
    private var getFloatValue: EventGetFloatValue?

    init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(iokit, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        guard
            let create = load("IOHIDEventSystemClientCreate", as: ClientCreate.self),
            let setMatching = load("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
            let copyServices = load("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
            let copyProperty = load("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
            let copyEvent = load("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
            let getFloatValue = load("IOHIDEventGetFloatValue", as: EventGetFloatValue.self),
            let client = create(nil)
        else { return }

        // เลือกเฉพาะ sensor ประเภทอุณหภูมิ
        let matching: NSDictionary = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
        _ = setMatching(client, Unmanaged.passUnretained(matching).toOpaque())

        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
    }

    func readAll() -> [TemperatureSensor] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let getFloatValue,
              let servicesPointer = copyServices(client)
        else { return [] }

        let services = Unmanaged<CFArray>.fromOpaque(servicesPointer).takeRetainedValue()
        let productKey = "Product" as CFString
        var result: [TemperatureSensor] = []

        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index) else { continue }

            var name = "Sensor \(index + 1)"
            if let namePointer = copyProperty(service, Unmanaged.passUnretained(productKey).toOpaque()),
               let product = Unmanaged<AnyObject>.fromOpaque(namePointer).takeRetainedValue() as? String {
                name = product
            }

            guard let event = copyEvent(service, temperatureEventType, 0, 0) else { continue }
            let value = getFloatValue(event, Int32(temperatureEventType << 16))
            Unmanaged<AnyObject>.fromOpaque(event).release()

            guard value > 5, value < 130 else { continue }
            let category: SensorCategory = name.contains("tdie") ? .cpuPerformance : .other
            result.append(TemperatureSensor(key: name, name: name, category: category, value: value))
        }
        return result
    }
}
