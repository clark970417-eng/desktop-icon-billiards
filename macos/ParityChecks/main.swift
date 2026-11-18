// Focused merge-review fixtures: no real desktop/Finder requests, hotkey
// registration, user preference writes, or visible application windows.
import AppKit

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}
func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let result = NSAppleEventDescriptor.list()
    for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
    return result
}
func point(_ x: Int32, _ y: Int32) -> NSAppleEventDescriptor {
    list([NSAppleEventDescriptor(int32: x), NSAppleEventDescriptor(int32: y)])
}
func row(_ path: String, _ x: Int32 = 100, _ y: Int32 = 200) -> NSAppleEventDescriptor {
    list([NSAppleEventDescriptor(string: path), point(x, y)])
}
func snapshot(_ rows: [NSAppleEventDescriptor], total: Int32? = nil) -> NSAppleEventDescriptor {
    var fields = [NSAppleEventDescriptor(int32: 64), list(rows)]
    if let total { fields.append(NSAppleEventDescriptor(int32: total)) }
    return list(fields)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var passed = 0, failed = 0
    func check(_ title: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(title)") }
        catch { failed += 1; print("FAIL \(title): \(error)") }
    }
    // Exercise the actual flat pills and grouped layout used by GameView. Keep
    // the same controls alive through state/language changes so sizing observes
    // the final title, rather than a startup-only fittingSize measurement.
    let groups = [3, 2, 2, 1].map { count in
        (0..<count).map { _ in WinPill(title: "", target: nil, action: nil) }
    }
    let actions = (0..<2).map { _ in WinPill(title: "", target: nil, action: nil) }
    let functions = groups.flatMap { $0 }
    for button in functions + actions { button.font = .systemFont(ofSize: 12) }
    functions.last?.font = .systemFont(ofSize: 11)
    func applyLabels(language: AppLanguage, guides: Bool, table: Bool, ranking: Bool) {
        let labels: [(String, String)] = [
            (guides ? "辅助线 开" : "辅助线 关", guides ? "Guide on" : "Guide off"),
            (table ? "台面 开" : "台面 关", table ? "Table on" : "Table off"),
            ("白球外观", "Cue appearance"), ("排名", "Ranking"), ("排行榜", "Leaderboard"),
            ("检查更新", "Check updates"), ("打赏", "Donate"),
            ("GitHub@liuxiaogang-com", "GitHub@liuxiaogang-com")
        ]
        for (button, label) in zip(functions, labels) { button.title = language.text(label.0, label.1) }
        functions[0].kind = guides ? .on : .off
        functions[3].kind = ranking ? .on : .off
        actions[0].title = language.text("重新开始", "Restart")
        actions[1].title = language.text("退出", "Exit")
    }
    func statsWidth(language: AppLanguage, viewWidth: CGFloat) -> CGFloat {
        let labels = [("本局用时", "Time"), ("图标入袋", "Pocketed"), ("剩余", "Left")]
        // Include the hour field reserved by GameView and the maximum rack.
        let values = ["1:00:00.00", "45/45", "45"]
        return zip(labels, values).reduce(CGFloat.zero) { total, item in
            let label = language.text(item.0.0, item.0.1) as NSString
            let labelWidth = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            let valueWidth = (item.1 as NSString).size(withAttributes:
                [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)]).width
            return total + (viewWidth < 500 ? max(labelWidth, valueWidth) + 16 : labelWidth + valueWidth + 22)
        }
    }
    for width: CGFloat in [320, 360, 420, 640, 1180] {
        check("actual Win toolbar preserves final labels, author, actions and stats at width \(Int(width))") {
            for language in [AppLanguage.zhHans, .en, .zhHans] {
                for guides in [false, true] { for table in [false, true] { for ranking in [false, true] {
                    applyLabels(language: language, guides: guides, table: table, ranking: ranking)
                    let finalWidths = functions.map { $0.intrinsicContentSize.width }
                    let finalActionWidths = actions.map { $0.intrinsicContentSize.width }
                    let finalStatsWidth = statsWidth(language: language, viewWidth: width)
                    let layout = WinToolbarLayout(availableWidth: width - 32,
                        groups: groups.map { $0.map { $0.intrinsicContentSize.width } },
                        actions: finalActionWidths, statsWidth: finalStatsWidth)
                    let container = NSRect(origin: .zero, size: layout.size)
                    try expect(layout.size.width <= width - 32, "panel outside view margins")
                    try expect(layout.frames.count == functions.count && layout.actionFrames.count == 2,
                               "function or action disappeared")
                    let frames = layout.frames + layout.actionFrames
                    let finalLabelWidths = finalWidths + finalActionWidths
                    for (index, frame) in frames.enumerated() {
                        try expect(container.contains(frame), "control outside toolbar bounds")
                        try expect(frame.width >= finalLabelWidths[index], "final state label clipped: \((functions + actions)[index].title)")
                        for other in frames.dropFirst(index + 1) {
                            try expect(!frame.intersects(other), "toolbar controls overlap")
                        }
                    }
                    try expect(functions.last?.title == "GitHub@liuxiaogang-com", "full author credit changed")
                    let stats = NSRect(x: 34, y: layout.statsY, width: finalStatsWidth,
                                       height: width < 500 ? 42 : 28)
                    try expect(container.contains(stats), "time or count statistics outside toolbar")
                    for frame in frames { try expect(!frame.intersects(stats), "statistics overlap controls") }
                } } }
            }
        }
    }
    check("language values select exact text without writing saved preferences") {
        try expect(AppLanguage.zhHans.text("辅助线：关", "Guide off") == "辅助线：关", "Chinese choice wrong")
        try expect(AppLanguage.en.text("辅助线：关", "Guide off") == "Guide off", "English choice wrong")
        try expect(AppLanguage(rawValue: "invalid") == nil, "unknown saved language accepted")
        try expect(AppLanguage.allCases.count == 2, "unexpected language count")
    }
    check("window edge clamping keeps the chosen negative-coordinate monitor") {
        let main = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let left = NSRect(x: -1280, y: 0, width: 1280, height: 800)
        let expanded = NSRect(x: -1240, y: 700, width: 800, height: 220)
        let selected = WindowGeometry.workArea(for: expanded, candidates: [main, left])
        try expect(selected == left, "toolbar moved to another monitor")
        let clamped = WindowGeometry.clamp(expanded, to: left)
        try expect(left.contains(clamped), "edge clamping failed")
        try expect(clamped.minX == expanded.minX && clamped.maxY == left.maxY, "unnecessary horizontal movement")
    }
    check("oversized windows fit narrow work areas in logical points") {
        let work = NSRect(x: -420, y: 24, width: 420, height: 616)
        let clamped = WindowGeometry.clamp(NSRect(x: -60, y: 580, width: 1180, height: 790), to: work)
        try expect(clamped == work, "oversized frame did not fit")
    }
    check("already-contained windows preserve their exact position and size") {
        let work = NSRect(x: 120, y: 50, width: 900, height: 700)
        let original = NSRect(x: 160, y: 110, width: 700, height: 500)
        try expect(WindowGeometry.clamp(original, to: work) == original, "unnecessary reposition")
    }
    check("process-held instance lock excludes duplicates and releases for next launch") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("billiards-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: SingleInstanceLock? = SingleInstanceLock(directory: root)
        try expect(first?.acquired == true, "first process could not lock")
        let second = SingleInstanceLock(directory: root)
        try expect(!second.acquired, "duplicate process acquired the lock")
        first = nil
        let next = SingleInstanceLock(directory: root)
        try expect(next.acquired, "lock did not release after owner left")
    }
    check("symlink instance-lock paths are refused without altering their target") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("billiards-lock-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("sentinel")
        let original = Data("unchanged".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("instance.lock"), withDestinationURL: target)
        let lock = SingleInstanceLock(directory: root)
        try expect(!lock.acquired, "symlink lock accepted")
        try expect(try Data(contentsOf: target) == original, "symlink target altered")
    }
    check("desktop trimming prioritizes Apps then files then folders stably") {
        let urls = ["folderA", "photo.png", "first.app", "note.txt", "second.APP", "link.webloc", "folderB"]
            .map { URL(fileURLWithPath: "/fixture/\($0)") }
        let chosen = DesktopSelection.indices(urls: urls, minimum: 0, maximum: 7,
            isDirectory: { $0.lastPathComponent.hasPrefix("folder") })
        try expect(chosen == [2, 4, 5, 1, 3, 0, 6], "priority or stable order differs")
    }
    check("sparse desktops pad artwork to fifteen without creating files") {
        let urls = [URL(fileURLWithPath: "/fixture/a.png"), URL(fileURLWithPath: "/fixture/b.png")]
        let chosen = DesktopSelection.indices(urls: urls, isDirectory: { _ in false })
        try expect(chosen.count == 15 && Set(chosen) == [0, 1], "padding lost originals or wrong count")
        try expect(chosen.prefix(6).map { $0 } == [0, 1, 0, 1, 0, 1], "padding order differs")
    }
    check("dense desktops cap at forty-five and directory metadata is read once per item") {
        let urls = (0..<100).map { URL(fileURLWithPath: "/fixture/file\($0).png") }
        var reads = 0
        let chosen = DesktopSelection.indices(urls: urls, isDirectory: { _ in reads += 1; return false })
        try expect(chosen == Array(0..<45), "dense selection order or bound differs")
        try expect(reads <= urls.count, "directory metadata reread during sort")
    }
    check("selection leaves real temporary source files and metadata unchanged") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("billiards-select-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picture.png")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: file)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        _ = DesktopSelection.indices(urls: [folder, file])
        try expect(try Data(contentsOf: file) == bytes, "source contents changed")
        try expect((try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) == before,
                   "source modification date changed")
        try expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).sorted() == ["folder", "picture.png"],
                   "padding created source files")
    }
    check("empty desktop selection stays empty") {
        try expect(DesktopSelection.indices(urls: []).isEmpty, "empty source padded unsafely")
    }
    check("invalid selection limits cannot create unbounded or invented sources") {
        let urls = [URL(fileURLWithPath: "/fixture/one.png")]
        try expect(DesktopSelection.indices(urls: urls, maximum: 0).isEmpty, "zero maximum accepted")
        try expect(DesktopSelection.indices(urls: urls, maximum: -1).isEmpty, "negative maximum accepted")
        try expect(DesktopSelection.indices(urls: urls, minimum: 100, maximum: 45, isDirectory: { _ in false }).count == 45,
                   "minimum bypassed maximum bound")
    }
    check("Finder file URLs decode spaces and reserved characters without a live request") {
        let decoded = try DesktopSnapshot.parse(snapshot([row("file:///fixture/Desktop/a%20b%23c.png", -120, 340)], total: 90),
            loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) })
        try expect(decoded.items.first?.url.path == "/fixture/Desktop/a b#c.png", "file URL was not decoded")
        try expect(decoded.items.first?.finderPosition == NSPoint(x: -120, y: 340), "source position changed")
        try expect(decoded.totalItemCount == 90, "real desktop count lost during capture")
    }
    check("Finder snapshot capture bounds image loading while preserving total count") {
        let rows = (0..<600).map { row("file:///fixture/item\($0).png") }
        var loads = 0
        let decoded = try DesktopSnapshot.parse(snapshot(rows, total: 900), loadImage: { _ in
            loads += 1; return NSImage(size: NSSize(width: 16, height: 16))
        })
        try expect(decoded.items.count == 512 && loads == 512, "capture did not bound work")
        try expect(decoded.totalItemCount == 900, "total desktop count incorrectly clamped to selected balls")
    }
    check("legacy two-field Finder snapshots still decode and count captured rows") {
        let decoded = try DesktopSnapshot.parse(snapshot([row("/fixture/one"), row("/fixture/two")]),
            loadImage: { _ in NSImage(size: NSSize(width: 16, height: 16)) })
        try expect(decoded.totalItemCount == 2 && decoded.items.count == 2, "legacy snapshot compatibility lost")
    }
    print("\(passed) parity checks passed; \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
