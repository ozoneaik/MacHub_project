import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ข้อมูล clipboard

/// รายการ 1 อันในประวัติ clipboard
struct ClipItem: Identifiable {
    enum Content {
        case text(String)
        case image(NSImage)
        case files([ClipFile])  // ไฟล์ที่ copy จาก Finder (เก็บที่อยู่ไฟล์ ไม่ใช่แค่ชื่อ)
    }

    let id = UUID()
    let content: Content
    let date: Date

    /// ข้อความที่ใช้ค้นหา
    var searchText: String {
        switch content {
        case .text(let text): return text
        case .image: return "image รูปภาพ"
        case .files(let files): return files.map(\.url.lastPathComponent).joined(separator: " ") + " file ไฟล์"
        }
    }
}

/// ไฟล์ 1 ไฟล์ใน clipboard
struct ClipFile {
    let url: URL
    let isImage: Bool
    let contentType: UTType?
    let thumbnail: NSImage  // ภาพย่อถ้าเป็นรูป ไม่งั้นเป็นไอคอนของไฟล์

    init(url: URL) {
        self.url = url
        contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        isImage = contentType?.conforms(to: .image) ?? false
        thumbnail = (isImage ? Self.makeThumbnail(of: url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    /// ย่อรูปตอนเก็บเลย (ไม่โหลดรูปเต็มไว้ใน RAM)
    private static func makeThumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // หมุนตาม EXIF
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// ข้อมูลสำหรับวางเป็น "ตัวรูป" (ใส่ทั้งชนิดเดิมของไฟล์ + TIFF/PNG ให้แอปไหนก็อ่านได้)
    func imagePasteboardItem() -> NSPasteboardItem? {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data),
              let tiff = image.tiffRepresentation
        else { return nil }

        let item = NSPasteboardItem()
        if let contentType {
            item.setData(data, forType: NSPasteboard.PasteboardType(contentType.identifier))
        }
        item.setData(tiff, forType: .tiff)
        if contentType != .png, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        return item
    }
}

// MARK: - ตัวเก็บประวัติ

/// คอยดู clipboard ของระบบทุก 0.5 วินาที แล้วเก็บประวัติไว้
@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    var maxItems: Int { AppSettings.shared.clipboardMaxItems }
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        // ข้ามสิ่งที่ copy ไว้ตอนปิด feature อยู่
        lastChangeCount = pasteboard.changeCount
        // macOS ไม่มี event แจ้งเตือนเมื่อ clipboard เปลี่ยน จึงต้องเช็คเป็นระยะ (ทุกแอปก็ทำแบบนี้)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPasteboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() {
        items.removeAll()
    }

    /// ตัดรายการเก่าทิ้งให้ไม่เกิน maxItems (เรียกเมื่อเปลี่ยนจำนวนในหน้าตั้งค่า)
    func trim() {
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
    }

    /// คืนรายการที่ตรงกับคำค้นหา
    func filtered(by query: String) -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
    }

    /// นำรายการที่เลือกกลับไปใส่ clipboard คืน false ถ้าใส่ไม่ได้ (เช่นไฟล์ถูกลบไปแล้ว)
    @discardableResult
    func copyToPasteboard(_ item: ClipItem) -> Bool {
        switch item.content {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .image(let image):
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        case .files(let files):
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            guard !existing.isEmpty else { return false }
            pasteboard.clearContents()
            if existing.allSatisfy(\.isImage) {
                // ไฟล์รูปทั้งหมด → วางเป็นตัวรูป
                pasteboard.writeObjects(existing.compactMap { $0.imagePasteboardItem() })
            } else {
                // มีไฟล์อื่นปน → วางเป็นไฟล์ (Finder = copy ไฟล์, แอปแชท = แนบไฟล์)
                pasteboard.writeObjects(existing.map { $0.url as NSURL })
            }
        }
        // จำ changeCount ไว้ จะได้ไม่บันทึกซ้ำเป็นรายการใหม่
        lastChangeCount = pasteboard.changeCount

        // ย้ายรายการนี้ขึ้นไปบนสุด
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let moved = items.remove(at: index)
            items.insert(ClipItem(content: moved.content, date: Date()), at: 0)
        }
        return true
    }

    private func checkPasteboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // ข้ามข้อมูลลับ เช่น รหัสผ่านที่ copy จาก password manager
        let types = pasteboard.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) { return }

        // ต้องเช็คไฟล์ก่อนข้อความ เพราะตอน copy ไฟล์ Finder ใส่ชื่อไฟล์เป็นข้อความมาด้วย
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        if !fileURLs.isEmpty {
            add(.files(fileURLs.map(ClipFile.init)))
        } else if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.text(text))
        } else if let image = NSImage(pasteboard: pasteboard) {
            add(.image(image))
        }
    }

    private func add(_ content: ClipItem.Content) {
        // ถ้าข้อความซ้ำกับที่มีอยู่ ให้ลบอันเก่าออก (จะได้ขึ้นไปอยู่บนสุดแทน)
        // (ไฟล์ชุดเดิมก็เช่นกัน)
        items.removeAll { item in
            switch (item.content, content) {
            case (.text(let old), .text(let new)): return old == new
            case (.files(let old), .files(let new)): return old.map(\.url) == new.map(\.url)
            default: return false
            }
        }
        items.insert(ClipItem(content: content, date: Date()), at: 0)

        // เก็บไม่เกิน maxItems รายการ
        trim()
    }
}

// MARK: - หน้าต่าง clipboard

/// NSPanel ปกติรับคีย์บอร์ดไม่ได้ถ้าไม่มีขอบ → override ให้รับได้ (ใช้พิมพ์ค้นหา)
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// state ของหน้าจอ clipboard
@MainActor
final class ClipboardViewState: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var focusToken = 0  // เปลี่ยนค่าเพื่อสั่งให้ช่องค้นหา focus ใหม่
}

/// ควบคุมการเปิด/ปิด และการเลือกรายการใน clipboard
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let manager: ClipboardManager
    private let state = ClipboardViewState()
    private var panel: KeyablePanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(manager: ClipboardManager) {
        self.manager = manager
        super.init()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        state.query = ""
        state.selectedIndex = 0
        state.focusToken += 1

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // วางไว้กลางจอที่เมาส์อยู่ ค่อนไปทางบน
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 80))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// ปุ่มลัดภายในหน้าต่าง clipboard คืน true = จัดการแล้ว
    func handleKey(_ keyCode: CGKeyCode) -> Bool {
        let list = manager.filtered(by: state.query)
        switch keyCode {
        case KeyCode.downArrow:
            state.selectedIndex = min(state.selectedIndex + 1, max(list.count - 1, 0))
        case KeyCode.upArrow:
            state.selectedIndex = max(state.selectedIndex - 1, 0)
        case KeyCode.returnKey:
            if list.indices.contains(state.selectedIndex) { pick(list[state.selectedIndex]) }
        case KeyCode.escape:
            hide()
        default:
            return false  // ปุ่มอื่นปล่อยให้พิมพ์ลงช่องค้นหา
        }
        return true
    }

    /// เลือกรายการ → ใส่ clipboard → ปิดหน้าต่าง → กด Cmd+V ให้อัตโนมัติ
    func pick(_ item: ClipItem) {
        guard manager.copyToPasteboard(item) else {
            NSSound.beep()  // ไฟล์ต้นฉบับถูกลบหรือย้ายไปแล้ว
            return
        }
        hide()
        // รอให้ focus กลับไปที่แอปเดิมก่อนค่อยวาง
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            ClipboardPanelController.simulatePaste()
        }
    }

    /// จำลองการกด Cmd+V
    nonisolated static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.v, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.v, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // คลิกออกนอกหน้าต่าง → ปิด
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let rootView = ClipboardView(manager: manager, state: state) { [weak self] item in
            self?.pick(item)
        }
        panel.contentView = NSHostingView(rootView: rootView)
        return panel
    }
}

// MARK: - หน้าตา (SwiftUI)

struct ClipboardView: View {
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var state: ClipboardViewState
    let onPick: (ClipItem) -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let list = manager.filtered(by: state.query)

        VStack(spacing: 0) {
            // ช่องค้นหา
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("ค้นหาใน clipboard...", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
            }
            .padding(14)

            Divider()

            if list.isEmpty {
                Spacer()
                Text(manager.items.isEmpty ? "ยังไม่มีประวัติ ลอง copy อะไรสักอย่าง" : "ไม่พบรายการที่ค้นหา")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, isSelected: index == state.selectedIndex)
                                    .id(item.id)
                                    .onTapGesture { onPick(item) }
                            }
                        }
                        .padding(6)
                    }
                    // เลื่อน scroll ตามรายการที่เลือกด้วยลูกศร
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        if list.indices.contains(newIndex) {
                            proxy.scrollTo(list[newIndex].id)
                        }
                    }
                }
            }

            Divider()

            Text("↑↓ เลือก    ⏎ วาง    esc ปิด")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 460, height: 500)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { isSearchFocused = true }
        .onChange(of: state.focusToken) { isSearchFocused = true }
        .onChange(of: state.query) { state.selectedIndex = 0 }  // พิมพ์ค้นหาใหม่ → เลือกอันแรก
    }
}

struct ClipRow: View {
    let item: ClipItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch item.content {
            case .text(let text):
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13))
                    .lineLimit(2)

            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("รูปภาพ \(Int(image.size.width))×\(Int(image.size.height))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

            case .files(let files):
                Image(nsImage: files[0].thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(files.count == 1
                         ? files[0].url.lastPathComponent
                         : "\(files.count) ไฟล์: " + files.map(\.url.lastPathComponent).joined(separator: ", "))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileSubtitle(files))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(item.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func fileSubtitle(_ files: [ClipFile]) -> String {
        if files.allSatisfy(\.isImage) { return files.count == 1 ? "ไฟล์รูป · วางเป็นรูป" : "ไฟล์รูป · วางเป็นรูปทั้งหมด" }
        return files[0].url.deletingLastPathComponent().path
    }
}
