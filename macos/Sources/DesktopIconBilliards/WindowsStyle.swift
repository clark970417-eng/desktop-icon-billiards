import AppKit

/// The upstream toolbar's flat pills, using native button semantics and focus.
final class WinPill: NSButton {
    enum Kind { case primary, soft, on, off, ghost, gold }
    var kind: Kind = .ghost { didSet { if kind != oldValue { needsDisplay = true } } }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        return NSSize(width: ceil(width) + 20, height: 28)
    }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        hoverTracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(hoverTracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func draw(_ dirtyRect: NSRect) {
        let palette: (UInt32, UInt32, UInt32)
        switch kind {
        case .primary: palette = (0x69ddb3, 0x86eac8, 0x0e1a18)
        case .soft: palette = (0x1f3733, 0x294843, 0xe8f5f0)
        case .on: palette = (0x1f5444, 0x28695a, 0xb6fbe0)
        case .off: palette = (0x25322f, 0x2f3f3b, 0x8aa69e)
        case .ghost: palette = (0x0e1a18, 0x18302c, 0x8aa69e)
        case .gold: palette = (0x0e1a18, 0x18302c, 0xf2ca87)
        }
        func color(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(value >> 16 & 255)/255, green: CGFloat(value >> 8 & 255)/255,
                    blue: CGFloat(value & 255)/255, alpha: 1)
        }
        color(isEnabled ? (hovered || isHighlighted ? palette.1 : palette.0) : 0x25322f).setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: color(isEnabled ? palette.2 : 0x5d726c)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        }
    }
}

/// Wrap final measured labels before sizing the panel, including the full credit.
struct WinToolbarLayout {
    let size: NSSize
    let frames: [NSRect]
    let statsY: CGFloat
    let actionFrames: [NSRect]
    init(availableWidth: CGFloat, groups: [[CGFloat]], actions: [CGFloat], statsWidth: CGFloat) {
        let available = max(1, availableWidth), left: CGFloat = 34, right: CGFloat = 12
        let usable = max(1, available-left-right)
        var positions: [(CGFloat,CGFloat,CGFloat)] = [], x: CGFloat = 0, row: CGFloat = 0, maxUsed: CGFloat = 0
        for group in groups {
            let total = group.reduce(0,+) + CGFloat(max(0,group.count-1))*4
            if x > 0 && x+total > usable { row += 1; x = 0 }
            for itemWidth in group {
                let width = min(itemWidth,usable)
                if x > 0 && x+width > usable { row += 1; x = 0 }
                positions.append((x,row,width)); x += width+4; maxUsed = max(maxUsed,x-4)
            }
            x += 12
        }
        let actionWidth = actions.reduce(0,+) + CGFloat(max(0,actions.count-1))*8
        let splitStats = statsWidth+16+actionWidth > usable
        let width = min(available, max(maxUsed, splitStats ? max(statsWidth,actionWidth) : statsWidth+16+actionWidth)+left+right)
        let height: CGFloat = 16+(row+1)*30+14+(splitStats ? 66 : 32)
        size = NSSize(width:width,height:height)
        frames = positions.map { NSRect(x:left+$0.0,y:height-8-28-$0.1*30,width:$0.2,height:28) }
        statsY = splitStats ? 43 : 9
        var actionX = width-right-actionWidth
        actionFrames = actions.map { width in
            defer { actionX += width+8 }
            return NSRect(x:actionX,y:8,width:width,height:28)
        }
    }
}
