import Foundation

/// Project knowledge that improves transcripts and summaries: the words speech recognition gets wrong,
/// the people, the recurring meetings and the ticket key format. A JSON file the user points Settings at,
/// written by hand or by their own tooling; every field is optional.
public struct MeetingContext: Codable, Sendable, Equatable {
    public struct Person: Codable, Sendable, Equatable {
        public var name: String
        public var aliases: [String]?
        public var role: String?
        public var `internal`: Bool?
    }

    /// A recurring meeting, recognised by keywords in its title.
    public struct Profile: Codable, Sendable, Equatable {
        public var name: String
        /// Lowercase keywords; a title matches when it contains all of them.
        public var match: [String]
        public var attendees: [String]?
        public var topics: [String]?
        public var vocabulary: [String]?
        public var language: String?
        /// What the meeting is for, given to the summary model.
        public var about: String?
    }

    public var version: Int?
    public var vocabulary: [String]?
    /// Misheard word or phrase > the right one; whole words, any case.
    public var corrections: [String: String]?
    public var people: [Person]?
    public var profiles: [Profile]?
    /// How notes for this project are written, added to the summary instructions.
    public var summaryStyle: String?
    /// A few hundred words on the project, for the summary model (see MeetingContext+Summary.swift).
    public var brief: String?
    public var tickets: [Ticket]?
    public var workStreams: [WorkStream]?
    public var recentDecisions: [Decision]?
    public var contacts: [Contact]?

    /// The project's ticket key prefix, e.g. "PRJ" for PRJ-1234. Nil turns all ticket handling off.
    public var ticketPrefix: String?

    /// `ticketPrefix` when it is a usable key prefix, uppercased.
    public var resolvedTicketPrefix: String? { ticketPrefix.flatMap(Self.normalizedTicketPrefix) }

    /// "prj-" -> "PRJ". A letter, then 1 to 9 letters or digits; anything else is nil.
    public static func normalizedTicketPrefix(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces).uppercased()
        while value.hasSuffix("-") { value.removeLast() }
        return value.wholeMatch(of: /[A-Z][A-Z0-9]{1,9}/) != nil ? value : nil
    }

    public init(vocabulary: [String]? = nil, corrections: [String: String]? = nil, people: [Person]? = nil,
                profiles: [Profile]? = nil, summaryStyle: String? = nil) {
        self.version = 1
        self.vocabulary = vocabulary
        self.corrections = corrections
        self.people = people
        self.profiles = profiles
        self.summaryStyle = summaryStyle
    }

    public static func load(from url: URL) -> MeetingContext? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MeetingContext.self, from: $0) }
    }

    /// The recurring meeting a title belongs to; the profile with the most matching keywords wins.
    public func profile(for title: String) -> Profile? {
        let lower = title.lowercased()
        return (profiles ?? [])
            .filter { !$0.match.isEmpty && $0.match.allSatisfy { lower.contains($0.lowercased()) } }
            .max { $0.match.count < $1.match.count }
    }

    /// Terms for the whisper prompt: the meeting's own first, then the project's.
    public func terms(for title: String) -> [String] {
        var seen = Set<String>()
        return ((profile(for: title)?.vocabulary ?? []) + (vocabulary ?? [])).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Corrections turned around for Parakeet's vocabulary boosting: the right spelling > the misheard forms.
    public var boostAliases: [String: [String]] {
        var result: [String: [String]] = [:]
        for (wrong, right) in corrections ?? [:] {
            let wrong = wrong.trimmingCharacters(in: .whitespaces), right = right.trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !right.isEmpty, wrong.lowercased() != right.lowercased() else { continue }
            result[right, default: []].append(wrong)
        }
        return result.mapValues { $0.sorted() }
    }

    /// Fixes words speech recognition is known to get wrong in this project.
    public func correct(_ text: String) -> String {
        guard let corrections, !corrections.isEmpty else { return text }
        var result = text
        // Longer phrases first, so "Bar Tech" is fixed before a correction for "Bar".
        for (wrong, right) in corrections.sorted(by: { $0.key.count > $1.key.count }) where !wrong.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: right))
        }
        return result
    }

    /// Extra instructions for the summary: house style plus what this kind of meeting usually covers.
    public func summaryGuidance(for meeting: Meeting) -> String? {
        var parts: [String] = []
        if let style = summaryStyle?.trimmingCharacters(in: .whitespacesAndNewlines), !style.isEmpty {
            parts.append("House style for these notes: \(style)")
        }
        if let profile = profile(for: meeting.title) {
            var line = "This is a recurring meeting: \(profile.name)."
            if let attendees = profile.attendees, !attendees.isEmpty { line += " Usual attendees: \(attendees.joined(separator: ", "))." }
            // Usual topics are left out: small models listed them as key points of meetings that never discussed them.
            parts.append(line + " Use this only to spell names and terms correctly; report only what the transcript says.")
        }
        let terms = terms(for: meeting.title)
        if !terms.isEmpty { parts.append("Correct spellings of project terms: \(terms.prefix(60).joined(separator: ", ")).") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// Reloads a context file when it changes on disk.
public final class MeetingContextFile: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (path: String, modified: Date, context: MeetingContext?)?

    public init() {}

    public func context(at path: String) -> MeetingContext? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty,
              let modified = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.modificationDate] as? Date else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.path == expanded, cached.modified == modified { return cached.context }
        let context = MeetingContext.load(from: URL(fileURLWithPath: expanded))
        cached = (expanded, modified, context)
        return context
    }
}
