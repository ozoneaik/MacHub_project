import Foundation

// ข้อมูลที่แอปกับตัวช่วยจัดการแบต (MacHubChargeHelper) ต้องรู้ตรงกัน

public enum ChargeHelperInfo {
    /// เพิ่มเลขนี้ทุกครั้งที่แก้โค้ดตัวช่วย → แอปจะรู้ว่าต้องติดตั้งตัวช่วยใหม่
    public static let version = "3"
    public static let label = "com.phuwadech.machub.chargehelper"
    /// ที่อยู่ของตัวช่วยหลังติดตั้ง (เป็นของ root แก้ไขไม่ได้ถ้าไม่ใช่ admin)
    public static let installedPath = "/Library/PrivilegedHelperTools/\(label)"
    /// LaunchDaemon → ระบบเปิดตัวช่วยให้ตั้งแต่เปิดเครื่อง แม้ไม่ได้เปิด MacHub
    public static let daemonPlistPath = "/Library/LaunchDaemons/\(label).plist"
    /// กฎ sudo ที่ให้ผู้ใช้สั่ง `set` / `uninstall` ได้โดยไม่ต้องใส่รหัส
    public static let sudoersPath = "/etc/sudoers.d/machub"
    /// ไฟล์ค่าตั้ง (root เขียน, ทุกคนอ่านได้) และสถานะล่าสุด (daemon เขียนทุก 10 วินาที)
    public static let dataDirectory = "/Library/Application Support/MacHub"
    public static let configPath = "\(dataDirectory)/charge-config.json"
    public static let statusPath = "\(dataDirectory)/charge-status.json"
    /// ชื่อไฟล์ใน Contents/MacOS ของแอป
    public static let bundledName = "MacHubChargeHelper"
}

/// ค่าตั้งของการจัดการแบต
public struct ChargeConfig: Codable, Equatable {
    /// % สูงสุดที่ยอมให้ชาร์จ (0 = ไม่จำกัด)
    public var limit: Int
    /// เสียบสายอยู่แต่แบตเกิน limit → ตัดไฟจากสาย ใช้แบตจนลดลงถึง limit
    public var autoDischarge: Bool
    /// Discharge ครั้งเดียวลงไปที่ % นี้ (nil = ไม่ได้สั่ง) ถึงแล้วตัวช่วยจะล้างค่าเอง
    public var dischargeTarget: Int?
    /// หยุดชาร์จเมื่อแบตร้อนถึงกี่ °C (0 = ปิด) เย็นลง 2°C แล้วชาร์จต่อ
    public var heatLimit: Int
    /// เสียบสายและยังชาร์จไม่ถึง limit → ไม่ให้เครื่อง sleep (แม้พับจอ)
    public var preventSleep: Bool

    public static let `default` = ChargeConfig(
        limit: 0, autoDischarge: false, dischargeTarget: nil, heatLimit: 35, preventSleep: true
    )

    public init(limit: Int, autoDischarge: Bool, dischargeTarget: Int?, heatLimit: Int, preventSleep: Bool) {
        self.limit = limit
        self.autoDischarge = autoDischarge
        self.dischargeTarget = dischargeTarget
        self.heatLimit = heatLimit
        self.preventSleep = preventSleep
    }

    /// บีบค่าให้อยู่ในช่วงที่ปลอดภัย (ตัวช่วยเรียกก่อนบันทึกเสมอ)
    public func sanitized() -> ChargeConfig {
        var config = self
        config.limit = limit <= 0 || limit >= 100 ? 0 : min(max(limit, 50), 95)
        config.dischargeTarget = dischargeTarget.map { min(max($0, 20), 95) }
        config.heatLimit = heatLimit <= 0 ? 0 : min(max(heatLimit, 30), 50)
        return config
    }

    public var isLimitOn: Bool { limit > 0 && limit < 100 }
}

/// สถานะล่าสุดที่ daemon รายงาน
public struct ChargeStatus: Codable {
    public var percent: Int
    public var onAC: Bool
    public var isCharging: Bool       // แบตกำลังรับไฟจริง (ตามที่ระบบรายงาน)
    public var inhibited: Bool        // ตัวช่วยสั่งหยุดชาร์จอยู่
    public var discharging: Bool      // ตัวช่วยตัดไฟจากสาย ใช้แบตอยู่
    public var heatHold: Bool         // หยุดเพราะแบตร้อน
    public var temperature: Double?   // °C
    public var sleepPrevented: Bool
    public var updated: Date

    public init(percent: Int, onAC: Bool, isCharging: Bool, inhibited: Bool, discharging: Bool,
                heatHold: Bool, temperature: Double?, sleepPrevented: Bool, updated: Date) {
        self.percent = percent
        self.onAC = onAC
        self.isCharging = isCharging
        self.inhibited = inhibited
        self.discharging = discharging
        self.heatHold = heatHold
        self.temperature = temperature
        self.sleepPrevented = sleepPrevented
        self.updated = updated
    }
}

public extension JSONEncoder {
    static let charge: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

public extension JSONDecoder {
    static let charge: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
