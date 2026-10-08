import AppKit

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    let screen: NSScreen
    let pointMode: Bool
    let selected: (NSScreen, CGRect) -> Void
    let cancelled: () -> Void
    private var start: CGPoint?
    private var selection: CGRect?

    init(screen: NSScreen, pointMode: Bool, selected: @escaping (NSScreen, CGRect) -> Void, cancelled: @escaping () -> Void) {
        self.screen = screen
        self.pointMode = pointMode
        self.selected = selected
        self.cancelled = cancelled
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(pointMode ? "다음 페이지 버튼을 클릭하세요. Esc로 취소합니다." : "책 본문을 마우스로 드래그하세요. 마우스를 놓으면 저장하고 Esc로 취소합니다.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
        }
        let text = pointMode ? "다음 페이지 버튼을 클릭하세요 · Esc 취소" : "책 본문을 드래그한 뒤 놓으세요 · Esc 취소"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: (bounds.width - size.width) / 2 - 18, y: bounds.height - 110, width: size.width + 36, height: 54)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 18, y: box.minY + 13), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if pointMode { selected(screen, CGRect(origin: point, size: .zero)); return }
        start = point
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds).integral
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !pointMode, let selection, selection.width >= 40, selection.height >= 40 else { return }
        selected(screen, selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled() } else { super.keyDown(with: event) }
    }
}
