import Foundation

/// whisper.cpp's `whisper-server`, kept running while there are chunks to transcribe so the model loads once
/// instead of for every chunk. Started on the first chunk, stopped after `idleTimeout` without one.
/// A failure sends that chunk to `whisper-cli`; after `Health.maxConsecutiveFailures` in a row the chunks fail
/// instead, since every `whisper-cli` run reloads the model and a backlog would crawl.
public actor WhisperServer {
    public static let shared = WhisperServer()

    /// Long enough to cover the gap between chunks of one backlog; short, because the model holds about 600 MB.
    public static let idleTimeout: TimeInterval = 60
    /// Once broken, chunks fail for this long before the server is tried again.
    static let retryAfter: TimeInterval = 600

    /// What to do with a chunk the server didn't transcribe.
    public enum Outcome: Sendable {
        case served(Data)
        /// No whisper-server installed, or a failure below the limit: this chunk goes to `whisper-cli`.
        case fallBack
        /// Failed this many times in a row: the chunk fails with an error.
        case broken(failures: Int)
    }

    /// Consecutive failures and when the last one was.
    struct Health: Equatable {
        static let maxConsecutiveFailures = 3
        var failures = 0
        var failedAt: Date?

        var isBroken: Bool { failures >= Self.maxConsecutiveFailures }

        /// Whether to skip the server for now: broken and the retry pause not over.
        func waiting(now: Date) -> Bool {
            guard isBroken, let failedAt else { return false }
            return now.timeIntervalSince(failedAt) < WhisperServer.retryAfter
        }

        mutating func failed(at now: Date) -> Outcome {
            failures += 1
            failedAt = now
            return isBroken ? .broken(failures: failures) : .fallBack
        }

        mutating func succeeded() { self = Health() }
    }
    static let startTimeout: TimeInterval = 60

    /// What the server process was started with; another model or VAD setting needs a restart.
    struct Configuration: Equatable {
        var model: String
        var vadModel: String?
        var threads: Int
    }

    private struct Running {
        let configuration: Configuration
        let process: Process
        let baseURL: URL
    }

    private var running: Running?
    private var starting: Task<Running?, Never>?
    private var startingConfiguration: Configuration?
    private var health = Health()
    private var idleGeneration = 0
    /// For stopping synchronously when the app quits.
    private nonisolated let processBox = ProcessBox()

    public static func findWhisperServer() -> URL? {
        WhisperBinaries.find("whisper-server")
    }

    /// Server flags; matching `Transcriber.arguments` (beam search 5, best of 5, VAD padding) keeps the output the same.
    static func arguments(_ configuration: Configuration, port: Int) -> [String] {
        var arguments = [
            "-m", configuration.model,
            "--host", "127.0.0.1", "--port", String(port),
            "-t", String(configuration.threads),
            "-bs", "5", "-bo", "5",
            "-sns", "--carry-initial-prompt",
        ]
        if let vad = configuration.vadModel {
            arguments += ["--vad", "-vm", vad, "-vp", "200", "-vsd", "500"]
        }
        return arguments
    }

    /// Runs the server under a shell that stops it when this app exits, so a crash never leaves the model in memory.
    static let watchdog = """
    parent=$1; shift
    "$@" &
    child=$!
    trap 'kill $child 2>/dev/null; exit 0' TERM INT
    while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 1; done
    kill $child 2>/dev/null
    """

    /// whisper-cli-shaped JSON for the chunk, or what to do instead.
    func transcribe(wav: URL, configuration: Configuration, language: String, prompt: String?, timeout: TimeInterval) async -> Outcome {
        guard Self.findWhisperServer() != nil else { return .fallBack }
        if health.waiting(now: Date()) { return .broken(failures: health.failures) }
        guard let server = await server(for: configuration) else { return fail() }
        idleGeneration += 1
        defer { scheduleIdleStop() }
        do {
            let data = try await Self.post(wav: wav, to: server.baseURL, language: language, prompt: prompt, timeout: timeout)
            guard let converted = Self.cliJSON(fromServer: data, requestedLanguage: language) else { return fail() }
            health.succeeded()
            return .served(converted)
        } catch {
            return fail()
        }
    }

    /// Stops the server now (app quit). Safe from any thread.
    public nonisolated func terminate() {
        processBox.terminate()
    }

    private func fail() -> Outcome {
        stop()
        return health.failed(at: Date())
    }

    private func stop() {
        running?.process.terminate()
        running = nil
        processBox.set(nil)
    }

    private func scheduleIdleStop() {
        idleGeneration += 1
        let generation = idleGeneration
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            self.stopIfIdle(generation)
        }
    }

    private func stopIfIdle(_ generation: Int) {
        guard generation == idleGeneration else { return }
        stop()
    }

    private func server(for configuration: Configuration) async -> Running? {
        if let running, running.configuration == configuration, running.process.isRunning { return running }
        if let starting, startingConfiguration == configuration { return await starting.value }
        stop()
        let task = Task { await Self.start(configuration) }
        starting = task
        startingConfiguration = configuration
        let started = await task.value
        if startingConfiguration == configuration {
            starting = nil
            startingConfiguration = nil
        }
        running = started
        processBox.set(started?.process)
        return started
    }

    private static func start(_ configuration: Configuration) async -> Running? {
        guard let binary = findWhisperServer(), let port = freePort() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdog, "sh", String(ProcessInfo.processInfo.processIdentifier), binary.path]
            + arguments(configuration, port: port)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        // The port opens once the model is loaded.
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline, process.isRunning {
            if await isReady(baseURL) { return Running(configuration: configuration, process: process, baseURL: baseURL) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        process.terminate()
        return nil
    }

    private static func isReady(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// A port nothing listens on right now, from the system's ephemeral range.
    static func freePort() -> Int? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func post(wav: URL, to baseURL: URL, language: String, prompt: String?, timeout: TimeInterval) async throws -> Data {
        let boundary = "chrupio-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "verbose_json")
        field("language", language)
        if let prompt { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wav))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranscriberError.failed("whisper-server returned an error.") }
        return data
    }

    /// Turns the server's `verbose_json` into the `-ojf` shape `Transcriber.parse` reads: segments with millisecond
    /// offsets, words as tokens, and the detected language code (the top of `language_probabilities`).
    static func cliJSON(fromServer data: Data, requestedLanguage: String) -> Data? {
        struct Word: Decodable { let word: String; let start: Double; let end: Double }
        struct Segment: Decodable { let text: String; let start: Double; let end: Double; let words: [Word]?; let avg_logprob: Double? }
        struct Output: Decodable {
            let segments: [Segment]?
            let language_probabilities: [String: Double]?
            let error: String?
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data), output.error == nil, let segments = output.segments else { return nil }
        let milliseconds = { (seconds: Double) in Int((seconds * 1000).rounded()) }
        let transcription: [[String: Any]] = segments.map { segment in
            var item: [String: Any] = [
                "offsets": ["from": milliseconds(segment.start), "to": milliseconds(segment.end)],
                "text": segment.text,
                "tokens": (segment.words ?? []).map { ["text": $0.word, "offsets": ["from": milliseconds($0.start), "to": milliseconds($0.end)]] },
            ]
            if let logprob = segment.avg_logprob { item["avg_logprob"] = logprob }
            return item
        }
        let language = requestedLanguage != "auto" ? requestedLanguage
            : output.language_probabilities?.max(by: { $0.value < $1.value })?.key
        var object: [String: Any] = ["transcription": transcription]
        if let language { object["result"] = ["language": language] }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    func set(_ process: Process?) { lock.withLock { self.process = process } }
    func terminate() { lock.withLock { process?.terminate(); process = nil } }
}
