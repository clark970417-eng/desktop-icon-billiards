// Deterministic AppKit fixtures only. No Finder request, wallpaper query,
// filesystem icon lookup, screen capture, or source-file mutation occurs.
import AppKit

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(description: message) }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.00001 }
func sameRect(_ a: NSRect, _ b: NSRect) -> Bool {
    near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
}
func samePoint(_ a: NSPoint, _ b: NSPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }
func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
    let value = NSAppleEventDescriptor.list()
    for (index, descriptor) in values.enumerated() { value.insert(descriptor, at: index + 1) }
    return value
}
func point(_ x: Int32, _ y: Int32) -> NSAppleEventDescriptor {
    list([NSAppleEventDescriptor(int32: x), NSAppleEventDescriptor(int32: y)])
}
func row(_ index: Int, position: NSAppleEventDescriptor? = nil, path: String? = nil) -> NSAppleEventDescriptor {
    list([NSAppleEventDescriptor(string: path ?? "/fixture/Desktop/item\(index)"),
          position ?? point(Int32(index * 10), Int32(index * 20))])
}
func snapshot(_ rows: [NSAppleEventDescriptor], size: Int32 = 64) -> NSAppleEventDescriptor {
    list([NSAppleEventDescriptor(int32: size), list(rows)])
}

MainActor.assumeIsolated {
    var passed = 0
    var failed = 0
    func check(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
    let canvas = NSRect(x: 0, y: 0, width: 1000, height: 1000)
    let wideImage = NSSize(width: 2000, height: 1000)
    check("wallpaper fit preserves the full image with centered empty bands") {
        let rect = DesktopBackdrop.imageRect(imageSize: wideImage, canvasRect: canvas,
                                             scaling: .scaleProportionallyUpOrDown, allowClipping: false)
        try expect(sameRect(rect, NSRect(x: 0, y: 250, width: 1000, height: 500)), "fit geometry differs")
    }
    check("wallpaper fill crops equally from both sides") {
        let rect = DesktopBackdrop.imageRect(imageSize: wideImage, canvasRect: canvas,
                                             scaling: .scaleProportionallyUpOrDown, allowClipping: true)
        try expect(sameRect(rect, NSRect(x: -500, y: 0, width: 2000, height: 1000)), "fill geometry differs")
    }
    check("wallpaper stretch fills the canvas without preserving aspect") {
        let rect = DesktopBackdrop.imageRect(imageSize: wideImage, canvasRect: canvas,
                                             scaling: .scaleAxesIndependently, allowClipping: false)
        try expect(sameRect(rect, canvas), "stretch did not cover canvas")
    }
    check("wallpaper center retains its original size and nonzero origin") {
        let target = NSRect(x: 30, y: 40, width: 1000, height: 500)
        let rect = DesktopBackdrop.imageRect(imageSize: NSSize(width: 200, height: 100), canvasRect: target,
                                             scaling: .scaleNone, allowClipping: true)
        try expect(sameRect(rect, NSRect(x: 430, y: 240, width: 200, height: 100)), "center shifted or resized")
    }
    check("wallpaper proportional-down never enlarges a small image") {
        let rect = DesktopBackdrop.imageRect(imageSize: NSSize(width: 200, height: 100), canvasRect: canvas,
                                             scaling: .scaleProportionallyDown, allowClipping: false)
        try expect(sameRect(rect, NSRect(x: 400, y: 450, width: 200, height: 100)), "down-only scaling enlarged image")
    }
    check("visible-frame cropping retains full-display wallpaper alignment") {
        // A window starting 20 points right and 50 points above screen origin
        // must draw against (-20,-50), not resize wallpaper to its smaller view.
        let displayInView = NSRect(x: -20, y: -50, width: 1440, height: 900)
        let rect = DesktopBackdrop.imageRect(imageSize: wideImage, canvasRect: displayInView,
                                             scaling: .scaleProportionallyUpOrDown, allowClipping: true)
        try expect(sameRect(rect, NSRect(x: -200, y: -50, width: 1800, height: 900)), "wallpaper lost screen alignment")
    }
    check("invalid wallpaper dimensions produce an empty render rectangle") {
        let rect = DesktopBackdrop.imageRect(imageSize: .zero, canvasRect: canvas,
                                             scaling: .scaleNone, allowClipping: false)
        try expect(rect == .zero, "invalid dimensions were used")
    }
    check("wallpaper backing renders opaque fill bands and fixture artwork") {
        let fixture = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw FixtureFailure(description: "could not create offscreen fixture context")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let backing = DesktopBackdrop(image: fixture, options: [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: NSNumber(value: false), .fillColor: NSColor.green
        ])
        backing.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let band = bitmap.colorAt(x: 10, y: 0)?.usingColorSpace(.deviceRGB),
              let artwork = bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB) else {
            throw FixtureFailure(description: "could not read fixture pixels")
        }
        try expect(band.greenComponent > 0.95 && band.alphaComponent > 0.99, "fill band was not opaque green")
        try expect(artwork.redComponent > 0.95 && artwork.greenComponent < 0.05 && artwork.alphaComponent > 0.99,
                   "fixture wallpaper artwork was not rendered")
    }
    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    check("Finder primary-screen points convert top-left to bottom-left") {
        let point = DesktopBackdrop.viewPoint(finderPosition: NSPoint(x: 100, y: 200),
                                              screenFrame: primary, primaryFrame: primary)
        try expect(samePoint(point, NSPoint(x: 100, y: 700)), "primary conversion failed")
    }
    check("Finder points on a display left of primary keep their local position") {
        let left = NSRect(x: -1280, y: 0, width: 1280, height: 800)
        let point = DesktopBackdrop.viewPoint(finderPosition: NSPoint(x: -100, y: 200),
                                              screenFrame: left, primaryFrame: primary)
        try expect(samePoint(point, NSPoint(x: 1180, y: 700)), "left-screen conversion failed")
    }
    check("Finder points above primary preserve negative Finder y coordinates") {
        let above = NSRect(x: 0, y: 900, width: 1280, height: 800)
        let point = DesktopBackdrop.viewPoint(finderPosition: NSPoint(x: 100, y: -100),
                                              screenFrame: above, primaryFrame: primary)
        try expect(samePoint(point, NSPoint(x: 100, y: 100)), "above-screen conversion failed")
    }
    check("Finder conversion handles a translated primary display frame") {
        let translated = NSRect(x: 300, y: -100, width: 1440, height: 900)
        let point = DesktopBackdrop.viewPoint(finderPosition: NSPoint(x: 100, y: 200),
                                              screenFrame: translated, primaryFrame: translated)
        try expect(samePoint(point, NSPoint(x: 100, y: 700)), "translated primary conversion failed")
    }
    let artwork = NSImage(size: NSSize(width: 16, height: 16))
    check("Finder descriptor fixtures preserve artwork, size, paths, and list positions") {
        var loaded = 0
        let result = try DesktopSnapshot.parse(snapshot([row(1, position: point(-120, 250)), row(2)])) { _ in
            loaded += 1; return artwork
        }
        try expect(result.items.count == 2 && loaded == 2 && result.iconSize == 64, "snapshot count or size differs")
        try expect(result.items[0].url.path == "/fixture/Desktop/item1", "source identity changed")
        try expect(result.items[0].image === artwork, "injected artwork was replaced")
        try expect(samePoint(result.items[0].finderPosition, NSPoint(x: -120, y: 250)), "list point changed")
    }
    check("Finder point decoder rejects malformed list coordinates") {
        try expect(DesktopSnapshot.decodePoint(list([NSAppleEventDescriptor(int32: 1)])) == nil, "one-item point accepted")
        try expect(DesktopSnapshot.decodePoint(list([NSAppleEventDescriptor(int32: 1), NSAppleEventDescriptor(int32: 2), NSAppleEventDescriptor(int32: 3)])) == nil, "three-item point accepted")
        try expect(DesktopSnapshot.decodePoint(point(10, -20)) == NSPoint(x: 10, y: -20), "valid negative point rejected")
    }
    check("Finder native QuickDraw point preserves signed horizontal and vertical values") {
        // Native Point payload is vertical (Int16), then horizontal (Int16).
        let bytes = Data([0xec, 0xff, 0x7b, 0x00]) // y=-20, x=123 on supported little-endian Macs.
        guard let descriptor = NSAppleEventDescriptor(descriptorType: typeQDPoint, data: bytes) else {
            throw FixtureFailure(description: "could not create native point descriptor")
        }
        try expect(DesktopSnapshot.decodePoint(descriptor) == NSPoint(x: 123, y: -20), "native point was swapped or unsigned")
    }
    check("Finder parser skips malformed rows without loading their artwork") {
        var loaded = 0
        let invalidPoint = list([NSAppleEventDescriptor(int32: 1)])
        let result = try DesktopSnapshot.parse(snapshot([
            row(1, path: "relative/path"), row(2, position: invalidPoint), row(3)
        ])) { _ in loaded += 1; return artwork }
        try expect(result.items.count == 1 && loaded == 1, "invalid rows were loaded")
        try expect(result.items[0].url.path == "/fixture/Desktop/item3", "valid row was lost")
    }
    check("Finder parser bounds work and image loading to 45 desktop items") {
        var loaded = 0
        let result = try DesktopSnapshot.parse(snapshot((1...60).map { row($0) })) { _ in loaded += 1; return artwork }
        try expect(result.items.count == 45 && loaded == 45, "45-item cap not enforced")
        try expect(result.items.last?.url.path == "/fixture/Desktop/item45", "cap changed source ordering")
    }
    check("Finder parser rejects empty or structurally invalid snapshots") {
        for descriptor in [snapshot([]), list([]), NSAppleEventDescriptor(string: "invalid")] {
            var rejected = false
            do { _ = try DesktopSnapshot.parse(descriptor) { _ in artwork } }
            catch { rejected = true }
            try expect(rejected, "empty or invalid snapshot accepted")
        }
    }
    check("Finder icon size is constrained to useful rendering bounds") {
        let low = try DesktopSnapshot.parse(snapshot([row(1)], size: 1)) { _ in artwork }
        let high = try DesktopSnapshot.parse(snapshot([row(1)], size: 1000)) { _ in artwork }
        try expect(low.iconSize == 16 && high.iconSize == 256, "icon-size bounds not enforced")
    }
    print("\(passed) desktop fixture checks passed; \(failed) failed")
    if failed > 0 { exit(1) }
}
