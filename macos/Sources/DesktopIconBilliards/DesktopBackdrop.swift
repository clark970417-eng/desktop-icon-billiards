import AppKit

/// A wallpaper-only backing drawn over Finder, so original desktop icons do not
/// remain visible underneath their moving game counterparts. No screenshot,
/// Finder preference, desktop image, or source file is changed.
@MainActor
struct DesktopBackdrop {
    let image: NSImage
    let options: [NSWorkspace.DesktopImageOptionKey: Any]

    static func read(screen: NSScreen) throws -> DesktopBackdrop {
        let workspace = NSWorkspace.shared
        guard let url = workspace.desktopImageURL(for: screen), url.isFileURL,
              let image = NSImage(contentsOf: url), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            throw BackdropError.unavailable
        }
        return DesktopBackdrop(image: image, options: workspace.desktopImageOptions(for: screen) ?? [:])
    }

    /// `rect` represents the entire display, not just its visibleFrame. If the
    /// game window excludes the menu bar/Dock, translate screen.frame into the
    /// view's local coordinates and pass that full rect to preserve alignment.
    func draw(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let fill = (options[.fillColor] as? NSColor ?? .black).withAlphaComponent(1)
        fill.setFill()
        rect.fill()

        let scalingValue = (options[.imageScaling] as? NSNumber)?.uintValue
            ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let scaling = NSImageScaling(rawValue: scalingValue) ?? .scaleProportionallyUpOrDown
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let destination = Self.imageRect(imageSize: image.size, canvasRect: rect,
                                         scaling: scaling, allowClipping: clipping)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: destination, from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Pure geometry, exposed internally for deterministic fixture checks.
    static func imageRect(imageSize: NSSize, canvasRect: NSRect,
                          scaling: NSImageScaling, allowClipping: Bool) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0,
              canvasRect.width > 0, canvasRect.height > 0 else { return .zero }
        let fittedSize: NSSize
        switch scaling {
        case .scaleAxesIndependently:
            fittedSize = canvasRect.size
        case .scaleNone:
            fittedSize = imageSize
        case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            let xScale = canvasRect.width / imageSize.width
            let yScale = canvasRect.height / imageSize.height
            var factor = allowClipping ? max(xScale, yScale) : min(xScale, yScale)
            if scaling == .scaleProportionallyDown { factor = min(1, factor) }
            fittedSize = NSSize(width: imageSize.width * factor, height: imageSize.height * factor)
        @unknown default:
            fittedSize = canvasRect.size
        }
        return NSRect(x: canvasRect.midX - fittedSize.width / 2,
                      y: canvasRect.midY - fittedSize.height / 2,
                      width: fittedSize.width, height: fittedSize.height)
    }

    /// Finder desktop positions use a top-left origin on the primary display.
    /// Cocoa screen frames use a global bottom-left origin. Convert through
    /// global coordinates so displays to the left or above the primary work.
    static func viewPoint(finderPosition: NSPoint, screenFrame: NSRect,
                          primaryFrame: NSRect) -> NSPoint {
        let global = NSPoint(x: primaryFrame.minX + finderPosition.x,
                             y: primaryFrame.maxY - finderPosition.y)
        return NSPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
    }

    enum BackdropError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "目前桌布無法讀取，暫時不能啟動桌面球局。請先在系統設定選擇可讀取的靜態圖片桌布，再重試。桌面圖示與排列尚未變動。"
        }
    }
}
