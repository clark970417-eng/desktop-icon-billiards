import AppKit

final class GameWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: GameWindow!
    var gameView: GameView!
    private var instance: SingleInstanceLock?
    private var exitHotKey: GlobalExitHotKey?
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private let information = InformationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        instance = SingleInstanceLock()
        guard instance?.acquired == true else {
            let identity = Bundle.main.bundleIdentifier ?? "io.github.clark970417-eng.desktop-icon-billiards.mac"
            NSRunningApplication.runningApplications(withBundleIdentifier: identity)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                .activate(options: [.activateAllWindows])
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let workArea = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1180,height:790)
        let frame = NSRect(x:workArea.midX-590,y:workArea.midY-395,width:1180,height:790)
        window = GameWindow(contentRect: frame, styleMask: [.titled,.closable,.miniaturizable,.resizable], backing:.buffered,defer:false)
        window.title = gameTitle(.saved)
        window.minSize = NSSize(width:min(420,workArea.width),height:min(620,workArea.height))
        window.isReleasedWhenClosed = false; window.delegate = self
        gameView = GameView(frame:NSRect(origin:.zero,size:frame.size))
        gameView.autoresizingMask = [.width,.height]
        window.contentView = gameView; window.acceptsMouseMovedEvents = true
        window.setFrameAutosaveName("MacBilliardsGameWindow")
        let targetArea = WindowGeometry.workArea(for:window.frame,candidates:NSScreen.screens.map(\.visibleFrame)) ?? workArea
        window.setFrame(WindowGeometry.clamp(window.frame,to:targetArea),display:true)
        gameView.onLanguageChange = { [weak self] language in
            self?.createMenu(language:language); self?.information.updateLanguage(language)
        }
        createMenu(language: gameView.language)
        exitHotKey = GlobalExitHotKey { NSApp.terminate(nil) }
        gameView.setGlobalExitAvailable(exitHotKey?.available == true)
        observeSystemEvents()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(gameView)
        NSApp.activate(ignoringOtherApps:true)
        if let index = CommandLine.arguments.firstIndex(of:"--render-preview"),CommandLine.arguments.count > index+1 {
            let path = CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in self?.renderPreview(path) }
        }
    }
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            let token = workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gameView?.suspendForSystemChange() }
            }
            systemObservers.append((workspace,token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameView?.screenConfigurationChanged() }
        }
        systemObservers.append((center,token))
    }
    private func createMenu(language: AppLanguage) {
        window?.title = gameTitle(language)
        let menu = NSMenu(), appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:language.text("关于桌面图标台球", "About Desktop Icon Billiards"),action:#selector(showAbout),keyEquivalent:"")
        appMenu.items.last?.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:language.text("退出 Desktop Icon Billiards", "Quit Desktop Icon Billiards"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let gameItem = NSMenuItem(); menu.addItem(gameItem)
        let gameMenu = NSMenu(title:language.text("游戏", "Game")); gameItem.submenu = gameMenu
        gameItem.title = gameMenu.title
        for (zh,en,selector,key) in [
            ("重新开始","Restart",#selector(GameView.restart),"r"),
            ("选择图标文件夹…","Choose icon folder…",#selector(GameView.selectFolder),"o"),
            ("桌面开局／退出还原","Play desktop / restore",#selector(GameView.toggleDesktop),"d"),
            ("切换辅助线","Toggle aiming guide",#selector(GameView.toggleGuides),"g"),
            ("切换台面","Toggle table",#selector(GameView.toggleTable),"t"),
            ("暂停／继续","Pause / resume",#selector(GameView.togglePause),"p"),
            ("白球外观","Cue appearance",#selector(GameView.showCueAppearance),""),
            ("开启／关闭全球排名","Enable / disable global ranking",#selector(GameView.toggleRanking),""),
            ("排行榜","Leaderboard",#selector(GameView.showRanking),""),
            ("检查更新","Check updates",#selector(GameView.checkUpdates),""),
            ("打赏","Donate",#selector(GameView.showDonation),""),
            ("成绩卡","Result card",#selector(GameView.showResults),"")
        ] {
            gameMenu.addItem(withTitle:language.text(zh,en),action:selector,keyEquivalent:key).target = gameView
        }
        let languageItem = NSMenuItem(title:language.text("语言", "Language"),action:nil,keyEquivalent:"")
        let languages = NSMenu(title:languageItem.title); languageItem.submenu = languages
        for (title,selector,selected) in [("简体中文",#selector(useChinese),language == .zhHans),("English",#selector(useEnglish),language == .en)] {
            let item = languages.addItem(withTitle:title,action:selector,keyEquivalent:"")
            item.target = self; item.state = selected ? .on : .off
        }
        gameMenu.addItem(.separator()); gameMenu.addItem(languageItem)
        NSApp.mainMenu = menu
    }
    private func gameTitle(_ language: AppLanguage) -> String { language.text("桌面图标台球", "Desktop Icon Billiards") }
    @objc private func useChinese() { gameView.setLanguage(.zhHans) }
    @objc private func useEnglish() { gameView.setLanguage(.en) }
    @objc private func showAbout() { information.showAbout(language:gameView?.language ?? .saved) }
    private func renderPreview(_ path: String) {
        gameView.layoutSubtreeIfNeeded()
        guard let bitmap = gameView.bitmapImageRepForCachingDisplay(in:gameView.bounds) else { exit(1) }
        gameView.cacheDisplay(in:gameView.bounds,to:bitmap)
        guard let png = bitmap.representation(using:.png,properties:[:]) else { exit(1) }
        do { try png.write(to:URL(fileURLWithPath:path)); NSApp.terminate(nil) }
        catch { fputs("Preview write failed\n",stderr); exit(1) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard gameView?.desktopMode == true else { return .terminateNow }
        gameView.restoreDesktop { sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
    deinit { for (center,token) in systemObservers { center.removeObserver(token) } }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared, delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
