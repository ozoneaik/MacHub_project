import AppKit

/// ข้อความตัวใหญ่ไล่สี (ชมพู → ม่วง → ฟ้า) ใช้เป็น view ของ NSMenuItem
final class GradientTextView: NSView {
    /// เรียกเมื่อคลิก (view ใน NSMenuItem ไม่ส่ง action ให้เอง)
    var onClick: (() -> Void)?

    private static let padding = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)

    init(text: String, fontSize: CGFloat = 72) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let textSize = attributed.size()
        let pad = Self.padding
        let frame = NSRect(x: 0, y: 0,
                           width: ceil(textSize.width) + pad.left + pad.right,
                           height: ceil(textSize.height) + pad.top + pad.bottom)
        super.init(frame: frame)
        wantsLayer = true

        let scale = NSScreen.main?.backingScaleFactor ?? 2

        // ไล่สีแนวนอน แล้วใช้ตัวอักษรเป็น mask
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: pad.left, y: pad.bottom, width: ceil(textSize.width), height: ceil(textSize.height))
        gradient.colors = [NSColor.systemPink.cgColor, NSColor.systemPurple.cgColor, NSColor.systemTeal.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)

        let textLayer = CATextLayer()
        textLayer.frame = gradient.bounds
        textLayer.string = attributed
        textLayer.contentsScale = scale
        gradient.mask = textLayer

        layer?.addSublayer(gradient)
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
