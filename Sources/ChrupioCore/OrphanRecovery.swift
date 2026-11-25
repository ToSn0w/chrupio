import Foundation
import os

extension MeetingStore {
    /// Meeting folders with recorded audio but no `meeting.json`: the recording started and the meeting was never
    /// saved (the app hung, crashed or was killed in between).
    public func orphanFolders() -> [UUID] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .filter { id in
                !FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent("meeting.json").path)
                    && !AudioChunkScanner.chunks(in: audioDirectory(for: id)).isEmpty
            }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// The meeting an orphan folder's audio becomes: it starts when the first chunk began and ends with the last
    /// chunk written, and is `transcribing`, so the usual recovery transcribes and summarizes it. Nil without chunks.
    public func orphanMeeting(_ id: UUID) -> Meeting? {
        let chunks = AudioChunkScanner.chunks(in: audioDirectory(for: id))
        let written = chunks.compactMap { chunk -> (chunk: AudioChunk, date: Date)? in
            guard let date = (try? chunk.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (chunk, date)
        }
        guard let first = written.min(by: { $0.chunk.startOffset < $1.chunk.startOffset }),
              let last = written.map(\.date).max() else { return nil }
        // A chunk is written when it ends: its file date minus where it ends on the meeting timeline is the start.
        let startedAt = first.date.addingTimeInterval(-(first.chunk.startOffset + first.chunk.duration))
        let ended = max(last, startedAt)
        let title = "Recovered recording " + Self.recoveredTitleFormatter.string(from: startedAt)
        return Meeting(id: id, title: title, platform: .other, startedAt: startedAt, endedAt: ended, status: .transcribing,
                       error: "Chrupio quit before this recording was saved; it was recovered from its audio.")
    }

    /// Where an orphan's audio holds more than one call: the middle of every stretch of over `minimumGap` seconds
    /// with no audible chunk on either track, whether nothing was recorded (a gap between chunk times) or only
    /// silence was. Seconds on the orphan's timeline, in order; empty for one call.
    public static func orphanCuts(_ chunks: [AudioChunk], minimumGap: TimeInterval = 120) -> [TimeInterval] {
        let heard = chunks.filter { !$0.isSilent }.map { (start: $0.startOffset, end: $0.startOffset + $0.duration) }
            .sorted { $0.start < $1.start }
        var cuts: [TimeInterval] = []
        var end: TimeInterval?
        for span in heard {
            if let last = end, span.start - last > minimumGap { cuts.append((last + span.start) / 2) }
            end = max(end ?? span.end, span.end)
        }
        return cuts
    }

    /// Saves the orphan as one meeting, then splits it at `orphanCuts` (`splitUnlocked`), so each call is
    /// transcribed and summarized on its own. Every part is "Recovered recording" with its own start time.
    func writeOrphanUnlocked(_ meeting: Meeting) throws -> [Meeting] {
        try writeUnlocked(meeting)
        var parts = [meeting]
        var done: TimeInterval = 0
        for cut in Self.orphanCuts(AudioChunkScanner.chunks(in: audioDirectory(for: meeting.id))) {
            guard let last = parts.last, cut - done > 0 else { continue }
            do {
                var (first, second) = try splitUnlocked(last.id, at: cut - done, retranscribe: true)
                second.title = "Recovered recording " + Self.recoveredTitleFormatter.string(from: second.startedAt)
                first.error = meeting.error
                second.error = meeting.error
                try writeUnlocked(first)
                try writeUnlocked(second)
                parts[parts.count - 1] = first
                parts.append(second)
                done = cut
            } catch {
                // The calls stay together; nothing is lost.
                CoreLog.store.error("splitting orphan \(meeting.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        return parts
    }

    /// Saves a meeting for every orphan folder; returns the recovered meetings.
    @discardableResult
    public func recoverOrphans() -> [Meeting] {
        recoverOrphans(lockTimeout: nil).recovered
    }

    /// With a `lockTimeout`, a folder whose save can't get the write lock in time (another process holds it) is left
    /// for a later try and counted in `blocked`, so launch never waits on the lock.
    public func recoverOrphans(lockTimeout: TimeInterval?) -> (recovered: [Meeting], blocked: Int) {
        var recovered: [Meeting] = [], blocked = 0
        for id in orphanFolders() {
            guard let meeting = orphanMeeting(id) else { continue }
            do {
                let parts = try withWriteLock(timeout: lockTimeout) { () -> [Meeting] in
                    // Another process may have written it meanwhile.
                    guard !FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent("meeting.json").path) else { return [meeting] }
                    return try writeOrphanUnlocked(meeting)
                }
                recovered += parts
            } catch is LockTimeout {
                blocked += 1
            } catch {
                continue
            }
        }
        return (recovered, blocked)
    }

    static let recoveredTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()
}
