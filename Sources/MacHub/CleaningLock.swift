import AppKit
import SwiftUI

/// ล็อกคีย์บอร์ดชั่วคราวเพื่อเช็ดทำความสะอาด
/// - ขึ้นหน้าจอเต็มทุกจอ พร้อมนับถอยหลัง
/// - ปลดล็อก: เอาเมาส์กด "เสร็จแล้ว" หรือรอครบเวลา
@MainActor
final class CleaningLock {
    var duration: TimeInterval { TimeInterval(AppSettings.shared.cleaningLockDuration) }

    private let keyboard: KeyboardInterceptor
    private let state = CleaningLockState()
    private var windows: [KeyableWindow] = []
    private var timer: Timer?

    var isActive: Bool { keyboard.isLocked }

    init(keyboard: KeyboardInterceptor) {
        self.keyboard = keyboard
    }

    func start() {
        guard !isActive else { return }
        keyboard.isLocked = true
        state.endDate = Date().addingTimeInterval(duration)
        state.now = Date()

        windows = NSScreen.screens.map(makeWindow)
        for window in windows { window.orderFrontRegardless() }
        // ให้คลิกปุ่มได้ทันทีโดยไม่ต้องคลิกเพื่อ focus ก่อน
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.now = Date()
                if self.state.now >= self.state.endDate { self.stop() }
            }
        }
    }

    func stop() {
        keyboard.isLocked = false
        timer?.invalidate()
        timer = nil
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    private func makeWindow(for screen: NSScreen) -> KeyableWindow {
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver  // บังทุกอย่าง รวม Dock และ menu bar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: CleaningLockView(state: state) { [weak self] in
            self?.stop()
        })
        window.setFrame(screen.frame, display: true)
        return window
    }
}

/// หน้าต่างไม่มีขอบปกติรับ focus ไม่ได้ → override ให้รับได้ (คลิกปุ่มครั้งเดียวติด)
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CleaningLockState: ObservableObject {
    @Published var endDate = Date()
    @Published var now = Date()

    var remainingText: String {
        let seconds = max(0, Int(endDate.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct CleaningLockView: View {
    @ObservedObject var state: CleaningLockState
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)

            VStack(spacing: 18) {
                Image(systemName: "keyboard")
                    .font(.system(size: 64, weight: .light))
                Text("กำลังทำความสะอาด")
                    .font(.system(size: 32, weight: .semibold))
                Text("คีย์บอร์ดถูกล็อกอยู่ เช็ดได้เลย")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                Text("ปลดล็อกอัตโนมัติใน \(state.remainingText)")
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)

                Button(action: onDone) {
                    Text("เสร็จแล้ว")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 36)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 12)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }
}
