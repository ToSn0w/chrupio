import Foundation

/// The project knowledge a summary model reads next to the transcript: the brief, the meeting's channel,
/// its tickets and decisions, and the spellings. A single call gets all of it; each part of a very long meeting a trimmed part.
extension MeetingContext {
    public struct Ticket: Codable, Sendable, Equatable {
        public var key: String
        public var title: String
        public var assignee: String?
        public var status: String?

        public init(key: String, title: String, assignee: String? = nil, status: String? = nil) {
            self.key = key
            self.title = title
            self.assignee = assignee
            self.status = status
        }

        /// Done and rejected tickets are closed in the tracker; the context lists recently closed ones too.
        public var isOpen: Bool {
            !["done", "rejected", "closed", "resolved"].contains((status ?? "").lowercased())
        }

        var line: String {
            let facts = [status, assignee ?? "unassigned"].compactMap { $0 }.joined(separator: ", ")
            return "- \(key) [\(facts)] \(title)"
        }
    }

    public struct WorkStream: Codable, Sendable, Equatable {
        public var stream: String
        public var area: String?
        public var owner: String?
    }

    public struct Decision: Codable, Sendable, Equatable {
        public var date: String?
        public var decision: String
    }

    public struct Contact: Codable, Sendable, Equatable {
        public var name: String
        public var role: String?
        public var notes: String?
    }

    /// Ticket keys said in a transcript, in order, written "PRJ-1234" for prefix "PRJ": "PRJ2,366", "P.R.J. 2366",
    /// "ticket 2419", "z zadania 2041". A number said alone counts only when `known` has a ticket with that number.
    /// No (valid) prefix means no tickets.
    public static func ticketKeys(in text: String, prefix rawPrefix: String?, known: Set<String> = []) -> [String] {
        guard let prefix = rawPrefix.flatMap(normalizedTicketPrefix) else { return [] }
        var found: [(offset: Int, key: String)] = []
        func add(_ digits: Substring, at index: String.Index) {
            let number = digits.filter(\.isNumber)
            guard (2...5).contains(number.count), let value = Int(number), value > 0 else { return }
            found.append((text.distance(from: text.startIndex, to: index), "\(prefix)-\(value)"))
        }
        // "PRJ", "P.R.J.", "P R J" and "prj-" all name the prefix.
        let spoken = prefix.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\.?\s?"#) + #"\.?"#
        if let said = try? Regex(#"(?i)\b"# + spoken + #"[\s\-]*(\d(?:[\d,.]{0,5}\d)?)(?![\d])"#) {
            for match in text.matches(of: said) {
                if let digits = match.output[1].substring { add(digits, at: match.range.lowerBound) }
            }
        }
        let words = /(?i)\b(?:ticket|tiket|tikiet|task|zadani|zgłoszeni|issue|jira|numer|nr)\p{L}*\.?\s+(?:nr\.?\s+|numer\s+)?(\d(?:[\d,.]{1,4}\d))(?![\d])/
        for match in text.matches(of: words) { add(match.1, at: match.range.lowerBound) }
        if !known.isEmpty {
            // Swift Regex has no lookbehind, so the character before the number is matched instead.
            for match in text.matches(of: /(?:^|[^\d,.:\-])(\d[,.]?\d{3})(?![\d,.:]\d|\d)/) {
                let key = "\(prefix)-" + String(match.1.filter { $0.isNumber })
                if known.contains(key) { add(match.1, at: match.range.lowerBound) }
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.offset < $1.offset }.map(\.key).filter { seen.insert($0).inserted }
    }

    /// The `MeetingContext` part of a Claude summary prompt: everything the model may need to name people,
    /// fix misheard words and connect the talk to tickets, with what this meeting touched first.
    public func summaryPrompt(for meeting: Meeting, transcript: String) -> String {
        var sections: [String] = []
        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            sections.append("## Project brief\n" + brief)
        }
        sections.append("## This meeting\n" + meetingFacts(meeting, topics: true))

        let selection = relevantTickets(for: meeting, transcript: transcript)
        if !selection.mentioned.isEmpty {
            sections.append("## Tickets said in this meeting (from the transcript, numbers already normalized)\n"
                            + selection.mentioned.joined(separator: "\n"))
        }
        if !selection.attendees.isEmpty {
            sections.append("## Open tickets of the people in this meeting\n" + selection.attendees.map(\.line).joined(separator: "\n"))
        }
        let shown = Set(selection.attendees.map(\.key)).union(selection.mentionedKeys)
        let others = (tickets ?? []).filter { !shown.contains($0.key) }
        if !others.isEmpty {
            sections.append("## Other recent tickets\n" + others.map(\.line).joined(separator: "\n"))
        }
        if let people, !people.isEmpty {
            sections.append("## People\n" + people.map { person in
                var line = "- \(person.name)"
                if let role = person.role, !role.isEmpty { line += ": \(role)" }
                if person.internal == false { line += " (client side)" }
                if let aliases = person.aliases, !aliases.isEmpty { line += "; also written or heard as \(aliases.joined(separator: ", "))" }
                return line
            }.joined(separator: "\n"))
        }
        if let workStreams, !workStreams.isEmpty {
            sections.append("## Work streams\n" + workStreams.map { stream in
                "- \(stream.stream)" + (stream.area.map { " (\($0))" } ?? "") + (stream.owner.map { ": \($0)" } ?? "")
            }.joined(separator: "\n"))
        }
        let decisions = relevantDecisions(mentioned: selection.mentionedKeys)
        if !decisions.isEmpty {
            sections.append("## Recent project decisions (background; report only decisions made in this meeting)\n"
                            + decisions.map { "- " + ($0.date.map { "\($0): " } ?? "") + $0.decision }.joined(separator: "\n"))
        }
        if let contacts, !contacts.isEmpty {
            sections.append("## Other contacts\n" + contacts.map { "- \($0.name)" + ($0.role.map { ": \($0)" } ?? "") }.joined(separator: "\n"))
        }
        sections.append(contentsOf: spellings(for: meeting, limit: nil))
        if let style = summaryStyle?.trimmingCharacters(in: .whitespacesAndNewlines), !style.isEmpty {
            sections.append("## House style\n" + style)
        }
        return sections.joined(separator: "\n\n")
    }

    /// What each part of a very long meeting gets: the short instructions plus the start of the brief and this meeting's tickets.
    /// Kept to a few thousand characters, since it is repeated in every part of a long meeting.
    public func localSummaryGuidance(for meeting: Meeting, transcript: String) -> String? {
        var parts: [String] = []
        if let guidance = summaryGuidance(for: meeting) { parts.append(guidance) }
        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            let lines = brief.components(separatedBy: "\n").prefix(2).joined(separator: " ")
            parts.append("About the project: " + String(lines.prefix(900)))
        }
        let selection = relevantTickets(for: meeting, transcript: transcript)
        let tickets = Array(selection.mentioned.prefix(10)) + selection.attendees.prefix(max(0, 10 - selection.mentioned.count)).map(\.line)
        if !tickets.isEmpty {
            let format = resolvedTicketPrefix.map { " (write keys as \($0)-1234)" } ?? ""
            parts.append("Tickets this meeting may refer to\(format):\n" + tickets.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func meetingFacts(_ meeting: Meeting, topics: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let minutes = max(1, Int((meeting.duration / 60).rounded()))
        var lines = [
            "- Title: \(UntrustedText.inline(meeting.title))",
            "- Platform: \(meeting.platform.displayName)",
            "- Date: \(formatter.string(from: meeting.startedAt)), about \(minutes) min",
        ]
        if let language = meeting.language, let name = Prompts.languageName(language) { lines.append("- Spoken language: \(name)") }
        if let selfName = meeting.selfName { lines.append("- Recorded by \(UntrustedText.inline(selfName, limit: 100)), who is \"You\" in the transcript") }
        if !meeting.attendees.isEmpty {
            lines.append("- Attendees the app saw: \(meeting.attendees.map { UntrustedText.inline($0, limit: 100) }.joined(separator: ", "))")
        }
        if let profile = profile(for: meeting.title) {
            lines.append("- Recurring meeting: \(profile.name)" + (profile.about.map { ". \($0)" } ?? ""))
            if let attendees = profile.attendees, !attendees.isEmpty {
                lines.append("- Usually attended by: \(attendees.joined(separator: ", "))")
            }
            if topics, let list = profile.topics, !list.isEmpty {
                lines.append("- Topics that often come up in this meeting (background only; mention one only if this transcript discusses it): "
                             + list.joined(separator: "; "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Tickets said in the transcript (as context lines, unknown keys included), then the open tickets of the
    /// people in the meeting: its named speakers, attendees and the channel's usual attendees.
    func relevantTickets(for meeting: Meeting, transcript: String) -> (mentioned: [String], mentionedKeys: Set<String>, attendees: [Ticket]) {
        let all = tickets ?? []
        let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = Self.ticketKeys(in: transcript, prefix: resolvedTicketPrefix, known: Set(byKey.keys))
        let mentioned = keys.map { byKey[$0]?.line ?? "- \($0) (not in the ticket list; title unknown)" }

        var names = meeting.attendees + (meeting.selfName.map { [$0] } ?? []) + (profile(for: meeting.title)?.attendees ?? [])
        names += meeting.segments.map(\.speaker.label).filter { !Summarizer.isUnknownSpeaker($0) && $0 != "You" }
        var folded = Set(names.map(Self.fold))
        for person in people ?? [] where folded.contains(Self.fold(person.name)) {
            folded.formUnion((person.aliases ?? []).map(Self.fold))
        }
        let keySet = Set(keys)
        let attendees = all.filter { ticket in
            guard ticket.isOpen, !keySet.contains(ticket.key), let assignee = ticket.assignee else { return false }
            return folded.contains(Self.fold(assignee))
        }
        return (mentioned, keySet, attendees)
    }

    /// Decisions about the tickets said in the meeting first, then the rest newest first.
    func relevantDecisions(mentioned: Set<String>) -> [Decision] {
        let all = recentDecisions ?? []
        let related = all.filter { decision in mentioned.contains { decision.decision.localizedCaseInsensitiveContains($0) } }
        return related + all.filter { !related.contains($0) }
    }

    func spellings(for meeting: Meeting, limit: Int?) -> [String] {
        var sections: [String] = []
        let terms = terms(for: meeting.title)
        if !terms.isEmpty {
            sections.append("## Correct spellings of project terms\n" + (limit.map { Array(terms.prefix($0)) } ?? terms).joined(separator: ", "))
        }
        if let corrections, !corrections.isEmpty {
            sections.append("## Known speech-recognition mistakes (heard -> meant)\n"
                            + corrections.sorted { $0.key < $1.key }.map { "- \($0.key) -> \($0.value)" }.joined(separator: "\n"))
        }
        return sections
    }

    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l").trimmingCharacters(in: .whitespaces)
    }
}
