import Foundation
import Network

/// Event posted by the Chrome extension to `POST /v1/event`.
public struct ExtensionEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case meeting, ended }

    public var type: Kind
    public var platform: Platform
    public var tabId: Int
    /// When the tab joined this call (extension 0.2.3+), so back-to-back calls in one tab stay apart.
    public var callId: Int?
    public var url: String?
    public var title: String?
    public var inMeeting: Bool?
    public var participants: [String]?
    public var activeSpeakers: [String]?
    public var selfName: String?
    public var ts: Double?
    /// Manifest version of the extension that sent the event; nil from versions before 0.2.0.
    public var extensionVersion: String?
    /// What the page's selectors found (extension 0.3.0+), kept with the meeting to tune them after a call.
    public var probe: AnyJSON?

    public init(type: Kind, platform: Platform, tabId: Int, callId: Int? = nil, url: String? = nil, title: String? = nil,
                inMeeting: Bool? = nil, participants: [String]? = nil, activeSpeakers: [String]? = nil,
                selfName: String? = nil, ts: Double? = nil) {
        self.type = type
        self.platform = platform
        self.tabId = tabId
        self.callId = callId
        self.url = url
        self.title = title
        self.inMeeting = inMeeting
        self.participants = participants
        self.activeSpeakers = activeSpeakers
        self.selfName = selfName
        self.ts = ts
    }

    /// How long a call with other people may go without one speaker event before the page's detection counts as broken.
    public static let speakerDetectionGrace: TimeInterval = 120

    /// Message when this tab names other participants but `speakerEventCount` events arrived in `elapsed` seconds;
    /// nil while detection may still be working. `diagnosticsSaved` (Settings > Save diagnostics) adds where probe.json is.
    public func missingSpeakersWarning(speakerEventCount: Int, elapsed: TimeInterval, diagnosticsSaved: Bool = true) -> String? {
        let others = (participants ?? []).filter { !$0.isEmpty && !PersonName.same($0, selfName) }
        guard speakerEventCount == 0, elapsed > Self.speakerDetectionGrace, !others.isEmpty else { return nil }
        return "The \(platform.displayName) tab lists \(others.count) participant(s) but no speaker was detected in "
            + "\(Int(elapsed / 60)) min, so the transcript won't name who spoke. Update the Chrupio Chrome extension"
            + (diagnosticsSaved ? "; probe.json in this meeting's folder shows what the page looked like." : ".")
    }
}

/// Any JSON value, for diagnostics passed through without a schema.
public indirect enum AnyJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([AnyJSON]), object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AnyJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: AnyJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Minimal HTTP server on 127.0.0.1 that receives meeting events from the Chrome extension.
public final class ExtensionServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47811

    private let port: UInt16
    private let version: String
    private let queue = DispatchQueue(label: "chrupio.extension-server")
    private var listener: NWListener?
    private let onEvent: @Sendable (ExtensionEvent) -> Void
    private let onHello: @Sendable (String?) -> Void
    private let onSnapshot: @Sendable (Data) -> Void
    /// Handles `chrupio-mcp` edits (see LocalAPI); nil disables the route.
    public typealias EditHandler = @Sendable (LocalAPI.EditRequest) async -> (status: Int, response: LocalAPI.EditResponse)
    private let onEdit: EditHandler?
    private let apiToken: String?

    /// `onHello` receives the extension's version from its presence ping, sent even when no call is open.
    public init(port: UInt16 = ExtensionServer.defaultPort, version: String = "1.0",
                apiToken: String? = nil, onEdit: EditHandler? = nil,
                onHello: @escaping @Sendable (String?) -> Void = { _ in },
                onSnapshot: @escaping @Sendable (Data) -> Void = { _ in },
                onEvent: @escaping @Sendable (ExtensionEvent) -> Void) {
        self.port = port
        self.version = version
        self.apiToken = apiToken
        self.onEdit = onEdit
        self.onHello = onHello
        self.onSnapshot = onSnapshot
        self.onEvent = onEvent
    }

    /// How long `start` waits between tries while the port is busy: 0.5 s for the first 5 s, then 2 s, about a minute
    /// in all. A quick reopen or an update's relaunch finds the port held for up to 30 s by the connections the old copy
    /// closed (TIME_WAIT, 2 x net.inet.tcp.msl), since address reuse stays off.
    public static let bindRetryDelays: [TimeInterval] = Array(repeating: 0.5, count: 10) + Array(repeating: 2, count: 28)

    /// Why the server isn't listening. `couldNotListen`: the port stayed busy through every retry, or another error
    /// stopped the listener before it was ready. `stoppedListening`: the listener failed after it was ready.
    public enum Failure: Error, Equatable, Sendable {
        case couldNotListen(String)
        case stoppedListening(String)

        public var message: String {
            switch self {
            case .couldNotListen(let message), .stoppedListening(let message): return message
            }
        }
    }

    private let lock = NSLock()
    private var stopped = false
    private var boundPort: UInt16?

    /// The port the listener got (it differs from the requested one only when that was 0).
    var listeningPort: UInt16 { lock.withLock { boundPort } ?? port }

    /// Listens on 127.0.0.1 only, never sharing the port: address reuse is off, so a program already holding it
    /// keeps it. While the port is busy, tries again after each of `retryDelays`, on the server's queue, until `stop`.
    /// `onReady` gets the bound port once the listener accepts connections; `onFailure` is called once, only after the
    /// retries run out or the listener fails, never while retrying.
    public func start(retryDelays: [TimeInterval] = ExtensionServer.bindRetryDelays,
                      onReady: @escaping @Sendable (UInt16) -> Void = { _ in },
                      onFailure: @escaping @Sendable (Failure) -> Void = { _ in }) throws {
        lock.withLock {
            stopped = false
            boundPort = nil
        }
        try listen(retryDelays: retryDelays[...], onReady: onReady, onFailure: onFailure)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func listen(retryDelays: ArraySlice<TimeInterval>,
                        onReady: @escaping @Sendable (UInt16) -> Void, onFailure: @escaping @Sendable (Failure) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let requested = port
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, !self.isStopped else { return }
            func giveUpOrRetry(_ error: NWError) {
                listener.stateUpdateHandler = nil
                listener.cancel()
                let wasReady = self.lock.withLock {
                    defer { self.boundPort = nil }
                    return self.boundPort != nil
                }
                if wasReady { return onFailure(.stoppedListening(error.localizedDescription)) }
                guard Self.isAddressInUse(error), let delay = retryDelays.first else {
                    return onFailure(.couldNotListen(error.localizedDescription))
                }
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.isStopped else { return }
                    do {
                        try self.listen(retryDelays: retryDelays.dropFirst(), onReady: onReady, onFailure: onFailure)
                    } catch {
                        onFailure(.couldNotListen(error.localizedDescription))
                    }
                }
            }
            switch state {
            case .ready:
                let bound = listener.port?.rawValue ?? requested
                self.lock.withLock { self.boundPort = bound }
                onReady(bound)
            case .failed(let error):
                giveUpOrRetry(error)
            case .waiting(let error) where Self.isAddressInUse(error):
                giveUpOrRetry(error)
            default:
                break
            }
        }
        let cancelled = lock.withLock {
            if stopped { return true }
            self.listener = listener
            return false
        }
        if cancelled { return }
        listener.start(queue: queue)
    }

    static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    public func stop() {
        let listener = lock.withLock {
            stopped = true
            boundPort = nil
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
    }

    /// A client that connects and sends nothing (or too slowly) is dropped after this long.
    static let requestTimeout: TimeInterval = 5

    /// Whether the safety-net cancel still has work to do for a connection in this state.
    static func needsCancel(_ state: NWConnection.State) -> Bool {
        switch state {
        case .cancelled, .failed: return false
        default: return true
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Edits wait on the app's main thread; everything else answers at once.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout + 10) {
            // Most connections are closed long before this fires; cancelling again only logs noise.
            if Self.needsCancel(connection.state) { connection.cancel() }
        }
        receive(on: connection, buffer: Data(), deadline: Date().addingTimeInterval(Self.requestTimeout))
    }

    private func receive(on connection: NWConnection, buffer: Data, deadline: Date) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 1_000_000 || error != nil || Date() > deadline {
                connection.cancel()
                return
            }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request) where request.path == LocalAPI.editPath:
                Task {
                    let response = await self.respondToEdit(request)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            case .complete(let request):
                let response = self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            case .incomplete where !isComplete:
                self.receive(on: connection, buffer: buffer, deadline: deadline)
            case .incomplete, .invalid:
                connection.send(content: HTTPRequest.response(status: 400, body: #"{"ok":false}"#), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// The companion extension's origin. Its ID is fixed by the `key` in extension/manifest.json.
    public static let extensionOrigin = "chrome-extension://hahmnnliogjjencmgldchchjlcebkccc"

    /// Local edits come from `chrupio-mcp`, never from a browser: no Origin, a loopback Host
    /// (against DNS rebinding) and the token from the user's Application Support folder.
    func respondToEdit(_ request: HTTPRequest) async -> Data {
        func reply(_ status: Int, _ ok: Bool, _ message: String) -> Data {
            let body = (try? JSONEncoder().encode(LocalAPI.EditResponse(ok: ok, message: message))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return HTTPRequest.response(status: status, body: body)
        }
        guard request.method == "POST" else { return reply(405, false, "Use POST.") }
        guard request.headers["origin"] == nil else { return reply(403, false, "Browsers may not edit meetings.") }
        let host = request.headers["host"] ?? ""
        let port = listeningPort
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased()) else { return reply(403, false, "Bad host.") }
        let presented = request.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        guard let onEdit, let apiToken, let presented, LocalAPI.tokensMatch(presented, apiToken) else {
            return reply(401, false, "Not authorized.")
        }
        guard let edit = try? JSONDecoder().decode(LocalAPI.EditRequest.self, from: request.body) else {
            return reply(400, false, "Malformed edit.")
        }
        let result = await onEdit(edit)
        let body = (try? JSONEncoder().encode(result.response)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return HTTPRequest.response(status: result.status, body: body)
    }

    func respond(to request: HTTPRequest) -> Data {
        // Events start recordings, so only our extension may send them. Web pages and other extensions may not.
        let origin = request.headers["origin"]
        if let origin, origin != Self.extensionOrigin {
            return HTTPRequest.response(status: 403, body: #"{"ok":false,"error":"origin not allowed"}"#)
        }
        if request.method == "POST", origin == nil {
            return HTTPRequest.response(status: 403, body: #"{"ok":false,"error":"origin required"}"#)
        }
        let cors = request.headers["origin"]
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            return HTTPRequest.response(status: 204, body: "", allowOrigin: cors)
        case ("GET", "/health"):
            return HTTPRequest.response(status: 200, body: #"{"ok":true,"app":"Chrupio","version":"\#(version)"}"#, allowOrigin: cors)
        case ("POST", "/v1/event"):
            guard let event = try? JSONDecoder().decode(ExtensionEvent.self, from: request.body) else {
                return HTTPRequest.response(status: 400, body: #"{"ok":false,"error":"bad event"}"#, allowOrigin: cors)
            }
            onEvent(event)
            return HTTPRequest.response(status: 200, body: #"{"ok":true}"#, allowOrigin: cors)
        case ("POST", "/v1/hello"):
            struct Hello: Decodable { var extensionVersion: String? }
            onHello((try? JSONDecoder().decode(Hello.self, from: request.body))?.extensionVersion)
            return HTTPRequest.response(status: 200, body: #"{"ok":true}"#, allowOrigin: cors)
        case ("POST", "/v1/snapshot"):
            // Page structure from a call where no names were found, saved for selector tuning (see SnapshotStore).
            guard request.body.count <= SnapshotStore.maxBytes,
                  (try? JSONSerialization.jsonObject(with: request.body)) is [String: Any] else {
                return HTTPRequest.response(status: 400, body: #"{"ok":false,"error":"bad snapshot"}"#, allowOrigin: cors)
            }
            onSnapshot(request.body)
            return HTTPRequest.response(status: 200, body: #"{"ok":true}"#, allowOrigin: cors)
        default:
            return HTTPRequest.response(status: 404, body: #"{"ok":false}"#, allowOrigin: cors)
        }
    }
}

struct HTTPRequest {
    enum ParseResult { case complete(HTTPRequest), incomplete, invalid }

    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...1_000_000).contains(length) else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: path,
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)])
        ))
    }

    static func response(status: Int, body: String, allowOrigin: String? = nil) -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 422: "Unprocessable Content"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        if let allowOrigin {
            head += "Access-Control-Allow-Origin: \(allowOrigin)\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n"
        }
        return Data((head + "\r\n" + body).utf8)
    }
}

/// Structure snapshots of call pages where the extension found nobody, kept in Application Support for selector tuning.
/// Only the newest few are kept.
public struct SnapshotStore: Sendable {
    public static let maxBytes = 300_000
    public let directory: URL
    public var keep = 5

    public init(directory: URL) { self.directory = directory }

    public static var `default`: SnapshotStore {
        SnapshotStore(directory: AppPaths.support.appendingPathComponent("debug", isDirectory: true))
    }

    @discardableResult
    public func save(_ data: Data, platform: String, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let safePlatform = platform.filter { $0.isLetter }.prefix(12)
        let url = directory.appendingPathComponent("snapshot-\(stamp)-\(safePlatform.isEmpty ? "call" : String(safePlatform)).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        let old = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(keep)
        for file in old { try? fm.removeItem(at: file) }
        return url
    }
}

/// The newest extension probe and page snapshot per call (BrowserMeetingTracker key), so a meeting's probe.json gets
/// them even when they arrived before its recording started. Both are sent rarely: a probe every 30 s at most when it
/// changed (every 2 min unchanged), a snapshot 15 s into a call that shows nobody.
public struct CallDiagnostics: Sendable {
    public private(set) var probes: [String: AnyJSON] = [:]
    public private(set) var snapshots: [String: AnyJSON] = [:]
    private var order: [String] = []
    public var limit = 8

    public init() {}

    /// Call key and snapshot of a /v1/snapshot body; the key is nil from extensions before 0.4.3, which sent no tabId.
    public static func snapshotEntry(_ data: Data) -> (key: String?, snapshot: AnyJSON)? {
        guard case .object(let body)? = try? JSONDecoder().decode(AnyJSON.self, from: data),
              let snapshot = body["snapshot"] else { return nil }
        var key: String?
        if case .number(let tab)? = body["tabId"] {
            var call: Int?
            if case .number(let id)? = body["callId"] { call = Int(id) }
            key = BrowserMeetingTracker.key(tabId: Int(tab), callId: call)
        }
        return (key, snapshot)
    }

    public mutating func record(probe: AnyJSON, key: String) {
        probes[key] = probe
        touch(key)
    }

    public mutating func record(snapshot: AnyJSON, key: String) {
        snapshots[key] = snapshot
        touch(key)
    }

    /// probe.json entries for a call: "extension" (the probe) and "snapshot".
    public func entries(for key: String) -> [String: AnyJSON] {
        var out: [String: AnyJSON] = [:]
        if let probe = probes[key] { out["extension"] = probe }
        if let snapshot = snapshots[key] { out["snapshot"] = snapshot }
        return out
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let old = order.removeFirst()
            probes[old] = nil
            snapshots[old] = nil
        }
    }
}
