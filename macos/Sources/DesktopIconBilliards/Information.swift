import AppKit

private enum InformationTheme {
    static let background = NSColor(srgbRed: 14/255, green: 26/255, blue: 24/255, alpha: 1)
    static let text = NSColor(srgbRed: 232/255, green: 245/255, blue: 240/255, alpha: 1)
    static let muted = NSColor(srgbRed: 138/255, green: 166/255, blue: 158/255, alpha: 1)
    static let button = NSColor(srgbRed: 31/255, green: 55/255, blue: 51/255, alpha: 1)
}

private final class InformationPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

private final class InformationDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Mirrors the original voluntary WeChat donation dialog. The artwork is the
/// upstream donation.jpg shipped by build.sh, never a replacement payment code.
@MainActor
final class InformationController: NSObject, NSWindowDelegate {
    private var window: InformationPanel?
    private var aboutWindow: InformationPanel?
    private let scroll = NSScrollView()
    private let document = InformationDocument()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let credit = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let artwork = NSImageView()
    private let unavailable = NSTextField(wrappingLabelWithString: "")
    private let sourceButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let aboutScroll = NSScrollView()
    private let aboutDocument = InformationDocument()
    private let aboutHeading = NSTextField(wrappingLabelWithString: "")
    private let aboutVersion = NSTextField(wrappingLabelWithString: "")
    private let aboutBody = NSTextField(wrappingLabelWithString: "")
    private let licenseButton = NSButton(title: "", target: nil, action: nil)
    private let downloadsButton = NSButton(title: "", target: nil, action: nil)
    private let aboutCloseButton = NSButton(title: "", target: nil, action: nil)
    private var language = AppLanguage.saved

    func show(language: AppLanguage, presentWindow: Bool = true) {
        self.language = language
        if window == nil { makeDonationWindow() }
        updateLanguage(language)
        if presentWindow { window?.makeKeyAndOrderFront(nil) }
        if let window { clamp(window) }
        layoutDonation()
    }
    func showAbout(language: AppLanguage, presentWindow: Bool = true) {
        self.language = language
        if aboutWindow == nil { makeAboutWindow() }
        updateLanguage(language)
        if presentWindow { aboutWindow?.makeKeyAndOrderFront(nil) }
        if let aboutWindow { clamp(aboutWindow) }
        layoutAbout()
    }
    func updateLanguage(_ language: AppLanguage) {
        self.language = language
        window?.title = language.text("打赏", "Support the project")
        heading.stringValue = language.text("微信扫码赞赏，感谢支持！", "Scan with WeChat. Thank you!")
        credit.stringValue = "LXG · GitHub@liuxiaogang-com"
        note.stringValue = language.text(
            "赞赏是对这个项目的自愿支持，不包含额外功能或专属技术支持。",
            "Donations are voluntary support for this project and do not include extra features or dedicated technical support.")
        unavailable.stringValue = language.text("暂时无法打开赞赏图片。", "The donation image could not be opened.")
        artwork.setAccessibilityLabel(language.text("原作者微信赞赏码", "Original author's WeChat donation code"))
        sourceButton.title = language.text("项目主页", "Project")
        closeButton.title = language.text("关闭", "Close")
        aboutWindow?.title = language.text("关于桌面图标台球", "About Desktop Icon Billiards")
        aboutHeading.stringValue = language.text("桌面图标台球", "Desktop Icon Billiards")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"
        aboutVersion.stringValue = "Mac v\(version)"
        aboutBody.stringValue = language.text("原作：LXG / liuxiaogang-com", "Original: LXG / liuxiaogang-com")
            + "\nCopyright (c) 2025–2026 LXG · MIT License\n"
            + language.text("Mac 版本：clark970417-eng", "Mac edition: clark970417-eng")
        licenseButton.title = language.text("原作与授权", "Project / license")
        downloadsButton.title = language.text("Mac 下载", "Mac downloads")
        aboutCloseButton.title = language.text("关闭", "Close")
        if let window { clamp(window) }
        if let aboutWindow { clamp(aboutWindow) }
        layoutDonation(); layoutAbout()
    }
    private func configure(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false) {
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = muted ? InformationTheme.muted : InformationTheme.text
        label.alignment = .center
        label.isSelectable = false
    }
    private func configure(_ button: NSButton, action: Selector) {
        button.target = self; button.action = action
        button.bezelStyle = .rounded
        button.bezelColor = InformationTheme.button
        button.contentTintColor = InformationTheme.text
        button.font = .systemFont(ofSize: 12, weight: .medium)
    }
    private func panel(size: NSSize) -> InformationPanel {
        let panel = InformationPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating; panel.hidesOnDeactivate = true
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = InformationTheme.background
        panel.titlebarAppearsTransparent = true
        panel.center()
        return panel
    }
    private func prepare(_ scroll: NSScrollView, document: NSView) {
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
    }
    private func makeDonationWindow() {
        let panel = panel(size: NSSize(width: 420, height: 580))
        configure(heading, size: 16, weight: .medium)
        configure(credit, size: 11, muted: true)
        configure(note, size: 11, muted: true)
        configure(unavailable, size: 13, muted: true)
        artwork.image = Self.donationArtwork()
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.imageAlignment = .alignCenter
        artwork.setAccessibilityLabel(language.text("原作者微信赞赏码", "Original author's WeChat donation code"))
        unavailable.isHidden = artwork.image != nil
        configure(sourceButton, action: #selector(openSource))
        configure(closeButton, action: #selector(closeDonation))
        closeButton.keyEquivalent = "\r"
        prepare(scroll, document: document)
        for view in [heading, credit, artwork, unavailable, note] as [NSView] { document.addSubview(view) }
        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(sourceButton)
        panel.contentView?.addSubview(closeButton)
        window = panel
    }
    private func makeAboutWindow() {
        let panel = panel(size: NSSize(width: 460, height: 310))
        configure(aboutHeading, size: 21, weight: .semibold)
        configure(aboutVersion, size: 12, muted: true)
        configure(aboutBody, size: 12, muted: true)
        configure(licenseButton, action: #selector(openLicense))
        configure(downloadsButton, action: #selector(openDownloads))
        configure(aboutCloseButton, action: #selector(closeAbout))
        aboutCloseButton.keyEquivalent = "\r"
        prepare(aboutScroll, document: aboutDocument)
        for view in [aboutHeading, aboutVersion, aboutBody] { aboutDocument.addSubview(view) }
        for view in [aboutScroll, licenseButton, downloadsButton, aboutCloseButton] as [NSView] { panel.contentView?.addSubview(view) }
        aboutWindow = panel
    }
    private func textHeight(_ field: NSTextField, width: CGFloat, minimum: CGFloat) -> CGFloat {
        guard let font = field.font else { return minimum }
        let bounds = (field.stringValue as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return max(minimum, ceil(bounds.height) + 6)
    }
    private func layoutDonation() {
        guard let bounds = window?.contentView?.bounds else { return }
        let margin: CGFloat = 16, gap: CGFloat = 10
        let inner = max(1, bounds.width - margin * 2)
        let stacked = inner < 230
        let buttonWidth = stacked ? inner : (inner-gap)/2
        sourceButton.frame = NSRect(x: margin, y: margin + (stacked ? 38 : 0), width: buttonWidth, height: 30)
        closeButton.frame = NSRect(x: stacked ? margin : margin+buttonWidth+gap, y: margin, width: buttonWidth, height: 30)
        let bottom = sourceButton.frame.maxY + 12
        scroll.frame = NSRect(x: margin, y: bottom, width: inner, height: max(1, bounds.height-bottom-margin))
        scroll.tile()
        let origin = scroll.contentView.bounds.origin
        let width = max(1, scroll.contentSize.width), textWidth = max(1, width-16)
        var y: CGFloat = 8
        heading.frame = NSRect(x: 8, y: y, width: textWidth, height: textHeight(heading, width: textWidth, minimum: 24)); y = heading.frame.maxY + 6
        credit.frame = NSRect(x: 8, y: y, width: textWidth, height: textHeight(credit, width: textWidth, minimum: 18)); y = credit.frame.maxY + 12
        let side = min(340, textWidth)
        artwork.frame = NSRect(x: (width-side)/2, y: y, width: side, height: side)
        unavailable.frame = artwork.frame
        y = artwork.frame.maxY + 10
        note.frame = NSRect(x: 8, y: y, width: textWidth, height: textHeight(note, width: textWidth, minimum: 40))
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, note.frame.maxY+12))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func layoutAbout() {
        guard let bounds = aboutWindow?.contentView?.bounds else { return }
        let margin: CGFloat = 16, gap: CGFloat = 10, inner = max(1, bounds.width-32)
        let stacked = inner < 250
        aboutCloseButton.frame = NSRect(x: margin, y: margin, width: inner, height: 30)
        let linkWidth = stacked ? inner : (inner-gap)/2
        licenseButton.frame = NSRect(x: margin, y: 56 + (stacked ? 38 : 0), width: linkWidth, height: 30)
        downloadsButton.frame = NSRect(x: stacked ? margin : margin+linkWidth+gap, y: 56, width: linkWidth, height: 30)
        let bottom = licenseButton.frame.maxY + 12
        aboutScroll.frame = NSRect(x: margin, y: bottom, width: inner, height: max(1,bounds.height-bottom-margin))
        aboutScroll.tile()
        let origin = aboutScroll.contentView.bounds.origin
        let width = max(1, aboutScroll.contentSize.width), textWidth = max(1,width-16)
        aboutHeading.frame = NSRect(x: 8, y: 8, width: textWidth, height: textHeight(aboutHeading, width: textWidth, minimum: 30))
        aboutVersion.frame = NSRect(x: 8, y: aboutHeading.frame.maxY+8, width: textWidth, height: 20)
        aboutBody.frame = NSRect(x: 8, y: aboutVersion.frame.maxY+14, width: textWidth, height: textHeight(aboutBody, width: textWidth, minimum: 68))
        aboutDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(aboutScroll.contentSize.height, aboutBody.frame.maxY+12))
        aboutScroll.contentView.scroll(to: origin); aboutScroll.reflectScrolledClipView(aboutScroll.contentView)
    }
    private func clamp(_ panel: NSPanel) {
        guard let area = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let work = area.insetBy(dx: 8, dy: 8)
        let frame = WindowGeometry.clamp(panel.frame, to: work)
        panel.minSize = NSSize(width: min(260, work.width), height: min(260, work.height))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    func windowDidResize(_ notification: Notification) { layoutDonation(); layoutAbout() }
    func windowDidChangeScreen(_ notification: Notification) {
        if let panel = notification.object as? NSPanel { clamp(panel) }
        layoutDonation(); layoutAbout()
    }
    static func donationArtwork() -> NSImage? {
        var locations: [URL] = []
        if let bundled = Bundle.main.url(forResource: "donation", withExtension: "jpg") {
            locations.append(bundled)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            // A broken packaged app must not substitute a payment image from
            // its caller's working directory.
            return nil
        }
        // Development runs may use the repository asset. Packaged builds use
        // the copied bundle resource above; no payment image is generated.
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        locations.append(current.appendingPathComponent("assets/donation.jpg"))
        locations.append(current.appendingPathComponent("../assets/donation.jpg"))
        for url in locations {
            if let image = NSImage(contentsOf: url), image.isValid { return image }
        }
        return nil
    }
    @objc private func closeDonation() { window?.close() }
    @objc private func closeAbout() { aboutWindow?.close() }
    @objc private func openSource() { NSWorkspace.shared.open(URL(string: "https://github.com/liuxiaogang-com/desktop-icon-billiards")!) }
    @objc private func openLicense() { NSWorkspace.shared.open(URL(string: "https://github.com/liuxiaogang-com/desktop-icon-billiards/blob/main/LICENSE")!) }
    @objc private func openDownloads() { NSWorkspace.shared.open(URL(string: "https://github.com/clark970417-eng/desktop-icon-billiards/releases")!) }
}
