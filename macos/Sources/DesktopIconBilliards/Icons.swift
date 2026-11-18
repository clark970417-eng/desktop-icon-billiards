import AppKit

struct IconSet {
    var images: [NSImage]
    var label: String
    var sourceURLs: [URL] = []

    static func applications() -> IconSet {
        let fm = FileManager.default
        // Prefer the user's installed apps. System apps only fill a shortage.
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
        var candidates: [URL] = []
        for root in roots {
            let entries: [URL] = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let apps = entries.filter { $0.pathExtension.lowercased() == "app" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            candidates.append(contentsOf: apps)
        }
        let available = candidates.isEmpty ? [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")] : candidates
        let urls = (0..<15).map { available[$0 % available.count] }
        let images = urls.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let allApplications = urls.allSatisfy { $0.deletingLastPathComponent().path == "/Applications" }
        return IconSet(images: images, label: allApplications ? "Applications App 图标 · 15 颗" : "本机 App 图标 · 15 颗",
                       sourceURLs: urls)
    }

    static func folder(_ url: URL) throws -> IconSet {
        // Enumerate one directory level; image contents are decoded separately
        // by the bounded background artwork loader.
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !urls.isEmpty else { throw IconError.emptyFolder }
        let originals = Array(urls.prefix(15))
        let sources = (0..<15).map { originals[$0 % originals.count] }
        let images = sources.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return IconSet(images: images, label: originals.count < 15 ? "文件夹图标 · 重复补至 15 颗" : "文件夹图标 · 15 颗",
                       sourceURLs: sources)
    }

    enum IconError: LocalizedError {
        case emptyFolder
        var errorDescription: String? { "文件夹里没有可用的图标，请选择其他文件夹。" }
    }
}
