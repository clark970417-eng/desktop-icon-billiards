import AppKit
import CryptoKit
import Darwin

// Mirrors dib/rank.py. Network access is explicitly opt-in and never includes
// artwork, desktop paths, file names, screenshots, or hardware identifiers.
struct RankingCredentials: Codable, Equatable, Sendable {
    let deviceID: String
    let secret: String
}

struct RankingEntry: Equatable, Sendable {
    let rank: Int
    let averageMilliseconds: Double
    let isMe: Bool
    let iconCount: Int?
    let shots: Int?
}

struct RankingBoard: Equatable, Sendable {
    let entries: [RankingEntry]
    let me: RankingEntry?
    let generatedAt: Date
}

struct RankingSubmission: Equatable, Sendable {
    let rank: Int
    let percentile: Double
    let bestRank: Int
    let isPersonalBest: Bool
}

struct RankingFailure: Error, Equatable, Sendable {
    let code: String
    let status: Int
    init(_ code: String, status: Int = 0) { self.code = code; self.status = status }
}

private final class RankingRequestState: @unchecked Sendable {
    var data = Data()
    var response: HTTPURLResponse?
    let completion: @Sendable (Result<(Data, HTTPURLResponse), Error>) -> Void
    init(completion: @escaping @Sendable (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        self.completion = completion
    }
}

private final class RankingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func attach(_ value: URLSessionDataTask) {
        lock.lock(); task = value; let cancelNow = cancelled; lock.unlock()
        if cancelNow { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
}

/// Streaming cap and redirect refusal apply to production and mocked requests.
private final class RankingHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private var requests: [Int: RankingRequestState] = [:]
    private var activeTasks: [Int: URLSessionDataTask] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let cancellation = RankingCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = RankingRequestState { continuation.resume(with: $0) }
                lock.lock(); requests[task.taskIdentifier] = state; activeTasks[task.taskIdentifier] = task; lock.unlock()
                cancellation.attach(task)
                task.resume()
            }
        }, onCancel: { cancellation.cancel() })
    }

    func cancelAll() {
        lock.lock(); let tasks = Array(activeTasks.values); lock.unlock()
        tasks.forEach { $0.cancel() }
    }
    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Signed device headers may never be replayed to a redirect target.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Self.maximumBytes else {
            finish(dataTask, .failure(RankingFailure("bad_response")))
            completionHandler(.cancel)
            return
        }
        lock.lock(); requests[dataTask.taskIdentifier]?.response = response; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = requests[dataTask.taskIdentifier] else { lock.unlock(); return }
        let oversized = state.data.count + data.count > Self.maximumBytes
        if !oversized { state.data.append(data) }
        lock.unlock()
        if oversized {
            finish(dataTask, .failure(RankingFailure("bad_response")))
            dataTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = requests.removeValue(forKey: task.taskIdentifier)
        activeTasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        if let error { state.completion(.failure(error)) }
        else if let response = state.response { state.completion(.success((state.data, response))) }
        else { state.completion(.failure(RankingFailure("bad_response"))) }
    }
    private func finish(_ task: URLSessionTask, _ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        let state = requests.removeValue(forKey: task.taskIdentifier)
        activeTasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        state?.completion(result)
    }
}

final class RankingAPI: @unchecked Sendable {
    static let defaultOrigin = URL(string: "https://billiards-rank-api.liuxiaogang.com")!
    let origin: URL
    private let transport: RankingHTTPTransport
    private let version: String

    init(origin: URL = RankingAPI.defaultOrigin, configuration: URLSessionConfiguration = .ephemeral,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "macOS") throws {
        self.origin = try Self.validatedOrigin(origin)
        self.version = version
        transport = RankingHTTPTransport(configuration: configuration)
    }
    deinit { transport.close() }
    func cancelAll() { transport.cancelAll() }

    static func validatedOrigin(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.port == nil || components.port == 443 else { throw RankingFailure("invalid_origin") }
        let plain = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard plain != "localhost", !plain.hasSuffix(".localhost"), !plain.hasSuffix(".local"), !plain.hasSuffix(".lan") else {
            throw RankingFailure("invalid_origin")
        }
        if plain.contains(":") {
            guard plain != "::", plain != "::1", !plain.hasPrefix("fc"), !plain.hasPrefix("fd"),
                  !plain.hasPrefix("fe80:"), !plain.hasPrefix("ff"), !plain.hasPrefix("::ffff:") else {
                throw RankingFailure("invalid_origin")
            }
        }
        let octets = plain.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            guard octets.allSatisfy({ (0...255).contains($0) }),
                  ![0, 10, 127].contains(octets[0]), octets[0] < 224,
                  !(octets[0] == 169 && octets[1] == 254),
                  !(octets[0] == 192 && octets[1] == 168),
                  !(octets[0] == 172 && (16...31).contains(octets[1])),
                  !(octets[0] == 100 && (64...127).contains(octets[1])) else { throw RankingFailure("invalid_origin") }
        }
        var normalized = components
        normalized.path = ""
        guard let result = normalized.url else { throw RankingFailure("invalid_origin") }
        return result
    }
    static func sign(secret: String, method: String, path: String, timestamp: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = Data("\(method)\n\(path)\n\(timestamp)\n\(bodyHash)".utf8)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func machineHash(anonymousID: String) -> String {
        SHA256.hash(data: Data(("dib-rank-v1|" + anonymousID.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func request(_ method: String, _ path: String, payload: [String: Any]? = nil,
                         credentials: RankingCredentials? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let body = try payload.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) } ?? Data()
        guard let url = URL(string: origin.absoluteString + path) else { throw RankingFailure("invalid_origin") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue("DesktopIconBilliards/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credentials {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            request.setValue(credentials.deviceID, forHTTPHeaderField: "X-Device-Id")
            request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
            request.setValue(Self.sign(secret: credentials.secret, method: method, path: path,
                                       timestamp: timestamp, body: body), forHTTPHeaderField: "X-Signature")
        }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch let failure as RankingFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw RankingFailure("network") }
        guard data.count <= RankingHTTPTransport.maximumBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RankingFailure("bad_response", status: response.statusCode)
        }
        guard response.statusCode == 200 else {
            let code = (json["error"] as? String).flatMap { $0.count < 80 ? $0 : nil } ?? "error"
            throw RankingFailure(code, status: response.statusCode)
        }
        return json
    }
    func register(machineHash: String) async throws -> RankingCredentials {
        guard machineHash.count == 64, machineHash.allSatisfy({ $0.isHexDigit }) else { throw RankingFailure("bad_request") }
        let json = try await request("POST", "/v1/device/register", payload: ["machine_hash": machineHash])
        guard let device = json["device_id"] as? String, let secret = json["secret"] as? String,
              Self.validCredential(device), Self.validCredential(secret) else { throw RankingFailure("bad_response") }
        return RankingCredentials(deviceID: device, secret: secret)
    }
    func startRound(credentials: RankingCredentials) async throws -> String {
        let json = try await request("POST", "/v1/round/start", payload: [:], credentials: credentials)
        guard let id = json["round_id"] as? String, Self.validCredential(id) else { throw RankingFailure("bad_response") }
        return id
    }
    func finishRound(credentials: RankingCredentials, roundID: String, milliseconds: Int,
                     iconCount: Int, shots: Int) async throws -> RankingSubmission {
        guard Self.validCredential(roundID), (15...45).contains(iconCount), (1...1_000_000).contains(shots),
              (1...86_400_000).contains(milliseconds) else { throw RankingFailure("bad_request") }
        let json = try await request("POST", "/v1/round/finish", payload: [
            "round_id": roundID, "total_ms": milliseconds, "icon_count": iconCount, "shots": shots
        ], credentials: credentials)
        guard let round = json["round"] as? [String: Any], let best = json["best"] as? [String: Any],
              let rank = Self.positiveInt(round["rank"]), let bestRank = Self.positiveInt(best["rank"]),
              let percentile = Self.number(round["percentile"]), (0...100).contains(percentile),
              let newBest = Self.boolean(json["is_personal_best"]) else { throw RankingFailure("bad_response") }
        return RankingSubmission(rank: rank, percentile: percentile, bestRank: bestRank, isPersonalBest: newBest)
    }
    func rankings(credentials: RankingCredentials?) async throws -> RankingBoard {
        let json = try await request("GET", "/v1/rankings", credentials: credentials)
        guard let rows = json["entries"] as? [[String: Any]], rows.count <= 50, json.keys.contains("me"),
              let dateString = json["generated_at"] as? String, dateString.count <= 50,
              let date = Self.parseDate(dateString) else { throw RankingFailure("bad_response") }
        let entries = try rows.map(Self.parseEntry)
        let me: RankingEntry?
        if json["me"] is NSNull { me = nil }
        else if let row = json["me"] as? [String: Any] { me = try Self.parseEntry(row) }
        else { throw RankingFailure("bad_response") }
        return RankingBoard(entries: entries, me: me, generatedAt: date)
    }
    static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy {
            // Accept UUID, hex and base64 credentials without permitting header
            // control characters. Secrets are signed locally, never sent raw.
            (33...126).contains($0.value)
        }
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func positiveInt(_ value: Any?) -> Int? {
        guard let value = number(value), value > 0, value <= 1_000_000_000, value.rounded() == value else { return nil }
        return Int(value)
    }
    private static func parseEntry(_ row: [String: Any]) throws -> RankingEntry {
        guard let rank = positiveInt(row["rank"]), let average = number(row["avg_ms"]), average > 0,
              average <= 86_400_000, let isMe = boolean(row["is_me"]) else { throw RankingFailure("bad_response") }
        let count = row["icon_count"].flatMap(positiveInt)
        let shots = row["shots"].flatMap(positiveInt)
        guard !row.keys.contains("icon_count") || count != nil,
              !row.keys.contains("shots") || shots != nil else { throw RankingFailure("bad_response") }
        return RankingEntry(rank: rank, averageMilliseconds: average, isMe: isMe, iconCount: count, shots: shots)
    }
    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

struct RankingPreferences: Codable {
    var enabled = false
    var anonymousID = UUID().uuidString.lowercased()
    var origin: String?
    var credentials: RankingCredentials?
}

@MainActor
final class RankingSettings {
    let fileURL: URL
    var preferences: RankingPreferences
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DesktopIconBilliards/ranking.json")
        let size = (try? self.fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        if size <= 64 * 1024, let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(RankingPreferences.self, from: data),
           UUID(uuidString: decoded.anonymousID) != nil {
            preferences = decoded
        } else { preferences = RankingPreferences() }
    }
    func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".ranking-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw RankingFailure("storage") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(preferences))
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw RankingFailure("storage") }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

@MainActor
final class RankingController: NSObject {
    private(set) var isEnabled: Bool
    private(set) var lastOutcome: RankingSubmission?
    var onOutcome: ((RankingSubmission) -> Void)?
    private(set) var statusCode = "off"
    private let api: RankingAPI
    private let settings: RankingSettings
    private var language: AppLanguage
    private var generation: UInt64 = 0
    private var roundGeneration: UInt64 = 0
    private var count: Int?
    private var hasShot = false
    private var skipped = false
    private var roundID: String?
    private var roundStartedAt: TimeInterval = 0
    private var startInProgress = false
    private var credentialTask: Task<RankingCredentials, Error>?
    private var roundTask: Task<String?, Never>?
    private var refreshTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?
    private var board: RankingBoard?
    private var failureCode: String?
    private var window: NSWindow?
    private let heading = NSTextField(labelWithString: "")
    private let privacy = NSTextField(wrappingLabelWithString: "")
    private let enabledButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let own = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView()

    init(language: AppLanguage, api: RankingAPI? = nil, settings: RankingSettings? = nil) {
        self.language = language
        self.api = api ?? (try! RankingAPI())
        self.settings = settings ?? RankingSettings()
        isEnabled = self.settings.preferences.enabled
        super.init()
        statusCode = isEnabled ? "ready" : "off"
    }

    func beginRound(iconCount: Int) {
        roundGeneration &+= 1
        roundTask?.cancel(); roundTask = nil
        submitTask?.cancel(); submitTask = nil
        count = iconCount; hasShot = false; skipped = false; roundID = nil; startInProgress = false
        lastOutcome = nil; failureCode = nil
        guard isEnabled, (15...45).contains(iconCount) else {
            statusCode = isEnabled ? "unrankable" : "off"; render(); return
        }
        prepareRound()
    }
    func markShotStarted() {
        guard !hasShot else { return }
        hasShot = true
        guard isEnabled, !skipped, let count, (15...45).contains(count) else { return }
        let expired = roundID != nil && ProcessInfo.processInfo.systemUptime - roundStartedAt > 30 * 60
        // Match Windows' first-shot recovery after a transient preparation
        // failure. An active start is shared, rather than creating two rounds.
        if expired || (roundID == nil && !startInProgress) {
            prepareRound()
        }
    }
    private func prepareRound() {
        roundGeneration &+= 1
        let roundToken = roundGeneration, token = generation
        roundTask?.cancel()
        roundID = nil; startInProgress = true; failureCode = nil; statusCode = "preparing"; render()
        roundStartedAt = ProcessInfo.processInfo.systemUptime
        roundTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let id = try await self.withCredentials(token: token) { credentials in
                    try await self.api.startRound(credentials: credentials)
                }
                guard self.permitted(token), self.roundGeneration == roundToken else { return nil }
                self.roundID = id; self.startInProgress = false; self.statusCode = "prepared"; self.render()
                return id
            } catch {
                guard self.permitted(token), self.roundGeneration == roundToken else { return nil }
                self.startInProgress = false
                self.failureCode = (error as? RankingFailure)?.code ?? "network"
                self.statusCode = "error"; self.render(); return nil
            }
        }
    }
    func submit(elapsed: Double, iconCount: Int, shots: Int) {
        guard isEnabled else { return }
        guard !skipped, count == iconCount, (15...45).contains(iconCount),
              elapsed.isFinite, elapsed > 0, elapsed <= 86_400, (1...1_000_000).contains(shots) else {
            statusCode = skipped ? "skipped" : "unrankable"; render(); return
        }
        guard submitTask == nil, lastOutcome == nil else { return }
        let token = generation, roundToken = roundGeneration
        let milliseconds = max(1, Int((elapsed * 1000).rounded()))
        let start = roundTask
        statusCode = "submitting"; render()
        submitTask = Task { [weak self] in
            guard let self else { return }
            let started = await start?.value
            guard self.permitted(token), self.roundGeneration == roundToken else { return }
            guard let id = self.roundID ?? started else {
                self.failureCode = "no_round"; self.statusCode = "error"; self.render(); return
            }
            do {
                let outcome = try await self.withCredentials(token: token) { credentials in
                    try await self.api.finishRound(credentials: credentials, roundID: id,
                        milliseconds: milliseconds, iconCount: iconCount, shots: shots)
                }
                guard self.permitted(token), self.roundGeneration == roundToken else { return }
                self.lastOutcome = outcome; self.statusCode = "submitted"; self.failureCode = nil
                self.render(); self.onOutcome?(outcome)
                self.refresh()
            } catch {
                guard self.permitted(token), self.roundGeneration == roundToken else { return }
                self.failureCode = (error as? RankingFailure)?.code ?? "network"
                self.statusCode = "error"; self.render()
            }
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        generation &+= 1
        isEnabled = enabled
        settings.preferences.enabled = enabled
        try? settings.save()
        credentialTask?.cancel(); credentialTask = nil
        roundTask?.cancel(); roundTask = nil
        refreshTask?.cancel(); refreshTask = nil
        submitTask?.cancel(); submitTask = nil
        api.cancelAll()
        roundID = nil; startInProgress = false; lastOutcome = nil; failureCode = nil
        if enabled {
            skipped = hasShot
            if !skipped, let count, (15...45).contains(count) { prepareRound() }
            else { statusCode = skipped ? "skipped" : "ready" }
            refresh()
        } else { statusCode = "off"; board = nil }
        render()
    }
    private func permitted(_ token: UInt64) -> Bool { isEnabled && generation == token && !Task.isCancelled }
    private func credentials(token: UInt64, force: Bool = false) async throws -> RankingCredentials {
        guard permitted(token) else { throw CancellationError() }
        if !force, settings.preferences.origin == api.origin.absoluteString,
           let cached = settings.preferences.credentials,
           RankingAPI.validCredential(cached.deviceID), RankingAPI.validCredential(cached.secret) { return cached }
        if let task = credentialTask {
            let value = try await task.value
            guard permitted(token) else { throw CancellationError() }
            return value
        }
        let hash = RankingAPI.machineHash(anonymousID: settings.preferences.anonymousID)
        let api = self.api
        let task = Task { [weak self] in
            let value = try await api.register(machineHash: hash)
            guard let self, self.permitted(token) else { throw CancellationError() }
            self.settings.preferences.origin = api.origin.absoluteString
            self.settings.preferences.credentials = value
            try? self.settings.save()
            return value
        }
        credentialTask = task
        let credentials: RankingCredentials
        do { credentials = try await task.value }
        catch { if generation == token { credentialTask = nil }; throw error }
        guard permitted(token) else { throw CancellationError() }
        credentialTask = nil
        return credentials
    }
    private func withCredentials<T>(token: UInt64,
                                    _ operation: (RankingCredentials) async throws -> T) async throws -> T {
        let current = try await credentials(token: token)
        guard permitted(token) else { throw CancellationError() }
        do { return try await operation(current) }
        catch let failure as RankingFailure where failure.status == 401 && failure.code == "unauthorized" {
            let refreshed = try await credentials(token: token, force: true)
            guard permitted(token) else { throw CancellationError() }
            return try await operation(refreshed)
        }
    }
    func refresh() {
        guard isEnabled else { statusCode = "off"; render(); return }
        refreshTask?.cancel()
        let token = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let board = try await self.withCredentials(token: token) { credentials in
                    try await self.api.rankings(credentials: credentials)
                }
                guard self.permitted(token) else { return }
                self.board = board
                self.render()
            } catch {
                guard self.permitted(token) else { return }
                self.failureCode = (error as? RankingFailure)?.code ?? "network"
                if self.lastOutcome == nil { self.statusCode = "error" }
                self.render()
            }
        }
    }
    func show() {
        if window == nil { makeWindow() }
        render()
        window?.makeKeyAndOrderFront(nil)
        if isEnabled { refresh() }
        clampWindow()
    }
    func updateLanguage(_ language: AppLanguage) {
        self.language = language
        render()
        window?.contentView?.layoutSubtreeIfNeeded()
        clampWindow()
    }
    @objc private func toggleOptIn() { setEnabled(enabledButton.state == .on) }
    @objc private func retry() { refresh() }
    private func t(_ chinese: String, _ english: String) -> String { language == .en ? english : chinese }
    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = true
        window.center()
        self.window = window
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        own.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        enabledButton.target = self; enabledButton.action = #selector(toggleOptIn)
        refreshButton.target = self; refreshButton.action = #selector(retry)
        refreshButton.bezelStyle = .rounded
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let content = window.contentView!
        for view in [heading, privacy, enabledButton, refreshButton, status, own, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            privacy.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            privacy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            privacy.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            enabledButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            enabledButton.topAnchor.constraint(equalTo: privacy.bottomAnchor, constant: 12),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            refreshButton.centerYAnchor.constraint(equalTo: enabledButton.centerYAnchor),
            enabledButton.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            status.topAnchor.constraint(equalTo: enabledButton.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: own.topAnchor, constant: -12),
            own.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            own.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            own.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }
    private func render() {
        heading.stringValue = t("全球排行榜", "Global rankings")
        window?.title = heading.stringValue
        privacy.stringValue = t(
            "默认关闭。开启后会连线至原作者的排名服务，传送匿名安装识别码与每局用时、球数及杆数。桌面图标、档名、路径及图片不会上传。中途开启时，下一局才计入排名。",
            "Off by default. Enabling connects to the original author's ranking service and sends an anonymous installation ID, round time, ball count and shots. Icons, file names, paths and images are never uploaded. Enabling mid-round applies from the next round.")
        enabledButton.title = t("开启全球排名", "Enable global rankings")
        enabledButton.state = isEnabled ? .on : .off
        refreshButton.title = t("重新整理", "Refresh")
        refreshButton.isEnabled = isEnabled
        status.stringValue = statusText()
        own.stringValue = board?.me.map { entry in
            t("我的最佳：第 \(entry.rank) 名 · 平均 ", "My best: #\(entry.rank) · Average ")
                + String(format: "%.3f", entry.averageMilliseconds / 1000) + t(" 秒／颗", " s/ball")
        } ?? t("我的最佳：尚无排名", "My best: no ranked score yet")
        let header = t("名次     球数     杆数       平均秒／颗\n", "Rank     Balls    Shots      Seconds/ball\n")
        let output = NSMutableAttributedString(string: header,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        for entry in board?.entries ?? [] {
            let line = String(format: "%4d     %4@     %5@       %8.3f%@\n", entry.rank,
                entry.iconCount.map(String.init) ?? "—", entry.shots.map(String.init) ?? "—",
                entry.averageMilliseconds / 1000, entry.isMe ? t("  我", "  Me") : "")
            output.append(NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: entry.isMe ? .semibold : .regular),
                .foregroundColor: entry.isMe ? NSColor.systemGreen : NSColor.labelColor
            ]))
        }
        if board?.entries.isEmpty != false {
            output.append(NSAttributedString(string: t("\n尚无可显示的榜单。", "\nNo rankings to display.")))
        }
        let selection = textView.selectedRange()
        let scroll = textView.enclosingScrollView
        let scrollOrigin = scroll?.contentView.bounds.origin
        textView.textStorage?.setAttributedString(output)
        if selection.location <= output.length {
            textView.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, output.length - selection.location)))
        }
        if let scroll, let scrollOrigin {
            scroll.contentView.scroll(to: scrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func statusText() -> String {
        switch statusCode {
        case "off": return t("排名已关闭，不会连线或上传。", "Ranking is off. No requests or uploads are made.")
        case "preparing": return t("正在准备本局排名…", "Preparing this ranked round…")
        case "prepared": return t("排名已开启，清台后提交成绩。", "Ranking is enabled. Scores submit after clearing the table.")
        case "submitting": return t("正在提交成绩…", "Submitting score…")
        case "submitted":
            guard let outcome = lastOutcome else { return "" }
            return t("本局第 \(outcome.rank) 名，超过 ", "Round rank #\(outcome.rank), ahead of ")
                + String(format: "%.1f%%", outcome.percentile)
                + (outcome.isPersonalBest ? t(" · 新的个人最佳", " · New personal best") : "")
        case "skipped": return t("本局开始后才开启排名，下一局起计入。", "Ranking was enabled mid-round. This round is excluded.")
        case "unrankable": return t("只有 15–45 颗球的球局可计入全球排名。", "Only rounds with 15–45 balls can be ranked.")
        case "error":
            switch failureCode {
            case "rate_limited": return t("请求过于频繁，请稍后重试。游戏可照常进行。", "Too many requests. Retry later; the game remains playable.")
            case "stale_timestamp": return t("系统时间不准，请校准后重试。", "Check your system clock and retry.")
            case "too_fast", "round_invalid", "implausible_time": return t("成绩未通过伺服器验证，本局未上传排名。", "The server could not verify this round; it was not ranked.")
            case "no_round": return t("未能准备排名球局，本局不计入排名。", "A ranked round could not be prepared; this score was not submitted.")
            case "bad_response": return t("排名服务回应异常，请重试。", "The ranking service returned an invalid response. Retry later.")
            default: return t("暂时无法连接排名服务，游戏可照常进行。", "The ranking service is unavailable. The game remains playable.")
            }
        default: return t("全球排名已开启。", "Global ranking is enabled.")
        }
    }
    private func clampWindow() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let work = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        var frame = window.frame
        frame.size.width = min(frame.width, work.width)
        frame.size.height = min(frame.height, work.height)
        frame.origin.x = min(max(frame.minX, work.minX), work.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, work.minY), work.maxY - frame.height)
        window.minSize = NSSize(width: min(420, work.width), height: min(350, work.height))
        window.setFrame(frame, display: true)
    }
}
