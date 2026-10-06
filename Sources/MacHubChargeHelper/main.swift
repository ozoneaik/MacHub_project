import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import SMCKit

// ตัวช่วยจัดการแบตของ MacHub (ต้องเป็น root ถึงจะเขียน SMC ได้)
//
// คำสั่ง:
//   --version        บอกเวอร์ชัน (ไม่ต้องเป็น root)
//   probe            แสดงค่า key ที่เกี่ยวกับการชาร์จ (ไว้ตรวจปัญหา)
//   daemon           ทำงานเบื้องหลังตลอด (launchd เรียกให้ตั้งแต่เปิดเครื่อง)
//   install-daemon   ติดตั้ง/รีสตาร์ท LaunchDaemon (สคริปต์ติดตั้งเรียกตอนใส่รหัส admin)
//   set <json>       บันทึกค่าตั้งใหม่ (MacHub เรียกผ่าน `sudo -n`)
//   uninstall        ถอนการติดตั้งทั้งหมด คืนการชาร์จปกติ (MacHub เรียกผ่าน `sudo -n`)

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error \(message)\n".utf8))
    exit(1)
}

// MARK: - สั่ง SMC

/// key ที่ใช้สั่งงาน แต่ละรุ่น firmware ใช้ไม่เหมือนกัน
/// ถ้าเครื่องมี key แบบใหม่ ใช้แบบใหม่ตัวเดียว (บน M4 key เก่ากับใหม่เป็นตัวเดียวกันข้างใน
/// เขียนทั้งคู่แล้วทับกันเอง ทำให้ discharge ติดๆ ดับๆ)
struct SwitchKey {
    let name: String
    let on: [UInt8]   // ค่าตอน "เปิดใช้" (หยุดชาร์จ / ตัดไฟจากสาย)
    let off: [UInt8]  // ค่าปกติ
}

/// หยุดชาร์จ: CHTE (firmware ใหม่) หรือ CH0B + CH0C (firmware เก่า)
let inhibitChargeKeySets = [
    [SwitchKey(name: "CHTE", on: [0x01, 0x00, 0x00, 0x00], off: [0x00, 0x00, 0x00, 0x00])],
    [SwitchKey(name: "CH0B", on: [0x02], off: [0x00]), SwitchKey(name: "CH0C", on: [0x02], off: [0x00])],
]

/// ตัดไฟจากสายชาร์จ (ใช้ทำ discharge): CHIE (firmware ใหม่) หรือ CH0I (firmware เก่า)
let disableAdapterKeySets = [
    [SwitchKey(name: "CHIE", on: [0x08], off: [0x00])],
    [SwitchKey(name: "CH0I", on: [0x01], off: [0x00])],
]

final class SMCSwitches {
    private let smc: SMC
    private let inhibitKeys: [SwitchKey]
    private let adapterKeys: [SwitchKey]

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        /// ชุดแรกที่เครื่องนี้มีครบทุก key
        func firstAvailable(_ sets: [[SwitchKey]]) -> [SwitchKey] {
            sets.first { keys in
                keys.allSatisfy { key in
                    smc.keyInfo(SMC.code(from: key.name)).map { Int($0.size) == key.on.count } ?? false
                }
            } ?? []
        }
        inhibitKeys = firstAvailable(inhibitChargeKeySets)
        adapterKeys = firstAvailable(disableAdapterKeySets)
    }

    var canInhibitCharging: Bool { !inhibitKeys.isEmpty }
    var canDisableAdapter: Bool { !adapterKeys.isEmpty }

    func setChargingInhibited(_ value: Bool) {
        set(inhibitKeys, on: value)
    }

    func setAdapterDisabled(_ value: Bool) {
        set(adapterKeys, on: value)
    }

    /// เขียนเฉพาะ key ที่ค่าปัจจุบันไม่ตรง (firmware อาจเติมบิตเอง เช่นเขียน 08 อ่านได้ 09
    /// จึงเทียบแค่ว่า "เป็นศูนย์หรือไม่")
    private func set(_ keys: [SwitchKey], on: Bool) {
        for key in keys {
            let code = SMC.code(from: key.name)
            let current = smc.readBytes(code, size: UInt32(key.on.count))
            let isOn = current.map { $0.contains { $0 != 0 } }
            if isOn != on {
                smc.writeBytes(code, on ? key.on : key.off)
            }
        }
    }

    /// อุณหภูมิแบต: ค่าสูงสุดของ sensor TB0T / TB1T / TB2T
    func batteryTemperature() -> Double? {
        let values = ["TB0T", "TB1T", "TB2T"].compactMap { name -> Double? in
            let code = SMC.code(from: name)
            guard let info = smc.keyInfo(code), let value = smc.readValue(code, info: info),
                  value > 0, value < 100 else { return nil }
            return value
        }
        return values.max()
    }

    func describe() -> String {
        (inhibitChargeKeySets + disableAdapterKeySets).flatMap { $0 }.map { key in
            let code = SMC.code(from: key.name)
            guard let info = smc.keyInfo(code), let bytes = smc.readBytes(code, size: info.size) else {
                return "\(key.name): -"
            }
            return "\(key.name): " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

// MARK: - อ่านสถานะแบต

struct BatteryState {
    let percent: Int
    let onAC: Bool
    let isCharging: Bool
}

func readBattery() -> BatteryState? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }

    for source in list {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
        else { continue }
        return BatteryState(
            percent: current * 100 / max,
            onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false
        )
    }
    return nil
}

// MARK: - ไฟล์ค่าตั้ง / สถานะ

func readConfig() -> ChargeConfig {
    guard let data = FileManager.default.contents(atPath: ChargeHelperInfo.configPath),
          let config = try? JSONDecoder.charge.decode(ChargeConfig.self, from: data)
    else { return .default }
    return config.sanitized()
}

/// เขียนแบบ atomic (เขียนไฟล์ชั่วคราวแล้วเปลี่ยนชื่อ) คนอ่านจะไม่เจอไฟล์ครึ่งๆ กลางๆ
func writeJSON<T: Encodable>(_ value: T, to path: String) {
    guard let data = try? JSONEncoder.charge.encode(value) else { return }
    try? FileManager.default.createDirectory(
        atPath: ChargeHelperInfo.dataDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    let url = URL(fileURLWithPath: path)
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
}

// MARK: - daemon

/// ตัดสินใจทุก 10 วินาที (และทันทีที่ค่าตั้งเปลี่ยน / ตื่นจาก sleep)
final class ChargeDaemon {
    private let switches: SMCSwitches
    private var config = ChargeConfig.default

    // สถานะที่ต้องจำข้ามรอบ (กันสลับไปมาถี่ๆ)
    private var limitHold = false   // ถึง limit แล้ว หยุดชาร์จอยู่
    private var heatHold = false    // ร้อนเกิน หยุดชาร์จอยู่
    private var inhibited = false
    private var discharging = false

    private var sleepAssertion: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerPort: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var powerNotifyPort: IONotificationPortRef?

    private let resumeGap = 3  // ชาร์จต่อเมื่อลดลงต่ำกว่า limit กี่ %
    private let heatGap = 2.0  // ชาร์จต่อเมื่อเย็นลงกี่ °C

    init(switches: SMCSwitches) {
        self.switches = switches
    }

    func run() -> Never {
        // ถูกสั่งหยุด (เช่น uninstall / launchctl bootout) → คืนการชาร์จปกติก่อนจบ
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.restoreAndExit() }
            source.resume()
            signalSources.append(source)
        }

        watchConfig()
        registerForSleep()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 10)
        timer.setEventHandler { [weak self] in self?.apply() }
        timer.resume()
        self.timer = timer

        dispatchMain()
    }

    /// คืนการชาร์จปกติแล้วจบโปรแกรม
    func restoreAndExit() -> Never {
        switches.setAdapterDisabled(false)
        switches.setChargingInhibited(false)
        setSleepPrevented(false)
        exit(0)
    }

    // MARK: ตัดสินใจ

    func apply() {
        config = readConfig()
        guard let battery = readBattery() else { return }
        let temperature = switches.batteryTemperature()

        // 1) Discharge ครั้งเดียว: ถึงเป้าแล้วล้างค่าเอง
        var manualDischarge = false
        if let target = config.dischargeTarget {
            if battery.percent <= target {
                config.dischargeTarget = nil
                writeJSON(config, to: ChargeHelperInfo.configPath)
            } else {
                manualDischarge = true
            }
        }
        // 2) Discharge อัตโนมัติ: เกิน limit → ใช้แบตจนลงมาถึง limit
        let autoDischarge = config.autoDischarge && config.isLimitOn && battery.percent > config.limit
        discharging = battery.onAC && switches.canDisableAdapter && (manualDischarge || autoDischarge)

        // 3) จำกัด %
        if !config.isLimitOn {
            limitHold = false
        } else if battery.percent >= config.limit {
            limitHold = true
        } else if battery.percent <= config.limit - resumeGap {
            limitHold = false
        }

        // 4) กันร้อน
        if config.heatLimit <= 0 || temperature == nil {
            heatHold = false
        } else if let temperature, temperature >= Double(config.heatLimit) {
            heatHold = true
        } else if let temperature, temperature <= Double(config.heatLimit) - heatGap {
            heatHold = false
        }

        inhibited = limitHold || heatHold || discharging

        // เช็คทุกรอบ เผื่อระบบรีเซ็ตค่ากลับเอง (เช่นหลังตื่นจาก sleep) — เขียนเฉพาะที่ไม่ตรง
        switches.setChargingInhibited(inhibited)
        switches.setAdapterDisabled(discharging)

        // 5) กันชาร์จเกินตอน sleep: กำลังชาร์จขึ้นไปหา limit → ห้าม sleep จนกว่าจะถึง
        setSleepPrevented(config.preventSleep && config.isLimitOn && battery.onAC && !inhibited)

        writeJSON(ChargeStatus(
            percent: battery.percent,
            onAC: battery.onAC,
            isCharging: battery.isCharging,
            inhibited: inhibited,
            discharging: discharging,
            heatHold: heatHold,
            temperature: temperature,
            sleepPrevented: sleepAssertion != 0,
            updated: Date()
        ), to: ChargeHelperInfo.statusPath)
    }

    // MARK: ค่าตั้งเปลี่ยน → ทำทันที

    private func watchConfig() {
        try? FileManager.default.createDirectory(
            atPath: ChargeHelperInfo.dataDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        // ดูที่ระดับโฟลเดอร์ เพราะการเขียนแบบ atomic เป็นการสร้างไฟล์ใหม่แล้วเปลี่ยนชื่อทับ
        let fd = open(ChargeHelperInfo.dataDirectory, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        var lastConfig = readConfig()
        source.setEventHandler { [weak self] in
            let newConfig = readConfig()
            guard newConfig != lastConfig else { return }  // ไฟล์สถานะเปลี่ยนเฉยๆ ไม่ต้องทำอะไร
            lastConfig = newConfig
            self?.apply()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    // MARK: sleep

    private func setSleepPrevented(_ prevent: Bool) {
        if prevent, sleepAssertion == 0 {
            // PreventSystemSleep = เหมือน `caffeinate -s` ใช้ได้เฉพาะตอนเสียบสาย กันได้แม้พับจอ
            IOPMAssertionCreateWithName(
                "PreventSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MacHub: กำลังชาร์จถึงค่าที่จำกัดไว้" as CFString,
                &sleepAssertion
            )
        } else if !prevent, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    private func registerForSleep() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(refcon, &powerNotifyPort, powerCallback, &powerNotifier)
        if let powerNotifyPort {
            IONotificationPortSetDispatchQueue(powerNotifyPort, .main)
        }
    }

    /// ระบบกำลังจะ sleep (เช่นถูกบังคับ หรือแบตไม่ได้เสียบสาย) → ตั้งค่าที่ปลอดภัยไว้ก่อนหลับ
    fileprivate func systemWillSleep() {
        // ห้ามตัดไฟจากสายระหว่าง sleep ไม่งั้นแบตจะลดลงเรื่อยๆ ทั้งคืน
        switches.setAdapterDisabled(false)
        discharging = false
        // ยังชาร์จไม่ถึง limit แต่ sleep อยู่ดี → ตัวช่วยดูไม่ได้ หยุดชาร์จไว้ก่อน กันชาร์จเกิน
        if config.isLimitOn {
            switches.setChargingInhibited(true)
        }
    }

    fileprivate func systemDidWake() {
        apply()
    }

    fileprivate func allowPowerChange(_ argument: UnsafeMutableRawPointer?) {
        IOAllowPowerChange(powerPort, Int(bitPattern: argument))
    }
}

// ค่าของ kIOMessage* (ใน header เป็น macro ที่ Swift มองไม่เห็น)
private let messageCanSystemSleep: UInt32 = 0xE000_0270
private let messageSystemWillSleep: UInt32 = 0xE000_0280
private let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

private let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, argument in
    guard let refcon else { return }
    let daemon = Unmanaged<ChargeDaemon>.fromOpaque(refcon).takeUnretainedValue()
    switch messageType {
    case messageCanSystemSleep:
        daemon.allowPowerChange(argument)
    case messageSystemWillSleep:
        daemon.systemWillSleep()
        daemon.allowPowerChange(argument)
    case messageSystemHasPoweredOn:
        daemon.systemDidWake()
    default:
        break
    }
}

// MARK: - ติดตั้ง / ถอน

func runLaunchctl(_ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func installDaemon() {
    let plist: [String: Any] = [
        "Label": ChargeHelperInfo.label,
        "ProgramArguments": [ChargeHelperInfo.installedPath, "daemon"],
        "RunAtLoad": true,
        "KeepAlive": true,
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
        fail("สร้าง plist ไม่ได้")
    }
    _ = runLaunchctl(["bootout", "system/\(ChargeHelperInfo.label)"])  // หยุดตัวเก่า (ถ้ามี)
    do {
        try data.write(to: URL(fileURLWithPath: ChargeHelperInfo.daemonPlistPath))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: ChargeHelperInfo.daemonPlistPath
        )
    } catch {
        fail("เขียน LaunchDaemon ไม่ได้: \(error.localizedDescription)")
    }
    if !FileManager.default.fileExists(atPath: ChargeHelperInfo.configPath) {
        writeJSON(ChargeConfig.default, to: ChargeHelperInfo.configPath)
    }
    guard runLaunchctl(["bootstrap", "system", ChargeHelperInfo.daemonPlistPath]) == 0 else {
        fail("เปิด LaunchDaemon ไม่ได้")
    }
    print("ok")
}

func uninstall() {
    _ = runLaunchctl(["bootout", "system/\(ChargeHelperInfo.label)"])  // daemon คืนการชาร์จก่อนจบ
    // เผื่อ daemon ไม่ได้ทำงานอยู่ → คืนค่าเองอีกรอบ
    if let switches = SMCSwitches() {
        switches.setAdapterDisabled(false)
        switches.setChargingInhibited(false)
    }
    let fm = FileManager.default
    for path in [ChargeHelperInfo.daemonPlistPath, ChargeHelperInfo.dataDirectory,
                 ChargeHelperInfo.sudoersPath, ChargeHelperInfo.installedPath] {
        try? fm.removeItem(atPath: path)
    }
    print("ok")
}

// MARK: - main

switch command {
case "--version":
    print(ChargeHelperInfo.version)

case "probe":
    guard let switches = SMCSwitches() else { fail("เปิด SMC ไม่ได้") }
    print(switches.describe())
    print("battery temperature:", switches.batteryTemperature().map { String(format: "%.1f°C", $0) } ?? "-")

case "daemon":
    guard getuid() == 0 else { fail("ต้องรันด้วยสิทธิ์ root") }
    guard let switches = SMCSwitches() else { fail("เปิด SMC ไม่ได้") }
    guard switches.canInhibitCharging else { fail("เครื่องนี้ไม่รองรับการจำกัดการชาร์จ") }
    ChargeDaemon(switches: switches).run()

case "install-daemon":
    guard getuid() == 0 else { fail("ต้องรันด้วยสิทธิ์ root") }
    installDaemon()

case "set":
    guard getuid() == 0 else { fail("ต้องรันด้วยสิทธิ์ root") }
    guard arguments.count == 2,
          let config = try? JSONDecoder.charge.decode(ChargeConfig.self, from: Data(arguments[1].utf8))
    else { fail("ค่าตั้งไม่ถูกต้อง") }
    writeJSON(config.sanitized(), to: ChargeHelperInfo.configPath)  // daemon เห็นไฟล์เปลี่ยนแล้วทำทันที
    print("ok")

case "uninstall":
    guard getuid() == 0 else { fail("ต้องรันด้วยสิทธิ์ root") }
    uninstall()

default:
    fail("ไม่รู้จักคำสั่ง '\(command)'")
}
