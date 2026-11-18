// Exercise real GameView entry/return state using invisible windows and fixtures.
// No Automation, screen capture, desktop file access, or Finder mutation.
import AppKit

final class FixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    guard let screen = NSScreen.screens.first else { fatalError("A display is required for session checks") }
    let originalFrame = NSRect(x: 80, y: 80, width: 1180, height: 790)
    let window = FixtureWindow(contentRect: originalFrame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = GameView(frame: NSRect(origin: .zero, size: originalFrame.size))
    window.contentView = view
    view.autoresizingMask = [.width, .height]
    let previousWindowFrame = window.frame
    let previousStyle = window.styleMask
    let previousCount = view.game.iconCount
    let image = NSImage(size: NSSize(width: 64, height: 64))
    let items = (0..<3).map { index in
        DesktopItem(url: URL(fileURLWithPath: "/fixture/item\(index)"),
                    finderPosition: NSPoint(x: 100 + index * 100, y: 200), image: image)
    }
    let snapshot = DesktopSnapshot(items: items, iconSize: 64)
    let backdrop = DesktopBackdrop(image: image, options: [:])
    var failures = 0
    var passed = 0
    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1; print("PASS \(message)") }
        else { failures += 1; print("FAIL \(message)") }
    }
    func pump(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
    do {
        try view.startDesktop(snapshot: snapshot, backdrop: backdrop, screen: screen, presentWindow: false)
        check(view.desktopMode && view.isDesktopTransitioning, "desktop entry starts with real item count")
        check(view.game.iconCount == 3, "sparse desktop is not padded with duplicate icons")
        check(window.styleMask == [.borderless] && window.isOpaque, "wallpaper backing covers originals in own window")
        view.restart()
        check(view.isDesktopTransitioning && view.game.shots == 0, "restart cannot interrupt entry")
        pump(1.0)
        check(view.desktopMode && !view.isDesktopTransitioning && !view.paused, "entry animation finishes playable")
        _ = view.game.shoot(toward: .init(900, 250), power: 0.5)
        pump(0.1)
        check(view.game.shots == 1, "desktop session accepts actual physics shots")
        var restored = false
        view.restoreDesktop { restored = true }
        check(view.isDesktopTransitioning, "exit starts return animation")
        pump(0.75)
        check(restored && !view.desktopMode && !view.isDesktopTransitioning, "exit completion fires after icons return")
        check(window.frame == previousWindowFrame && window.styleMask == previousStyle, "original application window restores exactly")
        check(view.game.iconCount == previousCount && view.game.shots == 0, "previous icon source restores without leaking desktop source")
        try view.startDesktop(snapshot: snapshot, backdrop: backdrop, screen: screen, presentWindow: false)
        pump(0.1)
        var interruptedReturn = false
        view.restoreDesktop { interruptedReturn = true }
        pump(0.75)
        check(interruptedReturn && !view.desktopMode, "exit during entry also restores safely")
        let outsideItems = [DesktopItem(url: URL(fileURLWithPath: "/fixture/outside"), finderPosition: .init(x: -100000, y: -100000), image: image)]
        do {
            try view.startDesktop(snapshot: .init(items: outsideItems, iconSize: 64), backdrop: backdrop, screen: screen, presentWindow: false)
            check(false, "off-display desktop rejects before changing window")
        } catch {
            check(!view.desktopMode && window.frame == previousWindowFrame, "off-display desktop rejects before changing window")
        }
    } catch { failures += 1; print("FAIL desktop session setup") }
    window.orderOut(nil)
    print("\(passed) session checks passed; \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
