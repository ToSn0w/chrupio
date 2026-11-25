import Foundation

/// The transcription queue: chunks waiting for the engine, which meeting each belongs to, how many of a meeting's
/// chunks are still out, how many failed, and the meetings that end once their last chunk is in.
public struct ChunkQueue: Sendable {
    public private(set) var jobs: [AudioChunk] = []
    private var owners: [URL: UUID] = [:]
    /// Chunks queued or being transcribed, per meeting; no entry once none are left.
    public private(set) var pending: [UUID: Int] = [:]
    private var failures: [UUID: Int] = [:]
    /// Meetings whose recording ended and which finish once nothing is pending.
    public private(set) var finishing: Set<UUID> = []

    public init() {}

    /// - Parameter first: goes ahead of the queue.
    public mutating func enqueue(_ chunk: AudioChunk, for meetingID: UUID, first: Bool = false) {
        if first { jobs.insert(chunk, at: 0) } else { jobs.append(chunk) }
        owners[chunk.url] = meetingID
        pending[meetingID, default: 0] += 1
    }

    public func meeting(of chunk: AudioChunk) -> UUID? { owners[chunk.url] }

    /// The next chunk to transcribe; it stays pending until `completed`.
    public mutating func next() -> AudioChunk? { jobs.isEmpty ? nil : jobs.removeFirst() }

    /// A chunk is done, transcribed or not; returns its meeting.
    @discardableResult
    public mutating func completed(_ chunk: AudioChunk, failed: Bool = false) -> UUID? {
        guard let meetingID = owners.removeValue(forKey: chunk.url) else { return nil }
        pending[meetingID, default: 1] -= 1
        if pending[meetingID] == 0 { pending[meetingID] = nil }
        if failed { failures[meetingID, default: 0] += 1 }
        return meetingID
    }

    public mutating func startFinishing(_ meetingID: UUID) { finishing.insert(meetingID) }

    /// Whether the meeting can finish now: its recording is over, it was ended, no chunk is pending and the
    /// recorder has handed over every chunk it was writing.
    public func isReady(_ meetingID: UUID, recording: Bool, deliveriesDone: Bool) -> Bool {
        !recording && finishing.contains(meetingID) && pending[meetingID] == nil && deliveriesDone
    }

    /// Ends the meeting's turn in the queue; returns how many of its chunks failed.
    public mutating func finish(_ meetingID: UUID) -> Int {
        finishing.remove(meetingID)
        return failures.removeValue(forKey: meetingID) ?? 0
    }
}

/// The order of a recording's start and stop, apart from the recorder and the UI.
public enum RecordingSession {
    public enum Start {
        case recording(Meeting)
        case failed(Meeting, message: String)
    }

    /// The meeting is saved before the recorder writes any audio, so a hang or crash after this leaves a meeting,
    /// not an orphan folder. If the recorder can't start, the meeting is saved again as failed.
    public static func start(_ meeting: Meeting, save: (Meeting) -> Void, startRecorder: () throws -> Void,
                             now: () -> Date = Date.init) -> Start {
        save(meeting)
        do {
            try startRecorder()
            return .recording(meeting)
        } catch {
            var failed = meeting
            let message = "Couldn't start recording: \(error.localizedDescription)"
            failed.status = .failed
            failed.endedAt = now()
            failed.error = message
            save(failed)
            return .failed(failed, message: message)
        }
    }

    /// The meeting as it is once the call ends: the open speaker run closed, ended, waiting for its last chunks.
    public static func stopped(_ meeting: inout Meeting, openRun: SpeakerEvent?, at endedAt: Date) {
        if let openRun { meeting.speakerEvents.append(openRun) }
        meeting.endedAt = endedAt
        meeting.status = .transcribing
    }

    public static func finalWriteMessage(_ failure: String) -> String {
        "The end of the recording couldn't be saved to disk: \(failure) That part of the call is missing."
    }
}
