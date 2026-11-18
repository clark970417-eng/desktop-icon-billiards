import AppKit
import BilliardsCore

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

@MainActor
final class GameView: NSView {
    let game = BilliardsGame(iconCount: 15)
    private(set) var iconSet = IconSet.applications()
    private(set) var paused = false
    private(set) var desktopMode = false
    private var guides = true
    private var aim = Vector(620, 250)
    private var chargeStart: TimeInterval?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var deactivationObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var savedFrame: NSRect?
    private var savedStyle: NSWindow.StyleMask?
    private var sessionWasPaused = false
    private var folderButton: NSButton!
    private var desktopButton: NSButton!
    private var restartButton: NSButton!
    private var guideButton: NSButton!
    private var pauseButton: NSButton!
    private var toast: String?
    private var toastUntil: TimeInterval = 0
    private var lastPocketCount = 0
    private var pocketFlash: TimeInterval = 0
    private var lastAccessibleState = ""
    private var desktopBackdrop: DesktopBackdrop?
    private var desktopItems: [DesktopItem] = []
    private var desktopOrigins: [NSPoint] = []
    private var desktopIconSize: CGFloat = 64
    private var wallpaperRect = NSRect.zero
    private var previousIconSet: IconSet?
    private var desktopTransition: DesktopTransition?
    private var pendingDesktopExit: (() -> Void)?
    var isDesktopTransitioning: Bool { desktopTransition != nil }

    private struct DesktopTransition {
        let started: TimeInterval
        let duration: TimeInterval
        let from: [NSPoint]
        let to: [NSPoint]
        let fromAlpha: [CGFloat]
        let returning: Bool
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    var charge: Double {
        chargeStart.map { BilliardsGame.chargePower(seconds: ProcessInfo.processInfo.systemUptime - $0) } ?? 0
    }
    var playingRect: NSRect {
        let availableWidth = max(100, bounds.width - 112)
        let availableHeight = max(50, bounds.height - 292)
        let width = min(availableWidth, availableHeight * 2)
        return NSRect(x: (bounds.width - width) / 2, y: 142 + (availableHeight - width / 2) / 2,
                      width: width, height: width / 2)
    }
    private var scale: CGFloat { playingRect.width / game.width }
    private var isActiveGame: Bool { !paused && desktopTransition == nil && !game.isMoving && !game.isComplete }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("桌面圖示撞球遊戲。移動滑鼠瞄準，按住左鍵蓄力，放開擊球。")
        folderButton = button("選取資料夾…", action: #selector(selectFolder))
        desktopButton = button("桌面開局", action: #selector(toggleDesktop))
        restartButton = button("重新開始  R", action: #selector(restart))
        guideButton = button("輔助線：開  G", action: #selector(toggleGuides))
        pauseButton = button("暫停  Space", action: #selector(togglePause))
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForInterruption() }
        }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.window else { return }
                self.pauseForInterruption()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        timer?.invalidate()
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = NSColor(hex: 0xdce8e7)
        addSubview(button)
        return button
    }
    override func layout() {
        super.layout()
        folderButton.frame = NSRect(x: bounds.width - 356, y: bounds.height - 69, width: 126, height: 30)
        desktopButton.frame = NSRect(x: bounds.width - 222, y: bounds.height - 69, width: 96, height: 30)
        restartButton.frame = NSRect(x: bounds.width - 118, y: bounds.height - 69, width: 100, height: 30)
        guideButton.frame = NSRect(x: 32, y: 73, width: 132, height: 30)
        pauseButton.frame = NSRect(x: 172, y: 73, width: 124, height: 30)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    func screenPoint(_ vector: Vector) -> NSPoint {
        NSPoint(x: playingRect.minX + vector.x * scale, y: playingRect.minY + vector.y * scale)
    }
    private func modelPoint(_ point: NSPoint) -> Vector {
        Vector((point.x - playingRect.minX) / scale, (point.y - playingRect.minY) / scale)
    }
    override func mouseMoved(with event: NSEvent) {
        aim = modelPoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard playingRect.contains(point), isActiveGame else { return }
        aim = modelPoint(point)
        if game.needsCuePlacement {
            if !game.placeCue(at: aim) { showToast("請選擇遠離其他球與袋口的位置") }
            return
        }
        chargeStart = ProcessInfo.processInfo.systemUptime
    }
    override func mouseUp(with event: NSEvent) {
        guard let started = chargeStart else { return }
        chargeStart = nil
        // Focus changes already cancel charge via notifications. Accept a valid
        // mouse-up delivered to this view, including macOS app-window automation.
        guard !paused, playingRect.contains(convert(event.locationInWindow, from: nil)) else {
            needsDisplay = true
            return
        }
        aim = modelPoint(convert(event.locationInWindow, from: nil))
        _ = game.shoot(toward: aim, power: BilliardsGame.chargePower(seconds: ProcessInfo.processInfo.systemUptime - started))
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil); return }
        guard !event.isARepeat else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": restart()
        case "g": toggleGuides()
        case " ": togglePause()
        default: super.keyDown(with: event)
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(1 / 15, max(0, now - lastTick))
        lastTick = now
        if !paused && desktopTransition == nil { game.step(delta) }
        advanceDesktopTransition(now: now)
        if game.pocketedCount > lastPocketCount { pocketFlash = now }
        lastPocketCount = game.pocketedCount
        // Timed animation stops redrawing idle tables; charging and pocket feedback remain smooth.
        if game.isMoving || chargeStart != nil || (!paused && game.shots > 0 && !game.isComplete)
            || now - pocketFlash < 0.7 || toast != nil || desktopTransition != nil {
            needsDisplay = true
        }
        if toast != nil && now > toastUntil { toast = nil; needsDisplay = true }
        let accessibleState = "桌面圖示撞球。\(game.shots) 桿，入袋 \(game.pocketedCount)/\(game.iconCount)。"
            + (paused ? "已暫停。" : game.isMoving ? "球滾動中。" : "可以擊球。")
            + (desktopMode ? "桌面模式。" : "視窗模式。")
        if accessibleState != lastAccessibleState {
            setAccessibilityLabel(accessibleState)
            lastAccessibleState = accessibleState
        }
    }
    @objc func restart() {
        guard desktopTransition == nil else { return }
        game.reset(iconCount: iconSet.images.count)
        paused = false
        chargeStart = nil
        lastPocketCount = 0
        aim = Vector(620, 250)
        pauseButton.title = "暫停  Space"
        lastTick = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
    }
    @objc func toggleGuides() {
        guides.toggle()
        guideButton.title = guides ? "輔助線：開  G" : "輔助線：關  G"
        needsDisplay = true
    }
    @objc func togglePause() {
        guard desktopTransition == nil else { return }
        paused.toggle()
        chargeStart = nil
        lastTick = ProcessInfo.processInfo.systemUptime
        pauseButton.title = paused ? "繼續  Space" : "暫停  Space"
        needsDisplay = true
    }
    private func pauseForInterruption() {
        chargeStart = nil
        if game.shots > 0 || game.isMoving { paused = true; pauseButton.title = "繼續  Space" }
        needsDisplay = true
    }
    @objc func selectFolder() {
        guard !desktopMode, let window, window.attachedSheet == nil else { return }
        sessionWasPaused = paused
        paused = true
        chargeStart = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用圖示"
        panel.message = "選擇桌面或其他資料夾。只讀取圖示，原始檔案不會移動。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.paused = self.sessionWasPaused
            if response == .OK, let url = panel.url {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    self.iconSet = try IconSet.folder(url)
                    self.restart()
                    self.showToast("已換成資料夾圖示，開始新的一局")
                } catch {
                    self.showToast("無法讀取圖示：\(error.localizedDescription)")
                }
            }
            self.pauseButton.title = self.paused ? "繼續  Space" : "暫停  Space"
            self.window?.makeFirstResponder(self)
            self.lastTick = ProcessInfo.processInfo.systemUptime
            self.needsDisplay = true
        }
    }
    @objc func toggleDesktop() {
        guard let window, window.attachedSheet == nil else { return }
        if desktopMode { NSApp.terminate(nil); return }
        guard let screen = NSScreen.screens.first else { return }
        chargeStart = nil
        let wasPaused = paused
        paused = true
        do {
            // Read the wallpaper first. If unavailable, leave the desktop alone
            // and avoid asking for unnecessary Finder access.
            let backdrop = try DesktopBackdrop.read(screen: screen)
            let snapshot = try DesktopSnapshot.read()
            try startDesktop(snapshot: snapshot, backdrop: backdrop, screen: screen)
        } catch {
            paused = wasPaused
            let alert = NSAlert()
            alert.messageText = "無法開始桌面球局"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window)
        }
        needsDisplay = true
    }

    /// Overlay the usable primary desktop with wallpaper and animate only its
    /// game copies. Finder remains untouched, including in crash/force-quit cases.
    func startDesktop(snapshot: DesktopSnapshot, backdrop: DesktopBackdrop, screen: NSScreen,
                      presentWindow: Bool = true) throws {
        guard !desktopMode, let window, let primary = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let candidates = snapshot.items.compactMap { item -> (DesktopItem, NSPoint)? in
            let point = DesktopBackdrop.viewPoint(finderPosition: item.finderPosition,
                                                   screenFrame: frame, primaryFrame: primary.frame)
            return NSRect(origin: .zero, size: frame.size).contains(point) ? (item, point) : nil
        }
        guard !candidates.isEmpty else { throw DesktopSnapshot.SnapshotError.noDesktopItems }
        previousIconSet = iconSet
        savedFrame = window.frame
        savedStyle = window.styleMask
        desktopItems = candidates.map { $0.0 }
        desktopOrigins = candidates.map { $0.1 }
        desktopIconSize = snapshot.iconSize
        desktopBackdrop = backdrop
        wallpaperRect = NSRect(x: screen.frame.minX - frame.minX, y: screen.frame.minY - frame.minY,
                               width: screen.frame.width, height: screen.frame.height)
        iconSet = IconSet(images: desktopItems.map(\.image), label: "你的桌面圖示 · \(desktopItems.count) 顆")
        game.reset(iconCount: desktopItems.count)
        lastPocketCount = 0
        paused = false
        desktopMode = true
        window.styleMask = [.borderless]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .floating
        window.setFrame(frame, display: true)
        layoutSubtreeIfNeeded()
        desktopButton.title = "退出還原"
        folderButton.isEnabled = false
        pauseButton.title = "暫停  Space"
        aim = Vector(620, 250)
        let targets = game.balls.filter { !$0.isCue }.map { screenPoint($0.position) }
        desktopTransition = DesktopTransition(started: ProcessInfo.processInfo.systemUptime, duration: 0.85,
            from: desktopOrigins, to: targets, fromAlpha: Array(repeating: 1, count: targets.count), returning: false)
        if presentWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(self)
        lastTick = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
    }

    func restoreDesktop(completion: (() -> Void)? = nil) {
        guard desktopMode else { completion?(); return }
        if let completion { pendingDesktopExit = completion }
        if desktopTransition?.returning == true { return }
        let now = ProcessInfo.processInfo.systemUptime
        let positions = desktopTransition.map { transitionPositions($0, now: now) }
            ?? game.balls.filter { !$0.isCue }.map { screenPoint($0.position) }
        let alphas: [CGFloat] = desktopTransition == nil
            ? game.balls.filter { !$0.isCue }.map { $0.pocketed ? 0 : 1 }
            : Array(repeating: 1, count: positions.count)
        chargeStart = nil
        paused = true
        desktopTransition = DesktopTransition(started: now, duration: 0.55,
            from: positions, to: desktopOrigins, fromAlpha: alphas, returning: true)
        needsDisplay = true
    }

    private func advanceDesktopTransition(now: TimeInterval) {
        guard let transition = desktopTransition, now - transition.started >= transition.duration else { return }
        desktopTransition = nil
        if transition.returning {
            desktopMode = false
            desktopBackdrop = nil
            desktopItems = []
            desktopOrigins = []
            if let previousIconSet { iconSet = previousIconSet }
            previousIconSet = nil
            if let window {
                window.styleMask = savedStyle ?? [.titled, .closable, .miniaturizable, .resizable]
                window.backgroundColor = NSColor(hex: 0x10191d)
                window.hasShadow = true
                window.level = .normal
                if let savedFrame { window.setFrame(savedFrame, display: true) }
                window.makeFirstResponder(self)
            }
            desktopButton.title = "桌面開局"
            folderButton.isEnabled = true
            restart()
            let completion = pendingDesktopExit
            pendingDesktopExit = nil
            completion?()
        } else {
            paused = false
            lastTick = now
        }
        needsDisplay = true
    }

    private func transitionPositions(_ transition: DesktopTransition, now: TimeInterval) -> [NSPoint] {
        let progress = min(1, max(0, (now - transition.started) / transition.duration))
        let eased = progress * progress * (3 - 2 * progress)
        return zip(transition.from, transition.to).enumerated().map { index, pair in
            let arc = sin(progress * .pi) * CGFloat(30 + index % 4 * 12)
            return NSPoint(x: pair.0.x + (pair.1.x - pair.0.x) * eased,
                           y: pair.0.y + (pair.1.y - pair.0.y) * eased + arc)
        }
    }

    private func drawDesktopTransition(_ transition: DesktopTransition, now: TimeInterval) {
        let progress = min(1, max(0, (now - transition.started) / transition.duration))
        let eased = CGFloat(progress * progress * (3 - 2 * progress))
        let positions = transitionPositions(transition, now: now)
        let ballSize = (game.balls.first?.radius ?? 22) * 2 * scale
        let size = transition.returning ? ballSize + (desktopIconSize - ballSize) * eased
            : desktopIconSize + (ballSize - desktopIconSize) * eased
        for (index, point) in positions.enumerated() where index < desktopItems.count {
            let alpha = transition.returning ? transition.fromAlpha[index] + (1 - transition.fromAlpha[index]) * eased : 1
            let imageRect = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            desktopItems[index].image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: alpha)
            let labelAlpha = transition.returning ? eased : 1 - eased
            text(desktopItems[index].url.lastPathComponent, at: NSPoint(x: point.x, y: point.y - size / 2 - 18),
                 size: 11, color: .white.withAlphaComponent(labelAlpha), centered: true)
        }
    }
    private func showToast(_ message: String) {
        toast = message
        toastUntil = ProcessInfo.processInfo.systemUptime + 4
        needsDisplay = true
    }
    private func text(_ string: String, at point: NSPoint, size: CGFloat = 13,
                      color: NSColor = NSColor(hex: 0xc4d6d3), weight: NSFont.Weight = .regular,
                      centered: Bool = false, mono: Bool = false) {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = string as NSString
        let width = centered ? ns.size(withAttributes: attributes).width : 0
        ns.draw(at: NSPoint(x: point.x - width / 2, y: point.y), withAttributes: attributes)
    }
    private func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = ProcessInfo.processInfo.systemUptime
        if desktopMode, let desktopBackdrop { desktopBackdrop.draw(in: wallpaperRect) }
        else {
            NSColor(hex: 0x0e181c).setFill(); bounds.fill()
            NSGradient(starting: NSColor(hex: 0x172a2c), ending: NSColor(hex: 0x0b141a))?.draw(in: bounds, angle: -70)
        }
        let hudFill = NSColor(hex: 0x142327, alpha: desktopMode ? 0.95 : 0.75)
        rounded(NSRect(x: 16, y: bounds.height - 120, width: bounds.width - 32, height: 104), radius: 16,
                fill: hudFill, stroke: NSColor(hex: 0x48665f, alpha: 0.3))
        text("MAC EDITION  /  01", at: NSPoint(x: 34, y: bounds.height - 39), size: 10,
             color: NSColor(hex: 0x9bddae), weight: .semibold, mono: true)
        text("桌面圖示撞球", at: NSPoint(x: 32, y: bounds.height - 72), size: 25,
             color: NSColor(hex: 0xf1f6e8), weight: .semibold)
        text(iconSet.label, at: NSPoint(x: 34, y: bounds.height - 102), size: 12, color: NSColor(hex: 0x8fa9a5))
        let minutes = Int(game.elapsed) / 60, seconds = Int(game.elapsed) % 60
        text(String(format: "%02d:%02d", minutes, seconds), at: NSPoint(x: bounds.width - 322, y: bounds.height - 103),
             size: 15, color: NSColor(hex: 0xe6eee7), mono: true)
        text("\(game.shots) 桿", at: NSPoint(x: bounds.width - 224, y: bounds.height - 103), size: 13, mono: true)
        text("入袋  \(game.pocketedCount) / \(game.iconCount)", at: NSPoint(x: bounds.width - 144, y: bounds.height - 103),
             size: 13, color: NSColor(hex: 0xafe4b7), weight: .medium, mono: true)
        drawTable(now: now)
        drawFooter()
        if desktopTransition == nil {
            if paused { drawCard(title: "暫停一下", subtitle: "按 Space 或「繼續」回到球局") }
            else if game.isComplete { drawCard(title: "漂亮，清台了！", subtitle: "\(game.shots) 桿 · \(minutes) 分 \(seconds) 秒   /   按 R 再來一局") }
            else if game.needsCuePlacement { drawCard(title: "白球自由球", subtitle: "點擊球桌上的空位，重新放置白球") }
        }
        if let toast {
            rounded(NSRect(x: bounds.midX - 270, y: 114, width: 540, height: 34), radius: 10, fill: NSColor(hex: 0x29433b))
            text(toast, at: NSPoint(x: bounds.midX, y: 123), size: 12, color: .white, centered: true)
        }
    }
    private func drawTable(now: TimeInterval) {
        let rect = playingRect
        rounded(rect.insetBy(dx: -24, dy: -24), radius: 34, fill: NSColor(hex: 0x080f12, alpha: desktopMode ? 0.7 : 1),
                stroke: NSColor(hex: 0x698473, alpha: 0.4))
        rounded(rect.insetBy(dx: -14, dy: -14), radius: 23, fill: NSColor(hex: 0x27483b, alpha: desktopMode ? 0.45 : 1))
        if !desktopMode {
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSGradient(starting: NSColor(hex: 0x22664e), ending: NSColor(hex: 0x154333))?.draw(in: path, angle: -70)
            // Restrained felt marks and the break line.
            NSColor(hex: 0xc0e2bf, alpha: 0.018).setStroke()
            let lines = NSBezierPath(); lines.lineWidth = 0.6
            for y in stride(from: rect.minY + 3, to: rect.maxY, by: 5) {
                lines.move(to: NSPoint(x: rect.minX + 4, y: y)); lines.line(to: NSPoint(x: rect.maxX - 4, y: y))
            }
            lines.stroke()
        }
        let line = NSBezierPath(); line.lineWidth = 1
        line.setLineDash([4, 8], count: 2, phase: 0)
        line.move(to: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + 18))
        line.line(to: NSPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY - 18))
        NSColor(hex: 0xd5edd3, alpha: 0.13).setStroke(); line.stroke()
        for index in 1..<8 where index != 4 {
            for y in [rect.minY - 17, rect.maxY + 17] {
                let point = NSPoint(x: rect.minX + rect.width * CGFloat(index) / 8, y: y)
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: point.x, y: point.y + 2.5))
                diamond.line(to: NSPoint(x: point.x + 2.5, y: point.y))
                diamond.line(to: NSPoint(x: point.x, y: point.y - 2.5))
                diamond.line(to: NSPoint(x: point.x - 2.5, y: point.y)); diamond.close()
                NSColor(hex: 0xb8c5a2, alpha: 0.6).setFill(); diamond.fill()
            }
        }
        for pocket in game.pockets {
            let p = screenPoint(pocket), radius = game.pocketRadius * scale
            let hole = NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            NSColor(hex: 0x69856a, alpha: 0.5).setFill(); NSBezierPath(ovalIn: hole.insetBy(dx: -2, dy: -2)).fill()
            NSColor(hex: 0x070e12).setFill(); NSBezierPath(ovalIn: hole).fill()
            NSColor(hex: 0x000406).setFill(); NSBezierPath(ovalIn: hole.insetBy(dx: 4, dy: 4)).fill()
        }
        text("DESKTOP ICON BILLIARDS", at: NSPoint(x: rect.midX, y: rect.midY + 65), size: 12,
             color: NSColor(hex: 0xe1efd5, alpha: desktopMode ? 0.4 : 0.12), weight: .semibold, centered: true)
        if guides && isActiveGame && !game.needsCuePlacement { drawGuide() }
        if let desktopTransition {
            drawDesktopTransition(desktopTransition, now: now)
        } else {
            for ball in game.balls where !ball.pocketed { drawBall(ball) }
        }
        if now - pocketFlash < 0.65 && game.pocketedCount > 0 {
            text("+1 入袋", at: NSPoint(x: rect.midX, y: rect.maxY + 28), size: 13,
                 color: NSColor(hex: 0xb8efaa, alpha: 1 - (now - pocketFlash) / 0.65), weight: .semibold, centered: true)
        }
    }
    private func drawBall(_ ball: Ball) {
        let p = screenPoint(ball.position), r = ball.radius * scale
        let circle = NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 1, height: -3); shadow.set()
        if ball.isCue {
            NSGradient(starting: NSColor(hex: 0xffffff), ending: NSColor(hex: 0xbcc7c4))?.draw(in: NSBezierPath(ovalIn: circle), angle: -60)
        } else {
            NSColor(hex: 0x0c2420, alpha: 0.45).setFill(); NSBezierPath(ovalIn: circle).fill()
            if !iconSet.images.isEmpty {
                let image = iconSet.images[(max(1, ball.id) - 1) % iconSet.images.count]
                image.draw(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06), from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSColor.white.withAlphaComponent(0.12).setStroke()
            NSBezierPath(ovalIn: circle).stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if ball.isCue {
            NSColor(hex: 0xffffff, alpha: 0.75).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r * 0.4, y: p.y + r * 0.2, width: r * 0.35, height: r * 0.28)).fill()
        }
    }
    private func drawGuide() {
        guard let cue = game.balls.first(where: { $0.isCue && !$0.pocketed }) else { return }
        let dx = aim.x - cue.position.x, dy = aim.y - cue.position.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        var distance = 1500.0
        // First rail intersection, then first ball intersection (swept cue circle).
        if ux > 0 { distance = min(distance, (game.width - cue.radius - cue.position.x) / ux) }
        if ux < 0 { distance = min(distance, (cue.radius - cue.position.x) / ux) }
        if uy > 0 { distance = min(distance, (game.height - cue.radius - cue.position.y) / uy) }
        if uy < 0 { distance = min(distance, (cue.radius - cue.position.y) / uy) }
        for ball in game.balls where !ball.isCue && !ball.pocketed {
            let bx = ball.position.x - cue.position.x, by = ball.position.y - cue.position.y
            let projection = bx * ux + by * uy
            let perpendicularSq = bx * bx + by * by - projection * projection
            let radius = ball.radius + cue.radius
            if projection > 0 && perpendicularSq < radius * radius {
                distance = min(distance, max(0, projection - sqrt(radius * radius - perpendicularSq)))
            }
        }
        distance = max(0, distance)
        let origin = screenPoint(cue.position)
        let target = screenPoint(Vector(cue.position.x + ux * distance, cue.position.y + uy * distance))
        let line = NSBezierPath(); line.lineWidth = 1.2; line.setLineDash([5, 6], count: 2, phase: 0)
        line.move(to: origin); line.line(to: target)
        NSColor(hex: 0xe2f3df, alpha: 0.55).setStroke(); line.stroke()
        let r = cue.radius * scale
        NSColor(hex: 0xe2f3df, alpha: 0.4).setStroke()
        NSBezierPath(ovalIn: NSRect(x: target.x - r, y: target.y - r, width: 2 * r, height: 2 * r)).stroke()
        // Cue stick pulls back as power rises.
        let gap = cue.radius + 13 + charge * 55
        let stick = NSBezierPath(); stick.lineWidth = 5; stick.lineCapStyle = .round
        stick.move(to: screenPoint(Vector(cue.position.x - ux * gap, cue.position.y - uy * gap)))
        stick.line(to: screenPoint(Vector(cue.position.x - ux * (gap + 130), cue.position.y - uy * (gap + 130))))
        NSColor(hex: 0xd6bb83).setStroke(); stick.stroke()
    }
    private func drawFooter() {
        rounded(NSRect(x: 16, y: 16, width: bounds.width - 32, height: 101), radius: 16,
                fill: NSColor(hex: 0x142327, alpha: desktopMode ? 0.95 : 0.75), stroke: NSColor(hex: 0x48665f, alpha: 0.3))
        let status: String
        if let desktopTransition {
            status = desktopTransition.returning ? "圖示正在回到桌面原位…" : "你的桌面圖示，準備開球…"
        } else {
            status = paused ? "已暫停" : game.isComplete ? "清台完成" : game.needsCuePlacement ? "點擊空位放置白球" : game.isMoving ? "球還在滾動…" : chargeStart != nil ? "放開左鍵，擊球！" : "移動滑鼠瞄準 · 按住左鍵蓄力 · 放開擊球"
        }
        text(status, at: NSPoint(x: 34, y: 48), size: 13, color: NSColor(hex: 0xe2eadc), weight: .medium)
        text("原作 LXG / liuxiaogang-com · MIT    |    Mac 原型 · Esc 離開", at: NSPoint(x: 34, y: 28), size: 10,
             color: NSColor(hex: 0x91a8a1))
        let bar = NSRect(x: bounds.width - 296, y: 48, width: 260, height: 8)
        rounded(bar, radius: 4, fill: NSColor(hex: 0x2b403c))
        if charge > 0 {
            rounded(NSRect(x: bar.minX, y: bar.minY, width: bar.width * charge, height: bar.height), radius: 4,
                    fill: NSColor(hex: charge > 0.85 ? 0xf1cf7a : 0xace7a5))
        }
        text("力度", at: NSPoint(x: bar.minX, y: 70), size: 11, color: NSColor(hex: 0x9ab2a8))
        text("\(Int(charge * 100))%", at: NSPoint(x: bar.maxX - 38, y: 70), size: 14,
             color: NSColor(hex: 0xe2eadc), weight: .medium, mono: true)
        text("1.5 秒蓄滿，再往返", at: NSPoint(x: bar.minX, y: 28), size: 10, color: NSColor(hex: 0x91a8a1))
    }
    private func drawCard(title: String, subtitle: String) {
        let rect = NSRect(x: bounds.midX - 230, y: playingRect.midY - 52, width: 460, height: 104)
        rounded(rect, radius: 18, fill: NSColor(hex: 0x101f23, alpha: 0.96), stroke: NSColor(hex: 0x94b68e, alpha: 0.55))
        text(title, at: NSPoint(x: rect.midX, y: rect.minY + 53), size: 25, color: NSColor(hex: 0xe8f1d9), weight: .semibold, centered: true)
        text(subtitle, at: NSPoint(x: rect.midX, y: rect.minY + 25), size: 13, centered: true)
    }
}
