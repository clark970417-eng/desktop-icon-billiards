import AppKit
import UniformTypeIdentifiers

/// Shareable results contain scalar game statistics only, never desktop names,
/// paths, image previews, or a device identifier.
struct RoundResult: Equatable {
    let elapsed: Double
    let iconCount: Int
    let shots: Int
    var globalRank: Int? = nil
    var percentile: Double? = nil
    var bestRank: Int? = nil
    var rankingPhase: String = "off"
    var rankingMessage: String? = nil
    var newBest: Bool = false

    var average: Double { elapsed / Double(max(1, iconCount)) }
    var isValid: Bool { elapsed.isFinite && elapsed >= 0 && iconCount > 0 && shots >= 0 }
    var formattedTime: String {
        guard elapsed.isFinite else { return "--:--.--" }
        let milliseconds = Int((max(0, min(elapsed, 86_400)) * 1000).rounded())
        let centiseconds = milliseconds / 10
        let seconds = centiseconds / 100, hours = seconds / 3600
        let clock = hours > 0
            ? String(format: "%d:%02d:%02d", hours, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return clock + String(format: ".%02d", centiseconds % 100)
    }
}

@MainActor
final class ResultsController: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private var language: AppLanguage = .zhHans
    private var result: RoundResult?
    private var bestAverage: Double?
    private var window: NSWindow?
    private var preview: NSImageView?
    private var saveButton: NSButton?
    private var copyButton: NSButton?
    private var againButton: NSButton?
    private var leaderboardButton: NSButton?
    var onAgain: (() -> Void)?
    var onShowRanking: (() -> Void)?
    private var status: NSTextField?
    private var activeSavePanel: NSSavePanel?
    private var didCopy = false
    private(set) var lastSavedURL: URL?
    private let bestKey = "mac.result.bestAverageSecondsPerIcon"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }

    func show(result: RoundResult, language: AppLanguage) {
        guard result.isValid else { return }
        self.result = result
        self.language = language
        let previous = defaults.object(forKey: bestKey) as? Double
        let validPrevious = previous.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        bestAverage = min(validPrevious ?? result.average, result.average)
        defaults.set(bestAverage, forKey: bestKey)
        didCopy = false
        if window == nil { makeWindow() }
        refresh()
        fitWindow()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Refresh a completed round after an asynchronous ranking reply. The
    /// existing panel, local record, clipboard state and save sheet stay intact.
    func updateResult(_ result: RoundResult) {
        guard result.isValid else { return }
        self.result = result
        refresh()
    }

    func updateLanguage(_ language: AppLanguage) {
        self.language = language
        refresh()
        fitWindow()
        activeSavePanel?.title = pick("保存成绩卡片", "Save result card")
        activeSavePanel?.prompt = pick("保存", "Save")
        activeSavePanel?.message = pick("图片只含成绩与作者署名，不含桌面文件或缩图。",
                                       "The card contains scores and author credit, without desktop files or previews.")
    }

    private func pick(_ zh: String, _ en: String) -> String { language == .en ? en : zh }

    private func makeWindow() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 875),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.backgroundColor = Self.color(0x0e1a18)
        panel.center()
        let body = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 875))
        body.wantsLayer = true
        body.layer?.backgroundColor = Self.color(0x0e1a18).cgColor
        let image = NSImageView(frame: NSRect(x: 24, y: 100, width: 422, height: 527.5))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("Result card")
        body.addSubview(image)
        preview = image
        let save = NSButton(title: "", target: self, action: #selector(saveCard))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 24, y: 53, width: 201, height: 32)
        body.addSubview(save); saveButton = save
        let copy = NSButton(title: "", target: self, action: #selector(copyCard))
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: 245, y: 53, width: 201, height: 32)
        body.addSubview(copy); copyButton = copy
        let again = NSButton(title: "", target: self, action: #selector(again))
        again.bezelStyle = .rounded; again.font = .systemFont(ofSize: 13, weight: .semibold)
        body.addSubview(again); againButton = again
        let leaderboard = NSButton(title: "", target: self, action: #selector(showLeaderboard))
        leaderboard.bezelStyle = .rounded
        body.addSubview(leaderboard); leaderboardButton = leaderboard
        for button in [save, copy, leaderboard] {
            button.bezelColor = Self.color(0x152623); button.contentTintColor = Self.color(0xe8f5f0)
        }
        again.bezelColor = Self.color(0x69ddb3); again.contentTintColor = Self.color(0x0e1a18)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = Self.color(0x8aa69e)
        status.alignment = .center
        status.frame = NSRect(x: 18, y: 19, width: 434, height: 25)
        status.lineBreakMode = .byTruncatingMiddle
        body.addSubview(status); self.status = status
        panel.contentView = body
        window = panel
    }

    private func fitWindow() {
        guard let window, let screen = window.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main else { return }
        let work = screen.visibleFrame
        let size = NSSize(width: min(600, max(220, work.width - 24)),
                          height: min(875, max(240, work.height - 52)))
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.x = max(work.minX, min(work.maxX - frame.width, frame.minX))
        frame.origin.y = max(work.minY, min(work.maxY - frame.height, frame.minY))
        window.setFrameOrigin(frame.origin)
        let stacked = size.width < 370
        let actionsTop: CGFloat = stacked ? 165 : 91
        preview?.frame = NSRect(x: 0, y: actionsTop + 35,
                                width: size.width, height: max(40, size.height - actionsTop - 35))
        leaderboardButton?.frame = NSRect(x: 12, y: actionsTop, width: size.width - 24, height: 31)
        if stacked {
            saveButton?.frame = NSRect(x: 12, y: 123, width: size.width - 24, height: 32)
            copyButton?.frame = NSRect(x: 12, y: 86, width: size.width - 24, height: 32)
            againButton?.frame = NSRect(x: 12, y: 49, width: size.width - 24, height: 32)
        } else {
            let width = (size.width - 48) / 3
            saveButton?.frame = NSRect(x: 12, y: 49, width: width, height: 32)
            copyButton?.frame = NSRect(x: 24 + width, y: 49, width: width, height: 32)
            againButton?.frame = NSRect(x: 36 + width * 2, y: 49, width: width, height: 32)
        }
        status?.frame = NSRect(x: 18, y: 14, width: size.width - 36, height: 31)
        status?.maximumNumberOfLines = 2
    }

    private func refresh() {
        window?.title = pick("清台完成", "Table cleared")
        saveButton?.title = pick("保存图片", "Save image")
        copyButton?.title = pick("复制图片", "Copy image")
        againButton?.title = pick("再来一局", "Play again")
        leaderboardButton?.title = pick("查看排行榜  ›", "View leaderboard  ›")
        againButton?.isEnabled = onAgain != nil
        leaderboardButton?.isEnabled = onShowRanking != nil
        status?.stringValue = didCopy ? pick("已复制，可贴到聊天或文件。", "Copied. Paste into a chat or document.")
            : pick("成绩卡片不含你的桌面文件或图片。", "The result card contains no desktop files or pictures.")
        guard let result else { return }
        preview?.image = Self.renderCard(result: result, language: language, bestAverage: bestAverage)
        preview?.setAccessibilityLabel(pick("成绩卡片", "Result card") + ", \(result.formattedTime), \(result.iconCount), \(result.shots)")
    }

    @objc private func again() {
        guard window?.attachedSheet == nil else { return }
        window?.orderOut(nil)
        onAgain?()
    }
    @objc private func showLeaderboard() { onShowRanking?() }

    @objc private func copyCard() {
        guard let result, let data = Self.renderPNG(result: result, language: language, bestAverage: bestAverage) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: .png) { didCopy = true; refresh() }
    }

    @objc private func saveCard() {
        guard let window, window.attachedSheet == nil, result != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "DesktopIconBilliards-result.png"
        panel.title = pick("保存成绩卡片", "Save result card")
        panel.prompt = pick("保存", "Save")
        panel.message = pick("图片只含成绩与作者署名，不含桌面文件或缩图。",
                             "The card contains scores and author credit, without desktop files or previews.")
        activeSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeSavePanel = nil
            guard response == .OK, let url = panel.url, let result = self.result,
                  let data = Self.renderPNG(result: result, language: self.language, bestAverage: self.bestAverage) else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.lastSavedURL = url
                self.didCopy = false
                self.status?.stringValue = self.pick("成绩卡片已保存。", "Result card saved.")
            } catch {
                self.status?.stringValue = self.pick("无法保存，请选择其他位置。", "Could not save. Choose another location.")
            }
        }
    }

    /// Matches Windows percentile boundaries. A tier is displayed only when an
    /// actual percentile exists; local averages never impersonate global ranks.
    static func tier(percentile: Double, language: AppLanguage) -> String {
        let names = language == .en
            ? ["Legend", "Desktop champion", "Master", "Expert", "Skilled", "Rookie"]
            : ["传奇球王", "桌面球王", "大师", "高手", "熟手", "新秀"]
        let thresholds = [99.0, 95, 85, 65, 40, 0]
        let value = percentile.isFinite ? max(0, min(100, percentile)) : 0
        return names[thresholds.firstIndex(where: { value >= $0 }) ?? 5]
    }

    static func renderPNG(result: RoundResult, language: AppLanguage, bestAverage: Double? = nil,
                          when: Date = Date(), logo: NSImage? = nil) -> Data? {
        let card = renderCard(result: result, language: language, bestAverage: bestAverage, when: when, logo: logo)
        return card.representations.compactMap { ($0 as? NSBitmapImageRep)?.representation(using: .png, properties: [:]) }.first
    }

    /// Native port of dib/card.py's current 1080×1350 card: all measurements
    /// below remain in the Windows renderer's top-left coordinate system.
    static func renderCard(result: RoundResult, language: AppLanguage, bestAverage: Double? = nil,
                           when: Date = Date(), logo: NSImage? = nil) -> NSImage {
        let width = 1080, height = 1350
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return NSImage(size: NSSize(width: width, height: height)) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let canvas = NSRect(x: 0, y: 0, width: width, height: height)
        let accent = color(0x69ddb3), accentLight = color(0xb6fbe0), textColor = color(0xecf8f3), muted = color(0x8aa69e)
        let gold = color(0xf2ca87)
        let ranked = result.globalRank.map { $0 > 0 } == true && result.percentile?.isFinite == true
        let percentile = result.percentile.map { max(0, min(100, $0)) } ?? 0
        let tierColor = ranked ? tierColor(percentile: percentile) : accent
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x, y: 1350 - y - h, width: w, height: h)
        }
        func word(_ zh: String, _ en: String) -> String { language == .en ? en : zh }
        func font(_ size: CGFloat, _ bold: Bool = false, _ numeric: Bool = false) -> NSFont {
            numeric ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
                : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        func measured(_ value: String, _ face: NSFont) -> NSSize { (value as NSString).size(withAttributes: [.font: face]) }
        func fitted(_ value: String, _ size: CGFloat, _ maximum: CGFloat, bold: Bool = false, numeric: Bool = false) -> NSFont {
            var face = font(size, bold, numeric)
            while measured(value, face).width > maximum && face.pointSize > 20 { face = font(face.pointSize - 4, bold, numeric) }
            return face
        }
        // anchor: top-left / middle-center / baseline-left / baseline-center /
        // middle-left / middle-right / top-right, matching Pillow card anchors.
        func draw(_ value: String, _ x: CGFloat, _ y: CGFloat, _ face: NSFont,
                  _ fill: NSColor, _ anchor: String = "tl") {
            let size = measured(value, face)
            var left = x, bottom = 1350 - y - size.height
            if ["mm", "ms"].contains(anchor) { left -= size.width / 2 }
            if ["rm", "tr"].contains(anchor) { left -= size.width }
            if ["ls", "ms"].contains(anchor) { bottom = 1350 - y + face.descender }
            if ["mm", "lm", "rm"].contains(anchor) { bottom = 1350 - y - size.height / 2 }
            (value as NSString).draw(at: NSPoint(x: left, y: bottom), withAttributes: [.font: face, .foregroundColor: fill])
        }
        func rounded(_ box: NSRect, _ radius: CGFloat, _ fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
            let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
            fill.setFill(); path.fill()
            if let stroke { stroke.setStroke(); path.lineWidth = lineWidth; path.stroke() }
        }
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ fill: NSColor, _ lineWidth: CGFloat = 2) {
            let path = NSBezierPath(); path.move(to: NSPoint(x: x0, y: 1350 - y0)); path.line(to: NSPoint(x: x1, y: 1350 - y1))
            fill.setStroke(); path.lineWidth = lineWidth; path.stroke()
        }
        NSGradient(starting: color(0x081614), ending: color(0x0f2f29))?.draw(in: canvas, angle: -90)
        for (center, radius, fill, strength) in [
            (NSPoint(x: 540, y: 1350 - 520), CGFloat(520), tierColor, CGFloat(0.34)),
            (NSPoint(x: 1040, y: 120), CGFloat(460), accent, CGFloat(0.16))
        ] {
            NSGradient(starting: fill.withAlphaComponent(strength), ending: fill.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }
        for x: CGFloat in [0, 1080] {
            for y: CGFloat in [0, 1350] {
                for (radius, alpha) in [(CGFloat(210), CGFloat(20) / 255), (150, 14 / 255)] {
                    let path = NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    accent.withAlphaComponent(alpha).setStroke(); path.lineWidth = 3; path.stroke()
                }
            }
        }
        let bundledLogo = Bundle.main.url(forResource: "desktop-icon-billiards", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        (logo ?? bundledLogo)?.draw(in: rect(96, 82, 80, 80), from: .zero, operation: .sourceOver, fraction: 1)
        draw(word("桌面图标台球", "Desktop Icon Billiards"), 200, 82, font(46, true), textColor)
        draw(word("把桌面图标打成一局台球", "Turn desktop icons into a game of billiards"), 202, 144,
             fitted(word("把桌面图标打成一局台球", "Turn desktop icons into a game of billiards"), 24, 650), muted)
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy.MM.dd"
        draw(date.string(from: when), 984, 92, font(26, true, true), muted, "tr")

        if ranked, let rank = result.globalRank {
            let title = tier(percentile: percentile, language: language), face = font(40, true)
            let badgeWidth = measured(title, face).width + 96
            rounded(rect(540 - badgeWidth / 2, 270, badgeWidth, 78), 39, tierColor.withAlphaComponent(46 / 255))
            draw(title, 540, 309, face, tierColor, "mm")
            draw(word("本局全球排名", "Global rank this round"), 540, 408, font(30), muted, "mm")
            let number = decimal(rank), big = fitted(number, 230, 640, bold: true, numeric: true), small = font(64, true)
            let prefix = word("第", "#"), suffix = word("名", "")
            let prefixWidth = measured(prefix, small).width, numberWidth = measured(number, big).width
            let suffixWidth = measured(suffix, small).width
            var left = (1080 - prefixWidth - numberWidth - suffixWidth - 28) / 2
            draw(prefix, left, 640, small, tierColor, "ls"); left += prefixWidth + 14
            draw(number, left, 640, big, tierColor, "ls"); left += numberWidth + 14
            draw(suffix, left, 640, small, tierColor, "ls")
            var percentage = String(format: "%.2f", percentile)
            while percentage.last == "0" { percentage.removeLast() }
            if percentage.last == "." { percentage.removeLast() }
            let parts: [(String, NSFont, NSColor)] = [
                (word("超过  ", "Ahead of  "), font(32), textColor),
                (percentage + "%", font(110, true, true), accentLight),
                (word("  的全球玩家", "  of global players"), font(32), textColor)
            ]
            var percentLeft = (1080 - parts.reduce(CGFloat(0)) { $0 + measured($1.0, $1.1).width }) / 2
            for (value, face, fill) in parts {
                draw(value, percentLeft, 828, face, fill, "ls"); percentLeft += measured(value, face).width
            }
            rounded(rect(190, 868, 700, 14), 7, accentLight.withAlphaComponent(70 / 255),
                    stroke: accentLight.withAlphaComponent(105 / 255))
            let filled = 700 * percentile / 100
            if filled > 0 { rounded(rect(190, 868, filled, 14), min(7, filled / 2), accentLight) }
        } else {
            draw(word("平均每颗用时", "Average time per icon"), 540, 300, font(34), muted, "mm")
            let value = String(format: "%.2f", result.average), big = fitted(value, 250, 680, numeric: true)
            draw(value, 510, 520, big, accent, "ms")
            draw(word("秒", "s"), 540 + measured(value, big).width / 2 - 10, 520, font(64, true), accent, "ls")
            let message: String
            switch result.rankingPhase {
            case "pending": message = word("正在提交成绩，稍后显示全球排名", "Submitting score; global rank will appear shortly")
            case "off": message = word("开启「全球排名」，看看你超过了多少玩家", "Enable global ranking to compare with other players")
            default: message = result.rankingMessage ?? ""
            }
            if !message.isEmpty {
                let face = fitted(message, 30, 808)
                let pillWidth = min(888, measured(message, face).width + 80)
                rounded(rect(540 - pillWidth / 2, 620, pillWidth, 70), 35, color(0x1f3733), stroke: color(0x3c645c), lineWidth: 2)
                draw(message, 540, 655, face, muted, "mm")
            }
        }

        line(96, 940, 984, 940, color(0x30544c))
        let values = [result.formattedTime, String(format: "%.2f", result.average), "\(result.iconCount)", "\(result.shots)"]
        let labels = language == .en ? ["Total time", "Average / icon", "Icons", "Shots"] : ["总用时", "平均每颗", "图标", "击球"]
        let units = language == .en ? ["", "s", "", ""] : ["", "秒", "颗", "杆"]
        for index in 0..<4 {
            let x = 96 + CGFloat(index) * 222
            draw(labels[index], x, 986, fitted(labels[index], 27, 190), muted)
            let face = fitted(values[index], 42, 180, numeric: true)
            draw(values[index], x, 1080, face, textColor, "ls")
            if !units[index].isEmpty { draw(units[index], x + 8 + measured(values[index], face).width, 1080, font(24), muted, "ls") }
        }
        if ranked, let bestRank = result.bestRank, bestRank > 0 {
            let value = word("个人最佳  \(decimal(bestRank)) 名", "Personal best  #\(decimal(bestRank))")
            draw(value, 96, 1186, fitted(value, 34, 690), accentLight, "lm")
            if result.newBest {
                let value = word("新纪录", "New best"), face = font(30), pill = measured(value, face).width + 56
                rounded(rect(984 - pill, 1156, pill, 60), 30, gold)
                draw(value, 984 - pill / 2, 1186, face, color(0x281c08), "mm")
                let stem = 984 - pill - 30
                line(stem + 9, 1205, stem - 5, 1168, gold)
                for offset: CGFloat in [0, 12, 24] {
                    let y = 1200 - offset, x = stem + 7 - offset / 3
                    for side: CGFloat in [-1, 1] {
                        let leaf = NSBezierPath()
                        leaf.move(to: NSPoint(x: x, y: 1350 - y))
                        leaf.line(to: NSPoint(x: x + side * 12, y: 1350 - y + 5))
                        leaf.line(to: NSPoint(x: x + side * 14, y: 1350 - y + 17))
                        leaf.line(to: NSPoint(x: x + side * 4, y: 1350 - y + 11)); leaf.close()
                        gold.setFill(); leaf.fill()
                    }
                }
            }
        }
        line(96, 1262, 984, 1262, color(0x30544c))
        draw("GitHub@liuxiaogang-com", 96, 1296, font(28, true, true), accent, "lm")
        draw(word("作者抖音 @LLLLLLLLLL", "Douyin @LLLLLLLLLL"), 984, 1296, font(24), muted, "rm")
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: width, height: height)
        let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap); return image
    }

    static func tierColor(percentile: Double) -> NSColor {
        let value = percentile.isFinite ? max(0, min(100, percentile)) : 0
        let tiers: [(Double, UInt32)] = [(99, 0xf2ca87), (95, 0xffaa66), (85, 0xbe9aff), (65, 0x69ddb3), (40, 0x8cc8ff), (0, 0xa6bab4)]
        return color(tiers.first(where: { value >= $0.0 })?.1 ?? 0xa6bab4)
    }
    private static func decimal(_ value: Int) -> String {
        let format = NumberFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.numberStyle = .decimal
        return format.string(from: NSNumber(value: value)) ?? String(value)
    }
    private static func color(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
