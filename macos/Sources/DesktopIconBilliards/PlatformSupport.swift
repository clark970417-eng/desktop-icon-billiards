import AppKit
import Carbon.HIToolbox
import Darwin

/// A process-held lock, not a stale PID file. Crashes release it automatically.
final class SingleInstanceLock {
    private var descriptor: Int32 = -1
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopIconBilliards", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return }
        let file = root.appendingPathComponent("instance.lock")
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return }
        descriptor = fd
    }
    var acquired: Bool { descriptor >= 0 }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}

@MainActor
final class GlobalExitHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var available = false
    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                  identity.signature == 0x4449424d, identity.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalExitHotKey>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &event, context, &handler)
        if result == noErr {
            available = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(cmdKey | optionKey),
                EventHotKeyID(signature: 0x4449424d, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
        }
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct WindowGeometry {
    static func clamp(_ frame: NSRect, to workArea: NSRect) -> NSRect {
        let width = min(max(1, frame.width), max(1, workArea.width))
        let height = min(max(1, frame.height), max(1, workArea.height))
        return NSRect(x: min(max(frame.minX, workArea.minX), workArea.maxX - width),
                      y: min(max(frame.minY, workArea.minY), workArea.maxY - height), width: width, height: height)
    }
    static func workArea(for frame: NSRect, candidates: [NSRect]) -> NSRect? {
        candidates.max { a, b in
            let x = frame.intersection(a), y = frame.intersection(b)
            return max(0, x.width) * max(0, x.height) < max(0, y.width) * max(0, y.height)
        }
    }
}
