import AppKit

/// Windows-compatible 15–45 ball selection; padding is artwork-only.
enum DesktopSelection {
    static func indices(urls: [URL], minimum: Int = 15, maximum: Int = 45,
                        isDirectory: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) -> [Int] {
        guard !urls.isEmpty, maximum > 0 else { return [] }
        func tier(_ index: Int) -> Int {
            let url = urls[index]
            if ["app", "webloc", "url", "alias"].contains(url.pathExtension.lowercased()) { return 0 }
            return isDirectory(url) ? 2 : 1
        }
        let tiers = urls.indices.map(tier)
        let ordered = urls.indices.sorted { a, b in tiers[a] == tiers[b] ? a < b : tiers[a] < tiers[b] }
        var chosen = Array(ordered.prefix(max(1, maximum)))
        let originals = chosen
        while chosen.count < min(maximum, minimum) { chosen.append(originals[(chosen.count - originals.count) % originals.count]) }
        return chosen
    }
}
