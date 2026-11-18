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
              descriptor.numberOfItems == 2,
              let sizeDescriptor = descriptor.atIndex(1),
              let rows = descriptor.atIndex(2), rows.descriptorType == typeAEList else {
            throw SnapshotError.invalidResponse
        }
        let iconSize = CGFloat(max(16, min(256, sizeDescriptor.int32Value)))
        var items: [DesktopItem] = []
        if rows.numberOfItems > 0 {
            for index in 1...min(45, rows.numberOfItems) {
                guard let row = rows.atIndex(index), row.descriptorType == typeAEList,
                      row.numberOfItems == 2,
                      let path = row.atIndex(1)?.stringValue, path.hasPrefix("/"),
                      let pointDescriptor = row.atIndex(2),
                      let position = decodePoint(pointDescriptor) else { continue }
                let url = URL(fileURLWithPath: path)
                items.append(DesktopItem(url: url, finderPosition: position, image: loadImage(url)))
            }
        }
        guard !items.isEmpty else { throw SnapshotError.noDesktopItems }
        return DesktopSnapshot(items: items, iconSize: iconSize)
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
                return "尚未允許讀取 Finder 桌面圖示。請到「系統設定 → 隱私權與安全性 → 自動化」，允許 Desktop Icon Billiards 控制 Finder 後再試一次。遊戲只會讀取圖示與位置。"
            case .noDesktopItems:
                return "Finder 桌面上沒有可用的圖示。請先放置檔案或資料夾，並確認桌面圖示已顯示。"
            case .finderReadFailed(let code):
                return "無法讀取 Finder 桌面圖示（錯誤 \(code)）。桌面與檔案均未變更。"
            case .scriptUnavailable, .invalidResponse:
                return "無法取得 Finder 桌面圖示與位置。桌面與檔案均未變更。"
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
            set desktopItems to every item of desktop
            set itemLimit to count of desktopItems
            if itemLimit > 45 then set itemLimit to 45
            if itemLimit > 0 then
                repeat with itemIndex from 1 to itemLimit
                    try
                        set desktopItem to item itemIndex of desktopItems
                        set sourcePath to POSIX path of (desktopItem as alias)
                        set iconPoint to desktop position of desktopItem
                        set end of snapshotRows to {sourcePath, iconPoint}
                    on error errorText number errorNumber
                        if errorNumber is -1743 then error number errorNumber
                    end try
                end repeat
            end if
            return {desktopIconSize, snapshotRows}
        end tell
    end timeout
    """
}
