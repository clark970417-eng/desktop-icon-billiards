// Temporary synthetic images only; no desktop, Applications, or Finder reads.
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct FixtureError: Error {}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("billiards-artwork-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

func writeImage(_ name: String, width: Int, height: Int, red: CGFloat, blue: CGFloat,
                type: UTType = .png, orientation: Int? = nil) throws -> URL {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError() }
    context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw FixtureError() }
    let url = root.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw FixtureError() }
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError() }
    return url
}
func centerColor(_ image: NSImage) -> (red: CGFloat, blue: CGFloat)? {
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return nil }
    return (color.redComponent, color.blueComponent)
}

let redURL = try writeImage("red.png", width: 320, height: 160, red: 1, blue: 0)
let blueURL = try writeImage("blue.png", width: 160, height: 320, red: 0, blue: 1)
let orientedURL = try writeImage("oriented.jpg", width: 160, height: 80, red: 1, blue: 0, type: .jpeg, orientation: 6)
let largeURL = try writeImage("large.png", width: 4096, height: 2048, red: 1, blue: 0)
let corruptURL = root.appendingPathComponent("corrupt.png")
try Data([0, 1, 2, 3]).write(to: corruptURL)
let bundleURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
let missingURL = root.appendingPathComponent("missing.png")

MainActor.assumeIsolated {
    var passed = 0, failed = 0
    func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1; print("PASS \(message)") }
        else { failed += 1; print("FAIL \(message)") }
    }
    func pump(_ seconds: TimeInterval, until predicate: () -> Bool = { false }) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end && !predicate() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
    let loader = ArtworkLoader()
    var results: [Int: NSImage] = [:]
    var mainCallbacks = true
    loader.load(urls: [redURL, blueURL, orientedURL, largeURL]) { index, image in
        mainCallbacks = mainCallbacks && Thread.isMainThread
        results[index] = image
    }
    pump(8) { results.count == 4 }
    check(results.count == 4, "PNG and JPEG previews load asynchronously")
    check(mainCallbacks, "artwork updates arrive on the main thread")
    if let red = results[0].flatMap(centerColor), let blue = results[1].flatMap(centerColor) {
        check(red.red > 0.9 && red.blue < 0.1 && blue.blue > 0.9 && blue.red < 0.1, "different pictures retain different visible content")
    } else { check(false, "different pictures retain different visible content") }
    if let image = results[0] { check(abs(image.size.width / image.size.height - 2) < 0.01, "thumbnail preserves image aspect ratio") }
    else { check(false, "thumbnail preserves image aspect ratio") }
    if let image = results[2] { check(image.size.height > image.size.width, "JPEG EXIF orientation is applied") }
    else { check(false, "JPEG EXIF orientation is applied") }
    if let image = results[3] { check(max(image.size.width, image.size.height) <= 256, "large image decodes to a bounded preview") }
    else { check(false, "large image decodes to a bounded preview") }
    var invalidCallbacks = 0
    loader.load(urls: [corruptURL, missingURL, bundleURL, URL(string: "https://invalid.example/image.png")!]) { _, _ in invalidCallbacks += 1 }
    pump(0.5)
    check(invalidCallbacks == 0, "corrupt missing remote and application sources preserve fallback icons")
    var cancelledCallbacks = 0
    loader.load(urls: Array(repeating: redURL, count: 45)) { _, _ in cancelledCallbacks += 1 }
    loader.cancel()
    pump(0.5)
    check(cancelledCallbacks == 0, "cancelled background work never updates the view")
    var currentImages: [NSImage] = []
    loader.load(urls: Array(repeating: redURL, count: 45)) { _, image in currentImages.append(image) }
    loader.load(urls: [blueURL]) { _, image in currentImages.append(image) }
    pump(4) { !currentImages.isEmpty }
    pump(0.2)
    check(currentImages.count == 1 && currentImages.first.flatMap(centerColor).map { $0.blue > 0.9 } == true,
          "new source ignores stale callbacks from the previous source")
    var boundedCallbacks = 0
    loader.load(urls: Array(repeating: blueURL, count: 80)) { _, _ in boundedCallbacks += 1 }
    pump(8) { boundedCallbacks == ArtworkLoader.maximumItems }
    pump(0.2)
    check(boundedCallbacks == ArtworkLoader.maximumItems && boundedCallbacks <= 64, "one load retains a bounded number of image previews")
    loader.cancel()
    print("\(passed) artwork checks passed; \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
