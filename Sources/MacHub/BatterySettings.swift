import AppKit
import SwiftUI
import SMCKit

/// หน้า "แบตเตอรี่" ในหน้าตั้งค่า
struct BatterySettingsView: View {
    @ObservedObject var manager: BatteryManager
    @ObservedObject private var settings = AppSettings.shared

    // ค่าที่กำลังลาก slider อยู่ (บันทึกจริงตอนปล่อยเมาส์ จะได้ไม่เรียก sudo ถี่ๆ)
    @State private var draftLimit: Double = 80
    @State private var dischargeTarget = 50

    private let heatChoices = [0, 35, 40, 45]

    var body: some View {
        Form {
            Section {
                Text(manager.statusLine)
                    .font(.system(size: 13, weight: .medium))
                if let error = manager.errorMessage {
                    Text("⚠️ \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("แสดงสถานะแบตในเมนู", isOn: $settings.showBatteryInMenu)
            } header: {
                Text("สถานะ")
            }

            // ยังไม่ติดตั้งตัวช่วย → ตั้งค่าไม่ได้
            Group {
                Section {
                    Toggle("จำกัดการชาร์จ", isOn: Binding(
                        get: { manager.config.isLimitOn },
                        set: { on in manager.update { $0.limit = on ? Int(draftLimit) : 0 } }
                    ))
                    if manager.config.isLimitOn {
                        HStack {
                            Slider(value: $draftLimit, in: 50...95, step: 5) { editing in
                                if !editing { manager.update { $0.limit = Int(draftLimit) } }
                            }
                            Text("\(Int(draftLimit))%")
                                .font(.system(size: 13).monospacedDigit())
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text("ถึงค่าที่ตั้ง → หยุดชาร์จ (เครื่องใช้ไฟจากสายแทน) · แบตลดลง 3% → ชาร์จต่อ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("จำกัดการชาร์จ")
                }

                Section {
                    Toggle("Discharge อัตโนมัติเมื่อแบตเกินค่าที่จำกัด", isOn: Binding(
                        get: { manager.config.autoDischarge },
                        set: { on in manager.update { $0.autoDischarge = on } }
                    ))
                    .disabled(!manager.config.isLimitOn)

                    if let target = manager.config.dischargeTarget {
                        HStack {
                            Text("กำลัง discharge ลงไปที่ \(target)%")
                            Spacer()
                            Button("หยุด") { manager.update { $0.dischargeTarget = nil } }
                        }
                    } else {
                        HStack {
                            Stepper("Discharge ครั้งเดียวลงไปที่ \(dischargeTarget)%",
                                    value: $dischargeTarget, in: 20...95, step: 5)
                            Spacer()
                            Button("เริ่ม") { manager.update { $0.dischargeTarget = dischargeTarget } }
                        }
                    }
                    Text("Discharge = ตัดไฟจากสายชาร์จ ให้เครื่องใช้แบตจนลดลงถึงค่าที่ตั้ง ทั้งที่เสียบสายอยู่")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Discharge")
                }

                Section {
                    Picker("หยุดชาร์จเมื่อแบตร้อนถึง", selection: Binding(
                        get: { manager.config.heatLimit },
                        set: { value in manager.update { $0.heatLimit = value } }
                    )) {
                        ForEach(heatChoices, id: \.self) { value in
                            Text(value == 0 ? "ปิด" : "\(value)°C").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("เย็นลง 2°C แล้วชาร์จต่อ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("กันร้อน")
                }

                Section {
                    Toggle("ไม่ให้ sleep จนกว่าจะชาร์จถึงค่าที่จำกัด", isOn: Binding(
                        get: { manager.config.preventSleep },
                        set: { on in manager.update { $0.preventSleep = on } }
                    ))
                    Text("ใช้เฉพาะตอนเสียบสาย กันได้แม้พับจอ ถ้าเครื่อง sleep ไปก่อน (เช่นแบตไม่ได้เสียบสาย) จะหยุดชาร์จไว้ระหว่าง sleep แทน")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sleep")
                }
            }
            .disabled(!manager.isInstalled)

            Section {
                switch manager.installState {
                case .installed:
                    HStack {
                        Text("✓ ติดตั้งแล้ว · ทำงานแม้ปิด MacHub")
                        Spacer()
                        Button("ถอนการติดตั้ง…", role: .destructive) { confirmUninstall() }
                    }
                case .needsUpdate:
                    HStack {
                        Text("ตัวช่วยต้องอัปเดต")
                        Spacer()
                        Button("อัปเดต (ใส่รหัส admin)") { manager.install() }
                    }
                case .notInstalled:
                    HStack {
                        Text("ต้องติดตั้งตัวช่วยก่อนใช้งาน")
                        Spacer()
                        Button("ติดตั้ง (ใส่รหัส admin)") { manager.install() }
                    }
                }
            } header: {
                Text("ตัวช่วย")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            manager.checkInstallState()
            manager.refresh()
            syncDraft()
        }
        .onChange(of: manager.config.limit) { syncDraft() }
    }

    private func syncDraft() {
        if manager.config.isLimitOn { draftLimit = Double(manager.config.limit) }
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "ถอนการติดตั้งตัวช่วยจัดการแบต?"
        alert.informativeText = "การชาร์จจะกลับเป็นปกติ (ชาร์จเต็ม 100%) และค่าตั้งทั้งหมดจะถูกลบ"
        alert.addButton(withTitle: "ถอนการติดตั้ง")
        alert.addButton(withTitle: "ยกเลิก")
        if alert.runModal() == .alertFirstButtonReturn { manager.uninstall() }
    }
}
