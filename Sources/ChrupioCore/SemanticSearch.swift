import Foundation
import NaturalLanguage
import os

/// Turns a passage into a vector. The real one is Apple's on-device `NLContextualEmbedding`; tests use a fake.
public protocol TextEmbedder: Sendable {
    /// Names the model and its revision; an index built by another model is rebuilt.
    var identifier: String { get }
    /// Throws `EmbeddingUnavailable` when the model can't run (assets not downloaded, no model for the script).
    func embed(_ text: String) throws -> [Float]
}

public struct EmbeddingUnavailable: LocalizedError, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Apple's multilingual contextual embedding for Latin-script languages (Polish and English among them).
/// Token vectors are mean-pooled into one vector per passage. The model asset is downloaded by macOS on first
/// request; until it is there, `embed` throws `EmbeddingUnavailable` and asks the OS to fetch it.
public final class AppleContextualEmbedder: TextEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var model: NLContextualEmbedding?
    private var requested = false
    public let identifier: String

    public init() {
        let probe = NLContextualEmbedding(script: .latin)
        identifier = "apple-nlce-latin/" + (probe.map { "\($0.modelIdentifier)/r\($0.revision)" } ?? "none")
    }

    private func loaded() throws -> NLContextualEmbedding {
        if let model { return model }
        guard let embedding = NLContextualEmbedding(script: .latin) else {
            throw EmbeddingUnavailable("This Mac has no on-device text embedding model for Latin-script languages.")
        }
        guard embedding.hasAvailableAssets else {
            if !requested {
                requested = true
                embedding.requestAssets { result, error in
                    CoreLog.semantic.info("embedding asset request: \(String(describing: result), privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
                }
            }
            throw EmbeddingUnavailable("The on-device embedding model isn't downloaded yet; macOS is fetching it. Try again in a few minutes.")
        }
        do { try embedding.load() } catch {
            throw EmbeddingUnavailable("The on-device embedding model failed to load: \(error.localizedDescription)")
        }
        model = embedding
        return embedding
    }

    public func embed(_ text: String) throws -> [Float] {
        try lock.withLock {
            let model = try loaded()
            let result = try model.embeddingResult(for: text, language: nil)
            var sum = [Double](repeating: 0, count: model.dimension)
            var tokens = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for index in 0..<min(vector.count, sum.count) { sum[index] += vector[index] }
                tokens += 1
                return true
            }
            guard tokens > 0 else { return [] }
            return sum.map { Float($0 / Double(tokens)) }
        }
    }
}

/// Vectors for each finished meeting's summary and transcript passages, one compact binary file per meeting in a
/// folder next to the meetings folder (outside it, so writing the index doesn't wake the folder watch).
///
/// One file per meeting instead of SQLite: the app and the MCP helper both write it, and replacing a single file
/// atomically needs no shared database lock or schema; a search reads a few hundred small files and compares
/// vectors by brute force, which takes milliseconds at this scale. meeting.json is only ever read.
public final class SemanticIndex: @unchecked Sendable {
    public struct Passage: Equatable, Sendable {
        public var text: String
        /// Transcript time of the passage's first line; nil for the summary.
        public var start: TimeInterval?
    }

    public struct Hit: Equatable, Sendable {
        public var meetingID: UUID
        public var passage: Passage
        public var score: Float
    }

    struct Entry {
        var model: String
        var fingerprint: String
        var passages: [Passage]
        /// Unit-length vectors, one per passage.
        var vectors: [[Float]]
    }

    public let directory: URL
    public let embedder: TextEmbedder
    private let lock = NSLock()
    private var cache: [UUID: (modified: Date, entry: Entry)] = [:]

    /// Transcript lines per passage and how many of them the next passage repeats.
    static let windowLines = 8
    static let windowOverlap = 2
    /// The model reads about 256 tokens; longer passages are split so nothing is silently cut.
    static let maxPassageCharacters = 700

    public init(directory: URL, embedder: TextEmbedder) {
        self.directory = directory
        self.embedder = embedder
    }

    public static func url(nextTo store: MeetingStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent("semantic-index", isDirectory: true)
    }

    public static func standard(for store: MeetingStore) -> SemanticIndex {
        SemanticIndex(directory: url(nextTo: store), embedder: AppleContextualEmbedder())
    }

    func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).vec") }

    // MARK: Passages

    /// The summary (with the title, in sections) and the transcript in overlapping windows of grouped lines.
    public static func passages(for meeting: Meeting) -> [Passage] {
        var result: [Passage] = []
        if let markdown = meeting.summary?.markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var section = meeting.title
            for line in markdown.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A section holding only the title and headings goes on with the next line, so no passage is a bare heading.
                if section.count + line.count + 1 > maxPassageCharacters, !section.isEmpty, !isHeadingsOnly(section, title: meeting.title) {
                    result += split(section).map { Passage(text: $0, start: nil) }
                    section = ""
                }
                section += (section.isEmpty ? "" : "\n") + line
            }
            if !section.isEmpty { result += split(section).map { Passage(text: $0, start: nil) } }
        }
        let lines = TranscriptFormatter.grouped(meeting.segments).flatMap { segment in
            split("[\(TranscriptFormatter.timestamp(segment.start))] \(segment.speaker.label): \(segment.text)")
                .map { (text: $0, start: segment.start) }
        }
        var index = 0
        while index < lines.count {
            var text = ""
            var end = index
            while end < lines.count, end - index < windowLines,
                  text.isEmpty || text.count + lines[end].text.count + 1 <= maxPassageCharacters {
                text += (text.isEmpty ? "" : "\n") + lines[end].text
                end += 1
            }
            result.append(Passage(text: text, start: lines[index].start))
            if end >= lines.count { break }
            index = max(index + 1, end - windowOverlap)
        }
        return result
    }

    static func isHeadingsOnly(_ section: String, title: String) -> Bool {
        section.split(separator: "\n").allSatisfy { $0.hasPrefix("#") || String($0) == title }
    }

    /// Cuts text longer than a passage at word boundaries into parts of about equal length, so no part is a
    /// leftover word or two (a lone "elementów." matched every query).
    static func split(_ text: String) -> [String] {
        guard text.count > maxPassageCharacters else { return [text] }
        let parts = (text.count + maxPassageCharacters - 1) / maxPassageCharacters
        let limit = (text.count + parts - 1) / parts
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + word.count + 1 > limit {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
            while current.count > maxPassageCharacters {
                result.append(String(current.prefix(maxPassageCharacters)))
                current = String(current.dropFirst(maxPassageCharacters))
            }
        }
        // Words longer than the even share can leave a last word or two over; they join the part before when it fits.
        if let last = result.last, !current.isEmpty, last.count + current.count + 1 <= maxPassageCharacters {
            result[result.count - 1] += " " + current
        } else if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Changes whenever the embedded text or the model changes.
    func fingerprint(_ passages: [Passage]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (embedder.identifier + "\u{1}" + passages.map(\.text).joined(separator: "\u{2}")).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Building

    /// Whether the stored vectors match the meeting's current text and the current model.
    public func isCurrent(_ meeting: Meeting) -> Bool {
        guard let entry = entry(meeting.id) else { return false }
        return entry.model == embedder.identifier && entry.fingerprint == fingerprint(Self.passages(for: meeting))
    }

    /// Embeds the meeting when its text changed since it was last indexed. Returns whether it wrote the file.
    /// Meetings still recording or transcribing are skipped. Throws `EmbeddingUnavailable` when the model can't run.
    @discardableResult
    public func update(_ meeting: Meeting) throws -> Bool {
        guard MeetingExporter.isExportable(meeting) else { return false }
        let passages = Self.passages(for: meeting)
        let print = fingerprint(passages)
        if let entry = entry(meeting.id), entry.model == embedder.identifier, entry.fingerprint == print { return false }
        let vectors = try passages.map { Self.normalized(try embedder.embed($0.text)) }
        try write(Entry(model: embedder.identifier, fingerprint: print, passages: passages, vectors: vectors), for: meeting.id)
        return true
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
        lock.withLock { cache[id] = nil }
    }

    // MARK: Searching

    /// How much a passage containing every query word adds to its score. The contextual model alone ranks by
    /// style more than topic (every summary passage scored 0.80-0.89 on any query), so words the query and the
    /// passage share, in any Polish or English word form, decide between passages the model finds equally close.
    static let keywordWeight: Float = 0.3

    /// The best-matching passage of each indexed meeting among `meetings`, highest score first. Vectors are compared
    /// after removing their mean over the searched passages, which the model's vectors all share, then the
    /// keyword share (`keywordScore`) is added.
    public func search(_ query: String, in meetings: [Meeting], limit: Int) throws -> [Hit] {
        let raw = try embedder.embed(query)
        guard !raw.isEmpty else { return [] }
        let entries = meetings.compactMap { meeting -> (UUID, Entry)? in
            guard let entry = entry(meeting.id), entry.model == embedder.identifier else { return nil }
            return (meeting.id, entry)
        }
        var mean = [Float](repeating: 0, count: raw.count)
        var count = 0
        for (_, entry) in entries {
            for candidate in entry.vectors where candidate.count == raw.count {
                for dimension in 0..<raw.count { mean[dimension] += candidate[dimension] }
                count += 1
            }
        }
        // With a handful of passages the mean is most of each vector; only center a real library.
        if count < 20 { mean = [Float](repeating: 0, count: raw.count) } else { mean = mean.map { $0 / Float(count) } }
        let vector = Self.normalized(zip(Self.normalized(raw), mean).map { $0 - $1 })
        let terms = Self.terms(query)
        var hits: [Hit] = []
        for (id, entry) in entries {
            var best: (index: Int, score: Float)?
            for (index, candidate) in entry.vectors.enumerated() where candidate.count == vector.count {
                let centered = Self.normalized(zip(candidate, mean).map { $0 - $1 })
                var score: Float = 0
                for dimension in 0..<vector.count { score += vector[dimension] * centered[dimension] }
                score += Self.keywordWeight * Self.keywordScore(terms, in: entry.passages[index].text)
                if score > best?.score ?? -.infinity { best = (index, score) }
            }
            if let best { hits.append(Hit(meetingID: id, passage: entry.passages[best.index], score: best.score)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Words too common to say what a query is about.
    static let stopWords: Set<String> = ["the", "and", "for", "with", "about", "from", "that", "this", "dla", "oraz", "jak", "się", "nie", "jest",
                                         "czy", "przez", "przy", "pod", "nad", "albo", "lub", "tym", "tak"]

    /// The query's words as stems: lowercased without diacritics, the last two letters dropped from words of six or
    /// more (four letters kept at least), so "umowa" also finds "umowy" and "umowę", "klientem" finds "klienta".
    static func terms(_ query: String) -> [String] {
        words(query).filter { $0.count >= 2 && !stopWords.contains($0) }.map { word in
            word.count >= 6 ? String(word.prefix(max(4, word.count - 2))) : word.count == 5 ? String(word.prefix(4)) : word
        }.reduce(into: [String]()) { list, term in if !list.contains(term) { list.append(term) } }
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "ł", with: "l")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The share of `terms` some word of `text` starts with; 0 for none.
    static func keywordScore(_ terms: [String], in text: String) -> Float {
        guard !terms.isEmpty else { return 0 }
        let passage = Set(words(text))
        let found = terms.filter { term in passage.contains { $0.hasPrefix(term) } }.count
        return Float(found) / Float(terms.count)
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    // MARK: Storage
    // Format: "OKSV", UInt32 version 1, UInt32 header length, JSON header {model, fingerprint, dimension, passages},
    // then passages × dimension Float32, little-endian.

    private struct Header: Codable {
        var model: String
        var fingerprint: String
        var dimension: Int
        var passages: [String]
        var starts: [Double?]
    }

    func entry(_ id: UUID) -> Entry? {
        let url = file(for: id)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            lock.withLock { cache[id] = nil }
            return nil
        }
        if let cached = lock.withLock({ cache[id] }), cached.modified == modified { return cached.entry }
        guard let data = try? Data(contentsOf: url), let entry = Self.decode(data) else { return nil }
        lock.withLock { cache[id] = (modified, entry) }
        return entry
    }

    private func write(_ entry: Entry, for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(entry).write(to: file(for: id), options: .atomic)
        lock.withLock { cache[id] = nil }
    }

    static func encode(_ entry: Entry) throws -> Data {
        let dimension = entry.vectors.first?.count ?? 0
        let header = try JSONEncoder().encode(Header(model: entry.model, fingerprint: entry.fingerprint, dimension: dimension,
                                                     passages: entry.passages.map(\.text), starts: entry.passages.map(\.start)))
        var data = Data("OKSV".utf8)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(1)
        append(UInt32(header.count))
        data.append(header)
        for vector in entry.vectors {
            for value in vector { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    static func decode(_ data: Data) -> Entry? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("OKSV".utf8) else { return nil }
        func uint32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) } }
        guard uint32(4) == 1 else { return nil }
        let headerLength = Int(uint32(8))
        guard bytes.count >= 12 + headerLength,
              let header = try? JSONDecoder().decode(Header.self, from: Data(bytes[12..<(12 + headerLength)])),
              header.starts.count == header.passages.count else { return nil }
        var offset = 12 + headerLength
        guard bytes.count == offset + header.passages.count * header.dimension * 4 else { return nil }
        var vectors: [[Float]] = []
        for _ in header.passages {
            var vector = [Float](repeating: 0, count: header.dimension)
            for index in 0..<header.dimension {
                vector[index] = Float(bitPattern: uint32(offset))
                offset += 4
            }
            vectors.append(vector)
        }
        let passages = zip(header.passages, header.starts).map { Passage(text: $0, start: $1) }
        return Entry(model: header.model, fingerprint: header.fingerprint, passages: passages, vectors: vectors)
    }
}

/// Keeps the index current in the background: meetings are queued as they are saved or summarized, and the
/// existing library is backfilled at launch. Only reads meetings. Stops quietly while the model is unavailable
/// and resumes on the next request.
public final class SemanticIndexer: @unchecked Sendable {
    public let index: SemanticIndex
    private let queue = DispatchQueue(label: "chrupio.semantic-index", qos: .utility)
    private let lock = NSLock()
    /// The newest snapshot waiting per meeting, so a burst of saves embeds once.
    private var waiting: [UUID: Meeting] = [:]
    private var order: [UUID] = []
    private var running = false

    public init(index: SemanticIndex) { self.index = index }

    public func enqueue(_ meeting: Meeting) { enqueue([meeting]) }

    /// Queues meetings, newest first; ones already queued keep their place with the newer snapshot.
    public func enqueue(_ meetings: [Meeting]) {
        let start = lock.withLock { () -> Bool in
            for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) where MeetingExporter.isExportable(meeting) {
                if waiting[meeting.id] == nil { order.append(meeting.id) }
                waiting[meeting.id] = meeting
            }
            guard !running, !order.isEmpty else { return false }
            running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    /// Waits for the queued work; for tests.
    public func waitUntilIdle() {
        while lock.withLock({ running }) { queue.sync {} }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> Meeting? in
                guard !order.isEmpty else { running = false; return nil }
                return waiting.removeValue(forKey: order.removeFirst())
            }
            guard let meeting = next else { return }
            do {
                try autoreleasepool { _ = try index.update(meeting) }
            } catch let error as EmbeddingUnavailable {
                CoreLog.semantic.info("semantic index paused: \(error.reason, privacy: .public)")
                lock.withLock { waiting = [:]; order = []; running = false }
                return
            } catch {
                CoreLog.semantic.error("semantic index of \(meeting.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
