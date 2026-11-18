// All requests are intercepted by URLProtocol. Never contacts the real service.
import AppKit
import CryptoKit

// This runner compiles the ranking file independently of the application UI.
enum AppLanguage { case zhHans, en }

struct MockRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let host: String
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}
struct MockReply {
    var status = 200
    var data: Data
    var delay: TimeInterval = 0
    init(_ object: [String: Any], status: Int = 200, delay: TimeInterval = 0) {
        self.status = status; self.data = try! JSONSerialization.data(withJSONObject: object); self.delay = delay
    }
    init(raw: Data, status: Int = 200) { self.status = status; self.data = raw }
}
final class RankingMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var saved: [MockRequest] = []
    private static var handler: (MockRequest) -> MockReply = { _ in MockReply([:]) }
    private let instanceLock = NSLock()
    private var stopped = false
    static func configure(_ handler: @escaping (MockRequest) -> MockReply) {
        lock.lock(); saved = []; self.handler = handler; lock.unlock()
    }
    static var requests: [MockRequest] { lock.lock(); defer { lock.unlock() }; return saved }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let record = MockRequest(method: request.httpMethod ?? "GET", path: request.url!.path + (request.url!.query.map { "?" + $0 } ?? ""),
            headers: request.allHTTPHeaderFields ?? [:], body: body, host: request.url!.host ?? "")
        Self.lock.lock(); Self.saved.append(record); let reply = Self.handler(record); Self.lock.unlock()
        let deliver = { [self] in
            instanceLock.lock(); let cancelled = stopped; instanceLock.unlock()
            guard !cancelled else { return }
            // Catch every host, including a mistaken production origin. No fallback networking.
            guard record.host == "rank.example.test" else {
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

struct CheckFailure: Error {}
func require(_ condition: @autoclosure () -> Bool) throws { if !condition() { throw CheckFailure() } }
func api() throws -> RankingAPI {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RankingMockProtocol.self]
    return try RankingAPI(origin: URL(string: "https://rank.example.test")!, configuration: config, version: "fixture")
}
func json(_ request: MockRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:] }
let credentials = RankingCredentials(deviceID: "11111111-2222-3333-4444-555555555555", secret: String(repeating: "b", count: 64))
let validBoard: [String: Any] = ["entries": [["rank": 1, "avg_ms": 1234, "is_me": false, "icon_count": 20, "shots": 12]],
                                "me": ["rank": 128, "avg_ms": 9000, "is_me": true], "generated_at": "2026-11-12T12:00:00Z"]
let validFinish: [String: Any] = ["round": ["rank": 20, "percentile": 87.5], "best": ["rank": 10], "is_personal_best": false]

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        var passed = 0, failed = 0
        @MainActor func check(_ name: String, _ body: @MainActor () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name)") }
        }
        @MainActor func wait(_ predicate: @MainActor () -> Bool, seconds: Double = 3) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(predicate())
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("billiards-rank-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        @MainActor func settings(_ suffix: String) -> RankingSettings { RankingSettings(fileURL: root.appendingPathComponent(suffix + "/ranking.json")) }

        await check("HMAC signatures match upstream server vectors") {
            let body = Data("{\"round_id\":\"x\",\"total_ms\":40000,\"icon_count\":20,\"shots\":12}".utf8)
            try require(RankingAPI.sign(secret: credentials.secret, method: "POST", path: "/v1/round/finish", timestamp: "1700000000", body: body)
                == "105fea036b3ab676ae6a694fe56f4739c9d0e33c977c33c8b45340f5dac2c62c")
            try require(RankingAPI.sign(secret: "k", method: "POST", path: "/v1/round/start", timestamp: "1700000000", body: Data())
                == "6eb8784679f4889281c0747fb448fe65343548bafafd48268e47efb5f6326350")
        }
        await check("HTTPS origin validation refuses credentials paths and private hosts") {
            for string in ["http://rank.example.test", "https://u:p@rank.example.test", "https://rank.example.test/api",
                           "https://rank.example.test?q=x", "https://localhost", "https://10.0.0.1", "https://192.168.1.1", "https://[::1]"] {
                do { _ = try RankingAPI.validatedOrigin(URL(string: string)!); throw CheckFailure() }
                catch is CheckFailure { throw CheckFailure() }
                catch { }
            }
            let normalized = try RankingAPI.validatedOrigin(URL(string: "https://rank.example.test/")!)
            try require(normalized.absoluteString == "https://rank.example.test")
        }
        await check("default-off controller makes no requests or uploads") {
            RankingMockProtocol.configure { _ in MockReply([:]) }
            let controller = RankingController(language: .zhHans, api: try api(), settings: settings("off"))
            controller.beginRound(iconCount: 15); controller.markShotStarted()
            controller.submit(elapsed: 60, iconCount: 15, shots: 8); controller.refresh(); controller.updateLanguage(.en)
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(!controller.isEnabled && controller.statusCode == "off" && RankingMockProtocol.requests.isEmpty)
        }
        await check("registration sends only a salted anonymous hash") {
            RankingMockProtocol.configure { _ in MockReply(["device_id": credentials.deviceID, "secret": credentials.secret]) }
            let client = try api()
            let id = UUID().uuidString.lowercased()
            let hash = RankingAPI.machineHash(anonymousID: id)
            let value = try await client.register(machineHash: hash)
            let request = RankingMockProtocol.requests.last!
            try require(value == credentials && Set(json(request).keys) == ["machine_hash"])
            try require(hash.count == 64 && !String(data: request.body, encoding: .utf8)!.contains(id))
            try require(request.header("X-Device-Id") == nil)
        }
        await check("start and finish requests use exact signed protocol and numeric scores") {
            RankingMockProtocol.configure { request in request.path == "/v1/round/start" ? MockReply(["round_id": "fixture-round"]) : MockReply(validFinish) }
            let client = try api()
            let round = try await client.startRound(credentials: credentials)
            let outcome = try await client.finishRound(credentials: credentials, roundID: round, milliseconds: 40123, iconCount: 20, shots: 12)
            try require(outcome.rank == 20 && outcome.bestRank == 10 && outcome.percentile == 87.5)
            for request in RankingMockProtocol.requests {
                let timestamp = request.header("X-Timestamp")!
                try require(request.header("X-Signature") == RankingAPI.sign(secret: credentials.secret, method: request.method,
                    path: request.path, timestamp: timestamp, body: request.body))
            }
            let payload = json(RankingMockProtocol.requests.last!)
            try require(Set(payload.keys) == ["round_id", "total_ms", "icon_count", "shots"])
            try require(payload["total_ms"] as? Int == 40123 && payload["icon_count"] as? Int == 20)
        }
        await check("top50 parsing retains personal best outside the top50") {
            RankingMockProtocol.configure { _ in MockReply(validBoard) }
            let result = try await api().rankings(credentials: credentials)
            try require(result.entries.count == 1 && result.me?.rank == 128 && result.me?.isMe == true)
        }
        await check("malformed rows timestamps booleans and oversized rankings fail closed") {
            for object: [String: Any] in [
                ["entries": [["rank": true, "avg_ms": 1000, "is_me": false]], "me": NSNull(), "generated_at": "2026-11-12T12:00:00Z"],
                ["entries": [["rank": 1, "avg_ms": -1, "is_me": false]], "me": NSNull(), "generated_at": "2026-11-12T12:00:00Z"],
                ["entries": [], "me": NSNull(), "generated_at": "invalid"],
                ["entries": Array(repeating: ["rank": 1, "avg_ms": 1000, "is_me": false], count: 51), "me": NSNull(), "generated_at": "2026-11-12T12:00:00Z"]
            ] {
                RankingMockProtocol.configure { _ in MockReply(object) }
                do { _ = try await api().rankings(credentials: nil); throw CheckFailure() }
                catch let error as RankingFailure { try require(error.code == "bad_response") }
            }
        }
        await check("64KiB response cap rejects large bodies and redirect replies are not replayed") {
            RankingMockProtocol.configure { _ in MockReply(raw: Data(repeating: 65, count: 70_000)) }
            do { _ = try await api().rankings(credentials: nil); throw CheckFailure() }
            catch let error as RankingFailure { try require(error.code == "bad_response") }
            RankingMockProtocol.configure { _ in MockReply(["error": "redirect"], status: 302) }
            do { _ = try await api().startRound(credentials: credentials); throw CheckFailure() }
            catch let error as RankingFailure { try require(error.status == 302) }
            try require(RankingMockProtocol.requests.count == 1)
        }
        await check("credentials persist atomically with owner-only file permissions") {
            let store = settings("permissions")
            store.preferences.enabled = true
            store.preferences.credentials = credentials
            try store.save()
            let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as! NSNumber
            try require(permissions.intValue & 0o777 == 0o600)
            let reloaded = RankingSettings(fileURL: store.fileURL)
            try require(reloaded.preferences.credentials == credentials && reloaded.preferences.anonymousID == store.preferences.anonymousID)
        }
        await check("enabled round registers starts submits once and refreshes rankings") {
            RankingMockProtocol.configure { request in
                switch request.path {
                case "/v1/device/register": return MockReply(["device_id": credentials.deviceID, "secret": credentials.secret])
                case "/v1/round/start": return MockReply(["round_id": "fixture-round"])
                case "/v1/round/finish": return MockReply(validFinish)
                default: return MockReply(validBoard)
                }
            }
            let controller = RankingController(language: .zhHans, api: try api(), settings: settings("round"))
            controller.beginRound(iconCount: 20); controller.setEnabled(true)
            try await wait({ RankingMockProtocol.requests.contains { $0.path == "/v1/round/start" } })
            controller.markShotStarted()
            controller.submit(elapsed: 40.123, iconCount: 20, shots: 12)
            try await wait({ controller.lastOutcome != nil })
            controller.submit(elapsed: 40.123, iconCount: 20, shots: 12)
            controller.updateLanguage(.en)
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(RankingMockProtocol.requests.filter { $0.path == "/v1/round/finish" }.count == 1)
            try require(controller.lastOutcome?.rank == 20 && controller.isEnabled)
            controller.setEnabled(false)
        }
        await check("enabling mid-round skips that round and does not send its score") {
            RankingMockProtocol.configure { request in
                request.path == "/v1/device/register" ? MockReply(["device_id": credentials.deviceID, "secret": credentials.secret]) : MockReply(validBoard)
            }
            let controller = RankingController(language: .en, api: try api(), settings: settings("mid"))
            controller.beginRound(iconCount: 15); controller.markShotStarted(); controller.setEnabled(true)
            controller.submit(elapsed: 40, iconCount: 15, shots: 10)
            try await Task.sleep(nanoseconds: 150_000_000)
            try require(!RankingMockProtocol.requests.contains { $0.path == "/v1/round/start" || $0.path == "/v1/round/finish" })
            try require(controller.lastOutcome == nil)
            controller.setEnabled(false)
        }
        await check("opting out cancels pending work and prevents subsequent upload") {
            RankingMockProtocol.configure { request in
                switch request.path {
                case "/v1/device/register": return MockReply(["device_id": credentials.deviceID, "secret": credentials.secret])
                case "/v1/round/start": return MockReply(["round_id": "late-round"], delay: 0.4)
                default: return MockReply(validBoard)
                }
            }
            let controller = RankingController(language: .en, api: try api(), settings: settings("cancel"))
            controller.beginRound(iconCount: 15); controller.setEnabled(true)
            try await wait({ RankingMockProtocol.requests.contains { $0.path == "/v1/round/start" } })
            controller.setEnabled(false)
            controller.submit(elapsed: 50, iconCount: 15, shots: 10)
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(!controller.isEnabled && controller.statusCode == "off" && controller.lastOutcome == nil)
            try require(!RankingMockProtocol.requests.contains { $0.path == "/v1/round/finish" })
        }
        await check("unauthorized credentials register again once before retrying") {
            var starts = 0, registrations = 0
            RankingMockProtocol.configure { request in
                switch request.path {
                case "/v1/device/register": registrations += 1; return MockReply(["device_id": credentials.deviceID, "secret": credentials.secret])
                case "/v1/round/start":
                    starts += 1
                    return starts == 1 ? MockReply(["error": "unauthorized"], status: 401) : MockReply(["round_id": "retried-round"])
                default: return MockReply(validBoard)
                }
            }
            let controller = RankingController(language: .en, api: try api(), settings: settings("retry"))
            controller.beginRound(iconCount: 15); controller.setEnabled(true)
            try await wait({ controller.statusCode == "prepared" })
            try require(starts == 2 && registrations == 2)
            controller.setEnabled(false)
        }
        await check("restart during registration reuses consented credentials without stale scores") {
            RankingMockProtocol.configure { request in
                switch request.path {
                case "/v1/device/register": return MockReply(["device_id": credentials.deviceID, "secret": credentials.secret], delay: 0.2)
                case "/v1/round/start": return MockReply(["round_id": "current-round"])
                default: return MockReply(validBoard)
                }
            }
            let store = settings("restart")
            let controller = RankingController(language: .en, api: try api(), settings: store)
            controller.beginRound(iconCount: 15); controller.setEnabled(true)
            try await wait({ RankingMockProtocol.requests.contains { $0.path == "/v1/device/register" } })
            controller.beginRound(iconCount: 20)
            try await wait({ controller.statusCode == "prepared" })
            try require(RankingMockProtocol.requests.filter { $0.path == "/v1/device/register" }.count == 1)
            try require(store.preferences.credentials == credentials)
            controller.setEnabled(false)
        }
        await check("first accepted shot retries a failed initial round preparation") {
            var starts = 0
            RankingMockProtocol.configure { request in
                switch request.path {
                case "/v1/device/register": return MockReply(["device_id": credentials.deviceID, "secret": credentials.secret])
                case "/v1/round/start":
                    starts += 1
                    return starts == 1 ? MockReply(["error": "busy"], status: 503) : MockReply(["round_id": "recovered-round"])
                case "/v1/round/finish": return MockReply(validFinish)
                default: return MockReply(validBoard)
                }
            }
            let controller = RankingController(language: .zhHans, api: try api(), settings: settings("first-shot-retry"))
            controller.beginRound(iconCount: 15); controller.setEnabled(true)
            try await wait({ controller.statusCode == "error" })
            controller.markShotStarted()
            try await wait({ controller.statusCode == "prepared" })
            controller.submit(elapsed: 45.123, iconCount: 15, shots: 10)
            try await wait({ controller.lastOutcome != nil })
            try require(starts == 2 && controller.lastOutcome?.rank == 20)
            controller.setEnabled(false)
        }
        await check("first shot shares an in-flight start instead of creating duplicate rounds") {
            RankingMockProtocol.configure { request in
                switch request.path {
                case "/v1/device/register": return MockReply(["device_id": credentials.deviceID, "secret": credentials.secret])
                case "/v1/round/start": return MockReply(["round_id": "shared-round"], delay: 0.25)
                default: return MockReply(validBoard)
                }
            }
            let controller = RankingController(language: .en, api: try api(), settings: settings("inflight-start"))
            controller.beginRound(iconCount: 15); controller.setEnabled(true)
            try await wait({ RankingMockProtocol.requests.contains { $0.path == "/v1/round/start" } })
            controller.markShotStarted()
            try await wait({ controller.statusCode == "prepared" })
            controller.updateLanguage(.zhHans)
            try require(controller.statusCode == "prepared" && controller.isEnabled)
            try require(RankingMockProtocol.requests.filter { $0.path == "/v1/round/start" }.count == 1)
            controller.setEnabled(false)
        }
        try? FileManager.default.removeItem(at: root)
        print("\(passed) ranking checks passed; \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}
