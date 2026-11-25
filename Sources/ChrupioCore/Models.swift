import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable {
    case meet, teams, slack, zoom, other

    public var displayName: String {
        switch self {
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .slack: "Slack Huddle"
        case .zoom: "Zoom"
        case .other: "Meeting"
        }
    }
}

public enum Speaker: Codable, Sendable, Hashable {
    /// The local user (microphone track).
    case me
    /// Someone else on the call (system/app audio track). Name is set when attribution is possible.
    case remote(String?)

    public var label: String {
        switch self {
        case .me: "You"
        case .remote(let name): name ?? "Others"
        }
    }

    public var isMe: Bool { if case .me = self { true } else { false } }
}

/// One spoken word with its time; seconds from meeting start once in a `TranscriptSegment`.
public struct TimedWord: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Seconds from meeting start.
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Speaker
    public var text: String
    /// Voice features of a remote segment (see `VoiceFeatures`), used to tell speakers apart when no live signal named them.
    public var voice: [Float]?
    /// Word times from whisper, used to split a line where the speaker changes; nil in older files.
    public var words: [TimedWord]?

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, speaker: Speaker, text: String, voice: [Float]? = nil, words: [TimedWord]? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.voice = voice
        self.words = words
    }
}

/// Named speakers observed as active at a moment of the meeting (from the browser extension or Zoom), or from
/// `time` to `end` when the same people were reported throughout (see `SpeakerRun`).
public struct SpeakerEvent: Codable, Sendable, Hashable {
    public var time: TimeInterval
    public var names: [String]
    /// The last report of the same names; nil for a single report (all meetings recorded before runs).
    public var end: TimeInterval?

    public init(time: TimeInterval, names: [String], end: TimeInterval? = nil) {
        self.time = time
        self.names = names
        self.end = end
    }

    public var lastSeen: TimeInterval { end ?? time }

    /// Seconds of `start...end` this event says its names were talking: each report stands for
    /// `SpeakerAttribution.eventReach` either side of its moment, `indicatorLag` earlier.
    public func overlap(start: TimeInterval, end: TimeInterval) -> TimeInterval {
        let lag = SpeakerAttribution.indicatorLag, reach = SpeakerAttribution.eventReach
        return min(end, lastSeen - lag + reach) - max(start, time - lag - reach)
    }

    /// The event moved `offset` seconds later (negative: earlier).
    public func shifted(by offset: TimeInterval) -> SpeakerEvent {
        SpeakerEvent(time: time + offset, names: names, end: end.map { $0 + offset })
    }

    /// When an extension event was sent (`ts`, Unix milliseconds); the arrival time when it has none or the
    /// clocks disagree by more than a few seconds.
    public static func date(ts: Double?, received: Date) -> Date {
        guard let ts else { return received }
        let sent = Date(timeIntervalSince1970: ts / 1000)
        return abs(sent.timeIntervalSince(received)) < 5 ? sent : received
    }
}

public struct MeetingSummary: Codable, Sendable, Hashable {
    public var markdown: String
    public var model: String
    public var createdAt: Date
    /// The checklist's items with their source quote and confidence; nil in summaries saved before these existed
    /// and in free-text ones. Done states live in `markdown`.
    public var actionItems: [SummaryActionItem]?
    /// Why Claude didn't write this summary ("Claude: session limit (...); local model used"); only on summaries
    /// written before summaries became Claude-only.
    public var fallbackReason: String?
    /// What may be missing from this summary (a part whose notes couldn't be read); nil when
    /// nothing is.
    public var warnings: [String]?
    /// A short title Claude suggested because the meeting's own was a generic fallback ("Browser call"); nil otherwise.
    public var suggestedTitle: String?
    /// The template (`SummaryTemplate.rawValue`) this summary was written with; nil for the default.
    public var template: String?

    public init(markdown: String, model: String, createdAt: Date = Date(), actionItems: [SummaryActionItem]? = nil) {
        self.markdown = markdown
        self.model = model
        self.createdAt = createdAt
        self.actionItems = actionItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Summaries saved before the summary-field cleanup are fixed whenever they are read.
        markdown = Self.tidied(try container.decode(String.self, forKey: .markdown))
        model = try container.decode(String.self, forKey: .model)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        actionItems = try container.decodeIfPresent([SummaryActionItem].self, forKey: .actionItems)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
        suggestedTitle = try container.decodeIfPresent(String.self, forKey: .suggestedTitle)
        template = try container.decodeIfPresent(String.self, forKey: .template)
    }

    /// Drops the headings and lists a small model stuffed into the "## Summary" paragraph; the sections after it
    /// already hold them. An emptied paragraph is rebuilt from the key points.
    static func tidied(_ stored: String) -> String {
        // "- - point", "- [ ] - task": the model bulleted its own list items.
        let markdown = Summarizer.tidyActionItems(stored.replacingOccurrences(of: #"(?m)^(- (?:\[[ xX]\] )?)(?:(?:[-*•]|\d+[.)])\s+)+"#, with: "$1", options: .regularExpression))
        // "## Podsumowanie": Polish summaries have localized headings (`SummaryHeadings`).
        let heading = ["## Summary\n", "## Podsumowanie\n"].first(where: markdown.hasPrefix) ?? "## Summary\n"
        guard markdown.hasPrefix(heading),
              let end = markdown.range(of: "\n\n## ", range: markdown.index(markdown.startIndex, offsetBy: heading.count)..<markdown.endIndex)
        else { return markdown }
        let original = String(markdown[markdown.index(markdown.startIndex, offsetBy: heading.count)..<end.lowerBound])
        var prose = original.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"(?i)^\s*#{1,6}\s*(?:summary|podsumowanie)\b:?\s*"#, with: "", options: .regularExpression)
        if let heading = prose.range(of: #"(?:^|\s)#{1,6}\s"#, options: .regularExpression) {
            prose = String(prose[..<heading.lowerBound])
        }
        prose = prose.trimmingCharacters(in: .whitespaces)
        if prose.isEmpty {
            let rest = markdown[end.upperBound...]
            guard rest.hasPrefix("Key points\n") || rest.hasPrefix("Najważniejsze punkty\n") else { return markdown }
            prose = rest.split(separator: "\n").dropFirst().prefix { $0.hasPrefix("- ") }
                .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
                .filter { $0.lowercased() != "none recorded" }
                .map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? $0 : $0 + "." }
                .joined(separator: " ")
            guard !prose.isEmpty else { return markdown }
        }
        return prose == original ? markdown : heading + prose + markdown[end.lowerBound...]
    }
}

/// A note added to a meeting after the fact, e.g. by Claude Code. Never part of the transcript.
public struct MeetingNote: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var author: String
    public var text: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), author: String, text: String) {
        self.id = id
        self.createdAt = createdAt
        self.author = author
        self.text = text
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, transcribing, summarizing, done, failed
}

public struct Meeting: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var platform: Platform
    public var startedAt: Date
    public var endedAt: Date?
    public var attendees: [String]
    public var selfName: String?
    public var url: String?
    public var segments: [TranscriptSegment]
    public var speakerEvents: [SpeakerEvent]
    public var summary: MeetingSummary?
    public var status: MeetingStatus
    public var error: String?
    /// Spoken language as detected by whisper (ISO code), pinned after the first chunks.
    public var language: String?
    /// Notes added after the meeting; nil in files written before notes existed.
    public var notes: [MeetingNote]?
    /// People the project context expects in this kind of meeting (its profile's attendees). Candidates when naming
    /// voices, not attendees: nobody here is listed as present unless heard or reported by the call.
    public var expectedAttendees: [String]?
    /// The diarizer's voice embedding behind each remote label ("Speaker 2" included), so naming a voice by hand can
    /// teach its print. Nil when the meeting was not diarized.
    public var speakerVoices: [String: [Float]]?
    /// Set while the summary failed and waits for an automatic retry; nil once one is written.
    public var summaryPending: SummaryPending?
    /// The `error` the last failed summary left, so a later summary clears it even after a restart; nil otherwise.
    public var summaryError: String?
    /// What the user typed in the meeting window during or after the call: the outline the summary follows.
    public var typedNotes: String?
    /// True for a call too short to summarize (`MeetingFragment`): no summary is written, and the meeting window
    /// offers to merge it into a neighbour or delete it. Nil otherwise.
    public var fragment: Bool?
    /// The summary template picked by hand (`SummaryTemplate.rawValue`); nil picks one from the title.
    public var summaryTemplate: String?
    /// Which engine transcribed how many chunks, and how long it took; nil for meetings transcribed before this was recorded.
    public var transcriptionStats: TranscriptionStats?

    public init(
        id: UUID = UUID(),
        title: String,
        platform: Platform,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        attendees: [String] = [],
        selfName: String? = nil,
        url: String? = nil,
        segments: [TranscriptSegment] = [],
        speakerEvents: [SpeakerEvent] = [],
        summary: MeetingSummary? = nil,
        status: MeetingStatus = .recording,
        error: String? = nil,
        language: String? = nil,
        notes: [MeetingNote]? = nil
    ) {
        self.id = id
        self.title = title
        self.platform = platform
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attendees = attendees
        self.selfName = selfName
        self.url = url
        self.segments = segments
        self.speakerEvents = speakerEvents
        self.summary = summary
        self.status = status
        self.error = error
        self.language = language
        self.notes = notes
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Adds names not yet present, keeping first-seen order and ignoring case and accent differences.
    /// Role markers are stripped ("Marek Unverified" > "Marek"); UI text and the user are left out.
    public mutating func mergeAttendees(_ names: [String]) {
        var seen = Set(attendees.map(PersonName.key))
        for name in names {
            let trimmed = Meeting.conversationName(PersonName.stripMarkers(Meeting.profileLinkName(name) ?? name))
            guard !trimmed.isEmpty, !Meeting.isUIText(trimmed), !isSelf(trimmed) else { continue }
            guard seen.insert(PersonName.key(trimmed)).inserted else {
                // "PiotrMazur" first, "Piotr Mazur" later: keep the spaced spelling.
                if let index = attendees.firstIndex(where: { PersonName.key($0) == PersonName.key(trimmed) }),
                   !attendees[index].contains(" "), trimmed.contains(" ") { attendees[index] = trimmed }
                continue
            }
            attendees.append(trimmed)
        }
    }

    /// Slack's "View Adam Nowicki’s Profile" button names a person; keep the name, not the button text.
    static func profileLinkName(_ label: String) -> String? {
        guard let match = profileLink.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let range = Range(match.range(at: 1), in: label) else { return nil }
        return String(label[range])
    }

    /// Slack's DM huddle title "Conversation with Piotr Sadowski" names the other person.
    static func conversationName(_ label: String) -> String {
        guard let match = label.wholeMatch(of: /(?i)conversation with (.+)/) else { return label }
        return String(match.1).trimmingCharacters(in: .whitespaces)
    }

    static let profileLink = try! NSRegularExpression(pattern: #"^View (.+?)[’']s Profile$"#)

    /// Meeting-app labels the extension sometimes reports as names, mirrored from
    /// `isJunkName` in extension/content/common.js.
    static let uiLabels: Set<String> = [
        "stickers", "emoji", "emojis", "effects", "visual effects", "backgrounds",
        "backgrounds and effects", "apply visual effects", "filters", "appearance",
        "send a reaction", "reactions", "hand raise", "raise hand", "activities", "polls",
        "q&a", "breakout rooms", "whiteboard", "recording", "transcript", "gemini",
        "take notes with gemini", "meeting details", "meeting tools", "host controls",
        "present now", "captions", "chat", "people", "participants", "everyone",
        "more options", "presentation", "channels and direct messages", "you", "(you)", "others", "unknown", "all"
    ]

    /// Meeting bots that join as participants ("Fireflies.ai Notetaker Łukasz", "Diego's Grain Notetaker").
    static let botWords = ["notetaker", "fireflies", "otter", "grain", "fathom"]

    /// True for UI text rather than a person: a known label, an emoji code ("raised_hand::skin-tone-2"), a lowercase
    /// slug ("acme-pl"), a notetaker bot, more than 4 words, or a
    /// sentence ending in "." after a full word ("Others might still see your full video.").
    /// Initials and abbreviations ("Anna K.", "John Smith Jr.") still count as names.
    public static func isUIText(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if uiLabels.contains(trimmed.lowercased()) { return true }
        if trimmed.contains("::") || trimmed.wholeMatch(of: /[a-z0-9]+(?:[-_][a-z0-9]+)+/) != nil { return true }
        // Whole words, so "Harry Potter" is not taken for Otter.
        let tokens = trimmed.lowercased().components(separatedBy: CharacterSet.letters.inverted)
        if tokens.contains(where: botWords.contains) { return true }
        // Slack sidebar text: "View Adam's Profile", "Channel team-ops (private)".
        if trimmed.wholeMatch(of: /(?i)view .+['’]s profile/) != nil || trimmed.wholeMatch(of: /(?i)channel .+\(private\)/) != nil {
            return true
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count > 4 { return true }
        guard let last = words.last, let end = trimmed.last else { return false }
        if "!?…".contains(end) { return true }
        if end == "." {
            return last.trimmingCharacters(in: CharacterSet(charactersIn: ".")).count > 3
        }
        return false
    }
}
