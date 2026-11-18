import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decodes only small, oriented image previews. Application bundles and other
/// file kinds keep their NSWorkspace icons. Source files are never modified.
@MainActor
final class ArtworkLoader {
    nonisolated static let maximumPixelSize = 256
    nonisolated static let maximumItems = 64
    private let queue: OperationQueue
    private var generation: UInt64 = 0

    init() {
        queue = OperationQueue()
        queue.name = "DesktopIconBilliards.ImagePreviews"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    deinit { queue.cancelAllOperations() }

    /// Every load replaces the previous source. Completion is delivered on the
    /// main actor, and stale work can never update a newer game or restored view.
    func load(urls: [URL], onUpdate: @escaping (Int, NSImage) -> Void) {
        cancel()
        let token = generation
        for (index, url) in urls.prefix(Self.maximumItems).enumerated() {
            queue.addOperation { [weak self] in
                guard let thumbnail = Self.decodeThumbnail(at: url) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    let size = NSSize(width: thumbnail.width, height: thumbnail.height)
                    onUpdate(index, NSImage(cgImage: thumbnail, size: size))
                }
            }
        }
    }

    func cancel() {
        generation &+= 1
        queue.cancelAllOperations()
    }

    /// Internal fixture seam. Runs on at most two worker threads in production;
    /// do not use NSImage(contentsOf:) here, which can decode full-size pictures.
    nonisolated static func decodeThumbnail(at url: URL) -> CGImage? {
        guard url.isFileURL,
              let contentType = UTType(filenameExtension: url.pathExtension),
              contentType.conforms(to: .image),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
              ]), values.isRegularFile == true else { return nil }
        // Do not cause an iCloud-only image to download for a game preview.
        if values.isUbiquitousItem == true {
            guard values.ubiquitousItemDownloadingStatus == .current
                    || values.ubiquitousItemDownloadingStatus == .downloaded else { return nil }
        }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
