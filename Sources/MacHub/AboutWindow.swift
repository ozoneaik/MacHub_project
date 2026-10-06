import AppKit
import SwiftUI

/// หน้าต่าง "About me" (เปิดจากชื่อผู้สร้างท้ายเมนู)
@MainActor
final class AboutWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About me"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        return window
    }
}

struct AboutView: View {
    // ---- แก้ข้อมูลส่วนตัวตรงนี้ ----
    private let name = "ozoneaik"
    private let bio = "นักพัฒนาผู้สร้าง MacHub — ชอบทำเครื่องมือเล็กๆ ที่ทำให้ใช้ Mac สะดวกขึ้น"
    private let links: [(icon: String, title: String, url: String)] = [
        ("chevron.left.forwardslash.chevron.right", "GitHub", "https://github.com/ozoneaik"),
        ("envelope.fill", "อีเมล", "mailto:aofphuwadech@gmail.com"),
        ("person.2.fill", "Facebook", "https://facebook.com/"),
    ]
    // --------------------------------

    private let features = [
        ("thermometer.medium", "ดูอุณหภูมิ CPU / GPU และ RAM"),
        ("battery.75percent", "จำกัดการชาร์จแบต"),
        ("doc.on.clipboard", "ประวัติ Clipboard (⌘⇧V)"),
        ("eyedropper", "เลือกสีจากหน้าจอ (⌘⌥C)"),
        ("keyboard", "ล็อกคีย์บอร์ดเพื่อทำความสะอาด"),
    ]

    private let gradient = LinearGradient(
        colors: [.pink, .purple, .teal],
        startPoint: .leading, endPoint: .trailing
    )

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 20) {
            profileImage
                .padding(.top, 36)

            VStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(gradient)
                Text(bio)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 10) {
                ForEach(links, id: \.title) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) {
                            Label(link.title, systemImage: link.icon)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 10) {
                Text("MacHub  v\(version)")
                    .font(.system(size: 15, weight: .bold))
                ForEach(features, id: \.1) { icon, text in
                    Label(text, systemImage: icon)
                        .font(.system(size: 13))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 600)
    }

    /// ใช้ Resources/Profile.png ถ้ามี ไม่งั้นใช้ไอคอนแทน
    @ViewBuilder private var profileImage: some View {
        let ring = Circle().stroke(gradient, lineWidth: 4)
        if let image = NSImage(named: "Profile") {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .overlay(ring)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 120, height: 120)
                .foregroundStyle(gradient)
                .overlay(ring)
        }
    }
}
