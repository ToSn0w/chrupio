import Foundation

/// Names remote speech using active-speaker events from the extension or Zoom.
public enum SpeakerAttribution {
    /// A meeting page lights its speaking indicator a little after the voice starts and keeps it on a little after
    /// it stops, so an event at `t` says who was talking around `t - indicatorLag`.
    public static let indicatorLag: TimeInterval = 0.8
    /// Half the stretch of speech one report stands for; reports come about once a second.
    public static let eventReach: TimeInterval = 0.6

    /// Seconds of each name's speech that overlap `start...end`, judged from the events.
    public static func votes(start: TimeInterval, end: TimeInterval, events: [SpeakerEvent], selfName: String?) -> [String: Double] {
        var votes: [String: Double] = [:]
        for event in events {
            let overlap = event.overlap(start: start, end: end)
            guard overlap > 0 else { continue }
            let names = event.names.filter { !PersonName.same($0, selfName) }
            // Two people lit at once split the evidence.
            for name in names { votes[name, default: 0] += overlap / Double(names.count) }
        }
        return votes
    }

    /// Returns the most likely remote speaker for a segment, or nil when unknown.
    public static func remoteSpeaker(
        start: TimeInterval,
        end: TimeInterval,
        events: [SpeakerEvent],
        attendees: [String],
        selfName: String?
    ) -> String? {
        if let name = liveSpeaker(start: start, end: end, events: events, selfName: selfName) { return name }
        let others = attendees.filter { !PersonName.same($0, selfName) }
        return others.count == 1 ? others[0] : nil
    }

    /// The name the live events give a stretch of speech; ties go to the earlier-seen name, not the alphabet.
    /// - Parameter lookAhead: a line no event covers goes to whoever lit up within a second after it.
    public static func liveSpeaker(start: TimeInterval, end: TimeInterval, events: [SpeakerEvent], selfName: String?,
                                   lookAhead: Bool = true) -> String? {
        liveSpeakerCoverage(start: start, end: end, events: events, selfName: selfName, lookAhead: lookAhead)?.name
    }

    /// `liveSpeaker` with the seconds of the stretch its events cover (0 when only the look-ahead found it).
    public static func liveSpeakerCoverage(start: TimeInterval, end: TimeInterval, events: [SpeakerEvent], selfName: String?,
                                           lookAhead: Bool = true) -> (name: String, seconds: Double)? {
        let covered = votes(start: start, end: end, events: events, selfName: selfName)
        var votes = covered
        // A line too short to overlap any event still belongs to whoever lit up right after it.
        if votes.isEmpty, lookAhead { votes = self.votes(start: start, end: end + 1, events: events, selfName: selfName) }
        guard let top = votes.values.max() else { return nil }
        let leaders = Set(votes.filter { $0.value >= top - 1e-9 }.keys)
        guard let name = events.lazy.flatMap(\.names).first(where: { leaders.contains($0) }) else { return nil }
        return (name, covered[name] ?? 0)
    }

    /// Re-labels remote segments of a meeting using its speaker events, splitting a line where the events
    /// say another person took over. With `onlyUnnamed`, segments that already carry a name keep it
    /// (the live pass during a recording).
    public static func apply(to meeting: inout Meeting, onlyUnnamed: Bool = false) {
        let events = meeting.speakerEvents, me = meeting.selfName
        meeting.segments = meeting.segments.flatMap { segment -> [TranscriptSegment] in
            guard !segment.speaker.isMe, !(onlyUnnamed && segment.speaker != .remote(nil)) else { return [segment] }
            let parts = SegmentSplitter.split(segment) { start, end in
                votes(start: start, end: end, events: events, selfName: me).max { $0.value < $1.value }?.key
            }
            return parts.map { part, _ in
                var updated = part
                updated.speaker = .remote(remoteSpeaker(
                    start: part.start, end: part.end,
                    events: events, attendees: meeting.attendees, selfName: me
                ))
                return updated
            }
        }
    }
}

/// Folds the extension's 1 s heartbeats into one event per stretch of the same speakers, so a live meeting stores
/// (and its open views redraw for) speaker changes, not every heartbeat.
public struct SpeakerRun: Sendable, Equatable {
    /// A longer pause between reports of the same names ends the run, so the pause isn't counted as their speech.
    public static let maxGap: TimeInterval = 3
    /// The run still growing; not in the meeting yet.
    public private(set) var open: SpeakerEvent?

    public init() {}

    /// Takes one report of who is talking; returns the finished run to store when the speakers changed.
    public mutating func record(_ names: [String], at time: TimeInterval, maxGap: TimeInterval = SpeakerRun.maxGap) -> SpeakerEvent? {
        if var run = open, Set(run.names) == Set(names), time - run.lastSeen <= maxGap {
            // A late report (sent before the last one) is already covered.
            if time > run.lastSeen { run.end = time }
            open = run
            return nil
        }
        defer { open = SpeakerEvent(time: time, names: names) }
        return open
    }

    /// Ends the open run (before a save, or when the call stops) and returns it.
    public mutating func close() -> SpeakerEvent? {
        defer { open = nil }
        return open
    }
}

/// Splits a line at word boundaries where the speaker changes, by any source of labels (live events, diarization).
public enum SegmentSplitter {
    /// Shorter runs of a different label are taken as noise and joined to their neighbour.
    public static let minimumRun: TimeInterval = 1

    /// The segment cut into runs of one label each, with that label; the whole segment when it has no word times
    /// or one label. Words with no label take their neighbour's.
    public static func split(_ segment: TranscriptSegment, label: (TimeInterval, TimeInterval) -> String?) -> [(TranscriptSegment, String?)] {
        guard let words = segment.words, words.count > 1 else { return [(segment, nil)] }
        // A word lasts a fraction of a second; widen it a little so it can meet an event or a turn.
        var labels = words.map { label($0.start - 0.1, $0.end + 0.1) }
        guard labels.contains(where: { $0 != nil }) else { return [(segment, nil)] }
        for index in labels.indices.dropFirst() where labels[index] == nil { labels[index] = labels[index - 1] }
        if let first = labels.firstIndex(where: { $0 != nil }) { for index in 0..<first { labels[index] = labels[first] } }

        // Runs of equal labels: (first word, last word).
        var runs: [(from: Int, to: Int)] = []
        for index in words.indices {
            if let last = runs.last, labels[last.to] == labels[index] { runs[runs.count - 1].to = index } else { runs.append((index, index)) }
        }
        let length = { (run: (from: Int, to: Int)) in words[run.to].end - words[run.from].start }
        // Join the shortest too-short run to a neighbour until every run is long enough.
        while runs.count > 1, let shortest = runs.indices.min(by: { length(runs[$0]) < length(runs[$1]) }), length(runs[shortest]) < minimumRun {
            let into = shortest == 0 ? 1 : shortest == runs.count - 1 ? shortest - 1
                : (length(runs[shortest - 1]) >= length(runs[shortest + 1]) ? shortest - 1 : shortest + 1)
            let merged = (from: min(runs[into].from, runs[shortest].from), to: max(runs[into].to, runs[shortest].to))
            for index in merged.from...merged.to { labels[index] = labels[runs[into].from] }
            runs[into] = merged
            runs.remove(at: shortest)
            // Joining can leave two neighbours with the same label.
            var joined: [(from: Int, to: Int)] = []
            for run in runs {
                if let last = joined.last, labels[last.to] == labels[run.from] { joined[joined.count - 1].to = run.to } else { joined.append(run) }
            }
            runs = joined
        }
        guard runs.count > 1 else { return [(segment, labels[0])] }
        return runs.enumerated().map { position, run in
            let slice = Array(words[run.from...run.to])
            var part = segment
            part.id = position == 0 ? segment.id : UUID()
            part.start = position == 0 ? segment.start : slice[0].start
            part.end = position == runs.count - 1 ? segment.end : slice[slice.count - 1].end
            part.text = slice.map(\.text).joined(separator: " ")
            part.words = slice
            // The voice features describe the whole line, which held more than one voice.
            part.voice = nil
            return (part, labels[run.from])
        }
    }
}

public enum TranscriptFormatter {
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Ordered segments with consecutive lines from the same speaker joined.
    public static func grouped(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speaker == segment.speaker, segment.start - last.end < 4 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    public static func plainText(_ segments: [TranscriptSegment]) -> String {
        grouped(segments)
            .map { "[\(timestamp($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    public static func markdown(_ meeting: Meeting) -> String {
        let dateFormatter = DateFormatter()
        // Exported notes are read by other tools; keep dates Gregorian even when the Mac uses another calendar.
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyyjmm")
        var lines = ["# \(meeting.title)", ""]
        lines.append("- **When:** \(dateFormatter.string(from: meeting.startedAt))")
        lines.append("- **Where:** \(meeting.platform.displayName)")
        lines.append("- **Duration:** \(durationText(meeting.duration))")
        if !meeting.attendees.isEmpty {
            lines.append("- **Attendees:** \(meeting.attendees.joined(separator: ", "))")
        }
        lines.append("")
        if let summary = meeting.summary {
            lines.append(summary.markdown)
            lines.append("")
            if let warnings = summary.warnings, !warnings.isEmpty {
                for warning in warnings {
                    lines.append("> Warning: \(warning.replacingOccurrences(of: "\n", with: " "))")
                }
                lines.append("")
            }
        }
        if let notes = meeting.notes, !notes.isEmpty {
            lines.append("## Notes")
            lines.append("")
            for note in notes {
                lines.append("**\(note.author)**, \(dateFormatter.string(from: note.createdAt)):")
                lines.append("")
                lines.append(note.text)
                lines.append("")
            }
        }
        lines.append("## Transcript")
        lines.append("")
        for segment in grouped(meeting.segments) {
            lines.append("**\(segment.speaker.label)** [\(timestamp(segment.start))]: \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "\(Int(seconds)) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

public enum TranscriptAssembler {
    /// Drops segments that came from the time ranges and tracks of `chunks`, before those chunks are transcribed again.
    public static func removing(_ segments: [TranscriptSegment], coveredBy chunks: [AudioChunk]) -> [TranscriptSegment] {
        segments.filter { segment in
            !chunks.contains { chunk in
                (chunk.track == .mic) == segment.speaker.isMe
                    && segment.start >= chunk.startOffset - 0.01
                    && segment.start < chunk.startOffset + chunk.duration
            }
        }
    }

    /// Turns whisper output for one chunk into meeting-relative segments.
    public static func segments(for chunk: AudioChunk, speech: [RecognizedSpeech]) -> [TranscriptSegment] {
        speech.map { item in
            let words = item.words.map {
                TimedWord(start: chunk.startOffset + min($0.start, chunk.duration), end: chunk.startOffset + min($0.end, chunk.duration), text: $0.text)
            }
            return TranscriptSegment(
                start: chunk.startOffset + item.start,
                end: chunk.startOffset + min(item.end, chunk.duration),
                speaker: chunk.track == .mic ? .me : .remote(nil),
                text: item.text,
                words: words.isEmpty ? nil : words
            )
        }
    }

    /// What the same track said right before `chunk`, when the speech runs on across the boundary (a gap under 5 s).
    public static func previousText(_ segments: [TranscriptSegment], before chunk: AudioChunk) -> String? {
        let track = segments.filter { ($0.speaker.isMe == (chunk.track == .mic)) && $0.start < chunk.startOffset - 0.01 }
        guard let last = track.max(by: { $0.end < $1.end }), chunk.startOffset - last.end < 5 else { return nil }
        let text = track.filter { $0.end > chunk.startOffset - 30 }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        return text.isEmpty ? nil : String(text.suffix(Transcriber.previousTextLimit * 2))
    }

    /// Drops microphone segments that are the remote audio leaking from speakers into the mic.
    /// Whisper misspells the same echoed words differently on each track ("pilne tematy" vs "pilnetymaty"),
    /// so lines are compared by shared three-letter fragments, not whole words.
    public static func removeEcho(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let remote = segments.filter { !$0.speaker.isMe }
        return segments.filter { segment in
            guard segment.speaker.isMe else { return true }
            let grams = trigrams(segment.text)
            guard !grams.isEmpty else { return true }
            // Short replies ("dzięki") are only echo when the remote side said nearly the same at the same moment.
            let isShort = wordSet(segment.text).count < 3
            let window: TimeInterval = isShort ? 1 : 3
            // An echoed line can span two remote segments, so compare against everything said around it.
            let nearby = remote.filter { $0.start < segment.end + window && $0.end > segment.start - window }
            let remoteGrams = nearby.reduce(into: Set<String>()) { $0.formUnion(trigrams($1.text)) }
            return containment(grams, in: remoteGrams) < (isShort ? 0.8 : 0.5)
        }
    }

    static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    /// Three-letter fragments of the text with word boundaries kept as spaces.
    static func trigrams(_ text: String) -> Set<String> {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let characters = Array(" " + words.joined(separator: " ") + " ")
        guard characters.count >= 3 else { return [] }
        return Set((0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) })
    }

    /// Share of the mic segment's fragments that also appear in the remote audio.
    static func containment(_ mic: Set<String>, in remote: Set<String>) -> Double {
        guard !mic.isEmpty else { return 0 }
        return Double(mic.intersection(remote).count) / Double(mic.count)
    }
}
