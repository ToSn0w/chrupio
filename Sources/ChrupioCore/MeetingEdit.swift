import Foundation

/// One change Claude Code (or the app) makes to a meeting. Applied by the app when it runs,
/// otherwise by `chrupio-mcp` directly under the store's write lock; both use `apply`.
public enum MeetingEdit: Codable, Sendable, Equatable {
    /// `item` is the 1-based action item number or text that identifies one item.
    case setActionItem(item: String, done: Bool)
    case addNote(text: String, author: String)
    case rename(title: String)
    case setSummary(markdown: String)
    /// Names a voice: every remote line labelled `speaker` (say "Speaker 2") becomes `name`.
    case assignSpeaker(speaker: String, name: String)

    public enum Failure: LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }

    static let maxTitle = 200
    static let maxNote = 10_000
    static let maxSummary = 50_000

    /// Changes `meeting` and returns a one-line description of what changed.
    public func apply(to meeting: inout Meeting, now: Date = Date()) throws -> String {
        switch self {
        case .setActionItem(let key, let done):
            guard let summary = meeting.summary else { throw Failure.invalid("\"\(meeting.title)\" has no summary, so it has no action items.") }
            let item = try ActionItem.find(key, in: summary.markdown)
            meeting.summary?.markdown = ActionItem.setting(item, done: done, in: summary.markdown)
            return "Marked action item \(item.number) \(done ? "done" : "open"): \(item.text)"

        case .addNote(let text, let author):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Failure.invalid("The note is empty.") }
            guard text.count <= Self.maxNote else { throw Failure.invalid("Notes are limited to \(Self.maxNote) characters.") }
            let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
            meeting.notes = (meeting.notes ?? []) + [MeetingNote(createdAt: now, author: author.isEmpty ? "Claude Code" : author, text: text)]
            return "Added a note to \"\(meeting.title)\"."

        case .rename(let title):
            let title = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { throw Failure.invalid("The title is empty.") }
            guard title.count <= Self.maxTitle else { throw Failure.invalid("Titles are limited to \(Self.maxTitle) characters.") }
            let old = meeting.title
            meeting.title = title
            return "Renamed \"\(old)\" to \"\(title)\"."

        case .setSummary(let markdown):
            let markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else { throw Failure.invalid("The summary is empty.") }
            guard markdown.count <= Self.maxSummary else { throw Failure.invalid("Summaries are limited to \(Self.maxSummary) characters.") }
            // The summarizer would overwrite the edit when it finishes.
            guard meeting.status != .summarizing, meeting.status != .recording, meeting.status != .transcribing else {
                throw Failure.invalid("\"\(meeting.title)\" is still being processed; edit the summary once it is done.")
            }
            let saved = meeting.summary?.model.trimmingCharacters(in: .whitespaces) ?? ""
            let model = saved.isEmpty ? "Claude Code" : saved
            meeting.summary = MeetingSummary(markdown: markdown, model: model.hasSuffix(", edited") ? model : model + ", edited", createdAt: now)
            // A summary written by hand ends the automatic retries and the error the last failed summary left.
            if let reason = meeting.summaryPending?.reason, meeting.error == reason { meeting.error = nil }
            meeting.summaryPending = nil
            if let failure = meeting.summaryError, meeting.error == failure { meeting.error = nil }
            // A failure saved before summaryError existed, as the scheduler clears it.
            if meeting.summaryError == nil, ClaudeSummarizerError.isSummaryFailure(meeting.error) { meeting.error = nil }
            meeting.summaryError = nil
            return "Replaced the summary of \"\(meeting.title)\"."

        case .assignSpeaker(let speaker, let name):
            let speaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = PersonName.stripMarkers(name.components(separatedBy: .newlines).joined(separator: " "))
            guard !name.isEmpty else { throw Failure.invalid("The name is empty.") }
            guard !Meeting.isUnnamedSpeaker(name) else { throw Failure.invalid("Give a person's name, not another speaker label.") }
            guard name.count <= Self.maxTitle else { throw Failure.invalid("Names are limited to \(Self.maxTitle) characters.") }
            // While summarizing the transcript is final; the app summarizes again once the running summary lands.
            guard meeting.status == .done || meeting.status == .failed || meeting.status == .summarizing else {
                throw Failure.invalid("\"\(meeting.title)\" is still being processed; name speakers once it is done.")
            }
            let key = PersonName.key(speaker)
            var renamed = 0
            for index in meeting.segments.indices {
                guard case .remote(let label?) = meeting.segments[index].speaker, PersonName.key(label) == key else { continue }
                meeting.segments[index].speaker = .remote(name)
                renamed += 1
            }
            guard renamed > 0 else {
                var seen = Set<String>()
                let labels = meeting.segments.compactMap { segment -> String? in
                    if case .remote(let label?) = segment.speaker, seen.insert(label).inserted { label } else { nil }
                }
                throw Failure.invalid("No line in \"\(meeting.title)\" is labelled \"\(speaker)\". Labels: "
                    + (labels.isEmpty ? "none" : labels.joined(separator: ", ")) + ".")
            }
            if let voice = meeting.voice(of: speaker), PersonName.key(name) != key {
                meeting.speakerVoices = meeting.speakerVoices?.filter { PersonName.key($0.key) != key }
                if meeting.voice(of: name) == nil { meeting.speakerVoices?[name] = voice }
            }
            // The summary names the voice by its label until it is rewritten, and keeps it if the rewrite fails.
            if let markdown = meeting.summary?.markdown, PersonName.key(name) != key {
                meeting.summary?.markdown = Self.replacingLabel(speaker, with: name, in: markdown)
                let items = meeting.summary?.actionItems?.map { item in
                    var item = item
                    if PersonName.key(item.owner) == key { item.owner = name }
                    return item
                }
                meeting.summary?.actionItems = items
            }
            if !(meeting.selfName.map { PersonName.key($0) == PersonName.key(name) } ?? false) { meeting.mergeAttendees([name]) }
            return "Named \(renamed) line\(renamed == 1 ? "" : "s") of \(speaker) as \(name) in \"\(meeting.title)\"."
        }
    }
}

extension MeetingEdit {
    /// `label` as a whole phrase ("Speaker 2", not the "Speaker 2" in "Speaker 21"), any case, becomes `name`.
    static func replacingLabel(_ label: String, with name: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: label) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: name))
    }
}

/// A checklist line ("- [ ] Owner: task") in a summary.
public struct ActionItem: Sendable, Equatable {
    /// 1-based position among the summary's checklist lines.
    public var number: Int
    public var text: String
    public var done: Bool
    /// Index of the line in the summary split on "\n".
    var line: Int

    public static func parse(_ markdown: String) -> [ActionItem] {
        var items: [ActionItem] = []
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            guard let match = raw.firstMatch(of: /^\s*[-*+]\s+\[([ xX])\]\s*(.*)$/) else { continue }
            let text = String(match.2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            items.append(ActionItem(number: items.count + 1, text: text, done: match.1 != " ", line: index))
        }
        return items
    }

    /// The item numbered `key`, or the only one whose text contains it.
    static func find(_ key: String, in markdown: String) throws -> ActionItem {
        let items = parse(markdown)
        guard !items.isEmpty else { throw MeetingEdit.Failure.invalid("This meeting's summary has no action items.") }
        let key = key.trimmingCharacters(in: .whitespaces)
        if let number = Int(key) {
            guard let item = items.first(where: { $0.number == number }) else {
                throw MeetingEdit.Failure.invalid("There is no action item \(number); this meeting has \(items.count).")
            }
            return item
        }
        let matches = items.filter { $0.text.localizedCaseInsensitiveContains(key) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw MeetingEdit.Failure.invalid("No action item contains \"\(key)\". Items: " + list(items))
        default: throw MeetingEdit.Failure.invalid("Several action items contain \"\(key)\"; use the number. Items: " + list(matches))
        }
    }

    static func list(_ items: [ActionItem]) -> String {
        items.map { "\($0.number). \($0.text)" }.joined(separator: "; ")
    }

    /// The summary with this item's checkbox set; nothing else changes.
    public static func setting(_ item: ActionItem, done: Bool, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(item.line) else { return markdown }
        lines[item.line] = lines[item.line].replacing(/\[[ xX]\]/, maxReplacements: 1) { _ in done ? "[x]" : "[ ]" }
        return lines.joined(separator: "\n")
    }
}
