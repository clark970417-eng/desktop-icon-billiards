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
    private var chargeOrigin: NSPoint?
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
    private let artworkLoader = ArtworkLoader()
    private var scopedSourceFolder: URL?
    private(set) var language = AppLanguage.saved
    var onLanguageChange: ((AppLanguage) -> Void)?
    private var languagePopup: NSPopUpButton!
    private var activeFolderPanel: NSOpenPanel?
    private var activeAlert: NSAlert?
    private var activeAlertError: Error?
    private var cueButton: NSButton!
    private var resultsButton: NSButton!
    private var rankingButton: NSButton!
    private var leaderboardButton: NSButton!
    private var updateButton: NSButton!
    private var donateButton: NSButton!
    private var creditButton: NSButton!
    private let informationController = InformationController()
    private lazy var updateController = MacUpdateController(language:language)
    private var toolbarPosition: NSPoint?
    private var toolbarDragOffset: NSPoint?
    private var windowBackdrop: DesktopBackdrop?
    private var tableButton: NSButton!
    private var exitButton: NSButton!
    private var eyeButton: NSButton!
    private var tableVisible = true
    private var headerCollapsed = false
    private var pointerNearControlsAt = ProcessInfo.processInfo.systemUptime
    private var shiftHeld = false
    private var globalExitAvailable = true
    private var lastCompactLayout: Bool?
    private var cueImage = CueAppearanceController.loadSaved()
    private lazy var cueArtwork = BallArtwork.cue(texture:cueImage)
    private lazy var cueController = CueAppearanceController(language: language) { [weak self] image in
        self?.cueImage = image; self?.cueArtwork = BallArtwork.cue(texture:image); self?.needsDisplay = true
    }
    private let resultsController = ResultsController()
    private let rankingOverride: RankingController?
    private lazy var rankingController = rankingOverride ?? RankingController(language: language)
    private var lastResult: RoundResult?
    private var resultReadyAt: TimeInterval?
    private var completedRoundHandled = false
    private var previousPocketed: Set<Int> = []
    private var sinkAnimations: [SinkAnimation] = []
    private var lastIdleDraw: TimeInterval = 0
    private var desktopOriginalCount = 0
    private var desktopUniqueCount = 0
    private struct SinkAnimation { let ball: Ball; let started: TimeInterval; let pocket: Vector }
    private let trashIcon = NSWorkspace.shared.icon(forFile: NSHomeDirectory() + "/.Trash")

    private var functionGroups: [[NSButton]] {
        [[guideButton, tableButton, cueButton], [rankingButton, leaderboardButton],
         [updateButton, donateButton], [creditButton]]
    }
    private var controls: [NSView] { functionGroups.flatMap { $0 } + [restartButton, exitButton] }
    private var extraControls: [NSView] { [folderButton, desktopButton, pauseButton, resultsButton, languagePopup] }
    private var compactLayout: Bool { bounds.width < 600 }
    private var toolbarLayout: WinToolbarLayout {
        WinToolbarLayout(availableWidth: max(1,bounds.width-32),
            groups: functionGroups.map { $0.map { $0.intrinsicContentSize.width } },
            actions: [restartButton,exitButton].map { $0!.intrinsicContentSize.width },
            statsWidth: statsWidth)
    }
    private var toolbarStats: [(String,String)] {
        [(l("本局用时", "Time"),formattedTime(game.elapsed)),
         (l("图标入袋", "Pocketed"),"\(game.pocketedCount)/\(game.iconCount)"),
         (l("剩余", "Left"),"\(game.iconCount-game.pocketedCount)")]
    }
    private var statsWidth: CGFloat {
        toolbarStats.enumerated().reduce(0) { total,item in
            let (index,(title,value)) = item
            let sample = index == 0 ? formattedTime(max(3600,game.elapsed)) : value
            let labelWidth = (title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width
            let valueWidth = (sample as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:14,weight:.semibold)]).width
            return total + (bounds.width < 500 ? max(labelWidth,valueWidth)+16 : labelWidth+valueWidth+22)
        }
    }
    private var headerRect: NSRect {
        let size = toolbarLayout.size
        let origin = toolbarPosition ?? NSPoint(x:(bounds.width-size.width)/2,y:bounds.height-size.height-16)
        return WindowGeometry.clamp(NSRect(origin:origin,size:size),to:bounds.insetBy(dx:8,dy:8))
    }
    private var headerHeight: CGFloat { toolbarLayout.size.height+24 }
    private var footerHeight: CGFloat { 48 }
    private func l(_ zh: String, _ en: String) -> String { language.text(zh, en) }
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
        // Fit all six visible hole extents as well as the 2:1 playing surface.
        let outer = NSRect(x:24,y:footerHeight+12,width:max(1,bounds.width-48),
            height:max(1,bounds.height-headerHeight-footerHeight-36))
        let radius = game.pocketRadius
        let fit = min(outer.width/(game.width+2*radius),outer.height/(game.height+2*radius))
        let width = game.width*fit, height = game.height*fit
        return NSRect(x:outer.midX-width/2,y:outer.midY-height/2,width:width,height:height)
    }

    private var scale: CGFloat { playingRect.width / game.width }
    private var isActiveGame: Bool { !paused && desktopTransition == nil && !game.isMoving && !game.isComplete }

    override convenience init(frame: NSRect) { self.init(frame: frame, ranking: nil) }
    init(frame: NSRect, ranking: RankingController?) {
        rankingOverride = ranking
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("桌面图标台球游戏。移动鼠标瞄准，按住左键蓄力，放开击球。")
        folderButton = button("选择文件夹…", action: #selector(selectFolder))
        desktopButton = button("桌面开局", action: #selector(toggleDesktop))
        restartButton = button("重新开始  R", action: #selector(restart))
        guideButton = button("辅助线：开  G", action: #selector(toggleGuides))
        pauseButton = button("暂停  Space", action: #selector(togglePause))
        cueButton = button("", action: #selector(showCueAppearance))
        resultsButton = button("", action: #selector(showResults))
        rankingButton = button("", action: #selector(toggleRanking))
        leaderboardButton = button("", action: #selector(showRanking))
        updateButton = button("", action: #selector(checkUpdates))
        donateButton = button("", action: #selector(showDonation))
        creditButton = button("GitHub@liuxiaogang-com", action: #selector(openCredit))
        tableButton = button("", action: #selector(toggleTable))
        exitButton = button("", action: #selector(exitGame))
        eyeButton = button("", action: #selector(showControls))
        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.addItems(withTitles: ["简体中文", "English"])
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)
        addSubview(languagePopup)
        if let screen = NSScreen.main { windowBackdrop = try? DesktopBackdrop.read(screen:screen) }
        if UserDefaults.standard.object(forKey:"toolbarOriginX") != nil {
            toolbarPosition = NSPoint(x:UserDefaults.standard.double(forKey:"toolbarOriginX"),
                                      y:UserDefaults.standard.double(forKey:"toolbarOriginY"))
        }
        applyLocalizedLabels()
        resultsController.onAgain = { [weak self] in self?.restart() }
        resultsController.onShowRanking = { [weak self] in self?.showRanking() }
        rankingController.beginRound(iconCount: game.iconCount)
        rankingController.onOutcome = { [weak self] outcome in
            guard let self, var result = self.lastResult else { return }
            result.globalRank = outcome.rank; result.percentile = outcome.percentile; result.bestRank = outcome.bestRank
            result.rankingPhase = "ok"; result.newBest = outcome.isPersonalBest
            self.lastResult = result; self.resultsController.updateResult(result)
        }
        updateControlVisibility()
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
        scopedSourceFolder?.stopAccessingSecurityScopedResource()
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = WinPill(title: title, target: self, action: action)
        button.isBordered = false
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = NSColor(hex: 0xdce8e7)
        addSubview(button)
        return button
    }
    override func layout() {
        super.layout()
        if lastCompactLayout != compactLayout { lastCompactLayout = compactLayout; applyLocalizedLabels() }
        let panel = headerRect, geometry = toolbarLayout
        for (view,frame) in zip(functionGroups.flatMap({ $0 }),geometry.frames) {
            view.frame = frame.offsetBy(dx:panel.minX,dy:panel.minY)
        }
        for (view,frame) in zip([restartButton,exitButton],geometry.actionFrames) {
            view?.frame = frame.offsetBy(dx:panel.minX,dy:panel.minY)
        }
        eyeButton?.frame = NSRect(x:panel.minX,y:panel.maxY-30,width:30,height:30)
        extraControls.forEach { $0.isHidden = true }
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: "interfaceLanguage")
        applyLocalizedLabels()
        resultsController.updateLanguage(language)
        cueController.updateLanguage(language)
        rankingController.updateLanguage(language)
        informationController.updateLanguage(language)
        updateController.updateLanguage(language)
        activeFolderPanel?.title = l("选择图标文件夹", "Choose an icon folder")
        activeFolderPanel?.prompt = l("使用图标", "Use icons")
        activeFolderPanel?.message = l("只读取图标与图片缩略图，不会移动文件。", "Only icons and image previews are read; files stay in place.")
        if let activeAlert, let error = activeAlertError {
            activeAlert.messageText = l("无法开始桌面球局", "Could not start desktop play")
            activeAlert.informativeText = localizedError(error)
            activeAlert.buttons.first?.title = l("好", "OK")
        }
        onLanguageChange?(language)
        // Final state-dependent labels are measured before layout and clamping.
        needsLayout = true; layoutSubtreeIfNeeded()
        if !desktopMode, let window,
           let area = WindowGeometry.workArea(for: window.frame, candidates: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(WindowGeometry.clamp(window.frame, to: area), display: true)
        }
        lastAccessibleState = ""; needsDisplay = true
    }
    @objc private func languageChanged() { setLanguage(languagePopup.indexOfSelectedItem == 1 ? .en : .zhHans) }
    private func applyLocalizedLabels() {
        folderButton.title = l("选择文件夹…", "Choose folder…")
        desktopButton.title = desktopMode ? l("退出还原", "Restore & exit") : l("桌面开局", "Play desktop")
        restartButton.title = l("重新开始", "Restart")
        guideButton.title = guides ? l("辅助线 开", "Guide on") : l("辅助线 关", "Guide off")
        pauseButton.title = paused ? l("继续", "Resume") : l("暂停", "Pause")
        cueButton.title = l("白球外观", "Cue appearance")
        resultsButton.title = l("成绩卡", "Result card")
        rankingButton.title = l("排名", "Ranking")
        leaderboardButton.title = l("排行榜", "Leaderboard")
        updateButton.title = l("检查更新", "Check updates")
        donateButton.title = l("打赏", "Donate")
        tableButton.title = tableVisible ? l("台面 开", "Table on") : l("台面 关", "Table off")
        exitButton.title = l("退出", "Exit")
        eyeButton.title = "◉"
        controls.compactMap { $0 as? NSControl }.forEach { $0.font = .systemFont(ofSize:12) }
        creditButton.font = .systemFont(ofSize:11)
        (guideButton as? WinPill)?.kind = guides ? .on : .off
        (rankingButton as? WinPill)?.kind = rankingController.isEnabled ? .on : .off
        (leaderboardButton as? WinPill)?.kind = .soft
        (donateButton as? WinPill)?.kind = .gold
        (restartButton as? WinPill)?.kind = .primary
        (exitButton as? WinPill)?.kind = .soft
        languagePopup.selectItem(at: language == .en ? 1 : 0)
        guideButton.toolTip = l("白线：首次碰撞；蓝线：白球后续；绿线：被撞图标。路线不代表滚动距离。",
            "White: first contact. Blue: outgoing cue ball. Green: outgoing icon. Lines show direction, not travel distance.")
        rankingButton.toolTip = l("全球排名默认关闭；点击后开启联网与匿名成绩提交。", "Ranking is off by default. Click to enable network access and anonymous score submission.")
        exitButton.toolTip = globalExitAvailable ? l("退出并还原桌面 · ⌘⌥X", "Restore desktop and quit · ⌘⌥X") : l("退出并还原桌面 · Esc", "Restore desktop and quit · Esc")
        eyeButton.toolTip = l("显示工具栏", "Show controls")
        needsLayout = true
    }
    @objc func toggleRanking() {
        rankingController.setEnabled(!rankingController.isEnabled); applyLocalizedLabels(); needsDisplay = true
    }
    @objc func checkUpdates() { chargeStart = nil; updateController.show() }
    @objc func showDonation() { chargeStart = nil; informationController.show(language:language) }
    @objc private func openCredit() { NSWorkspace.shared.open(URL(string:"https://github.com/liuxiaogang-com/desktop-icon-billiards")!) }
    @objc func showCueAppearance() { chargeStart = nil; cueController.show() }
    @objc func showRanking() { chargeStart = nil; rankingController.show() }
    @objc func showResults() {
        if let lastResult { resultsController.show(result: lastResult, language: language) }
        else { showToast(l("清台后就能保存或复制成绩卡", "Clear the table to save or copy a result card.")) }
    }
    @objc private func exitGame() { NSApp.terminate(nil) }
    @objc func toggleTable() {
        tableVisible.toggle(); headerCollapsed = false
        pointerNearControlsAt = ProcessInfo.processInfo.systemUptime
        applyLocalizedLabels(); updateControlVisibility()
        if !tableVisible { showToast(l("工具栏移开 1 秒收起；移到左上角可恢复，按住 Shift 显示球杆。", "Controls hide after 1 second. Hover top left to restore; hold Shift to show the cue.")) }
        needsDisplay = true
    }
    @objc private func showControls() {
        headerCollapsed = false; pointerNearControlsAt = ProcessInfo.processInfo.systemUptime
        updateControlVisibility(); needsDisplay = true
    }
    private func updateControlVisibility() {
        controls.forEach { $0.isHidden = headerCollapsed }
        extraControls.forEach { $0.isHidden = true }
        eyeButton.isHidden = !headerCollapsed
    }
    override func flagsChanged(with event: NSEvent) {
        shiftHeld = event.modifierFlags.contains(.shift); needsDisplay = true
    }
    func setGlobalExitAvailable(_ available: Bool) {
        globalExitAvailable = available; applyLocalizedLabels()
        if !available { showToast(l("全局退出快捷键已被占用；可以按 Esc 或点击退出。", "Global exit shortcut is unavailable. Use Esc or the Exit button.")) }
    }
    private func finishActiveInterval() {
        let now = ProcessInfo.processInfo.systemUptime
        if !paused && desktopTransition == nil { game.step(max(0, now-lastTick)) }
        lastTick = now
    }
    func suspendForSystemChange() {
        finishActiveInterval()
        toolbarDragOffset = nil
        chargeStart = nil; paused = true; lastTick = ProcessInfo.processInfo.systemUptime
        applyLocalizedLabels(); needsDisplay = true
    }
    func screenConfigurationChanged() {
        suspendForSystemChange()
        if desktopMode {
            restoreDesktop()
            if let transition = desktopTransition {
                desktopTransition = DesktopTransition(started: transition.started, duration: 0,
                    from: transition.from, to: transition.to, fromAlpha: transition.fromAlpha, returning: true)
                advanceDesktopTransition(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        if let window, let area = WindowGeometry.workArea(for: window.frame, candidates: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(WindowGeometry.clamp(window.frame, to: area), display: true)
        }
        showToast(l("屏幕配置已变更，已安全还原桌面。", "Display configuration changed. The desktop has been restored."))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refreshArtwork() } else { artworkLoader.cancel() }
    }

    private func refreshArtwork() {
        artworkLoader.load(urls: iconSet.sourceURLs) { [weak self] index, image in
            guard let self, self.iconSet.images.indices.contains(index) else { return }
            self.iconSet.images[index] = image
            if self.desktopMode, self.desktopItems.indices.contains(index) {
                let item = self.desktopItems[index]
                self.desktopItems[index] = DesktopItem(url: item.url, finderPosition: item.finderPosition, image: image)
            }
            self.needsDisplay = true
        }
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
        let point = convert(event.locationInWindow, from: nil)
        if headerRect.contains(point) || eyeButton.frame.contains(point) { showControls() }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if let offset = toolbarDragOffset {
            let point = convert(event.locationInWindow,from:nil)
            toolbarPosition = NSPoint(x:point.x-offset.x,y:point.y-offset.y)
            toolbarPosition = headerRect.origin
            needsLayout = true; layoutSubtreeIfNeeded(); needsDisplay = true
        } else { mouseMoved(with:event) }
    }
    override func mouseDown(with event: NSEvent) {
        toolbarDragOffset = nil
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if !headerCollapsed && headerRect.contains(point) {
            toolbarDragOffset = NSPoint(x:point.x-headerRect.minX,y:point.y-headerRect.minY); chargeStart = nil; return
        }
        guard playingRect.contains(point), isActiveGame else { return }
        aim = modelPoint(point)
        if game.needsCuePlacement {
            if !game.placeCue(at: aim) { showToast(l("请选择远离其他球与袋口的位置", "Choose a clear position away from balls and pockets.")) }
            return
        }
        chargeStart = ProcessInfo.processInfo.systemUptime
        chargeOrigin = point
    }
    override func mouseUp(with event: NSEvent) {
        if toolbarDragOffset != nil {
            toolbarDragOffset = nil
            if let toolbarPosition {
                UserDefaults.standard.set(toolbarPosition.x,forKey:"toolbarOriginX")
                UserDefaults.standard.set(toolbarPosition.y,forKey:"toolbarOriginY")
            }
            return
        }
        guard let started = chargeStart else { return }
        chargeStart = nil
        // Focus changes already cancel charge via notifications. Accept a valid
        // mouse-up delivered to this view, including macOS app-window automation.
        guard !paused, playingRect.contains(convert(event.locationInWindow, from: nil)) else {
            needsDisplay = true
            return
        }
        aim = modelPoint(convert(event.locationInWindow, from: nil))
        let firstShot = game.shots == 0
        if game.shoot(toward: aim, power: BilliardsGame.chargePower(seconds: ProcessInfo.processInfo.systemUptime - started)), firstShot {
            lastTick = ProcessInfo.processInfo.systemUptime
            rankingController.markShotStarted()
        }
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil); return }
        guard !event.isARepeat else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": restart()
        case "g": toggleGuides()
        case "t": toggleTable()
        case " ": togglePause()
        default: super.keyDown(with: event)
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        (rankingButton as? WinPill)?.kind = rankingController.isEnabled ? .on : .off
        if var result = lastResult, result.rankingPhase == "pending", rankingController.statusCode == "error" {
            result.rankingPhase = "error"
            result.rankingMessage = l("排名暂时无法查询，本局成绩已显示。", "Ranking is unavailable. Your result is shown.")
            lastResult = result; resultsController.updateResult(result)
        }
        let delta = max(0, now - lastTick)
        lastTick = now
        if !paused && desktopTransition == nil { game.step(delta) }
        advanceDesktopTransition(now: now)
        let pocketed = Set(game.balls.filter(\.pocketed).map(\.id))
        for ball in game.balls where ball.pocketed && !previousPocketed.contains(ball.id) {
            let pocket = game.pockets.min { ($0 - ball.position).length < ($1 - ball.position).length } ?? ball.position
            sinkAnimations.append(SinkAnimation(ball: ball, started: now, pocket: pocket))
        }
        previousPocketed = pocketed
        sinkAnimations.removeAll { now - $0.started > 0.62 }
        if game.pocketedCount > lastPocketCount { pocketFlash = now }
        lastPocketCount = game.pocketedCount
        if game.isComplete && !completedRoundHandled {
            completedRoundHandled = true
            lastResult = RoundResult(elapsed: game.elapsed, iconCount: game.iconCount, shots: game.shots,
                rankingPhase:rankingController.isEnabled ? "pending" : "off")
            resultReadyAt = now + 0.65
            rankingController.submit(elapsed: game.elapsed, iconCount: game.iconCount, shots: game.shots)
        }
        if let at = resultReadyAt, now >= at {
            resultReadyAt = nil
            if NSApp.activationPolicy() != .prohibited { showResults() }
        }
        if !tableVisible && desktopTransition == nil {
            let pointer = window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
            if let pointer, (headerCollapsed ? eyeButton.frame : headerRect).contains(pointer) { pointerNearControlsAt = now }
            let collapsed = now - pointerNearControlsAt > 1
            if collapsed != headerCollapsed { headerCollapsed = collapsed; updateControlVisibility(); needsDisplay = true }
        }
        let animated = game.isMoving || chargeStart != nil || !sinkAnimations.isEmpty || now - pocketFlash < 0.7
            || toast != nil || desktopTransition != nil
        if animated || (!paused && game.shots > 0 && !game.isComplete && now - lastIdleDraw > 0.1) {
            needsDisplay = true; lastIdleDraw = now
        }
        if toast != nil && now > toastUntil { toast = nil; needsDisplay = true }
        let accessibleState = l("桌面图标台球。", "Desktop Icon Billiards. ")
            + "\(game.shots) " + l("杆，入袋", "shots, pocketed") + " \(game.pocketedCount)/\(game.iconCount). "
            + (paused ? l("已暂停。", "Paused. ") : game.isMoving ? l("球滚动中。", "Balls moving. ") : l("可以击球。", "Ready to shoot. "))
            + (desktopMode ? l("桌面模式。", "Desktop mode.") : l("窗口模式。", "Window mode."))
        if accessibleState != lastAccessibleState { setAccessibilityLabel(accessibleState); lastAccessibleState = accessibleState }
    }

    @objc func restart() {
        guard desktopTransition == nil else { return }
        game.reset(iconCount: iconSet.images.count)
        previousPocketed = []; sinkAnimations = []; resultReadyAt = nil; completedRoundHandled = false
        rankingController.beginRound(iconCount: game.iconCount)
        paused = false
        chargeStart = nil
        lastPocketCount = 0
        aim = Vector(620, 250)
        applyLocalizedLabels()
        lastTick = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
    }
    @objc func toggleGuides() {
        guides.toggle()
        applyLocalizedLabels()
        needsDisplay = true
    }
    @objc func togglePause() {
        guard desktopTransition == nil else { return }
        finishActiveInterval()
        paused.toggle()
        chargeStart = nil
        lastTick = ProcessInfo.processInfo.systemUptime
        applyLocalizedLabels()
        needsDisplay = true
    }
    private func pauseForInterruption() {
        finishActiveInterval()
        toolbarDragOffset = nil
        chargeStart = nil
        if game.shots > 0 || game.isMoving { paused = true; applyLocalizedLabels() }
        needsDisplay = true
    }
    @objc func selectFolder() {
        guard !desktopMode, let window, window.attachedSheet == nil else { return }
        finishActiveInterval()
        sessionWasPaused = paused
        paused = true
        chargeStart = nil
        let panel = NSOpenPanel()
        activeFolderPanel = panel
        panel.title = l("选择图标文件夹", "Choose an icon folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = l("使用图标", "Use icons")
        panel.message = l("选择桌面或其他文件夹。只读取图标与缩略图，不会移动文件。", "Choose a folder. Only icons and image previews are read; source files stay in place.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeFolderPanel = nil
            self.paused = self.sessionWasPaused
            if response == .OK, let url = panel.url {
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let nextSet = try IconSet.folder(url)
                    self.artworkLoader.cancel()
                    self.scopedSourceFolder?.stopAccessingSecurityScopedResource()
                    self.scopedSourceFolder = scoped ? url : nil
                    self.iconSet = nextSet
                    self.restart()
                    self.refreshArtwork()
                    self.showToast(self.l("已换成文件夹图标，开始新的一局", "Folder icons loaded. A new round is ready."))
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    self.showToast(self.l("无法读取图标：", "Could not read icons: ") + error.localizedDescription)
                }
            }
            self.applyLocalizedLabels()
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
            alert.messageText = l("无法开始桌面球局", "Could not start desktop play")
            alert.informativeText = localizedError(error)
            activeAlert = alert; activeAlertError = error
            alert.addButton(withTitle: l("好", "OK"))
            alert.beginSheetModal(for: window) { [weak self] _ in self?.activeAlert = nil; self?.activeAlertError = nil }
        }
        needsDisplay = true
    }

    private func localizedError(_ error: Error) -> String {
        guard language == .en else { return error.localizedDescription }
        if let error = error as? DesktopSnapshot.SnapshotError {
            switch error {
            case .automationDenied: return "Allow Desktop Icon Billiards to access Finder in System Settings → Privacy & Security → Automation. It only reads desktop icons and positions."
            case .noDesktopItems: return "No usable icons were found on the primary desktop. Your files and layout have not changed."
            case .finderReadFailed(let code): return "Finder could not return the desktop icons (code \(code)). Nothing was changed."
            case .scriptUnavailable, .invalidResponse: return "Finder returned unavailable desktop data. Nothing was changed."
            }
        }
        if error is DesktopBackdrop.BackdropError { return "The current wallpaper could not be read as a still image. Choose an accessible picture wallpaper and retry. Your desktop has not changed." }
        return error.localizedDescription
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
        artworkLoader.cancel()
        savedFrame = window.frame
        savedStyle = window.styleMask
        desktopOriginalCount = candidates.count
        let chosen = DesktopSelection.indices(urls: candidates.map { $0.0.url })
        desktopUniqueCount = Set(chosen).count
        desktopItems = chosen.map { candidates[$0].0 }
        desktopOrigins = chosen.map { candidates[$0].1 }
        desktopIconSize = snapshot.iconSize
        desktopBackdrop = backdrop
        wallpaperRect = NSRect(x: screen.frame.minX - frame.minX, y: screen.frame.minY - frame.minY,
                               width: screen.frame.width, height: screen.frame.height)
        iconSet = IconSet(images: desktopItems.map(\.image), label: "你的桌面图标 · \(desktopItems.count) 颗",
                          sourceURLs: desktopItems.map(\.url))
        game.reset(iconCount: desktopItems.count)
        previousPocketed = []; sinkAnimations = []; resultReadyAt = nil; completedRoundHandled = false
        rankingController.beginRound(iconCount: game.iconCount)
        lastPocketCount = 0
        paused = false
        desktopMode = true
        window.styleMask = [.borderless]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .normal
        window.setFrame(frame, display: true)
        layoutSubtreeIfNeeded()
        applyLocalizedLabels()
        folderButton.isEnabled = false
        applyLocalizedLabels()
        aim = Vector(620, 250)
        let targets = game.balls.filter { !$0.isCue }.map { screenPoint($0.position) }
        desktopTransition = DesktopTransition(started: ProcessInfo.processInfo.systemUptime, duration: 0.85,
            from: desktopOrigins, to: targets, fromAlpha: Array(repeating: 1, count: targets.count), returning: false)
        if presentWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(self)
        lastTick = ProcessInfo.processInfo.systemUptime
        refreshArtwork()
        needsDisplay = true
    }

    func restoreDesktop(completion: (() -> Void)? = nil) {
        guard desktopMode else { completion?(); return }
        if let completion { pendingDesktopExit = completion }
        if desktopTransition?.returning == true { return }
        artworkLoader.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let positions = desktopTransition.map { transitionPositions($0, now: now) }
            ?? game.balls.filter { !$0.isCue }.map { screenPoint($0.position) }
        let alphas: [CGFloat] = desktopTransition == nil
            ? game.balls.filter { !$0.isCue }.map { $0.pocketed ? 0 : 1 }
            : Array(repeating: 1, count: positions.count)
        chargeStart = nil
        paused = true
        headerCollapsed = false; updateControlVisibility()
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
            applyLocalizedLabels()
            folderButton.isEnabled = true
            restart()
            refreshArtwork()
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
            let desiredAlpha: CGFloat = index < desktopUniqueCount ? 1 : 0
            let alpha = transition.returning ? transition.fromAlpha[index] + (desiredAlpha - transition.fromAlpha[index]) * eased : 1
            let imageRect = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            drawArtwork(desktopItems[index].image, in: imageRect, alpha: alpha)
            let labelAlpha = (index < desktopUniqueCount) ? (transition.returning ? eased : 1 - eased) : 0
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
                      centered: Bool = false, mono: Bool = false, maxWidth: CGFloat? = nil) {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = string as NSString
        let width = centered ? ns.size(withAttributes: attributes).width : 0
        if let maxWidth {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = centered ? .center : .left
            var boundedAttributes = attributes; boundedAttributes[.paragraphStyle] = paragraph
            ns.draw(in: NSRect(x: centered ? point.x - maxWidth / 2 : point.x, y: point.y,
                              width: max(1,maxWidth), height: size * 1.6), withAttributes: boundedAttributes)
        } else { ns.draw(at: NSPoint(x: point.x - width / 2, y: point.y), withAttributes: attributes) }
    }
    private func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }
    private func drawArtwork(_ image: NSImage, in rect: NSRect, alpha: CGFloat = 1) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let factor = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = ProcessInfo.processInfo.systemUptime
        if desktopMode, let desktopBackdrop { desktopBackdrop.draw(in: wallpaperRect) }
        else {
            if let windowBackdrop { windowBackdrop.draw(in:bounds) }
            else { NSColor(hex:0x0e1a18).setFill(); bounds.fill() }
        }
        NSColor(hex:0x081a19,alpha:40/255).setFill(); bounds.fill()
        drawTable(now: now)
        if !headerCollapsed { drawToolbar() }
        if chargeStart != nil { drawFooter() }
        if desktopTransition == nil && !headerCollapsed {
            if paused { drawCard(title: l("已暂停", "Paused"), subtitle: l("按空格键继续", "Press Space to continue.")) }
            else if game.isComplete { drawCard(title: l("漂亮，清台了！", "Table cleared!"), subtitle: formattedTime(game.elapsed) + l(" · 按 R 再来一局", " · Press R for another round.")) }
            else if game.needsCuePlacement { drawCard(title: l("白球自由球", "Ball in hand"), subtitle: l("点击球桌上的空位放置白球", "Click a clear spot to place the cue ball.")) }
        }
        if let toast {
            let width = min(610, bounds.width - 48)
            rounded(NSRect(x: bounds.midX - width/2, y: 10, width: width, height: 42), radius: 10,
                    fill: NSColor(hex: 0x29433b))
            text(toast, at: NSPoint(x: bounds.midX, y: 21), size: 11, color: .white,
                 centered: true, maxWidth: width - 20)
        }
    }
    private func sourceDescription() -> String {
        if desktopMode {
            if desktopOriginalCount < game.iconCount {
                return l("桌面 \(desktopOriginalCount) 个图标，复制补到 \(game.iconCount) 颗", "\(desktopOriginalCount) desktop icons, copied to \(game.iconCount) balls")
            }
            return l("桌面图标 · 使用 \(game.iconCount) / \(desktopOriginalCount) 颗", "Desktop icons · \(game.iconCount) of \(desktopOriginalCount) selected")
        }
        if iconSet.sourceURLs.allSatisfy({ $0.pathExtension.lowercased() == "app" }) {
            return l("Applications App 图标 · \(game.iconCount) 颗", "Applications icons · \(game.iconCount) balls")
        }
        return l("文件夹图标与图片缩略图 · \(game.iconCount) 颗", "Folder icons and image previews · \(game.iconCount) balls")
    }
    private func formattedTime(_ value: Double) -> String {
        let cs = Int(min(86_400_00,max(0,value * 100)))
        let hours = cs / 360000
        return hours > 0 ? String(format:"%d:%02d:%02d.%02d",hours,cs/6000%60,cs/100%60,cs%100)
            : String(format:"%02d:%02d.%02d",cs/6000,cs/100%60,cs%100)
    }
    private func drawTable(now: TimeInterval) {
        let rect = playingRect
        if tableVisible {
            if desktopMode, let desktopBackdrop {
                desktopBackdrop.drawBlurred(in:bounds,desktopFrame:wallpaperRect,clipRect:rect,darkenOpacity:0)
            } else if let windowBackdrop {
                windowBackdrop.drawBlurred(in:bounds,desktopFrame:bounds,clipRect:rect,darkenOpacity:0)
            } else {
                NSColor(hex:0x0e523f,alpha:0.61).setFill(); rect.fill()
            }
            NSColor(hex:0x69ddb3,alpha:0.72).setStroke()
            let edge = NSBezierPath(rect:rect); edge.lineWidth = 2; edge.stroke()
        }
        for pocket in game.pockets {
            let p = screenPoint(pocket), radius = game.pocketRadius * scale
            if !tableVisible {
                drawArtwork(trashIcon, in: NSRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
                continue
            }
            let hole = NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            NSColor(hex: 0x69ddb3, alpha: 0.41).setFill(); NSBezierPath(ovalIn: hole.insetBy(dx: -2, dy: -2)).fill()
            NSColor(hex: 0x0b1615).setFill(); NSBezierPath(ovalIn: hole).fill()
            NSColor(hex: 0x040a0b).setFill(); NSBezierPath(ovalIn: hole.insetBy(dx: 4, dy: 4)).fill()
        }
        if tableVisible {
            text("GitHub@liuxiaogang-com",at:NSPoint(x:rect.midX,y:rect.minY-game.pocketRadius*scale-22),
                size:11,color:NSColor.white.withAlphaComponent(0.55),centered:true,maxWidth:max(1,rect.width-40))
        }
        if isActiveGame && !game.needsCuePlacement && (tableVisible || shiftHeld) { drawGuide() }
        if let desktopTransition {
            drawDesktopTransition(desktopTransition, now: now)
        } else {
            for ball in game.balls where !ball.pocketed { drawBall(ball) }
        }
        drawSinkAnimations(now: now)
        if now - pocketFlash < 0.65 && game.pocketedCount > 0 && tableVisible {
            text(l("+1 入袋", "+1 pocketed"), at: NSPoint(x: rect.midX, y: rect.maxY + 28), size: 13,
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
            drawArtwork(cueArtwork, in:circle)
        } else {
            if !iconSet.images.isEmpty {
                let image = iconSet.images[(max(1, ball.id) - 1) % iconSet.images.count]
                drawArtwork(image, in: circle.insetBy(dx: r * 0.24, dy: r * 0.24))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawGuide() {
        guard let cue = game.balls.first(where: { $0.isCue && !$0.pocketed }) else { return }
        let dx = aim.x - cue.position.x, dy = aim.y - cue.position.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        NSGraphicsContext.saveGraphicsState()
        if !tableVisible { NSGraphicsContext.current?.cgContext.setAlpha(0.55) }
        defer { NSGraphicsContext.restoreGraphicsState() }
        func isBright(_ start: Vector,_ end: Vector) -> Bool {
            let backdrop = desktopMode ? desktopBackdrop : windowBackdrop
            let frame = desktopMode ? wallpaperRect : bounds
            let samples = (0...4).compactMap { index -> CGFloat? in
                let t = Double(index)/4
                return backdrop?.luminance(at:screenPoint(start+(end-start)*t),desktopFrame:frame)
            }
            return !samples.isEmpty && samples.reduce(0,+)/CGFloat(samples.count)>150
        }
        if guides {
            let prediction = game.aimGuide(toward: aim)
            func palette(_ role:Int,_ bright:Bool) -> NSColor {
                let colors: [UInt32] = bright ? [0x1a2a30,0x0a46a8,0x007644] : [0xf0fcf7,0x96cdff,0x6cf5b7]
                return NSColor(hex:colors[role])
            }
            func segment(_ start: Vector, _ end: Vector, role:Int) {
                let bright = isBright(start,end), color = palette(role,bright)
                let line = NSBezierPath(); line.setLineDash([12,8],count:2,phase:0)
                line.move(to:screenPoint(start)); line.line(to:screenPoint(end))
                (bright ? NSColor.white : NSColor(hex:0x040e0d)).withAlphaComponent(0.8).setStroke()
                line.lineWidth = 5.5; line.stroke()
                color.setStroke(); line.lineWidth = 2.6; line.stroke()
                let point = screenPoint(end), dot = NSRect(x:point.x-5,y:point.y-5,width:10,height:10)
                let ring = NSBezierPath(ovalIn:dot); ring.lineWidth = 2; ring.stroke()
            }
            if prediction.cuePath.count >= 2 { segment(prediction.cuePath[0],prediction.cuePath[1],role:0) }
            if prediction.cuePath.count >= 3 { segment(prediction.cuePath[1],prediction.cuePath[2],role:1) }
            if prediction.objectPath.count >= 2 { segment(prediction.objectPath[0],prediction.objectPath[1],role:2) }
            func contact(_ center:Vector,_ radius:Double,_ role:Int) {
                let point = screenPoint(center), r = radius*scale, color = palette(role,isBright(center,center))
                let ring=NSBezierPath(ovalIn:NSRect(x:point.x-r,y:point.y-r,width:r*2,height:r*2))
                if role == 2 { color.withAlphaComponent(0.1).setFill(); ring.fill() }
                color.withAlphaComponent(0.55).setStroke(); ring.lineWidth=1.8; ring.stroke()
            }
            if let center = prediction.collisionCenter { contact(center,cue.radius,1) }
            if let targetID=prediction.targetBallID,let target=game.balls.first(where:{$0.id==targetID}) {
                contact(target.position,target.radius,2)
            }
        }
        // Match the original long, two-tone wooden cue and blue chalk tip.
        let gap = cue.radius + 12 + charge*34
        let tip = screenPoint(Vector(cue.position.x-ux*gap,cue.position.y-uy*gap))
        var stickLength = min(440,game.height*0.48)*scale
        for (value,direction,low,high) in [(tip.x,-ux,CGFloat(5),bounds.width-5),(tip.y,-uy,CGFloat(5),bounds.height-5)] {
            if abs(direction) > 0.000001 { stickLength = min(stickLength,max(0,((direction > 0 ? high : low)-value)/direction)) }
        }
        let tail = NSPoint(x:tip.x-ux*stickLength,y:tip.y-uy*stickLength)
        let grip = NSPoint(x:tail.x+(tip.x-tail.x)*0.37,y:tail.y+(tip.y-tail.y)*0.37)
        func rod(_ from:NSPoint,_ to:NSPoint,_ color:UInt32,_ width:CGFloat) {
            let path=NSBezierPath(); path.move(to:from); path.line(to:to); path.lineWidth=width; path.lineCapStyle = .round
            NSColor(hex:color).setStroke(); path.stroke()
        }
        rod(tail,tip,0x3c2516,7*max(0.65,scale)); rod(tail,tip,0xefc17e,4*max(0.65,scale))
        rod(tail,grip,0x7f4f30,5*max(0.65,scale))
        NSColor(hex:0x7ecfe4).setFill(); NSBezierPath(ovalIn:NSRect(x:tip.x-2,y:tip.y-2,width:4,height:4)).fill()
    }
    private func drawSinkAnimations(now: TimeInterval) {
        for animation in sinkAnimations {
            let progress = min(1,max(0,(now-animation.started)/0.62))
            let from = screenPoint(animation.ball.position), to = screenPoint(animation.pocket)
            let point = NSPoint(x:from.x+(to.x-from.x)*progress, y:from.y+(to.y-from.y)*progress)
            let r = animation.ball.radius * scale
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by:point.x,yBy:point.y)
            transform.rotate(byDegrees:progress*220); transform.scale(by:max(0.02,1-progress)); transform.concat()
            let frame = NSRect(x:-r,y:-r,width:r*2,height:r*2)
            if animation.ball.isCue {
                drawArtwork(cueArtwork,in:frame,alpha:1-progress)
            } else if iconSet.images.indices.contains(animation.ball.id-1) {
                drawArtwork(iconSet.images[animation.ball.id-1],in:frame,alpha:1-progress)
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor(hex:0xaadab7,alpha:(1-progress)*0.5).setStroke()
            let ripple = game.pocketRadius * scale * (1+progress)
            NSBezierPath(ovalIn:NSRect(x:to.x-ripple,y:to.y-ripple,width:ripple*2,height:ripple*2)).stroke()
            let glow = pow(sin(Double.pi*progress),0.65)
            for index in 0..<6 {
                let angle = Double(index)*Double.pi/3+Double(animation.ball.id)*0.61
                let distance = progress*Double(12+index%3*7)*scale
                let size = max(0.7,(1-progress)*Double(2+index%2))*scale
                let x=to.x+cos(angle)*distance,y=to.y+sin(angle)*distance
                NSColor(hex:0xadffdd,alpha:0.82*glow).setFill()
                NSBezierPath(ovalIn:NSRect(x:x-size,y:y-size,width:size*2,height:size*2)).fill()
            }
        }
    }
    private func drawToolbar() {
        let panel = headerRect, geometry = toolbarLayout
        NSColor(hex:0x0e1a18).setFill(); panel.fill()
        text("⋮⋮",at:NSPoint(x:panel.minX+10,y:panel.midY-8),size:16,color:NSColor(hex:0x8aa69e))
        let y = panel.minY+geometry.statsY
        NSColor(hex:0x263d36).setFill()
        NSRect(x:panel.minX+34,y:y+(bounds.width < 500 ? 45 : 35),width:panel.width-46,height:1).fill()
        var x = panel.minX+34
        for (title,value) in toolbarStats {
            let labelWidth = (title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width
            let valueWidth = (value as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:14,weight:.semibold)]).width
            if bounds.width < 500 {
                text(title,at:NSPoint(x:x,y:y+24),size:11,color:NSColor(hex:0x8aa69e))
                text(value,at:NSPoint(x:x,y:y+4),size:14,color:NSColor(hex:0xe8f5f0),weight:.semibold,mono:true)
                x += max(labelWidth,valueWidth)+16
            } else {
                text(title,at:NSPoint(x:x,y:y+7),size:11,color:NSColor(hex:0x8aa69e)); x += labelWidth+6
                text(value,at:NSPoint(x:x,y:y+5),size:14,color:NSColor(hex:0xe8f5f0),weight:.semibold,mono:true); x += valueWidth+16
            }
        }
    }
    private func drawFooter() {
        let origin = chargeOrigin ?? NSPoint(x:bounds.midX,y:60)
        let meter = WindowGeometry.clamp(NSRect(x:origin.x+18,y:origin.y-58,width:150,height:45),to:bounds.insetBy(dx:8,dy:8))
        rounded(meter,radius:6,fill:NSColor(hex:0x0d1917,alpha:0.96),stroke:NSColor(hex:0x4a695e))
        text(l("力度", "Power"),at:NSPoint(x:meter.minX+8,y:meter.minY+24),size:12,color:NSColor(hex:0xdeeee7))
        let falling = chargeStart.map { (ProcessInfo.processInfo.systemUptime-$0).truncatingRemainder(dividingBy:3)>1.5 } ?? false
        text(falling ? "⌄" : "⌃",at:NSPoint(x:meter.midX-4,y:meter.minY+21),size:14,color:NSColor(hex:0x85f2c6))
        text("\(Int(charge*100))%",at:NSPoint(x:meter.maxX-43,y:meter.minY+24),size:12,color:NSColor(hex:0x85f2c6),mono:true)
        let bar = NSRect(x:meter.minX+8,y:meter.minY+9,width:134,height:6)
        rounded(bar,radius:3,fill:NSColor(hex:0x314c46))
        if charge > 0 { rounded(NSRect(x:bar.minX,y:bar.minY,width:bar.width*charge,height:bar.height),radius:3,fill:NSColor(hex:0x6fefb9)) }
    }
    private func drawCard(title: String, subtitle: String) {
        guard playingRect.height > 120 else { return }
        let width = min(460,bounds.width-64)
        let rect = NSRect(x: bounds.midX - width/2, y: playingRect.midY - 52, width: width, height: 104)
        rounded(rect, radius: 18, fill: NSColor(hex: 0x101f23, alpha: 0.96), stroke: NSColor(hex: 0x94b68e, alpha: 0.55))
        text(title, at: NSPoint(x: rect.midX, y: rect.minY + 53), size: 25, color: NSColor(hex: 0xe8f1d9), weight: .semibold, centered: true, maxWidth: rect.width - 24)
        text(subtitle, at: NSPoint(x: rect.midX, y: rect.minY + 25), size: 12, centered: true, maxWidth: rect.width - 24)
    }
}
