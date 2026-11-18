// Generated artwork and isolated preferences only. Never reads a user's images,
// desktop, clipboard, or persistent application settings.
import AppKit
import ImageIO
import UniformTypeIdentifiers

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var passed = 0, failures = 0
    func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1; print("PASS \(name)") }
        else { failures += 1; print("FAIL \(name)") }
    }
    let result = RoundResult(elapsed: 65.321, iconCount: 15, shots: 8)
    check(result.isValid && result.formattedTime == "01:05.32" && abs(result.average - 4.3547333333) < 0.00001,
          "result values preserve precise average and match Windows centisecond display")
    check(!RoundResult(elapsed: .nan, iconCount: 15, shots: 1).isValid
          && RoundResult(elapsed: .infinity, iconCount: 0, shots: -1).formattedTime == "--:--.--",
          "invalid result values cannot reach a valid score")
    let zh = ResultsController.renderPNG(result: result, language: .zhHans, bestAverage: 4)
    let en = ResultsController.renderPNG(result: result, language: .en, bestAverage: 4)
    let zhBitmap = zh.flatMap(NSBitmapImageRep.init(data:))
    let enBitmap = en.flatMap(NSBitmapImageRep.init(data:))
    check(zhBitmap?.pixelsWide == 1080 && zhBitmap?.pixelsHigh == 1350
          && enBitmap?.pixelsWide == 1080 && enBitmap?.pixelsHigh == 1350,
          "both localized share cards render exactly 1080 by 1350 pixels")
    check(zh != en && (zh?.count ?? 0) > 20_000 && (en?.count ?? 0) > 20_000,
          "language changes refresh complete rendered result artwork")
    let ranked = RoundResult(elapsed: 30, iconCount: 15, shots: 4, globalRank: 12, percentile: 96, bestRank: 10)
    check(ResultsController.renderPNG(result: ranked, language: .en) != en,
          "actual ranked results use the ranked card layout")
    var improvedBest = ranked
    improvedBest.bestRank = 3
    var noBest = ranked
    noBest.bestRank = nil
    check(ResultsController.renderPNG(result: improvedBest, language: .en)
          != ResultsController.renderPNG(result: ranked, language: .en)
          && ResultsController.renderPNG(result: noBest, language: .en)
          != ResultsController.renderPNG(result: ranked, language: .en),
          "ranked card renders the supplied personal global best without inventing one")
    check(ResultsController.tier(percentile: 99, language: .en) == "Legend"
          && ResultsController.tier(percentile: 95, language: .en) == "Desktop champion"
          && ResultsController.tier(percentile: 85, language: .en) == "Master"
          && ResultsController.tier(percentile: 65, language: .en) == "Expert"
          && ResultsController.tier(percentile: 40, language: .en) == "Skilled"
          && ResultsController.tier(percentile: 39.99, language: .en) == "Rookie",
          "global percentile tiers match the Windows boundaries")
    let legendColor = ResultsController.tierColor(percentile: 99).usingColorSpace(.deviceRGB)!
    let masterColor = ResultsController.tierColor(percentile: 85).usingColorSpace(.deviceRGB)!
    check(abs(legendColor.redComponent - 242.0/255) < 0.001
          && abs(legendColor.greenComponent - 202.0/255) < 0.001
          && abs(masterColor.blueComponent - 1) < 0.001,
          "ranked card tier colors match the Windows palette")
    var pending = result
    pending.rankingPhase = "pending"
    check(ResultsController.renderPNG(result: pending, language: .zhHans) != zh,
          "off and pending card messages use distinct Windows states")
    let hour = RoundResult(elapsed: 3661.239, iconCount: 15, shots: 8)
    check(hour.formattedTime == "1:01:01.23", "long round time matches Windows hour formatting")
    if let png = zh, let source = CGImageSourceCreateWithData(png as CFData, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        let metadata = String(describing: properties)
        check(!metadata.contains("Desktop") && !metadata.contains("fixture"),
              "share-card PNG metadata contains no desktop names or source paths")
    } else { check(false, "share-card PNG metadata contains no desktop names or source paths") }
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let logo = NSImage(contentsOf: sourceRoot.appendingPathComponent("assets/desktop-icon-billiards.png"))
    let when = Date(timeIntervalSince1970: 1_794_960_000)
    let fixtureDirectory = sourceRoot.appendingPathComponent("macos/dist", isDirectory: true)
    try? FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    if let card = ResultsController.renderPNG(result: ranked, language: .zhHans, when: when, logo: logo) {
        try? card.write(to: fixtureDirectory.appendingPathComponent("result-card-native.png"))
    }
    if let card = ResultsController.renderPNG(result: result, language: .zhHans, when: when, logo: logo) {
        try? card.write(to: fixtureDirectory.appendingPathComponent("result-card-native-unranked.png"))
    }
    let fit = CueCrop.rect(imageSize: NSSize(width: 800, height: 400), zoom: 1)
    check(fit == NSRect(x: 200, y: 0, width: 400, height: 400), "cue crop uses a centered square without stretching")
    let corner = CueCrop.rect(imageSize: NSSize(width: 800, height: 400), zoom: 4, center: NSPoint(x: -500, y: 900))
    check(corner == NSRect(x: 0, y: 300, width: 100, height: 100), "dragged cue crop clamps to all image edges")
    let invalid = CueCrop.rect(imageSize: NSSize(width: 800, height: 400), zoom: .nan, center: NSPoint(x: CGFloat.nan, y: CGFloat.infinity))
    check(invalid == fit && CueCrop.rect(imageSize: .zero, zoom: 1) == .zero,
          "invalid cue geometry falls back safely")
    let image = NSImage(size: NSSize(width: 800, height: 400))
    image.lockFocus()
    NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 400, height: 400).fill()
    NSColor.blue.setFill(); NSRect(x: 400, y: 0, width: 400, height: 400).fill()
    image.unlockFocus()
    let left = CueCrop.texture(image: image, zoom: 1, center: NSPoint(x: 200, y: 200))!
    let right = CueCrop.texture(image: image, zoom: 1, center: NSPoint(x: 600, y: 200))!
    func centerColor(_ image: NSImage) -> NSColor? {
        guard let bitmap = image.representations.first as? NSBitmapImageRep else { return nil }
        return bitmap.colorAt(x: 128, y: 128)?.usingColorSpace(.deviceRGB)
    }
    check(left.representations.first?.pixelsWide == 256 && left.representations.first?.pixelsHigh == 256
          && (centerColor(left)?.redComponent ?? 0) > 0.9 && (centerColor(right)?.blueComponent ?? 0) > 0.9,
          "cue pan selects matching picture pixels in a bounded 256px texture")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("billiards-presentation-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: unrelated)
        try CueAppearanceStore.save(left, directory: directory)
        check(CueAppearanceStore.load(directory: directory)?.size == NSSize(width: 256, height: 256),
              "applied cue appearance persists and reloads without its source path")
        try CueAppearanceStore.save(nil, directory: directory)
        check(CueAppearanceStore.load(directory: directory) == nil
              && (try? Data(contentsOf: unrelated)) == Data("preserve".utf8),
              "reset removes only the generated cue cache")
        let large = directory.appendingPathComponent("large.png")
        try Data(count: 20 * 1024 * 1024 + 1).write(to: large)
        do { _ = try CueAppearanceStore.source(at: large); check(false, "oversized cue sources reject before decoding") }
        catch { check(true, "oversized cue sources reject before decoding") }
        try FileManager.default.removeItem(at: directory)
    } catch { check(false, "fixture persistence succeeds in an isolated temporary directory") }
    print("\(passed) presentation checks passed; \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
