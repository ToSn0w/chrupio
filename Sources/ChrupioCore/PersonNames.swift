import Foundation

/// People's names as calls report them, reduced to one spelling per person.
public enum PersonName {
    /// Role markers platforms put after a name: "Jane (Guest)", "Jane [External]", "Jane (You)", "Jane (Organizer)".
    static let markers = ["you", "me", "ty", "guest", "gość", "gosc", "external", "zewnętrzny", "organizer", "organiser",
                          "organizator", "host", "co-host", "presenter", "unverified", "niezweryfikowany"]
    private static let bracketed = try! NSRegularExpression(
        pattern: "\\s*[\\(\\[]\\s*(?:" + markers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\s*[\\)\\]]\\s*$",
        options: [.caseInsensitive])
    /// Teams prints "Unverified" without brackets after external accounts: "Marek Unverified".
    private static let bare = try! NSRegularExpression(pattern: "\\s+(?:unverified|niezweryfikowany|niezweryfikowana)$", options: [.caseInsensitive])

    /// The name without role markers; a name that is nothing but a marker stays as it is.
    public static func stripMarkers(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            var next = name
            for regex in [bracketed, bare] {
                next = regex.stringByReplacingMatches(in: next, range: NSRange(next.startIndex..., in: next), withTemplate: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if next == name || next.isEmpty { return name }
            name = next
        }
    }

    /// Comparison key: case, diacritics (ł too), punctuation and spacing folded and camelCase split, so "Łukasz Żurek",
    /// "lukasz  zurek", "LukaszZurek" and "Łukasz Żurek." match, and "Anna-Maria" matches "Anna Maria".
    public static func key(_ name: String) -> String {
        name.replacing(/(\p{Ll})(\p{Lu})/) { "\($0.1) \($0.2)" }.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
            .replacing(/\p{P}/) { _ in " " }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension MeetingContext {
    /// The roster spelling of a reported name: role markers stripped, then matched against people's names and aliases
    /// ("Marek Unverified" > "Marek" > "Marek Wróbel"). An alias two people share, or no match, leaves the stripped name.
    public func canonicalName(_ raw: String) -> String {
        let stripped = PersonName.stripMarkers(raw)
        let key = PersonName.key(stripped)
        let people = self.people ?? []
        if let exact = people.first(where: { PersonName.key($0.name) == key }) { return exact.name }
        let matches = people.filter { ($0.aliases ?? []).contains { PersonName.key($0) == key } }
        return matches.count == 1 ? matches[0].name : stripped
    }

    /// Who this kind of meeting usually has (its profile's attendees), in roster spelling; empty without a profile.
    public func expectedAttendees(for title: String) -> [String] {
        var seen = Set<String>()
        return (profile(for: title)?.attendees ?? []).map(canonicalName).filter { seen.insert(PersonName.key($0)).inserted }
    }
}

extension Meeting {
    /// Puts every reported name (attendees, live speaker events, line labels, self) in roster spelling, so one person
    /// is one name across meetings and voice prints. Without a context only role markers are stripped.
    public mutating func canonicalizeNames(_ canonical: (String) -> String) {
        func rename(_ name: String) -> String {
            let result = canonical(name)
            return result.isEmpty ? name : result
        }
        let named = attendees.map(rename)
        attendees = []
        mergeAttendees(named)
        selfName = selfName.map(rename)
        expectedAttendees = expectedAttendees.map { $0.map(rename) }
        speakerEvents = speakerEvents.map { event in
            var event = event
            event.names = event.names.map(rename)
            return event
        }
        segments = segments.map { segment in
            var segment = segment
            if case .remote(let name?) = segment.speaker { segment.speaker = .remote(rename(name)) }
            return segment
        }
    }
}

extension Meeting {
    /// Whether `label` is a voice nobody named ("Speaker 2").
    public static func isUnnamedSpeaker(_ label: String) -> Bool {
        label.wholeMatch(of: /Speaker \d+/) != nil
    }

    /// The diarizer's voice behind a remote label.
    public func voice(of label: String) -> [Float]? {
        let key = PersonName.key(label)
        return speakerVoices?.first { PersonName.key($0.key) == key }?.value
    }

    /// Who a voice in this meeting can be named as: expected people, then reported ones, then the roster; self excluded.
    public func speakerCandidates(roster: [String]) -> [String] {
        var seen = Set([selfName].compactMap { $0 }.map(PersonName.key))
        let remote = segments.compactMap { segment -> String? in
            if case .remote(let name?) = segment.speaker, !Meeting.isUnnamedSpeaker(name) { name } else { nil }
        }
        return ((expectedAttendees ?? []) + attendees + remote + roster).filter { seen.insert(PersonName.key($0)).inserted }
    }
}

extension SpeakerPrints {
    /// Where the app keeps voice prints: next to the meetings folder.
    public static func url(nextTo store: MeetingStore) -> URL {
        store.root.deletingLastPathComponent().appendingPathComponent("speaker-prints.json")
    }

    /// Teaches the voice someone named by hand (`assignSpeaker`): the label's voice from `before`, under `name`.
    public static func learnAssignment(_ edit: MeetingEdit, before: Meeting, at url: URL, canonical: (String) -> String) {
        guard case .assignSpeaker(let speaker, let name) = edit, let voice = before.voice(of: speaker) else { return }
        let person = canonical(PersonName.stripMarkers(name))
        guard !person.isEmpty, !Meeting.isUnnamedSpeaker(person) else { return }
        do {
            try update(at: url) { prints in
                prints = prints.normalized(canonical)
                prints.learn(person, embedding: voice)
            }
        } catch {
            // Learning a voice is optional; the speaker edit itself already succeeded.
            CoreLog.store.error("Voice print for \(person, privacy: .private) not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The same prints under roster spellings; prints that land on one name are merged, weighted by how often each
    /// was learned. Fixes names stored before canonicalisation, such as "Marek Unverified".
    public func normalized(_ canonical: (String) -> String) -> SpeakerPrints {
        var result = SpeakerPrints()
        result.learnedMeetings = learnedMeetings
        // Sorted, so merging is the same on every load.
        for (name, print) in people.sorted(by: { $0.key < $1.key }) {
            let target = canonical(name).isEmpty ? name : canonical(name)
            if var existing = result.people[target], existing.embedding.count == print.embedding.count {
                let a = Float(existing.count), b = Float(print.count)
                existing.embedding = zip(existing.embedding, print.embedding).map { ($0 * a + $1 * b) / (a + b) }
                existing.count += print.count
                result.people[target] = existing
            } else if result.people[target] == nil {
                result.people[target] = print
            }
        }
        return result
    }
}
