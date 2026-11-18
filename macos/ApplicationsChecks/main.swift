// Reads installed app artwork only. Never launches, modifies, or copies apps.
// Output intentionally omits app names and source paths.
import AppKit
import CryptoKit

private struct SourceState: Equatable {
    let bundleModified: Date?
    let infoModified: Date?
    let infoContents: Data?
}

private func state(_ url: URL) -> SourceState {
    let info = url.appendingPathComponent("Contents/Info.plist")
    let rootAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let infoAttributes = try? FileManager.default.attributesOfItem(atPath: info.path)
    return SourceState(bundleModified: rootAttributes?[.modificationDate] as? Date,
                       infoModified: infoAttributes?[.modificationDate] as? Date,
                       infoContents: try? Data(contentsOf: info))
}

@MainActor
private func artworkDigest(_ image: NSImage) -> Data? {
    guard image.isValid,
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill(using: .copy)
    image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero,
               operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return Data(SHA256.hash(data: data))
}

MainActor.assumeIsolated {
    var failures = 0
    var passed = 0
    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1; print("PASS \(message)") }
        else { failures += 1; print("FAIL \(message)") }
    }
    let installed = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"),
         includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
        .filter { $0.pathExtension.lowercased() == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    let original = Dictionary(uniqueKeysWithValues: installed.map { ($0, state($0)) })
    let icons = IconSet.applications()
    check(icons.images.count == 15 && icons.sourceURLs.count == 15, "installed App source fills 15 balls with matching artwork URLs")
    check(icons.sourceURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "all chosen source bundles exist")
    check(icons.sourceURLs.allSatisfy {
        $0.pathExtension.lowercased() == "app" && Bundle(url: $0)?.bundleIdentifier != nil
    }, "all chosen sources are readable App bundles")
    let installedSet = Set(installed)
    let selectedInstalled = icons.sourceURLs.filter { installedSet.contains($0) }
    if installed.count >= 15 {
        check(selectedInstalled.count == 15 && Set(selectedInstalled).count == 15,
              "15 distinct user-installed Apps are preferred over system Apps")
    } else if !installed.isEmpty {
        check(Set(selectedInstalled).count == installedSet.count,
              "every available user-installed App is used before system fallback")
    }
    let digests = icons.images.compactMap { artworkDigest($0) }
    check(digests.count == 15, "every App icon renders as valid bitmap artwork")
    check(Set(digests).count > 1, "App balls retain visibly different artwork")
    check(installed.allSatisfy { state($0) == original[$0] }, "reading icons preserves source bundles and metadata")
    print("Installed App count: \(installed.count); unique selected artwork: \(Set(digests).count)")
    print("\(passed) Applications checks passed; \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
