import AppKit

/// The update feed belongs to this Mac fork. Windows update.exe/feed endpoints
/// are deliberately not used. Construction and ordinary app launch stay offline.
struct MacReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum MacUpdateArchitecture: String, Sendable {
    case arm64, x86_64
    static var current: Self {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

struct MacRelease: Equatable, Sendable {
    let version: MacReleaseVersion
    let releaseURL: URL
    let assetURL: URL
    let assetName: String
    let notes: String
    let publishedAt: Date?
}

enum MacUpdateFailure: Error, Equatable {
    case invalidVersion, invalidResponse, oversized, network, rateLimited, http(Int)
}

enum MacUpdateState: Equatable {
    case idle, checking, noMacRelease
    case upToDate(MacRelease)
    case available(MacRelease)
    case failed(MacUpdateFailure)
}

/// One request per instance. The byte cap is enforced while streaming, before
/// parsing; redirects are refused even though the feed carries no credentials.
private final class MacUpdateRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 256 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var cancelled = false

    init(configuration: URLSessionConfiguration) {
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    let task = session.dataTask(with: request)
                    self.task = task
                    let cancelled = self.cancelled
                    lock.unlock()
                    if cancelled { task.cancel() }
                    task.resume()
                }
            }, onCancel: { self.cancel() })
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(with: result)
        session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(MacUpdateFailure.invalidResponse)); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Self.maximumBytes else {
            finish(.failure(MacUpdateFailure.oversized)); completionHandler(.cancel); return
        }
        self.response = response
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= Self.maximumBytes else {
            finish(.failure(MacUpdateFailure.oversized)); dataTask.cancel(); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(MacUpdateFailure.network)) }
        } else if let response { finish(.success((bytes, response))) }
        else { finish(.failure(MacUpdateFailure.invalidResponse)) }
    }
}

final class MacUpdateClient: @unchecked Sendable {
    static let repositoryPath = "/clark970417-eng/desktop-icon-billiards"
    static let releasesURL = URL(string: "https://github.com" + repositoryPath + "/releases")!
    static let feedURL = URL(string: "https://api.github.com/repos" + repositoryPath + "/releases?per_page=20")!
    private let configuration: URLSessionConfiguration
    private let architecture: MacUpdateArchitecture
    init(configuration: URLSessionConfiguration = .ephemeral, architecture: MacUpdateArchitecture = .current) {
        self.configuration = configuration
        self.architecture = architecture
    }
    func check(currentVersion: String) async throws -> MacUpdateState {
        guard let current = MacReleaseVersion(currentVersion) else { throw MacUpdateFailure.invalidVersion }
        try Task.checkCancellation()
        var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DesktopIconBilliards/\(currentVersion) macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await MacUpdateRequest(configuration: configuration).send(request)
        try Task.checkCancellation()
        if response.statusCode == 404 { return .noMacRelease }
        if response.statusCode == 429 { throw MacUpdateFailure.rateLimited }
        if response.statusCode == 403 {
            let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "").lowercased()
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || message.contains("rate limit") {
                throw MacUpdateFailure.rateLimited
            }
        }
        guard response.statusCode == 200 else { throw MacUpdateFailure.http(response.statusCode) }
        guard let latest = try Self.latestRelease(data: data, architecture: architecture) else { return .noMacRelease }
        return latest.version > current ? .available(latest) : .upToDate(latest)
    }
    static func latestRelease(data: Data, architecture: MacUpdateArchitecture) throws -> MacRelease? {
        guard data.count <= MacUpdateRequest.maximumBytes else { throw MacUpdateFailure.oversized }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 20 else {
            throw MacUpdateFailure.invalidResponse
        }
        var candidates: [MacRelease] = []
        for row in rows {
            guard jsonBoolean(row["draft"]) == false, jsonBoolean(row["prerelease"]) == false,
                  let tag = row["tag_name"] as? String, tag.count <= 80,
                  let version = versionFromTag(tag),
                  let html = row["html_url"] as? String,
                  let releaseURL = trustedURL(html, host: "github.com", path: repositoryPath + "/releases/tag/" + tag),
                  let assets = row["assets"] as? [[String: Any]], assets.count <= 100 else { continue }
            var preferred: (rank: Int, url: URL, name: String)?
            for asset in assets {
                guard let name = asset["name"] as? String, name.count <= 180,
                      let parsed = assetVersion(name), parsed.version == version,
                      parsed.architecture == "universal" || parsed.architecture == architecture.rawValue,
                      let link = asset["browser_download_url"] as? String,
                      let url = trustedURL(link, host: "github.com", path: repositoryPath + "/releases/download/" + tag + "/" + name) else { continue }
                let rank = parsed.architecture == "universal" ? 2 : 1
                if preferred == nil || rank > preferred!.rank { preferred = (rank, url, name) }
            }
            guard let preferred else { continue }
            let notes = String((row["body"] as? String ?? "").prefix(4000))
            let date = (row["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            candidates.append(MacRelease(version: version, releaseURL: releaseURL, assetURL: preferred.url,
                                         assetName: preferred.name, notes: notes, publishedAt: date))
        }
        return candidates.max { $0.version < $1.version }
    }
    static func trustedURL(_ string: String, host: String, path: String) -> URL? {
        guard string.utf8.count < 4096, let url = URL(string: string),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.lowercased() == host,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443, components.path == path else { return nil }
        return url
    }
    private static func versionFromTag(_ tag: String) -> MacReleaseVersion? {
        for prefix in ["macOS-v", "mac-v", "macos-v", "macOS-", "mac-", "macos-", "v", ""] where tag.hasPrefix(prefix) {
            if let value = MacReleaseVersion(String(tag.dropFirst(prefix.count))) { return value }
        }
        return nil
    }
    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func assetVersion(_ name: String) -> (version: MacReleaseVersion, architecture: String)? {
        let prefix = "DesktopIconBilliards-"
        guard name.hasPrefix(prefix), name.hasSuffix(".zip") else { return nil }
        let stem = String(name.dropFirst(prefix.count).dropLast(4))
        let pieces = stem.components(separatedBy: "-macOS-")
        guard pieces.count == 2, let version = MacReleaseVersion(pieces[0]),
              ["universal", "arm64", "x86_64"].contains(pieces[1]) else { return nil }
        return (version, pieces[1])
    }
}

@MainActor
final class MacUpdateController: NSObject, NSWindowDelegate {
    private let client: MacUpdateClient
    private let currentVersion: String
    private var language: AppLanguage
    private(set) var state: MacUpdateState = .idle
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var window: NSWindow?
    private let heading = NSTextField(labelWithString: "")
    private let current = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let notesHeading = NSTextField(labelWithString: "")
    private let notes = NSTextView()
    private let checkButton = NSButton(title: "", target: nil, action: nil)
    private let releaseButton = NSButton(title: "", target: nil, action: nil)
    private var lastRelease: MacRelease?

    init(language: AppLanguage,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0",
         client: MacUpdateClient = MacUpdateClient()) {
        self.language = language; self.currentVersion = currentVersion; self.client = client
        super.init()
    }
    func show() {
        if window == nil { makeWindow() }
        render()
        window?.makeKeyAndOrderFront(nil)
        clampWindow()
        check()
    }
    func check() {
        guard state != .checking else { return }
        generation &+= 1
        let token = generation
        task?.cancel(); state = .checking; render()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.check(currentVersion: self.currentVersion)
                guard !Task.isCancelled, self.generation == token else { return }
                self.state = result
                switch result {
                case .available(let release), .upToDate(let release): self.lastRelease = release
                case .noMacRelease: self.lastRelease = nil
                default: break
                }
            } catch is CancellationError {
                // Closing the window changes generation and already resets the
                // state. An unexpected transport cancellation must not leave
                // the retry button disabled forever.
                guard !Task.isCancelled, self.generation == token else { return }
                self.state = .failed(.network)
            }
            catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.state = .failed((error as? MacUpdateFailure) ?? .network)
            }
            self.render()
        }
    }
    func updateLanguage(_ language: AppLanguage) {
        self.language = language; render()
        window?.contentView?.layoutSubtreeIfNeeded(); clampWindow()
    }
    func windowWillClose(_ notification: Notification) {
        generation &+= 1; task?.cancel(); task = nil
        if state == .checking { state = .idle }
    }
    @objc private func retry() { check() }
    @objc private func openReleasePage() {
        // This user action opens the release page only. Nothing is downloaded,
        // installed, launched, or written over the running application.
        let url = lastRelease?.releaseURL ?? MacUpdateClient.releasesURL
        NSWorkspace.shared.open(url)
    }
    private func t(_ chinese: String, _ english: String) -> String { language == .en ? english : chinese }
    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.level = .floating; window.hidesOnDeactivate = true
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.center(); self.window = window
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        current.font = .systemFont(ofSize: 13)
        current.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13, weight: .medium)
        notesHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        notes.isEditable = false; notes.isSelectable = true; notes.drawsBackground = false
        notes.font = .systemFont(ofSize: 13)
        notes.frame = NSRect(x: 0, y: 0, width: 600, height: 330)
        notes.isVerticallyResizable = true; notes.isHorizontallyResizable = false
        notes.autoresizingMask = .width
        notes.textContainer?.widthTracksTextView = true
        notes.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        notes.textContainerInset = NSSize(width: 4, height: 6)
        checkButton.bezelStyle = .rounded; checkButton.target = self; checkButton.action = #selector(retry)
        releaseButton.bezelStyle = .rounded; releaseButton.target = self; releaseButton.action = #selector(openReleasePage)
        let scroll = NSScrollView(); scroll.documentView = notes
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = window.contentView!
        for view in [heading, current, status, notesHeading, scroll, checkButton, releaseButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            current.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            current.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            current.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            status.topAnchor.constraint(equalTo: current.bottomAnchor, constant: 12),
            notesHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            notesHeading.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: notesHeading.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: checkButton.topAnchor, constant: -16),
            checkButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            checkButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            releaseButton.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            releaseButton.centerYAnchor.constraint(equalTo: checkButton.centerYAnchor),
            checkButton.trailingAnchor.constraint(lessThanOrEqualTo: releaseButton.leadingAnchor, constant: -12)
        ])
    }
    private func render() {
        heading.stringValue = t("软件更新", "Software update")
        window?.title = heading.stringValue
        current.stringValue = t("当前版本：", "Current version: ") + currentVersion
        notesHeading.stringValue = t("更新内容", "What's new")
        checkButton.title = t("重新检查", "Check again")
        checkButton.isEnabled = state != .checking
        releaseButton.title = t("前往发布页面", "Open releases")
        status.stringValue = statusText
        let body = lastRelease.map { release in
            t("Mac 版本 ", "Mac version ") + release.version.description + "\n\n"
                + (release.notes.isEmpty ? t("暂无更新说明", "No release notes provided.") : release.notes)
        } ?? t("仅检查此 Mac 分支的正式发布，不会自动下载或安装。", "Checks published Mac releases from this fork. Downloads and installation are manual.")
        let selection = notes.selectedRange(), scroll = notes.enclosingScrollView
        let origin = scroll?.contentView.bounds.origin
        notes.string = body
        notes.setSelectedRange(NSRange(location: min(selection.location, body.utf16.count),
                                       length: min(selection.length, max(0, body.utf16.count - min(selection.location, body.utf16.count)))))
        if let scroll, let origin { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
    var statusText: String {
        switch state {
        case .idle: return t("点击重新检查，查询是否有新版本。", "Check for a newer version.")
        case .checking: return t("正在检查更新…", "Checking for updates…")
        case .noMacRelease: return t("当前发布列表暂无适用于这台 Mac 的安装包。", "No compatible Mac package was found in the current release list.")
        case .upToDate: return t("当前已是最新可用的 Mac 版本。", "Your Mac version is up to date.")
        case .available(let release): return t("发现新版本 ", "New version available: ") + release.version.description
        case .failed(let failure):
            switch failure {
            case .rateLimited: return t("检查过于频繁，请稍后重试。", "Too many update checks. Try again later.")
            case .invalidVersion: return t("当前版本信息无效，无法检查更新。", "The current version is invalid, so updates cannot be checked.")
            case .invalidResponse, .oversized: return t("更新服务返回异常，请稍后重试。", "The update service returned an invalid response. Try again later.")
            default: return t("检查更新失败，请检查网络后重试。", "Could not check for updates. Check your connection and retry.")
            }
        }
    }
    private func clampWindow() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var frame = window.frame
        frame.size.width = min(frame.width, area.width); frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        window.minSize = NSSize(width: min(420, area.width), height: min(320, area.height))
        window.setFrame(frame, display: true)
    }
}
