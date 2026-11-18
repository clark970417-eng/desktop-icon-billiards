// Invisible fixture panels only. No window is ordered onscreen and no links,
// donations, applications, or network actions are activated.
import AppKit
import CryptoKit

@MainActor
func labels(_ view: NSView) -> [NSTextField] {
    var result = (view as? NSTextField).map { [$0] } ?? []
    for child in view.subviews { result += labels(child) }
    return result
}
@MainActor
func images(_ view: NSView) -> [NSImageView] {
    var result = (view as? NSImageView).map { [$0] } ?? []
    for child in view.subviews { result += images(child) }
    return result
}
@MainActor
func buttons(_ view: NSView) -> [NSButton] {
    var result = (view as? NSButton).map { [$0] } ?? []
    for child in view.subviews { result += buttons(child) }
    return result
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    var passed = 0, failed = 0
    func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1; print("PASS \(name)") }
        else { failed += 1; print("FAIL \(name)") }
    }
    let information = InformationController()
    information.show(language: .zhHans, presentWindow: false)
    guard let donation = NSApp.windows.first(where: { $0.title == "打赏" }), let content = donation.contentView else {
        print("FAIL invisible donation fixture could not be prepared"); exit(1)
    }
    let fields = labels(content)
    check(!donation.isVisible, "donation fixtures do not show an actual UI window")
    check(fields.contains { $0.stringValue == "微信扫码赞赏，感谢支持！" }
          && fields.contains { $0.stringValue == "赞赏是对这个项目的自愿支持，不包含额外功能或专属技术支持。" },
          "donation dialog preserves original simplified Chinese wording")
    check(fields.contains { $0.stringValue.contains("GitHub@liuxiaogang-com") }, "original author credit remains visible")
    let original = NSImage(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/donation.jpg"))
    let actual = images(content).first?.image
    check(original?.tiffRepresentation != nil && actual?.tiffRepresentation == original?.tiffRepresentation,
          "donation artwork is the original repository image")
    let artworkIdentity = actual
    for language in [AppLanguage.en, .zhHans] {
        donation.setContentSize(NSSize(width: 280, height: 300))
        information.updateLanguage(language)
        let rootBounds = content.bounds.insetBy(dx: -1, dy: -1)
        check(buttons(content).allSatisfy { rootBounds.contains($0.frame) },
              "donation actions stay accessible in a narrow work area")
        if let scroll = content.subviews.compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
            check(document.subviews.allSatisfy { document.bounds.insetBy(dx: -1, dy: -1).contains($0.frame) },
                  "donation text and artwork stay inside the scrollable document")
        } else { check(false, "donation text and artwork stay inside the scrollable document") }
    }
    check(images(content).first?.image === artworkIdentity, "language changes preserve the selected donation artwork")
    information.showAbout(language: .zhHans, presentWindow: false)
    guard let about = NSApp.windows.first(where: { $0.title == "关于桌面图标台球" }), let aboutContent = about.contentView else {
        print("FAIL invisible About fixture could not be prepared"); exit(1)
    }
    about.setContentSize(NSSize(width: 280, height: 280))
    information.updateLanguage(.en)
    let aboutFields = labels(aboutContent)
    check(!about.isVisible && aboutFields.contains { $0.stringValue.contains("MIT License") && $0.stringValue.contains("LXG") },
          "About keeps original authorship and MIT license without opening a UI window")
    check(buttons(aboutContent).allSatisfy { aboutContent.bounds.insetBy(dx: -1, dy: -1).contains($0.frame) },
          "About links and Close stay inside a narrow panel")
    donation.close(); about.close()
    print("\(passed) information checks passed; \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
