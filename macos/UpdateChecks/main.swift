// This runner intercepts every request. No GitHub or release asset is contacted.
import AppKit

enum AppLanguage { case zhHans, en }
struct UpdateCheckFailure: Error {}
func require(_ condition: @autoclosure () -> Bool) throws { if !condition() { throw UpdateCheckFailure() } }
struct UpdateMockReply {
    let status: Int
    let data: Data
    let delay: TimeInterval
    let error: URLError?
    init(_ object: Any, status: Int = 200, delay: TimeInterval = 0) {
        self.status = status; data = try! JSONSerialization.data(withJSONObject: object); self.delay = delay; error = nil
    }
    init(raw: Data, status: Int = 200) { self.status = status; data = raw; delay = 0; error = nil }
    init(error: URLError) { status = 0; data = Data(); delay = 0; self.error = error }
}
final class UpdateMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var saved: [URLRequest] = []
    private static var handler: (URLRequest) -> UpdateMockReply = { _ in UpdateMockReply([]) }
    private let instanceLock = NSLock()
    private var stopped = false
    static func configure(_ handler: @escaping (URLRequest) -> UpdateMockReply) {
        lock.lock(); saved = []; self.handler = handler; lock.unlock()
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return saved }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.saved.append(request); let reply = Self.handler(request); Self.lock.unlock()
        let deliver = { [self] in
            instanceLock.lock(); let cancelled = stopped; instanceLock.unlock()
            guard !cancelled else { return }
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
            // Even an accidental endpoint remains mocked, never delegated to DNS.
            guard request.url?.host == "api.github.com" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() { instanceLock.lock(); stopped = true; instanceLock.unlock() }
}
func fixtureAsset(_ version: String, architecture: String = "universal", suffix: String? = nil,
                  host: String = "github.com", tag: String? = nil) -> [String: Any] {
    let tag = tag ?? "mac-v\(version)"
    let name = suffix ?? "DesktopIconBilliards-\(version)-macOS-\(architecture).zip"
    return ["name": name, "browser_download_url": "https://\(host)\(MacUpdateClient.repositoryPath)/releases/download/\(tag)/\(name)"]
}
func fixtureRelease(_ version: String, assets: [[String: Any]]? = nil, draft: Bool = false,
                    prerelease: Bool = false, notes: String = "Original release notes\n更新说明原文") -> [String: Any] {
    let tag = "mac-v\(version)"
    return ["tag_name": tag, "html_url": "https://github.com\(MacUpdateClient.repositoryPath)/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease, "body": notes, "published_at": "2026-11-19T00:00:00Z",
            "assets": assets ?? [fixtureAsset(version)]]
}
func client() -> MacUpdateClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateMockProtocol.self]
    return MacUpdateClient(configuration: configuration, architecture: .arm64)
}
func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        var passed = 0, failed = 0
        @MainActor func check(_ name: String, _ body: @MainActor () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name)") }
        }
        @MainActor func wait(_ predicate: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(predicate())
        }
        await check("semantic versions compare numerically and reject malformed versions") {
            try require(MacReleaseVersion("0.10.0")! > MacReleaseVersion("0.9.99")!)
            try require(MacReleaseVersion("1.0.0")! > MacReleaseVersion("0.999999.999999")!)
            for version in ["0.4", "v0.4.0", "0.4.0-beta", "-1.0.0", "1.1000000.0", "1..0"] {
                try require(MacReleaseVersion(version) == nil)
            }
        }
        await check("controller construction and language changes make no startup requests") {
            UpdateMockProtocol.configure { _ in UpdateMockReply([]) }
            let controller = MacUpdateController(language: .zhHans, currentVersion: "0.4.0", client: client())
            controller.updateLanguage(.en)
            try await Task.sleep(nanoseconds: 50_000_000)
            try require(controller.state == .idle && UpdateMockProtocol.requests.isEmpty)
        }
        await check("highest Mac release wins instead of a newer Windows-only release") {
            let rows = [fixtureRelease("9.0.0", assets: [fixtureAsset("9.0.0", suffix: "DesktopIconBilliards-9.0.0-win-x64.exe")]),
                        fixtureRelease("0.9.0"), fixtureRelease("0.10.0")]
            let release = try MacUpdateClient.latestRelease(data: data(rows), architecture: .arm64)
            try require(release?.version == MacReleaseVersion("0.10.0"))
            try require(release?.assetName.hasSuffix("macOS-universal.zip") == true)
        }
        await check("draft prerelease incompatible architecture and non-Mac files are ignored") {
            let rows = [fixtureRelease("0.5.0", draft: true), fixtureRelease("0.6.0", prerelease: true),
                        fixtureRelease("0.7.0", assets: [fixtureAsset("0.7.0", architecture: "x86_64")]),
                        fixtureRelease("0.8.0", assets: [fixtureAsset("0.8.0", suffix: "setup.exe")])]
            let release = try MacUpdateClient.latestRelease(data: data(rows), architecture: .arm64)
            try require(release == nil)
        }
        await check("universal ZIP is preferred over an architecture-only ZIP") {
            let row = fixtureRelease("0.5.0", assets: [fixtureAsset("0.5.0", architecture: "arm64"), fixtureAsset("0.5.0")])
            let release = try MacUpdateClient.latestRelease(data: data([row]), architecture: .arm64)
            try require(release?.assetName.hasSuffix("universal.zip") == true)
        }
        await check("release and asset URLs must be HTTPS links inside this exact fork") {
            let version = "0.5.0", expected = MacUpdateClient.repositoryPath + "/releases/tag/mac-v0.5.0"
            for bad in ["http://github.com\(expected)", "https://github.com.evil.example\(expected)",
                        "https://user@github.com\(expected)", "https://github.com\(expected)?token=x", "https://github.com/other/repo/releases/tag/mac-v0.5.0"] {
                try require(MacUpdateClient.trustedURL(bad, host: "github.com", path: expected) == nil)
            }
            let unsafe = fixtureRelease(version, assets: [fixtureAsset(version, host: "downloads.example")])
            let mismatched = fixtureRelease(version, assets: [fixtureAsset("0.6.0", tag: "mac-v0.5.0")])
            let unsafeResult = try MacUpdateClient.latestRelease(data: data([unsafe]), architecture: .arm64)
            let mismatchedResult = try MacUpdateClient.latestRelease(data: data([mismatched]), architecture: .arm64)
            try require(unsafeResult == nil && mismatchedResult == nil)
        }
        await check("GitHub 404 and empty or Windows-only lists report no Mac release") {
            for reply in [UpdateMockReply(["message": "Not Found"], status: 404), UpdateMockReply([]),
                          UpdateMockReply([fixtureRelease("9.0.0", assets: [fixtureAsset("9.0.0", suffix: "setup.exe")])])] {
                UpdateMockProtocol.configure { _ in reply }
                let result = try await client().check(currentVersion: "0.4.0")
                try require(result == .noMacRelease)
            }
        }
        await check("a real Mac release is required before reporting up-to-date") {
            UpdateMockProtocol.configure { _ in UpdateMockReply([fixtureRelease("0.4.0")]) }
            let result = try await client().check(currentVersion: "0.4.0")
            guard case .upToDate(let release) = result else { throw UpdateCheckFailure() }
            try require(release.version.description == "0.4.0")
        }
        await check("manual checks use only the fork API with no download request") {
            UpdateMockProtocol.configure { _ in UpdateMockReply([fixtureRelease("0.5.0")]) }
            let result = try await client().check(currentVersion: "0.4.0")
            guard case .available = result else { throw UpdateCheckFailure() }
            let requests = UpdateMockProtocol.requests
            try require(requests.count == 1 && requests[0].url == MacUpdateClient.feedURL)
            try require(requests[0].httpMethod == "GET" && requests[0].httpBody == nil)
            try require(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        }
        await check("rate limiting malformed data oversized bodies and redirects fail closed") {
            for (reply, expected) in [(UpdateMockReply(["message": "rate limited"], status: 403), MacUpdateFailure.rateLimited),
                (UpdateMockReply(raw: Data("invalid".utf8)), .invalidResponse),
                (UpdateMockReply(raw: Data(repeating: 65, count: 300_000)), .oversized),
                (UpdateMockReply([:], status: 302), .http(302))] {
                UpdateMockProtocol.configure { _ in reply }
                do { _ = try await client().check(currentVersion: "0.4.0"); throw UpdateCheckFailure() }
                catch let error as MacUpdateFailure { try require(error == expected) }
                try require(UpdateMockProtocol.requests.count == 1)
            }
        }
        await check("invalid current versions are rejected before any request") {
            UpdateMockProtocol.configure { _ in UpdateMockReply([]) }
            do { _ = try await client().check(currentVersion: "broken"); throw UpdateCheckFailure() }
            catch let error as MacUpdateFailure { try require(error == .invalidVersion) }
            try require(UpdateMockProtocol.requests.isEmpty)
        }
        await check("language switches preserve an in-flight check and original release notes") {
            let originalNotes = "Original notes stay unchanged\n这里不自动翻译"
            UpdateMockProtocol.configure { _ in UpdateMockReply([fixtureRelease("0.5.0", notes: originalNotes)], delay: 0.1) }
            let controller = MacUpdateController(language: .zhHans, currentVersion: "0.4.0", client: client())
            controller.check(); controller.updateLanguage(.en)
            try require(controller.state == .checking)
            try await wait({ controller.state != .checking })
            guard case .available(let release) = controller.state else { throw UpdateCheckFailure() }
            try require(release.notes == originalNotes && controller.statusText.contains("New version"))
            let state = controller.state
            controller.updateLanguage(.zhHans)
            try require(controller.state == state && controller.statusText.contains("发现新版本"))
            try require(UpdateMockProtocol.requests.count == 1)
        }
        await check("closing during a check cancels stale results without reopening a window") {
            UpdateMockProtocol.configure { _ in UpdateMockReply([fixtureRelease("0.5.0")], delay: 0.3) }
            let controller = MacUpdateController(language: .en, currentVersion: "0.4.0", client: client())
            controller.check()
            try await wait({ !UpdateMockProtocol.requests.isEmpty })
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            try await Task.sleep(nanoseconds: 350_000_000)
            try require(controller.state == .idle)
        }
        await check("long release notes are bounded while their original text is preserved") {
            let note = String(repeating: "x", count: 6000)
            let release = try MacUpdateClient.latestRelease(data: data([fixtureRelease("0.5.0", notes: note)]), architecture: .arm64)
            try require(release?.notes == String(note.prefix(4000)))
        }
        await check("ordinary forbidden responses are not mislabeled as rate limiting") {
            UpdateMockProtocol.configure { _ in UpdateMockReply(["message": "Forbidden"], status: 403) }
            do { _ = try await client().check(currentVersion: "0.4.0"); throw UpdateCheckFailure() }
            catch let error as MacUpdateFailure { try require(error == .http(403)) }
        }
        await check("unexpected transport cancellation does not leave a check stuck forever") {
            UpdateMockProtocol.configure { _ in UpdateMockReply(error: URLError(.cancelled)) }
            let controller = MacUpdateController(language: .en, currentVersion: "0.4.0", client: client())
            controller.check()
            try await wait({ controller.state != .checking })
            try require(controller.state == .failed(.network))
        }
        print("\(passed) update checks passed; \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}
