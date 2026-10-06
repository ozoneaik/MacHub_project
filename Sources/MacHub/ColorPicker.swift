import AppKit
import SwiftUI

// MARK: - ข้อมูลสี

/// สี 1 สี (sRGB 0–255) พร้อมแปลงเป็นรูปแบบต่างๆ
struct PickedColor: Equatable, Identifiable {
    let red: Int
    let green: Int
    let blue: Int

    var id: String { hex }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        red = Int((srgb.redComponent * 255).rounded())
        green = Int((srgb.greenComponent * 255).rounded())
        blue = Int((srgb.blueComponent * 255).rounded())
    }

    /// จาก "#RRGGBB" (ใช้ตอนโหลดประวัติ)
    init?(hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        red = value >> 16 & 0xFF
        green = value >> 8 & 0xFF
        blue = value & 0xFF
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }

    var hsl: String {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) / 2

        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch maxValue {
            case r: hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = 60 * ((b - r) / delta + 2)
            default: hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        return "hsl(\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

// MARK: - state

@MainActor
final class ColorPickerState: ObservableObject {
    @Published var current: PickedColor?
    @Published private(set) var history: [PickedColor] = []
    @Published var copiedText: String?  // แสดง "✓" ข้างปุ่มที่เพิ่งกด

    private let maxHistory = 12
    private let historyKey = "colorHistory"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        history = saved.compactMap(PickedColor.init(hex:))
        current = history.first
    }

    func add(_ color: PickedColor) {
        current = color
        history.removeAll { $0 == color }
        history.insert(color, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        UserDefaults.standard.set(history.map(\.hex), forKey: historyKey)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedText == text { self?.copiedText = nil }
        }
    }
}

// MARK: - ตัวควบคุม

/// NSPanel ที่กด esc แล้วปิด
final class EscClosablePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// กด ⌘⌥C → แว่นขยายของระบบ → คลิกเลือกสี → หน้าต่างให้ copy เป็น HEX / RGB / HSL
@MainActor
final class ColorPickerController {
    private let sampler = NSColorSampler()
    private let state = ColorPickerState()
    private var panel: EscClosablePanel?
    private var isSampling = false

    func pick() {
        guard !isSampling else { return }
        isSampling = true
        let wasVisible = panel?.isVisible ?? false
        panel?.orderOut(nil)  // ซ่อนหน้าต่างไว้ จะได้เลือกสีที่อยู่ข้างหลังได้

        sampler.show { [weak self] color in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSampling = false
                if let color, let picked = PickedColor(color) {
                    self.state.add(picked)
                }
                // กด esc ระหว่างเลือก = ไม่ได้สี → เปิดหน้าต่างกลับเฉพาะถ้าเปิดอยู่ก่อนหน้า
                if color != nil || wasVisible {
                    self.showPanel()
                }
            }
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        if self.panel == nil {
            self.panel = panel
            // เปิดครั้งแรก: วางไว้ใกล้ๆ เมาส์
            let mouse = NSEvent.mouseLocation
            panel.setFrameTopLeftPoint(CGPoint(x: mouse.x + 16, y: mouse.y - 16))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> EscClosablePanel {
        let panel = EscClosablePanel(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 230),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Color Picker"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ColorPickerView(state: state) { [weak self] in
            self?.pick()
        })
        return panel
    }
}

// MARK: - หน้าตา

struct ColorPickerView: View {
    @ObservedObject var state: ColorPickerState
    let onPickAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let color = state.current {
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.color)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.15)))
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        formatRow("HEX", color.hex)
                        formatRow("RGB", color.rgb)
                        formatRow("HSL", color.hsl)
                    }
                }
            }

            if !state.history.isEmpty {
                Text("ประวัติ").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(state.history) { color in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color.color)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(color == state.current ? Color.accentColor : .primary.opacity(0.15),
                                            lineWidth: color == state.current ? 2 : 1)
                            )
                            .frame(width: 20, height: 20)
                            .help(color.hex)
                            .onTapGesture { state.current = color }
                    }
                }
            }

            Button {
                onPickAgain()
            } label: {
                Label("เลือกสีใหม่  (⌘⌥C)", systemImage: "eyedropper")
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func formatRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(state.copiedText == value ? "✓" : "Copy") { state.copy(value) }
                .controlSize(.small)
                .frame(width: 52)
        }
    }
}
