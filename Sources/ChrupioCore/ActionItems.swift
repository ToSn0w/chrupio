import Foundation

/// One follow-up task from a summary, as structured data. The summary's "## Action items" checklist is rendered
/// from these and stays the place where done states live; these keep what the checklist can't (quote, confidence).
public struct SummaryActionItem: Codable, Sendable, Hashable {
    /// Starts with a verb: "Send the deck to the client".
    public var action: String
    /// A person, a "Speaker N" label (renamed when the voice is named) or "Unassigned".
    public var owner: String
    public var deadline: String?
    /// The transcript words the task comes from.
    public var sourceQuote: String?
    /// 0-1: how sure the model is that someone committed to this.
    public var confidence: Double?
    public var tickets: [String]?
    /// The deadline as YYYY-MM-DD, worked out from the meeting's date; nil when no day was said.
    public var deadlineDate: String?

    public init(action: String, owner: String, deadline: String? = nil, sourceQuote: String? = nil, confidence: Double? = nil,
                tickets: [String]? = nil, deadlineDate: String? = nil) {
        self.action = action
        self.owner = owner
        self.deadline = deadline
        self.sourceQuote = sourceQuote
        self.confidence = confidence
        self.tickets = tickets
        self.deadlineDate = deadlineDate
    }
}

/// Rules that make action items trustworthy whichever model wrote them.
public enum ActionItemRules {
    /// Calls with less speech than this get no action items: too short for anyone to commit to anything.
    public static let minimumSpeechSeconds: TimeInterval = 60
    /// Items the model itself rates below this are left out.
    public static let minimumConfidence = 0.4
    /// Two actions at least this similar (same owner) are one task.
    static let duplicateSimilarity = 0.8

    /// Seconds in which someone was speaking; overlapping lines count once.
    public static func speechSeconds(_ meeting: Meeting) -> TimeInterval {
        let spans = meeting.segments.map { ($0.start, max($0.start, $0.end)) }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (TimeInterval, TimeInterval)?
        for span in spans {
            if let open = current, span.0 <= open.1 {
                current = (open.0, max(open.1, span.1))
            } else {
                if let open = current { total += open.1 - open.0 }
                current = span
            }
        }
        if let open = current { total += open.1 - open.0 }
        return total
    }

    public static func isShortCall(_ meeting: Meeting) -> Bool {
        speechSeconds(meeting) < minimumSpeechSeconds
    }

    /// Everyone an owner can be: who was in the call, who the project expected, the recorder, named voices and `extra`
    /// (the project's people, voice prints).
    public static func knownPeople(_ meeting: Meeting, extra: [String]) -> [String] {
        let named = meeting.segments.compactMap { segment -> String? in
            if case .remote(let name?) = segment.speaker, !Meeting.isUnnamedSpeaker(name) { name } else { nil }
        }
        var seen = Set<String>()
        return (meeting.attendees + (meeting.expectedAttendees ?? []) + [meeting.selfName].compactMap { $0 } + named + extra)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(PersonName.key($0)).inserted }
    }

    /// The known spelling of `owner`: the same name ignoring case and accents, a unique first name, or a close
    /// misspelling ("Mipiotr" > "Piotr Kowalski"). Labels, "Unassigned" and unknown names stay as given.
    public static func snapOwner(_ owner: String, known: [String]) -> String {
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !Summarizer.isUnknownSpeaker(owner), owner.lowercased() != "unassigned", owner.lowercased() != "you" else { return owner }
        let key = PersonName.key(owner)
        if let exact = known.first(where: { PersonName.key($0) == key }) { return cleaned(exact) }
        // The model saw names as `Prompts.header` prints them (cleaned and capped by `UntrustedText.inline`); an owner
        // copied from there, with or without the "…", is that attendee. Two attendees that look the same there: ambiguous.
        let seen = Set(known.filter { name in
            let shown = UntrustedText.inline(name, limit: 100)
            return PersonName.key(shown) == key || (shown.hasSuffix("…") && PersonName.key(String(shown.dropLast())) == key)
        }.map(cleaned))
        if seen.count > 1 { return owner }
        if let seen = seen.first { return seen }
        let single = !key.contains(" ")
        let limit = key.count <= 4 ? 1 : key.count <= 9 ? 2 : 3
        var best: (distance: Int, names: Set<String>) = (Int.max, [])
        for name in known {
            let full = PersonName.key(name)
            var distances = [editDistance(key, full)]
            if single, let first = full.split(separator: " ").first, first.count < full.count { distances.append(editDistance(key, String(first))) }
            let distance = distances.min()!
            guard distance <= limit else { continue }
            if distance < best.distance { best = (distance, [name]) } else if distance == best.distance { best.names.insert(name) }
        }
        return best.names.count == 1 ? cleaned(best.names.first!) : owner
    }

    /// A known name as an owner: on one line, without bidi or zero-width characters (it lands in "- [ ] Owner: task"
    /// lines and the meeting tools), never capped.
    static func cleaned(_ name: String) -> String { UntrustedText.inline(name, limit: .max) }

    /// Who may own an action item: the call's attendees, its named speakers, the recorder and "You". Unnamed voices
    /// ("Speaker 3") and people only the project context mentions are not on it.
    public static func allowedOwners(_ meeting: Meeting) -> Set<String> {
        let named = meeting.segments.compactMap { segment -> String? in
            if case .remote(let name?) = segment.speaker, !Meeting.isUnnamedSpeaker(name) { name } else { nil }
        }
        let people = meeting.attendees + named + [meeting.selfName].compactMap { $0 } + ["You"]
        return Set((people + people.map(cleaned)).map(PersonName.key))
    }

    /// The items to keep: none for a short call; owners normalised and snapped to known people, and anyone not in
    /// `allowedOwners` made "Unassigned"; unsure, empty and repeated items dropped (a repeat lends its deadline, quote and tickets to the kept item).
    public static func refine(_ items: [SummaryActionItem], meeting: Meeting, knownPeople extra: [String]) -> [SummaryActionItem] {
        guard !isShortCall(meeting) else { return [] }
        let known = knownPeople(meeting, extra: extra)
        let allowed = allowedOwners(meeting)
        var result: [SummaryActionItem] = []
        for var item in items {
            item.action = StructuredSummary.unbulleted(item.action)
            guard !StructuredSummary.isNone(item.action) else { continue }
            if let confidence = item.confidence, confidence < minimumConfidence { continue }
            let owner = StructuredSummary.clean(item.owner)
            if StructuredSummary.isNone(owner) || owner.lowercased() == "unassigned" || owner.range(of: #"^(?:others|inni)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                item.owner = "Unassigned"
            } else {
                let snapped = snapOwner(owner, known: known)
                item.owner = allowed.contains(PersonName.key(snapped)) ? snapped : "Unassigned"
            }
            item.action = Summarizer.droppingOwner(item.owner, from: item.action)
            item.deadline = item.deadline.map(StructuredSummary.clean).flatMap { StructuredSummary.isNone($0) || Summarizer.isNoDueDate($0) ? nil : $0 }
            item.deadlineDate = ActionItemDates.valid(item.deadlineDate, meetingStart: meeting.startedAt)
            item.sourceQuote = item.sourceQuote.map(StructuredSummary.clean).flatMap { $0.isEmpty ? nil : $0 }
            if let index = result.firstIndex(where: { PersonName.key($0.owner) == PersonName.key(item.owner)
                && similarity($0.action, item.action) >= duplicateSimilarity }) {
                var kept = result[index]
                if kept.deadline == nil { kept.deadline = item.deadline }
                if kept.deadlineDate == nil { kept.deadlineDate = item.deadlineDate }
                if kept.sourceQuote == nil { kept.sourceQuote = item.sourceQuote }
                let tickets = ((kept.tickets ?? []) + (item.tickets ?? [])).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !tickets.isEmpty { kept.tickets = tickets }
                kept.confidence = [kept.confidence, item.confidence].compactMap { $0 }.max()
                result[index] = kept
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// The summary with its "## Action items" (or "## Zadania") list replaced by "- None recorded" (short calls, free-text summaries).
    public static func clearingActionItems(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.range(of: SummaryHeadings.actionItemsPattern, options: .regularExpression) != nil }) else { return markdown }
        let end = lines[(heading + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        lines.replaceSubrange((heading + 1)..<end, with: ["- None recorded"] + (end < lines.endIndex ? [""] : []))
        return lines.joined(separator: "\n")
    }

    /// Lowercased words without accents or punctuation.
    static func normalized(_ text: String) -> [String] {
        PersonName.key(text).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// 0-1: the better of word overlap and character edit distance on the normalised texts.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = normalized(a), right = normalized(b)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        let shared = Set(left).intersection(right).count
        let jaccard = Double(shared) / Double(Set(left).union(right).count)
        let joinedLeft = left.joined(separator: " "), joinedRight = right.joined(separator: " ")
        let longest = max(joinedLeft.count, joinedRight.count)
        let characters = longest == 0 ? 1 : 1 - Double(editDistance(joinedLeft, joinedRight)) / Double(longest)
        return max(jaccard, characters)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// A summary that failed (Claude Code missing, logged out, at its limit, timed out) and is tried again on its own.
/// Kept in meeting.json, so the retry survives a relaunch.
public struct SummaryPending: Codable, Equatable, Sendable, Hashable {
    /// Waits after the 1st, 2nd, 3rd... failure; the last one repeats.
    public static let backoff: [TimeInterval] = [300, 900, 3_600, 3 * 3_600, 6 * 3_600]

    public var reason: String
    public var attempts: Int
    public var nextAttempt: Date

    public init(reason: String, attempts: Int, nextAttempt: Date) {
        self.reason = reason
        self.attempts = attempts
        self.nextAttempt = nextAttempt
    }

    /// The state after another failure: one more attempt counted, the next one further out.
    public static func failed(_ previous: SummaryPending?, reason: String, now: Date = Date()) -> SummaryPending {
        let attempts = (previous?.attempts ?? 0) + 1
        let wait = backoff[min(attempts, backoff.count) - 1]
        return SummaryPending(reason: reason, attempts: attempts, nextAttempt: now.addingTimeInterval(wait))
    }

    /// Every failure is retried except a transcript with nothing to summarize, a model Claude Code can't use and a CLI
    /// too old for the call: those fail the same way until the user changes something. Summaries turned off aren't
    /// a failure and aren't retried.
    public static func isRetryable(_ error: Error) -> Bool {
        if error is ClaudeSummariesOff { return false }
        if case SummarizerError.emptyTranscript = error { return false }
        switch error as? ClaudeSummarizerError {
        case .modelUnavailable, .outdated: return false
        default: return true
        }
    }

    /// Meetings whose retry is due, earliest first. At launch (`launch` true) every pending meeting is due at once.
    public static func due(_ meetings: [Meeting], now: Date = Date(), launch: Bool = false) -> [UUID] {
        meetings.compactMap { meeting in meeting.summaryPending.map { (meeting.id, $0.nextAttempt) } }
            .filter { launch || $0.1 <= now }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}

extension ActionItem {
    /// `new` with the items ticked in `old` ticked again: each done item marks the most similar open item in `new`
    /// (task text compared without the owner, who may have been renamed).
    public static func carryingDone(from old: String, into new: String, threshold: Double = 0.7) -> String {
        func task(_ text: String) -> String {
            let withoutOwner = text.firstMatch(of: /^[^:]{1,60}:\s+(.*)$/).map { String($0.1) } ?? text
            return withoutOwner.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        }
        var result = new
        var open = parse(new).filter { !$0.done }
        for done in parse(old) where done.done {
            let scored = open.map { (item: $0, score: ActionItemRules.similarity(task(done.text), task($0.text))) }
            guard let best = scored.max(by: { $0.score < $1.score }), best.score >= threshold else { continue }
            result = setting(best.item, done: true, in: result)
            open.removeAll { $0.line == best.item.line }
        }
        return result
    }
}

extension Meeting {
    /// Unnamed voices ("Speaker 2") that spoke in a meeting whose summary has an "Unassigned" action item, in order
    /// of first line; empty when every item has an owner or every voice has a name. Naming them lets the rewritten
    /// summary assign those items.
    public var unnamedSpeakersBlockingOwners: [String] {
        guard let summary else { return [] }
        let unassigned = summary.actionItems.map { items in items.contains { $0.owner == "Unassigned" } }
            ?? summary.markdown.contains("Unassigned:")
        guard unassigned else { return [] }
        var seen = Set<String>()
        return segments.compactMap { segment -> String? in
            guard case .remote(let label?) = segment.speaker, Meeting.isUnnamedSpeaker(label), seen.insert(label).inserted else { return nil }
            return label
        }
    }
}
