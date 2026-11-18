import AppKit

/// One real Finder desktop item. Artwork and source URLs stay in memory only.
struct DesktopItem {
    let url: URL
    /// Finder desktop coordinates: origin at the main display's upper left,
    /// x increases rightward and y increases downward. The renderer converts
    /// these to AppKit screen coordinates and filters other-display items.
    let finderPosition: NSPoint
    let image: NSImage
}

@MainActor
struct DesktopSnapshot {
    let items: [DesktopItem]
    let iconSize: CGFloat
    var totalItemCount: Int = 0
    static let maximumCapturedItems = 512

    /// Invoke only after an explicit desktop-play action. macOS may present
    /// its Finder Automation consent dialog. This script contains only reads;
    /// it never changes icon positions, Finder preferences, or source files.
    static func read() throws -> DesktopSnapshot {
        guard let script = NSAppleScript(source: scriptSource) else {
            throw SnapshotError.scriptUnavailable
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == -1743 { throw SnapshotError.automationDenied }
            // AppleScript errors can include file names or source paths.
            // Keep their raw descriptions out of UI messages and logs.
            throw SnapshotError.finderReadFailed(code)
        }
        return try parse(result)
    }

    /// Pure descriptor decoding is separate from the Automation request so
    /// fixture descriptors can verify parsing without contacting Finder.
    static func parse(_ descriptor: NSAppleEventDescriptor,
                      loadImage: (URL) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.path) }) throws -> DesktopSnapshot {
        guard descriptor.descriptorType == typeAEList,
              (2...3).contains(descriptor.numberOfItems),
              let sizeDescriptor = descriptor.atIndex(1),
              let rows = descriptor.atIndex(2), rows.descriptorType == typeAEList else {
            throw SnapshotError.invalidResponse
        }
        let iconSize = CGFloat(max(16, min(256, sizeDescriptor.int32Value)))
        var items: [DesktopItem] = []
        if rows.numberOfItems > 0 {
            for index in 1...min(Self.maximumCapturedItems, rows.numberOfItems) {
                guard let row = rows.atIndex(index), row.descriptorType == typeAEList,
                      row.numberOfItems == 2,
                      let path = row.atIndex(1)?.stringValue,
                      let pointDescriptor = row.atIndex(2),
                      let position = decodePoint(pointDescriptor) else { continue }
                let url: URL
                if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
                else if let file = URL(string: path), file.isFileURL { url = file }
                else { continue }
                items.append(DesktopItem(url: url, finderPosition: position, image: loadImage(url)))
            }
        }
        guard !items.isEmpty else { throw SnapshotError.noDesktopItems }
        return DesktopSnapshot(items: items, iconSize: iconSize,
            totalItemCount: max(items.count, min(1_000_000, Int(descriptor.atIndex(3)?.int32Value ?? Int32(rows.numberOfItems)))))
    }

    static func decodePoint(_ descriptor: NSAppleEventDescriptor) -> NSPoint? {
        // AppleScript usually coerces points to two-integer lists. Also accept
        // the native QuickDraw Point descriptor used by some Finder versions.
        if let list = descriptor.descriptorType == typeAEList
            ? descriptor : descriptor.coerce(toDescriptorType: typeAEList),
           list.numberOfItems == 2,
           let x = list.atIndex(1), let y = list.atIndex(2),
           let xValue = x.coerce(toDescriptorType: typeSInt32),
           let yValue = y.coerce(toDescriptorType: typeSInt32) {
            return NSPoint(x: Int(xValue.int32Value), y: Int(yValue.int32Value))
        }
        if descriptor.descriptorType == typeQDPoint, descriptor.data.count == 4 {
            // The Carbon Point payload is native-endian, vertical then horizontal.
            // Unaligned loads are avoided because NSData's alignment is unspecified.
            let bytes = [UInt8](descriptor.data)
            let vertical = Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
            let horizontal = Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
            return NSPoint(x: Int(horizontal), y: Int(vertical))
        }
        return nil
    }

    enum SnapshotError: LocalizedError {
        case scriptUnavailable
        case automationDenied
        case finderReadFailed(Int)
        case invalidResponse
        case noDesktopItems

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return "尚未允许读取 Finder 桌面图标。请到「系统设置 → 隐私权与安全性 → 自动化」，允许 Desktop Icon Billiards 控制 Finder 后再试一次。游戏只会读取图标与位置。"
            case .noDesktopItems:
                return "Finder 桌面上没有可用的图标。请先放置文件或文件夹，并确认桌面图标已显示。"
            case .finderReadFailed(let code):
                return "无法读取 Finder 桌面图标（错误 \(code)）。桌面与文件均未变更。"
            case .scriptUnavailable, .invalidResponse:
                return "无法取得 Finder 桌面图标与位置。桌面与文件均未变更。"
            }
        }
    }

    // Finder.sdef declares desktop position (dpos), container window (cwnd),
    // icon view options (icop), and icon size (lvis). No Finder setter appears.
    private static let scriptSource = """
    with timeout of 20 seconds
        tell application "Finder"
            set desktopIconSize to 64
            try
                set desktopIconSize to icon size of icon view options of container window of desktop
            end try
            set snapshotRows to {}
            set sourceURLs to URL of every item of desktop
            set iconPoints to desktop position of every item of desktop
            set totalItems to count of sourceURLs
            set itemLimit to totalItems
            if itemLimit > count of iconPoints then set itemLimit to count of iconPoints
            if itemLimit > 512 then set itemLimit to 512
            if itemLimit > 0 then
                repeat with itemIndex from 1 to itemLimit
                    set end of snapshotRows to {item itemIndex of sourceURLs, item itemIndex of iconPoints}
                end repeat
            end if
            return {desktopIconSize, snapshotRows, totalItems}
        end tell
    end timeout
    """
}
