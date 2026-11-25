import Darwin
import Foundation
import Security

/// The app's local edit API: `chrupio-mcp` sends meeting edits to the running app so its window
/// updates at once and its in-memory copy never overwrites them. Authenticated by a token file only
/// this user can read, sent only to the port the running app recorded; requests from web pages (which carry an Origin header) are refused.
public enum LocalAPI {
    public static let editPath = "/v1/meetings/edit"

    public struct EditRequest: Codable, Sendable, Equatable {
        public var id: UUID
        public var edit: MeetingEdit
        public init(id: UUID, edit: MeetingEdit) {
            self.id = id
            self.edit = edit
        }
    }

    public struct EditResponse: Codable, Sendable, Equatable {
        public var ok: Bool
        public var message: String
        public init(ok: Bool, message: String) {
            self.ok = ok
            self.message = message
        }
    }

    public static var tokenFile: URL { AppPaths.support.appendingPathComponent("local-api-token") }

    /// Creates the token on first use; the app calls this at launch. An existing token file of this account is kept
    /// and reset to 0600; a link or someone else's file in its place is replaced by a new token (the link's target is
    /// never read or changed). Nil when the system can't produce random bytes or the file can't be written: then the
    /// edit API stays off and `chrupio-mcp` writes files directly, as when the app is closed.
    public static func ensureToken(at file: URL = tokenFile,
                                   random: (inout [UInt8]) -> OSStatus = { SecRandomCopyBytes(kSecRandomDefault, $0.count, &$0) }) -> String? {
        var info = stat()
        if lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() {
            // AT_SYMLINK_NOFOLLOW: a file swapped for a link after the lstat still doesn't change the link's target.
            _ = fchmodat(AT_FDCWD, file.path, 0o600, AT_SYMLINK_NOFOLLOW)
            if let existing = try? readToken(at: file) { return existing }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard random(&bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Renames over whatever was there, a link included, so the new token never lands in a link's target.
            // A folder in its place stays: the rename fails and the edit API stays off.
            try FilePermissions.writePrivately(Data(token.utf8), to: file)
        } catch {
            CoreLog.localAPI.error("couldn't write the edit API token at \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return try? readToken(at: file)
    }

    /// The token, nil when there is none. Throws `FilePermissions.UnsafeFile` when the file is a link, belongs to
    /// another account or other accounts can read it: then the token is never sent.
    public static func readToken(at file: URL = tokenFile, owner: uid_t = getuid()) throws -> String? {
        guard let data = try FilePermissions.readPrivately(file, owner: owner),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 32 else { return nil }
        return token
    }

    /// Written by the app once its listener is ready, so `chrupio-mcp` sends the token only to the running app,
    /// never to another program on its port.
    public static var endpointFile: URL { AppPaths.support.appendingPathComponent("local-api-endpoint") }

    private struct Endpoint: Codable { var port: UInt16; var pid: Int32 }

    /// The app calls this once its listener is ready. Throws when the file can't be written, a folder in its place included.
    public static func recordEndpoint(port: UInt16, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                      at file: URL = endpointFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FilePermissions.writePrivately(try JSONEncoder().encode(Endpoint(port: port, pid: pid)), to: file)
    }

    /// Removes the file whatever it records. Removes a link itself, never its target.
    public static func clearEndpoint(at file: URL = endpointFile) {
        unlink(file.path)
    }

    /// The app calls this before it starts listening: removes a file left by a crash, so chrupio-mcp never sends to a
    /// port this copy hasn't opened, but keeps the file of another Chrupio of this account that is still running (a
    /// second copy started next to it). True when the file is gone.
    @discardableResult
    public static func clearStaleEndpoint(at file: URL = endpointFile,
                                          ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                          process: (Int32) -> ProcessIdentity? = identify) -> Bool {
        if let live = try? trustedEndpoint(at: file, process: process), live.pid != ownPid { return false }
        clearEndpoint(at: file)
        return true
    }

    /// The app calls this when it quits or its listener fails: removes the file only when this process wrote it, so
    /// a second copy quitting never hides the running app. True when it removed the file.
    @discardableResult
    public static func clearOwnEndpoint(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                        at file: URL = endpointFile) -> Bool {
        guard let data = try? FilePermissions.readPrivately(file),
              let recorded = try? JSONDecoder().decode(Endpoint.self, from: data),
              recorded.pid == pid else { return false }
        return unlink(file.path) == 0
    }

    /// A running process: its executable and the account it runs as.
    public struct ProcessIdentity: Sendable, Equatable {
        public var path: String
        public var uid: uid_t
        public init(path: String, uid: uid_t) {
            self.path = path
            self.uid = uid
        }
    }

    /// The executable and owner of a running process, nil when there is none or the system won't say.
    public static func identify(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(path: String(decoding: buffer.prefix(Int(length)), as: UTF8.self), uid: info.pbi_uid)
    }

    /// The recorded endpoint when its process is still a running Chrupio of `owner`'s account.
    private static func trustedEndpoint(at file: URL, process: (Int32) -> ProcessIdentity?,
                                        owner: uid_t = getuid()) throws -> Endpoint? {
        guard let data = try FilePermissions.readPrivately(file, owner: owner),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
              endpoint.port != 0,
              let running = process(endpoint.pid),
              running.uid == owner,
              URL(fileURLWithPath: running.path).lastPathComponent == "Chrupio" else { return nil }
        return endpoint
    }

    /// The port to send the token to: only when the app recorded it and that process is still a running Chrupio of
    /// this account. Nil when there is no such file, it holds something else, or the process is gone, isn't Chrupio or
    /// runs as another account. Throws `FilePermissions.UnsafeFile` when the file is a link or a folder, belongs to
    /// another account or other accounts can read it.
    public static func endpoint(at file: URL = endpointFile, process: (Int32) -> ProcessIdentity? = identify,
                                owner: uid_t = getuid()) throws -> UInt16? {
        try trustedEndpoint(at: file, process: process, owner: owner)?.port
    }

    /// What `send` says when the token or endpoint file is unsafe to use. The edit was never sent.
    static func unsentMessage(_ error: Error) -> String {
        if let unsafe = error as? FilePermissions.UnsafeFile, unsafe.reason == .folder {
            return "Chrupio didn't send the edit to the app: \(unsafe.path) is a folder. Delete it, then quit and reopen Chrupio."
        }
        return "Chrupio didn't send the edit to the app: \(error.localizedDescription). Quit and reopen Chrupio to fix it."
    }

    /// Compares without stopping at the first differing byte.
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public enum SendOutcome: Sendable, Equatable {
        case applied(String)
        /// The app answered and refused the edit (bad input, meeting busy).
        case rejected(String)
        /// The app doesn't know this meeting (it uses another meetings folder).
        case notFound
        /// The app recorded no port, its process is gone, nothing listens, or no token exists: the app isn't running.
        case appNotRunning
        case failed(String)
    }

    /// Sends one edit to the app and waits up to `timeout` + 0.5 s, so a stuck app blocks an MCP call for 2.5 s at most.
    /// The token goes only to the port the running app recorded, never to whatever else listens on 47811.
    public static func send(_ request: EditRequest, tokenFile: URL = tokenFile, endpointFile: URL = endpointFile,
                            process: (Int32) -> ProcessIdentity? = identify, timeout: TimeInterval = 2) -> SendOutcome {
        let port: UInt16, token: String
        do {
            guard let recorded = try endpoint(at: endpointFile, process: process),
                  let saved = try readToken(at: tokenFile) else { return .appNotRunning }
            (port, token) = (recorded, saved)
        } catch {
            return .failed(unsentMessage(error))
        }
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(editPath)")!, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try? JSONEncoder().encode(request)

        let box = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]  // loopback only, never through a proxy
        let session = URLSession(configuration: configuration)
        session.dataTask(with: urlRequest) { data, response, error in
            defer { done.signal() }
            if let error = error as? URLError {
                box.value = [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code)
                    ? .appNotRunning : .failed("Chrupio didn't answer: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { try? JSONDecoder().decode(EditResponse.self, from: $0) }
            switch status {
            case 200: box.value = .applied(body?.message ?? "Done.")
            case 404 where body != nil: box.value = .notFound
            case 401: box.value = .failed("Chrupio refused the edit: the access token doesn't match. Quit and reopen Chrupio.")
            case 404: box.value = .failed("This version of Chrupio can't take edits; update the app with scripts/install.sh.")
            default: box.value = .rejected(body?.message ?? "Chrupio couldn't apply the edit (HTTP \(status)).")
            }
        }.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut { return .failed("Chrupio didn't answer in time.") }
        session.finishTasksAndInvalidate()
        return box.value
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SendOutcome = .failed("No response.")
        var value: SendOutcome {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
