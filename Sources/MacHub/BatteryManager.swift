import AppKit
import SMCKit

/// คุยกับตัวช่วยจัดการแบต (MacHubChargeHelper)
///
/// ตัวช่วยเป็น LaunchDaemon ของระบบ ทำงานตลอดแม้ไม่ได้เปิด MacHub
/// - ติดตั้งครั้งเดียว (ถามรหัส admin): copy ตัวช่วยไปไว้ที่ /Library/PrivilegedHelperTools,
///   เพิ่มกฎ sudo ให้ผู้ใช้คนนี้รันตัวช่วยได้โดยไม่ต้องใส่รหัส แล้วลงทะเบียน LaunchDaemon
/// - เปลี่ยนค่าตั้ง: `sudo -n ตัวช่วย set <json>` → ตัวช่วยเขียนไฟล์ค่าตั้ง → daemon ทำตามทันที
/// - อ่านสถานะ: daemon เขียนไฟล์สถานะทุก 10 วินาที (ทุกคนอ่านได้ ไม่ต้องใช้สิทธิ์)
@MainActor
final class BatteryManager: ObservableObject {
    enum InstallState {
        case notInstalled, needsUpdate, installed
    }

    @Published private(set) var config = ChargeConfig.default
    @Published private(set) var status: ChargeStatus?
    @Published private(set) var installState = InstallState.notInstalled
    @Published var errorMessage: String?

    var isInstalled: Bool { installState == .installed }

    /// สถานะเก่าเกิน 40 วินาที = daemon ไม่ทำงาน
    var isStatusFresh: Bool {
        guard let status else { return false }
        return Date().timeIntervalSince(status.updated) < 40
    }

    init() {
        checkInstallState()
        refresh()
    }

    /// อ่านค่าตั้ง + สถานะล่าสุดจากไฟล์ (เรียกทุก 2 วินาทีพร้อมอุณหภูมิ)
    func refresh() {
        if let data = FileManager.default.contents(atPath: ChargeHelperInfo.configPath),
           let config = try? JSONDecoder.charge.decode(ChargeConfig.self, from: data) {
            if config != self.config { self.config = config }
        }
        if let data = FileManager.default.contents(atPath: ChargeHelperInfo.statusPath),
           let status = try? JSONDecoder.charge.decode(ChargeStatus.self, from: data) {
            self.status = status
        } else {
            status = nil
        }
    }

    func checkInstallState() {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ChargeHelperInfo.installedPath),
              fm.fileExists(atPath: ChargeHelperInfo.sudoersPath)
        else {
            installState = .notInstalled
            return
        }
        let versionOK = installedHelperVersion() == ChargeHelperInfo.version
        let daemonOK = fm.fileExists(atPath: ChargeHelperInfo.daemonPlistPath)
        installState = versionOK && daemonOK ? .installed : .needsUpdate
    }

    // MARK: - เปลี่ยนค่าตั้ง

    func update(_ change: (inout ChargeConfig) -> Void) {
        var newConfig = config
        change(&newConfig)
        newConfig = newConfig.sanitized()
        guard newConfig != config else { return }

        guard isInstalled else {
            errorMessage = "ต้องติดตั้งตัวช่วยก่อน"
            return
        }
        guard let data = try? JSONEncoder().encode(newConfig) else { return }
        let result = runHelperWithSudo(["set", String(decoding: data, as: UTF8.self)])
        if result.ok {
            config = newConfig
            errorMessage = nil
        } else {
            errorMessage = "บันทึกค่าไม่สำเร็จ: \(result.output)"
        }
    }

    // MARK: - ติดตั้ง / ถอน

    /// ติดตั้ง/อัปเดตตัวช่วย (ระบบจะถามรหัส admin)
    func install() {
        errorMessage = nil
        guard let source = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent(ChargeHelperInfo.bundledName).path,
              FileManager.default.fileExists(atPath: source)
        else {
            errorMessage = "ไม่พบตัวช่วยในแอป (ต้องติดตั้งด้วย build.sh install)"
            return
        }
        // ชื่อผู้ใช้จะถูกเขียนลงกฎ sudo → รับเฉพาะตัวอักษรที่ปลอดภัย
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            errorMessage = "ชื่อผู้ใช้มีตัวอักษรที่ใช้ไม่ได้"
            return
        }

        let target = ChargeHelperInfo.installedPath
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 '\(source)' '\(target)'
        tmp=$(mktemp)
        echo '\(user) ALL=(root) NOPASSWD: \(target)' > $tmp
        /usr/sbin/visudo -cf $tmp
        install -o root -g wheel -m 440 $tmp \(ChargeHelperInfo.sudoersPath)
        rm -f $tmp
        '\(target)' install-daemon
        """
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escaped)" with prompt "MacHub ต้องติดตั้งตัวช่วยสำหรับจัดการการชาร์จแบต" with administrator privileges
        """

        NSApp.activate(ignoringOtherApps: true)  // ให้หน้าต่างถามรหัสขึ้นมาข้างหน้า
        var error: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {  // -128 = กดยกเลิก
            errorMessage = "ติดตั้งไม่สำเร็จ: \(error[NSAppleScript.errorMessage] ?? "")"
        }
        checkInstallState()
        if isInstalled { migrateOldLimit() }
        refresh()
    }

    func uninstall() {
        let result = runHelperWithSudo(["uninstall"])
        if !result.ok { errorMessage = "ถอนการติดตั้งไม่สำเร็จ: \(result.output)" }
        checkInstallState()
        config = .default
        refresh()
    }

    /// MacHub รุ่นก่อนจำ % ไว้ใน UserDefaults → ย้ายไปไว้ในค่าตั้งของตัวช่วย
    private func migrateOldLimit() {
        let oldLimit = UserDefaults.standard.integer(forKey: "chargeLimit")
        guard oldLimit > 0 else { return }
        UserDefaults.standard.removeObject(forKey: "chargeLimit")
        refresh()
        update { $0.limit = oldLimit }
    }

    // MARK: - เรียกตัวช่วย

    private func installedHelperVersion() -> String? {
        run(ChargeHelperInfo.installedPath, ["--version"]).output
    }

    private func runHelperWithSudo(_ arguments: [String]) -> (ok: Bool, output: String) {
        // -n = ห้ามถามรหัส (กฎ sudo ที่ติดตั้งไว้อนุญาตแล้ว)
        let result = run("/usr/bin/sudo", ["-n", ChargeHelperInfo.installedPath] + arguments)
        if result.output.contains("password") {
            installState = .needsUpdate
            return (false, "กฎ sudo หายไป — กดติดตั้งตัวช่วยใหม่")
        }
        return result
    }

    private func run(_ path: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, output)
    }

    // MARK: - ข้อความสถานะ

    /// เช่น "แบต 80% · หยุดชาร์จแล้ว (ถึง 80%) · 31.2°C"
    var statusLine: String {
        guard isInstalled else { return "ยังไม่ได้ติดตั้งตัวช่วย" }
        guard let status, isStatusFresh else { return "⚠️ ตัวช่วยไม่ตอบ" }

        var text = "แบต \(status.percent)% · "
        if !status.onAC {
            text += "ใช้แบต (ไม่ได้เสียบสาย)"
        } else if status.discharging {
            text += "กำลัง discharge (ใช้แบตทั้งที่เสียบสาย)"
        } else if status.heatHold {
            text += "หยุดชาร์จ: แบตร้อน"
        } else if status.inhibited {
            text += "หยุดชาร์จแล้ว (ถึง \(config.limit)%)"
        } else if status.isCharging {
            text += config.isLimitOn ? "กำลังชาร์จถึง \(config.limit)%" : "กำลังชาร์จ"
        } else {
            text += "เสียบสาย · ไม่ได้ชาร์จ"
        }
        if let temperature = status.temperature {
            text += String(format: " · %.1f°C", temperature)
        }
        return text
    }
}
