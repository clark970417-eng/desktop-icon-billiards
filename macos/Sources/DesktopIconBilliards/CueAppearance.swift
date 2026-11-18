import AppKit
import ImageIO
import UniformTypeIdentifiers

private enum CuePalette {
    static var background: NSColor { NSColor(srgbRed: 14/255, green: 26/255, blue: 24/255, alpha: 1) }
    static var card: NSColor { NSColor(srgbRed: 21/255, green: 38/255, blue: 35/255, alpha: 1) }
    static var text: NSColor { NSColor(srgbRed: 232/255, green: 245/255, blue: 240/255, alpha: 1) }
    static var muted: NSColor { NSColor(srgbRed: 138/255, green: 166/255, blue: 158/255, alpha: 1) }
    static var accent: NSColor { NSColor(srgbRed: 105/255, green: 221/255, blue: 179/255, alpha: 1) }
}

/// Pure crop geometry shared by the preview and saved 256-pixel texture.
enum CueCrop {
    static func rect(imageSize: NSSize, zoom: Double, center: NSPoint? = nil) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite else { return .zero }
        let boundedZoom = zoom.isFinite ? max(1, min(4, zoom)) : 1
        let side = min(imageSize.width, imageSize.height) / boundedZoom
        let proposed = center ?? NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        let x = proposed.x.isFinite ? proposed.x : imageSize.width / 2
        let y = proposed.y.isFinite ? proposed.y : imageSize.height / 2
        let clamped = NSPoint(x: max(side / 2, min(imageSize.width - side / 2, x)),
                              y: max(side / 2, min(imageSize.height - side / 2, y)))
        return NSRect(x: clamped.x - side / 2, y: clamped.y - side / 2, width: side, height: side)
    }

    @MainActor
    static func texture(image: NSImage, zoom: Double, center: NSPoint? = nil) -> NSImage? {
        let crop = rect(imageSize: image.size, zoom: zoom, center: center)
        guard crop.width > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 0.965, green: 0.98, blue: 0.98, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 256, height: 256).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: crop,
                   operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 256, height: 256)
        let texture = NSImage(size: bitmap.size)
        texture.addRepresentation(bitmap)
        return texture
    }
}

/// Persistence writes only our processed texture. It never edits the selected
/// source image. Directory injection lets fixtures avoid the user's settings.
@MainActor
enum CueAppearanceStore {
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopIconBilliards", isDirectory: true)
    }
    static func load(directory: URL = directory) -> NSImage? {
        let url = directory.appendingPathComponent("cue-ball.png")
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    static func save(_ image: NSImage?, directory: URL = directory) throws {
        let url = directory.appendingPathComponent("cue-ball.png")
        guard let image else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        guard let data = image.representations.compactMap({ ($0 as? NSBitmapImageRep)?.representation(using: .png, properties: [:]) }).first else {
            throw AppearanceError.decode
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func source(at url: URL) throws -> NSImage {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue * height.doubleValue <= 25_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw AppearanceError.decode }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    enum AppearanceError: Error { case decode }
}

@MainActor
final class CueAppearanceController: NSObject, NSWindowDelegate {
    private var language: AppLanguage
    private let onChange: (NSImage?) -> Void
    private let storageDirectory: URL
    private var panel: NSPanel?
    private var preview: CueCropView?
    private var heading: NSTextField?
    private var hint: NSTextField?
    private var status: NSTextField?
    private var percentage: NSTextField?
    private var chooseButton: NSButton?
    private var applyButton: NSButton?
    private var resetButton: NSButton?
    private var slider: NSSlider?
    private var picker: NSOpenPanel?
    private var source: NSImage?
    private var saved: NSImage?
    private var isEditing = false
    private var failure = false

    init(language: AppLanguage, directory: URL = CueAppearanceStore.directory, onChange: @escaping (NSImage?) -> Void) {
        self.language = language; self.onChange = onChange; self.storageDirectory = directory
        self.saved = CueAppearanceStore.load(directory: directory)
        super.init()
    }
    static func loadSaved() -> NSImage? { CueAppearanceStore.load() }
    func show() {
        if panel == nil { makePanel() }
        refresh()
        fitPanel()
        panel?.makeKeyAndOrderFront(nil)
    }
    func updateLanguage(_ language: AppLanguage) {
        self.language = language
        refresh()
        fitPanel()
        picker?.title = pick("选择白球图片", "Choose cue-ball image")
        picker?.prompt = pick("选择", "Choose")
    }
    private func pick(_ zh: String, _ en: String) -> String { language == .en ? en : zh }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.backgroundColor = CuePalette.background
        panel.center()
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        body.wantsLayer = true; body.layer?.backgroundColor = CuePalette.background.cgColor
        let heading = NSTextField(labelWithString: "")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.textColor = CuePalette.text; heading.alignment = .center
        body.addSubview(heading); self.heading = heading
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = CuePalette.muted
        hint.alignment = .center
        hint.frame = NSRect(x: 18, y: 475, width: 404, height: 24)
        body.addSubview(hint); self.hint = hint
        let preview = CueCropView(frame: NSRect(x: 60, y: 145, width: 320, height: 320))
        preview.source = saved
        preview.onGeometryChange = { [weak self] in self?.refreshPercent() }
        preview.setAccessibilityLabel(pick("拖曳调整白球裁切", "Drag to position the cue-ball crop"))
        body.addSubview(preview); self.preview = preview
        let slider = NSSlider(value: 1, minValue: 1, maxValue: 4, target: self, action: #selector(scaleChanged))
        slider.frame = NSRect(x: 60, y: 113, width: 256, height: 24)
        body.addSubview(slider); self.slider = slider
        let percentage = NSTextField(labelWithString: "100%")
        percentage.alignment = .right
        percentage.frame = NSRect(x: 322, y: 113, width: 58, height: 24)
        percentage.textColor = CuePalette.text
        body.addSubview(percentage); self.percentage = percentage
        let choose = NSButton(title: "", target: self, action: #selector(choose))
        choose.bezelStyle = .rounded; choose.frame = NSRect(x: 24, y: 65, width: 126, height: 32)
        body.addSubview(choose); chooseButton = choose
        let apply = NSButton(title: "", target: self, action: #selector(apply))
        apply.bezelStyle = .rounded; apply.frame = NSRect(x: 157, y: 65, width: 126, height: 32)
        body.addSubview(apply); applyButton = apply
        let reset = NSButton(title: "", target: self, action: #selector(reset))
        reset.bezelStyle = .rounded; reset.frame = NSRect(x: 290, y: 65, width: 126, height: 32)
        body.addSubview(reset); resetButton = reset
        for button in [choose, reset] { button.bezelColor = CuePalette.card; button.contentTintColor = CuePalette.text }
        choose.font = .systemFont(ofSize: 13, weight: .semibold)
        apply.font = .systemFont(ofSize: 13, weight: .semibold)
        apply.bezelColor = CuePalette.accent; apply.contentTintColor = CuePalette.background
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = CuePalette.muted
        status.alignment = .center
        status.frame = NSRect(x: 16, y: 22, width: 408, height: 28)
        body.addSubview(status); self.status = status
        panel.contentView = body; self.panel = panel
    }
    private func fitPanel() {
        guard let panel, let screen = panel.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        let work = screen.visibleFrame
        let size = NSSize(width: min(440, max(280, work.width - 24)),
                          height: min(520, max(300, work.height - 52)))
        panel.setContentSize(size)
        var frame = panel.frame
        frame.origin.x = max(work.minX, min(work.maxX - frame.width, frame.minX))
        frame.origin.y = max(work.minY, min(work.maxY - frame.height, frame.minY))
        panel.setFrameOrigin(frame.origin)
        heading?.frame = NSRect(x: 18, y: size.height - 38, width: size.width - 36, height: 26)
        hint?.frame = NSRect(x: 18, y: size.height - 69, width: size.width - 36, height: 24)
        let side = max(48, min(320, size.width - 48, size.height - 235))
        preview?.frame = NSRect(x: (size.width - side) / 2, y: 145, width: side, height: side)
        slider?.frame = NSRect(x: 24, y: 113, width: size.width - 112, height: 24)
        percentage?.frame = NSRect(x: size.width - 82, y: 113, width: 58, height: 24)
        let width = (size.width - 62) / 3
        chooseButton?.frame = NSRect(x: 24, y: 65, width: width, height: 32)
        applyButton?.frame = NSRect(x: 31 + width, y: 65, width: width, height: 32)
        resetButton?.frame = NSRect(x: 38 + width * 2, y: 65, width: width, height: 32)
        status?.frame = NSRect(x: 16, y: 15, width: size.width - 32, height: 40)
        status?.maximumNumberOfLines = 2
    }

    private func refresh() {
        panel?.title = pick("白球外观", "Cue-ball appearance")
        preview?.setAccessibilityLabel(pick("拖曳调整白球裁切", "Drag to position the cue-ball crop"))
        heading?.stringValue = pick(isEditing ? "裁切白球图片" : "白球外观", isEditing ? "Crop cue-ball image" : "Cue-ball appearance")
        hint?.stringValue = isEditing
            ? pick("拖动图片调整位置 · 滚轮或滑块缩放", "Drag to position · Scroll or use the slider to zoom")
            : pick("选图后可拖动、缩放，调整圆形裁切", "Choose an image, then drag and zoom the circular crop")
        chooseButton?.title = pick("选择图片", "Choose image")
        applyButton?.title = pick("使用图片", "Use image")
        resetButton?.title = pick("恢复默认", "Reset")
        slider?.isEnabled = isEditing
        applyButton?.isEnabled = isEditing
        resetButton?.isEnabled = saved != nil
        if failure {
            status?.stringValue = pick("无法使用或保存图片；请选择 20 MB、2500 万像素以内的图片。",
                                      "Could not use/save image. Choose up to 20 MB and 25 megapixels.")
        } else {
            status?.stringValue = isEditing ? pick("确认裁切后按「使用图片」；关闭窗口不套用。", "Click Use image to apply. Closing discards this crop.")
                : pick((saved == nil ? "默认白球" : "自定义图片") + " · JPG / PNG / WebP · 仅保存在本机",
                       (saved == nil ? "Default cue ball" : "Custom image") + " · JPG / PNG / WebP · Saved locally")
        }
        refreshPercent()
    }
    private func refreshPercent() {
        let zoom = preview?.zoom ?? 1
        slider?.doubleValue = zoom
        percentage?.stringValue = String(format: "%.0f%%", zoom * 100)
    }
    @objc private func scaleChanged() {
        guard isEditing else { return }
        preview?.zoom = slider?.doubleValue ?? 1
        preview?.needsDisplay = true
        refreshPercent()
    }
    @objc private func choose() {
        guard let panel, panel.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.image]
        picker.title = pick("选择白球图片", "Choose cue-ball image")
        picker.prompt = pick("选择", "Choose")
        self.picker = picker
        picker.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.picker = nil
            guard response == .OK, let url = picker.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let image = try CueAppearanceStore.source(at: url)
                self.source = image
                self.preview?.source = image
                self.preview?.center = NSPoint(x: image.size.width / 2, y: image.size.height / 2)
                self.preview?.zoom = 1
                self.preview?.allowsEditing = true
                self.isEditing = true
                self.failure = false
            } catch { self.failure = true }
            self.refresh()
        }
    }
    @objc private func apply() {
        guard let source, let preview,
              let texture = CueCrop.texture(image: source, zoom: preview.zoom, center: preview.center) else { return }
        do {
            try CueAppearanceStore.save(texture, directory: storageDirectory)
            saved = texture; isEditing = false; failure = false
            preview.source = texture; preview.zoom = 1; preview.center = NSPoint(x: 128, y: 128)
            preview.allowsEditing = false
            self.source = nil
            onChange(texture)
        } catch { failure = true }
        refresh()
    }
    @objc private func reset() {
        do {
            try CueAppearanceStore.save(nil, directory: storageDirectory)
            saved = nil; source = nil; isEditing = false; failure = false
            preview?.source = nil; preview?.zoom = 1; preview?.center = nil
            preview?.allowsEditing = false
            onChange(nil)
        } catch { failure = true }
        refresh()
    }
    func windowWillClose(_ notification: Notification) {
        guard isEditing else { return }
        source = nil; isEditing = false; failure = false
        preview?.source = saved; preview?.zoom = 1; preview?.center = nil
        preview?.allowsEditing = false
        refresh()
    }
}

@MainActor
private final class CueCropView: NSView {
    var source: NSImage?
    var center: NSPoint?
    var zoom: Double = 1
    var allowsEditing = false
    var onGeometryChange: (() -> Void)?
    private var lastPoint: NSPoint?
    private var circle: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func draw(_ dirtyRect: NSRect) {
        CuePalette.background.setFill(); bounds.fill()
        if let source {
            NSColor(srgbRed: 0.965, green: 0.98, blue: 0.98, alpha: 1).setFill(); bounds.fill()
            source.draw(in: bounds, from: CueCrop.rect(imageSize: source.size, zoom: zoom, center: center),
                        operation: .sourceOver, fraction: 1)
            CuePalette.background.withAlphaComponent(0.8).setFill(); bounds.fill()
        }
        let path = NSBezierPath(ovalIn: circle)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(srgbRed: 0.965, green: 0.98, blue: 0.98, alpha: 1).setFill(); circle.fill()
        if let source {
            source.draw(in: circle, from: CueCrop.rect(imageSize: source.size, zoom: zoom, center: center),
                        operation: .sourceOver, fraction: 1)
        } else {
            NSGradient(starting: .white, ending: .lightGray)?.draw(in: path, angle: -60)
        }
        NSGraphicsContext.restoreGraphicsState()
        CuePalette.accent.setStroke(); path.lineWidth = 2; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard allowsEditing else { return }
        lastPoint = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowsEditing, let lastPoint, let source else { return }
        let point = convert(event.locationInWindow, from: nil)
        let crop = CueCrop.rect(imageSize: source.size, zoom: zoom, center: center)
        let previous = center ?? NSPoint(x: source.size.width / 2, y: source.size.height / 2)
        let moved = NSPoint(x: previous.x - (point.x - lastPoint.x) * crop.width / circle.width,
                            y: previous.y - (point.y - lastPoint.y) * crop.height / circle.height)
        let clamped = CueCrop.rect(imageSize: source.size, zoom: zoom, center: moved)
        center = NSPoint(x: clamped.midX, y: clamped.midY)
        self.lastPoint = point
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil }
    override func scrollWheel(with event: NSEvent) {
        guard allowsEditing else { return }
        zoom = max(1, min(4, zoom + Double(event.scrollingDeltaY) * 0.02))
        needsDisplay = true
        onGeometryChange?()
    }
}
