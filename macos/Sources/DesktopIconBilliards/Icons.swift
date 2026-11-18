import AppKit

struct IconSet {
    var images: [NSImage]
    var label: String

    static func applications() -> IconSet {
        let fm = FileManager.default
        let roots = ["/System/Applications", "/System/Applications/Utilities", "/Applications"]
        var candidates: [URL] = []
        for root in roots {
            let entries: [URL] = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            candidates.append(contentsOf: entries.filter { $0.pathExtension == "app" })
        }
        let urls = candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let images = urls.prefix(24).map { NSWorkspace.shared.icon(forFile: $0.path) }
        let fallback = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        let sources = images.isEmpty ? [fallback] : images
        let padded = (0..<15).map { sources[$0 % sources.count] }
        return IconSet(images: padded,
                       label: "本機 App 圖示 · 15 顆")
    }

    static func folder(_ url: URL) throws -> IconSet {
        // Enumerate one directory level only; icon(forFile:) does not open source files.
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !urls.isEmpty else { throw IconError.emptyFolder }
        let originals = Array(urls.prefix(15)).map { NSWorkspace.shared.icon(forFile: $0.path) }
        let images = (0..<15).map { originals[$0 % originals.count] }
        return IconSet(images: images, label: originals.count < 15 ? "資料夾圖示 · 重複補至 15 顆" : "資料夾圖示 · 15 顆")
    }

    enum IconError: LocalizedError {
        case emptyFolder
        var errorDescription: String? { "資料夾裡沒有可用的圖示，請選擇其他資料夾。" }
    }
}
