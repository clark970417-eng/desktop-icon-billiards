import AppKit

final class GameWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: GameWindow!
    var gameView: GameView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let frame = NSRect(x: 0, y: 0, width: 1180, height: 790)
        window = GameWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        window.title = "Desktop Icon Billiards — Mac 原型"
        window.minSize = NSSize(width: 920, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        gameView = GameView(frame: frame)
        gameView.autoresizingMask = [.width, .height]
        window.contentView = gameView
        window.acceptsMouseMovedEvents = true
        createMenu()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gameView)
        NSApp.activate(ignoringOtherApps: true)
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.renderPreview(path)
            }
        }
    }
    private func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "關於 Desktop Icon Billiards", action: #selector(showAbout), keyEquivalent: "")
        appMenu.items.last?.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 Desktop Icon Billiards", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let gameItem = NSMenuItem(); menu.addItem(gameItem)
        let gameMenu = NSMenu(title: "遊戲"); gameItem.submenu = gameMenu
        for (title, selector, key) in [
            ("重新開始", #selector(GameView.restart), "r"),
            ("選取圖示資料夾…", #selector(GameView.selectFolder), "o"),
            ("桌面開局／退出還原", #selector(GameView.toggleDesktop), "d"),
            ("顯示／隱藏輔助線", #selector(GameView.toggleGuides), "g")
        ] {
            let item = gameMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = gameView
        }
        NSApp.mainMenu = menu
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Desktop Icon Billiards · Mac 原型",
            .applicationVersion: "0.3.0",
            .credits: NSAttributedString(string: "原作 LXG / liuxiaogang-com\nMac fork: clark970417-eng\nMIT License\n圖示在本機讀取；無網路連線與成績上傳。")
        ])
    }
    private func renderPreview(_ path: String) {
        gameView.layoutSubtreeIfNeeded()
        guard let bitmap = gameView.bitmapImageRepForCachingDisplay(in: gameView.bounds) else { exit(1) }
        gameView.cacheDisplay(in: gameView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: path)); print("Preview rendered"); NSApp.terminate(nil) }
        catch { fputs("Preview write failed\n", stderr); exit(1) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard gameView?.desktopMode == true else { return .terminateNow }
        gameView.restoreDesktop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
