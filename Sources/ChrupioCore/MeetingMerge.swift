import Foundation

/// A call too short to be worth a summary: a minute-long reconnect, a mis-detected app, a false start. It is flagged,
/// not summarized, and the meeting window offers to merge it into a neighbour or delete it.
public enum MeetingFragment {
    public static let minimumSeconds: TimeInterval = 60
    public static let minimumLines = 3

    public static func isFragment(_ meeting: Meeting) -> Bool {
        meeting.duration < minimumSeconds || meeting.segments.count < minimumLines
    }
}

/// Joining two recordings of one call: the counterpart of `MeetingStore.split`.
public enum MeetingMerge {
    /// How far apart two meetings may be and still count as adjacent.
    public static let maximumGap: TimeInterval = 10 * 60

    /// The nearest meeting on the same platform that starts before `meeting` and the nearest that starts after it,
    /// each only when it overlaps or the gap between them is at most `maximumGap`.
    public static func neighbours(of meeting: Meeting, in meetings: [Meeting]) -> (previous: Meeting?, next: Meeting?) {
        let others = meetings.filter { $0.id != meeting.id && $0.platform == meeting.platform && $0.status != .recording }
        let end = meeting.endedAt ?? meeting.startedAt
        let previous = others.filter { $0.startedAt <= meeting.startedAt }
            .filter { meeting.startedAt.timeIntervalSince($0.endedAt ?? $0.startedAt) <= maximumGap }
            .max { $0.startedAt < $1.startedAt }
        let next = others.filter { $0.startedAt > meeting.startedAt && $0.id != previous?.id }
            .filter { $0.startedAt.timeIntervalSince(end) <= maximumGap }
            .min { $0.startedAt < $1.startedAt }
        return (previous, next)
    }

    /// `source` folded into `target`: one timeline from the earlier start to the later end, lines and speaker events
    /// in time order, attendees, notes and typed notes combined. The target keeps its id and title; the summary is
    /// dropped (it described only part of the call) and the fragment flag cleared. `shifts` are the seconds each
    /// meeting's own timeline moves by.
    public static func merged(_ source: Meeting, into target: Meeting) -> (meeting: Meeting, targetShift: TimeInterval, sourceShift: TimeInterval) {
        let start = min(source.startedAt, target.startedAt)
        let targetShift = target.startedAt.timeIntervalSince(start), sourceShift = source.startedAt.timeIntervalSince(start)
        var meeting = target
        meeting.startedAt = start
        let ends = [source.endedAt, target.endedAt].compactMap { $0 }
        meeting.endedAt = ends.max()
        meeting.segments = deduplicated(target.segments.map { shifted($0, by: targetShift) }, source.segments.map { shifted($0, by: sourceShift) })
            .sorted { $0.start < $1.start }
        meeting.speakerEvents = (target.speakerEvents.map { $0.shifted(by: targetShift) } + source.speakerEvents.map { $0.shifted(by: sourceShift) })
            .sorted { $0.time < $1.time }
        meeting.mergeAttendees(source.attendees)
        if meeting.selfName == nil { meeting.selfName = source.selfName }
        if meeting.url == nil { meeting.url = source.url }
        if meeting.language == nil { meeting.language = source.language }
        let notes = (target.notes ?? []) + (source.notes ?? [])
        meeting.notes = notes.isEmpty ? nil : notes.sorted { $0.createdAt < $1.createdAt }
        let typed = [target, source].sorted { $0.startedAt < $1.startedAt }.compactMap(\.typedNotes)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        meeting.typedNotes = typed.isEmpty ? nil : typed.joined(separator: "\n\n")
        if let expected = source.expectedAttendees {
            meeting.expectedAttendees = ((target.expectedAttendees ?? []) + expected)
                .reduce(into: [String]()) { list, name in if !list.contains(where: { PersonName.key($0) == PersonName.key(name) }) { list.append(name) } }
        }
        if let voices = source.speakerVoices {
            meeting.speakerVoices = (target.speakerVoices ?? [:]).merging(voices) { kept, _ in kept }
        }
        meeting.summary = nil
        meeting.summaryPending = nil
        meeting.fragment = nil
        meeting.status = .done
        meeting.error = nil
        meeting.summaryError = nil
        return (meeting, targetShift, sourceShift)
    }

    /// Seconds apart two lines may start and still be one line heard by both recordings.
    public static let duplicateWindow: TimeInterval = 5

    /// Both meetings' lines, where recordings overlapped in time a line both of them transcribed kept once: the same
    /// or nearly the same words (`isNearDuplicate`) starting within `duplicateWindow`, whatever the speaker label.
    /// The longer of the two is kept; on a tie, the target's.
    static func deduplicated(_ target: [TranscriptSegment], _ source: [TranscriptSegment]) -> [TranscriptSegment] {
        var kept = target
        for line in source {
            guard let index = kept.indices.first(where: { abs(kept[$0].start - line.start) <= duplicateWindow && isNearDuplicate(kept[$0].text, line.text) }) else {
                kept.append(line)
                continue
            }
            if line.text.count > kept[index].text.count { kept[index] = line }
        }
        return kept
    }

    /// The same words, ignoring case and punctuation, or at least 80% of the longer line's words shared.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shared = Set(left).intersection(right).count
        return Double(shared) / Double(max(Set(left).count, Set(right).count)) >= 0.8
    }

    static func shifted(_ segment: TranscriptSegment, by offset: TimeInterval) -> TranscriptSegment {
        var segment = segment
        segment.start += offset
        segment.end += offset
        segment.words = segment.words?.map { TimedWord(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
        return segment
    }
}

extension MeetingStore {
    /// Merges the saved meeting `source` into `target` (`MeetingMerge.merged`), moves its audio across and deletes
    /// its folder; returns the merged target.
    @discardableResult
    public func merge(_ source: UUID, into target: UUID) throws -> Meeting {
        try withWriteLock {
            let from = try load(source), into = try load(target)
            let (merged, targetShift, sourceShift) = MeetingMerge.merged(from, into: into)
            let undo = try moveAudioUnlocked(from: source, into: target, targetShift: targetShift, sourceShift: sourceShift)
            do {
                try writeUnlocked(merged)
            } catch {
                undo()
                throw error
            }
            try? FileManager.default.removeItem(at: directory(for: source))
            if var index = readIndex() {
                index.entries[source] = nil
                writeIndex(index)
            }
            return merged
        }
    }

    /// `moveAudioUnlocked` under the write lock; the app moves the audio before it saves the merged meeting.
    public func moveAudio(from source: UUID, into target: UUID, targetShift: TimeInterval, sourceShift: TimeInterval) throws {
        _ = try withWriteLock { try moveAudioUnlocked(from: source, into: target, targetShift: targetShift, sourceShift: sourceShift) }
    }

    /// Moves `source`'s audio chunks into `target`'s folder, numbered after the target's own per track, and shifts
    /// both onto the merged timeline. Any failure puts everything back. Returns the undo for a later failure.
    func moveAudioUnlocked(from source: UUID, into target: UUID, targetShift: TimeInterval, sourceShift: TimeInterval) throws -> () -> Void {
        let fm = FileManager.default
        let sidecar = { (url: URL) in url.deletingPathExtension().appendingPathExtension("json") }
        let destination = audioDirectory(for: target)
        let targetChunks = AudioChunkScanner.chunks(in: destination)
        let sourceChunks = AudioChunkScanner.chunks(in: audioDirectory(for: source))
        var undo: [() -> Void] = []
        let undoAll = { undo.reversed().forEach { $0() } }
        do {
            if !sourceChunks.isEmpty { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
            if targetShift != 0 {
                for chunk in targetChunks {
                    let url = sidecar(chunk.url)
                    let old = try? Data(contentsOf: url)
                    var shifted = chunk
                    shifted.startOffset += targetShift
                    try JSONEncoder().encode(shifted).write(to: url, options: .atomic)
                    undo.append { if let old { try? old.write(to: url, options: .atomic) } else { try? fm.removeItem(at: url) } }
                }
            }
            var counts = Dictionary(grouping: targetChunks, by: \.track).mapValues { $0.map(\.index).max() ?? 0 }
            for chunk in sourceChunks {
                let index = (counts[chunk.track] ?? 0) + 1
                counts[chunk.track] = index
                var moved = chunk
                moved.index = index
                moved.startOffset = chunk.startOffset + sourceShift
                moved.url = destination.appendingPathComponent(String(format: "%@-%04d.%@", chunk.track.rawValue, index, chunk.url.pathExtension))
                try fm.moveItem(at: chunk.url, to: moved.url)
                undo.append { try? fm.moveItem(at: moved.url, to: chunk.url) }
                try JSONEncoder().encode(moved).write(to: sidecar(moved.url), options: .atomic)
                undo.append { try? fm.removeItem(at: sidecar(moved.url)) }
                if let data = try? Data(contentsOf: sidecar(chunk.url)) {
                    try fm.removeItem(at: sidecar(chunk.url))
                    undo.append { try? data.write(to: sidecar(chunk.url), options: .atomic) }
                }
            }
        } catch {
            undoAll()
            throw error
        }
        return undoAll
    }
}
