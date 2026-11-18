// Offscreen shader checks with generated pixels only; no UI, files, or settings read.
import AppKit

@MainActor
func runChecks() {
    var passed = 0
    var failed = 0
    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1; print("PASS \(message)") }
        else { failed += 1; print("FAIL \(message)") }
    }
    func bitmap(_ image: NSImage) -> NSBitmapImageRep {
        image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
    }
    func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    func luma(_ color: NSColor) -> CGFloat {
        color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
    }

    let plain = BallArtwork.cue(texture: nil)
    let plainPixels = bitmap(plain)
    check([(0,0), (191,0), (0,191), (191,191)].allSatisfy { pixel(plainPixels, $0.0, $0.1).alphaComponent == 0 }
          && pixel(plainPixels,96,96).alphaComponent == 1,
          "sphere has transparent corners and an opaque center")
    check(luma(pixel(plainPixels,56,50)) > luma(pixel(plainPixels,135,141)) + 0.2,
          "sphere lighting and highlight face the upper left")

    let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 192,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let sourceBytes = source.bitmapData!
    for y in 0..<192 { for x in 0..<192 {
        let i = y * source.bytesPerRow + x * 4
        sourceBytes[i] = y < 96 ? 240 : 20
        sourceBytes[i+1] = 100
        sourceBytes[i+2] = y < 96 ? 20 : 240
        sourceBytes[i+3] = 255
    } }
    let before = Data(bytes: sourceBytes, count: source.bytesPerRow * source.pixelsHigh)
    let texture = NSImage(size: NSSize(width:192,height:192)); texture.addRepresentation(source)
    let shaded = BallArtwork.cue(texture: texture)
    let shadedPixels = bitmap(shaded)
    let top = pixel(shadedPixels,96,40), bottom = pixel(shadedPixels,96,151)
    check(top.redComponent > top.blueComponent && bottom.blueComponent > bottom.redComponent,
          "texture keeps its top-to-bottom orientation")
    check(luma(pixel(shadedPixels,80,120)) > luma(pixel(shadedPixels,145,165)) + 0.015,
          "texture receives spherical edge shading")
    check(before == Data(bytes: sourceBytes, count: source.bytesPerRow * source.pixelsHigh)
          && texture.size == NSSize(width:192,height:192),
          "shader preserves source pixels and dimensions")

    if let directory = ProcessInfo.processInfo.environment["BALL_ARTWORK_FIXTURES"] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, pixels) in [("cue-ball-plain.png",plainPixels),("cue-ball-textured.png",shadedPixels)] {
            if let data = pixels.representation(using: .png, properties: [:]) {
                try? data.write(to: url.appendingPathComponent(name))
            }
        }
    }
    print("\(passed) ball artwork checks passed; \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runChecks() }
