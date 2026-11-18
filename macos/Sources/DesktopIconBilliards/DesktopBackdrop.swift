import AppKit
import CoreImage

/// A wallpaper-only backing drawn over Finder, so original desktop icons do not
/// remain visible underneath their moving game counterparts. No screenshot,
/// Finder preference, desktop image, or source file is changed.
@MainActor
struct DesktopBackdrop {
    let image: NSImage
    let options: [NSWorkspace.DesktopImageOptionKey: Any]
    private let blurCache = BlurCache()
    private let luminanceCache = LuminanceCache()
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(image: NSImage, options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        self.image = image
        self.options = options
    }

    /// Internal fixture diagnostic: repeated animation frames reuse one cached
    /// image. There is no filename/artwork logging or persistent image cache.
    var blurGenerationCount: Int { blurCache.generationCount }
    var luminanceGenerationCount: Int { luminanceCache.generationCount }

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

    /// Approximate placed-wallpaper brightness in the Windows 0...255 range.
    /// The eight-physical-pixel grid is prepared once for each display placement
    /// and backing scale. Sampling guide legs never reads the screen or applies
    /// a filter. Coordinates are the same local-view coordinates used by draw.
    func luminance(at point: NSPoint, desktopFrame: NSRect) -> CGFloat? {
        guard point.x.isFinite, point.y.isFinite, desktopFrame.width.isFinite, desktopFrame.height.isFinite,
              desktopFrame.width > 0, desktopFrame.height > 0, desktopFrame.contains(point) else { return nil }
        let transform = NSGraphicsContext.current?.cgContext.ctm ?? .identity
        let scale = min(4, max(1, hypot(transform.a, transform.b)))
        let key = LuminanceKey(desktopFrame: desktopFrame, backingScale: scale)
        if luminanceCache.key != key {
            luminanceCache.key = key
            luminanceCache.generationCount += 1
            luminanceCache.grid = makeLuminanceGrid(desktopFrame: desktopFrame, backingScale: scale)
        }
        guard let grid = luminanceCache.grid else { return nil }
        let x = min(grid.width - 1, max(0, Int((point.x - desktopFrame.minX) / desktopFrame.width * CGFloat(grid.width))))
        let y = min(grid.height - 1, max(0, Int((point.y - desktopFrame.minY) / desktopFrame.height * CGFloat(grid.height))))
        return CGFloat(grid.values[y * grid.width + x])
    }

    private func makeLuminanceGrid(desktopFrame: NSRect, backingScale: CGFloat) -> LuminanceGrid? {
        let width = Int(min(2048, max(1, desktopFrame.width * backingScale / 8)))
        let height = Int(min(2048, max(1, desktopFrame.height * backingScale / 8)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let xScale = CGFloat(width) / desktopFrame.width, yScale = CGFloat(height) / desktopFrame.height
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -desktopFrame.minX * xScale, y: -desktopFrame.minY * yScale)
        context.cgContext.scaleBy(x: xScale, y: yScale)
        draw(in: desktopFrame)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = bitmap.bitmapData else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (height - 1 - y) * bitmap.bytesPerRow + x * 4
                // Pillow's RGB -> L coefficients, matching the Windows map.
                let value = 0.299 * Double(bytes[offset]) + 0.587 * Double(bytes[offset + 1]) + 0.114 * Double(bytes[offset + 2])
                values[y * width + x] = UInt8(min(255, max(0, value.rounded())))
            }
        }
        return LuminanceGrid(width: width, height: height, values: values)
    }

    /// Draw a table-sized crop of the same placed wallpaper used by `draw(in:)`.
    /// `bounds` is the view canvas, `desktopFrame` is the complete display in
    /// view-local coordinates, and `clipRect` is the playing surface. Keep the
    /// full-display placement unchanged so the blurred crop cannot slide or
    /// stretch relative to the clear wallpaper around it.
    ///
    /// Windows uses GaussianBlur(max(10, physicalTableHeight / 55)). Render at
    /// the current backing scale, filter once, and reuse the result until the
    /// table/display geometry changes. The default subtle tint comes from the
    /// Windows minimal desktop layer's (8,26,25,40) RGBA colour. Pass zero for
    /// the upstream table interior's un-tinted blurred wallpaper.
    func drawBlurred(in bounds: NSRect, desktopFrame: NSRect, clipRect: NSRect,
                     darkenOpacity: CGFloat = 40.0 / 255.0) {
        let clip = bounds.intersection(clipRect)
        guard !clip.isNull, !clip.isEmpty, desktopFrame.width > 0, desktopFrame.height > 0,
              let context = NSGraphicsContext.current else { return }
        let transform = context.cgContext.ctm
        let backingScale = min(4, max(1, hypot(transform.a, transform.b)))
        let radius = max(10 / backingScale, clipRect.height / 55)
        let key = BlurKey(bounds: bounds, desktopFrame: desktopFrame, clip: clip,
                          backingScale: backingScale, radius: radius)
        if blurCache.key != key {
            blurCache.key = key
            blurCache.generationCount += 1
            blurCache.image = blurredImage(bounds: bounds, desktopFrame: desktopFrame,
                                          clip: clip, backingScale: backingScale, radius: radius)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        if let cached = blurCache.image {
            cached.draw(in: clip, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            // Core Image may be unavailable on a device/session. Keep the
            // original wallpaper placement as a cheap, deterministic fallback.
            draw(in: desktopFrame)
        }
        NSColor(srgbRed: 8.0 / 255.0, green: 26.0 / 255.0, blue: 25.0 / 255.0,
                alpha: min(1, max(0, darkenOpacity))).setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func blurredImage(bounds: NSRect, desktopFrame: NSRect, clip: NSRect,
                              backingScale: CGFloat, radius: CGFloat) -> NSImage? {
        // Gaussian tails are included before cropping, exactly as blurring the
        // whole placed wallpaper would do. Bound the temporary bitmap to 4096
        // pixels per side, and keep only one final table crop in memory.
        let padding = ceil(radius * 4)
        let sourceRect = bounds.intersection(clip.insetBy(dx: -padding, dy: -padding))
        guard !sourceRect.isNull, !sourceRect.isEmpty else { return nil }
        let scale = min(backingScale, 4096 / max(sourceRect.width, sourceRect.height))
        guard scale > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: max(1, Int(ceil(sourceRect.width * scale))),
                  pixelsHigh: max(1, Int(ceil(sourceRect.height * scale))),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -sourceRect.minX * scale, y: -sourceRect.minY * scale)
        context.cgContext.scaleBy(x: scale, y: scale)
        (options[.fillColor] as? NSColor ?? .black).withAlphaComponent(1).setFill()
        sourceRect.fill()
        draw(in: desktopFrame)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let input = bitmap.cgImage else { return nil }
        let crop = CGRect(x: (clip.minX - sourceRect.minX) * scale,
                          y: (clip.minY - sourceRect.minY) * scale,
                          width: clip.width * scale, height: clip.height * scale)
        let filtered = CIImage(cgImage: input).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
            .cropped(to: crop)
        guard let result = Self.imageContext.createCGImage(filtered, from: crop) else { return nil }
        return NSImage(cgImage: result, size: clip.size)
    }

    private struct BlurKey: Equatable {
        let bounds: NSRect
        let desktopFrame: NSRect
        let clip: NSRect
        let backingScale: CGFloat
        let radius: CGFloat
    }
    private final class BlurCache {
        var key: BlurKey?
        var image: NSImage?
        var generationCount = 0
    }
    private struct LuminanceKey: Equatable {
        let desktopFrame: NSRect
        let backingScale: CGFloat
    }
    private struct LuminanceGrid {
        let width: Int
        let height: Int
        let values: [UInt8]
    }
    private final class LuminanceCache {
        var key: LuminanceKey?
        var grid: LuminanceGrid?
        var generationCount = 0
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
            "目前桌布无法读取，暂时不能启动桌面球局。请先在系统设置选择可读取的静态图片桌布，再重试。桌面图标与排列尚未变动。"
        }
    }
}
