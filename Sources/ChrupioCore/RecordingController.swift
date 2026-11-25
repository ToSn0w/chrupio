import Foundation
import Observation
import os

/// The recorder a recording drives: `AudioRecorder` in the app, a fake in tests.
public protocol AudioRecording: AnyObject, Sendable {
    var micLevel: Float { get }
    var systemLevel: Float { get }
    var systemPeakLevel: Float { get }
    var systemCaptureError: String? { get }
    var writeError: String? { get }
    func start(captureSystemAudio: Bool) throws
    /// Flushes and returns the last chunks; writes files, so never called on the main thread.
    func stop() -> [AudioChunk]
    func reviveStalledTracks(now: Date)
    func lostTracks(now: Date) -> Set<AudioChunk.Track>
}

extension AudioRecorder: AudioRecording {}

/// Keeps the Mac awake (and the app from being terminated) while the last audio of a sleep-triggered stop is written.
public protocol SleepHolding: AnyObject, Sendable {
    func hold(reason: String) -> NSObjectProtocol
    func release(_ token: NSObjectProtocol)
}

public final class ProcessSleepHold: SleepHolding, Sendable {
    public init() {}
    public func hold(reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: reason)
    }
    public func release(_ token: NSObjectProtocol) { ProcessInfo.processInfo.endActivity(token) }
}

/// Counts chunks the audio queue has handed to the main actor but that haven't arrived yet,
/// so a meeting isn't finished while its last chunks are in flight.
public final class ChunkDeliveries: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: [UUID: Int]())
    public init() {}
    public func add(_ meetingID: UUID) { counts.withLock { $0[meetingID, default: 0] += 1 } }
    public func remove(_ meetingID: UUID) {
        counts.withLock {
            $0[meetingID, default: 1] -= 1
            if $0[meetingID] == 0 { $0[meetingID] = nil }
        }
    }
    public func isEmpty(_ meetingID: UUID) -> Bool { counts.withLock { $0[meetingID] == nil } }
}

/// The call being recorded now.
public struct ActiveRecording {
    public var meetingID: UUID
    public var recorder: AudioRecording
    /// Detector key that started it; nil for manual recordings.
    public var candidateKey: String?
    /// Where attendees, title and speakers come from; set for manual recordings of a detected call too.
    public var sourceKey: String?
    public var startedAt: Date
    public var lastAudible: Date
    public var warnedNoSystemAudio = false
    public var warnedWriteError = false
    public var warnedNoSpeakers = false
    /// Tracks whose device has delivered nothing for a while; warned about until they return.
    public var lostTracks: Set<AudioChunk.Track> = []
    /// Speaker events change every tick; saving them is throttled to this.
    public var lastLivePersist = Date.distantPast
    /// Who is talking now; stored in the meeting when the speakers change or before a save.
    public var speakerRun = SpeakerRun()

    public init(meetingID: UUID, recorder: AudioRecording, candidateKey: String?, sourceKey: String?, startedAt: Date = Date()) {
        self.meetingID = meetingID
        self.recorder = recorder
        self.candidateKey = candidateKey
        self.sourceKey = sourceKey
        self.startedAt = startedAt
        self.lastAudible = startedAt
    }
}

/// What the recording controller asks the rest of the app, and tells it.
@MainActor
public protocol RecordingControllerEnvironment: AnyObject {
    var captureSystemAudio: Bool { get }
    func makeRecorder(directory: URL, onChunk: @escaping AudioRecorder.ChunkHandler) -> AudioRecording
    /// Problems that would leave the recording silent or untranscribed; shown on the meeting.
    func setupProblem() -> String?
    /// Fills in what the detector knows about the call (self name, attendees) before the meeting is first saved.
    func prepare(_ meeting: inout Meeting, for candidate: MeetingCandidate)
    /// The recorder runs; the meeting's transcriber can be fixed and early diagnostics written.
    func recordingStarted(_ meeting: Meeting, candidate: MeetingCandidate, manual: Bool)
    /// The recorder couldn't start; the detector should not retry this call.
    func recordingFailed(candidate: MeetingCandidate, manual: Bool)
    /// The call ended; its last chunks are being flushed. `hadMeeting` is false when the meeting was deleted.
    func recordingStopped(_ meetingID: UUID, hadMeeting: Bool)
    /// A chunk written during the call reached the main actor.
    func chunkArrived(_ chunk: AudioChunk, for meetingID: UUID)
    /// The recorder stopped and handed over its final chunks.
    func lastChunksArrived(_ chunks: [AudioChunk], for meetingID: UUID)
    /// Recording started or stopped: App Nap may need holding off or may be allowed again.
    func activityChanged()
}

/// Starts and stops recordings: the meeting is saved before any audio is written, chunks are counted until they
/// reach the main actor, stopping flushes the recorder off the main thread (holding off sleep when the lid closed),
/// and while recording it warns about lost devices, silent call audio and failing writes, and ends a recording
/// left running after the call or for hours.
@MainActor
@Observable
public final class RecordingController {
    public private(set) var recording: ActiveRecording?

    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored public weak var environment: RecordingControllerEnvironment?
    @ObservationIgnored public weak var notifier: MeetingNotifying?
    @ObservationIgnored public let deliveries = ChunkDeliveries()
    @ObservationIgnored private let sleepHold: SleepHolding
    @ObservationIgnored private let limits: RecordingLimits
    /// Recorder stops still flushing their last chunks; quitting waits for them.
    @ObservationIgnored public private(set) var stopTasks: [UUID: Task<Void, Never>] = [:]
    /// Held from a sleep-triggered stop until its last chunks are written.
    @ObservationIgnored public private(set) var sleepActivities: [UUID: NSObjectProtocol] = [:]

    public init(library: MeetingLibrary, sleepHold: SleepHolding = ProcessSleepHold(), limits: RecordingLimits = RecordingLimits()) {
        self.library = library
        self.sleepHold = sleepHold
        self.limits = limits
    }

    public var isRecording: Bool { recording != nil }

    /// Changes the running recording (speaker runs, hand-over keys, warnings); nothing happens when none runs.
    public func modify(_ change: (inout ActiveRecording) -> Void) {
        guard recording != nil else { return }
        change(&recording!)
    }

    // MARK: Start

    /// Records `candidate`; manual recordings stop only manually. Returns the new meeting's id, nil when the
    /// recorder couldn't start (the meeting is then saved as failed and `lastError` says why).
    @discardableResult
    public func start(_ candidate: MeetingCandidate, manual: Bool) -> UUID? {
        guard recording == nil, let environment else { return nil }
        var meeting = Meeting(title: candidate.title ?? candidate.platform.displayName, platform: candidate.platform, url: candidate.url)
        environment.prepare(&meeting, for: candidate)
        let meetingID = meeting.id
        let deliveries = deliveries
        let recorder = environment.makeRecorder(directory: library.store.audioDirectory(for: meetingID)) { [weak self] chunk in
            deliveries.add(meetingID)
            Task { @MainActor in self?.deliver(chunk, for: meetingID) }
        }
        let problem = environment.setupProblem()
        if let problem { meeting.error = problem }
        // Saved before any audio is written: a hang or crash after this point leaves a meeting, not an orphan folder.
        library.meetings.insert(meeting, at: 0)
        let capture = environment.captureSystemAudio
        let started = RecordingSession.start(meeting, save: { saved in
            if let index = library.index(of: saved.id) { library.meetings[index] = saved }
            library.persist(saved)
        }, startRecorder: { try recorder.start(captureSystemAudio: capture) })
        if case .failed(_, let message) = started {
            library.lastError = message
            notifier?.post(title: "Recording failed", body: message)
            // Don't retry (and re-notify) every few seconds; wait until this call ends.
            environment.recordingFailed(candidate: candidate, manual: manual)
            return nil
        }
        if let problem { notifier?.post(title: "Chrupio needs setup", body: problem) }
        library.phases.send(.recordingStarted, to: meetingID)
        recording = ActiveRecording(meetingID: meetingID, recorder: recorder, candidateKey: manual ? nil : candidate.key,
                                    sourceKey: candidate.key == "manual" ? nil : candidate.key)
        environment.recordingStarted(meeting, candidate: candidate, manual: manual)
        environment.activityChanged()
        notifier?.post(title: "Taking notes", body: "Recording \(meeting.title). Open the menu bar icon to stop.")
        CoreLog.coordinator.info("started recording \(meetingID, privacy: .public) for \(candidate.key, privacy: .public)")
        return meetingID
    }

    private func deliver(_ chunk: AudioChunk, for meetingID: UUID) {
        deliveries.remove(meetingID)
        environment?.chunkArrived(chunk, for: meetingID)
    }

    // MARK: Stop

    /// - Parameter holdingOffSleep: the Mac is about to sleep; keep it awake until the last chunks are on disk,
    ///   or a battery that dies during sleep loses them.
    public func stop(holdingOffSleep: Bool = false) {
        guard var current = recording else { return }
        recording = nil
        let meetingID = current.meetingID
        CoreLog.coordinator.info("stopping \(meetingID, privacy: .public)\(holdingOffSleep ? " before sleep" : "", privacy: .public)")
        if holdingOffSleep {
            sleepActivities[meetingID] = sleepHold.hold(reason: "Saving the last audio before sleep")
        }
        for track in current.lostTracks { notifier?.remove(identifier: Self.lostTrackNotification(track, meetingID)) }
        let endedAt = Date()
        var hadMeeting = false
        if let index = library.index(of: meetingID) {
            RecordingSession.stopped(&library.meetings[index], openRun: current.speakerRun.close(), at: endedAt)
            library.phases.send(.stopRequested, to: meetingID)
            hadMeeting = true
        }
        // Counted as a delivery until the last chunks are queued, so the meeting can't finish without them.
        deliveries.add(meetingID)
        let recorder = current.recorder
        // Flushing the last chunks writes WAV files and can wait on the audio queue: never on the main thread.
        stopTasks[meetingID] = Task.detached(priority: .userInitiated) { [weak self] in
            let lastChunks = recorder.stop()
            let failure = recorder.writeError
            await self?.finishStopping(meetingID, lastChunks: lastChunks, writeError: failure)
        }
        environment?.recordingStopped(meetingID, hadMeeting: hadMeeting)
    }

    /// Stops the recording and waits for every recorder stop still flushing its last chunks, including one
    /// started just before.
    public func stopAndWait() async {
        stop()
        while let (_, task) = stopTasks.first { await task.value }
    }

    private func finishStopping(_ meetingID: UUID, lastChunks: [AudioChunk], writeError: String?) {
        defer {
            if let activity = sleepActivities.removeValue(forKey: meetingID) { sleepHold.release(activity) }
        }
        CoreLog.coordinator.info("stopped \(meetingID, privacy: .public): \(lastChunks.count, privacy: .public) final chunks")
        stopTasks[meetingID] = nil
        deliveries.remove(meetingID)
        library.phases.send(.lastChunksQueued, to: meetingID)
        if let index = library.index(of: meetingID) {
            if let failure = writeError {
                CoreLog.coordinator.error("final audio write failed for \(meetingID, privacy: .public): \(failure, privacy: .public)")
                let message = RecordingSession.finalWriteMessage(failure)
                library.meetings[index].error = message
                notifier?.post(title: "Recording incomplete", body: message, important: true)
            }
            library.persist(library.meetings[index])
        }
        // The final chunks are queued before checking for completion, or the meeting would finish without them.
        environment?.lastChunksArrived(lastChunks, for: meetingID)
    }

    // MARK: While recording

    /// The 2 s checks of a running recording. Returns whether the recording was ended (left running after the
    /// call, or for hours).
    public func tick(now: Date) -> Bool {
        guard let recording else { return false }
        recording.recorder.reviveStalledTracks(now: now)
        checkLostTracks(now: now)
        checkSystemAudio(now: now)
        checkAudioWrites()
        return checkLimits(now: now)
    }

    /// macOS returns silence instead of an error when system audio recording isn't allowed.
    private func checkSystemAudio(now: Date) {
        guard var current = recording, environment?.captureSystemAudio == true, !current.warnedNoSystemAudio else { return }
        let message: String
        if let systemError = current.recorder.systemCaptureError {
            message = "Only your microphone is recorded. \(systemError)"
        } else if now.timeIntervalSince(current.startedAt) > 90, current.recorder.systemPeakLevel == 0 {
            message = "No sound from the other participants yet. If they are talking, allow Chrupio in System Settings > Privacy & Security > Screen & System Audio Recording."
        } else {
            return
        }
        current.warnedNoSystemAudio = true
        recording = current
        library.update(current.meetingID) { if $0.error == nil { $0.error = message } }
        notifier?.post(title: "Can't hear the other participants", body: message)
    }

    /// Ends a recording left running after the call (both tracks silent) or for hours; returns whether it stopped.
    private func checkLimits(now: Date) -> Bool {
        guard let current = recording else { return false }
        if max(current.recorder.micLevel, current.recorder.systemLevel) >= RecordingLimits.audibleLevel {
            recording?.lastAudible = now
            return false
        }
        guard let reason = limits.stopReason(startedAt: current.startedAt, lastAudible: current.lastAudible,
                                             detected: current.candidateKey != nil, now: now) else { return false }
        CoreLog.coordinator.info("auto-stopping \(current.meetingID, privacy: .public): \(reason, privacy: .public)")
        let title = library.meeting(current.meetingID)?.title ?? "Meeting"
        stop()
        notifier?.post(title: "Recording stopped", body: "\(title): \(reason)")
        return true
    }

    /// A track whose device is gone is recorded as silence: warn once it has been gone a while, and take the
    /// notification back when it returns. The menu bar icon turns red meanwhile, in case notifications are off.
    private func checkLostTracks(now: Date) {
        guard var current = recording else { return }
        let lost = current.recorder.lostTracks(now: now)
        guard lost != current.lostTracks else { return }
        for track in lost.subtracting(current.lostTracks) {
            let message = Self.lostTrackMessage(track)
            CoreLog.coordinator.error("\(track.rawValue, privacy: .public) track lost in \(current.meetingID, privacy: .public)")
            library.update(current.meetingID) { $0.error = message }
            notifier?.post(title: track == .mic ? "Microphone lost" : "Call audio lost", body: message, important: true,
                           identifier: Self.lostTrackNotification(track, current.meetingID))
        }
        for track in current.lostTracks.subtracting(lost) {
            CoreLog.coordinator.info("\(track.rawValue, privacy: .public) track back in \(current.meetingID, privacy: .public)")
            notifier?.remove(identifier: Self.lostTrackNotification(track, current.meetingID))
            let gap = track == .mic ? "Your microphone was lost for part of the call; that stretch has no audio from you."
                : "The call audio was lost for part of the call; that stretch has no audio from the others."
            library.update(current.meetingID) { if $0.error == Self.lostTrackMessage(track) { $0.error = gap } }
        }
        current.lostTracks = lost
        recording = current
    }

    public static func lostTrackMessage(_ track: AudioChunk.Track) -> String {
        track == .mic
            ? "Your microphone stopped sending audio, so you're being recorded as silence. Check the headset, or pick another input in System Settings > Sound."
            : "The call audio stopped, so the other participants are being recorded as silence. Check the output device in System Settings > Sound."
    }

    public static func lostTrackNotification(_ track: AudioChunk.Track, _ meetingID: UUID) -> String {
        "lost-\(track.rawValue)-\(meetingID.uuidString)"
    }

    /// Audio that can't be written stays in memory, so tell the user to free space before it's lost.
    private func checkAudioWrites() {
        guard var current = recording else { return }
        let failure = current.recorder.writeError
        guard (failure != nil) != current.warnedWriteError else { return }
        current.warnedWriteError = failure != nil
        recording = current
        guard let failure else { return }
        let message = "Can't save audio to disk: \(failure) It's kept in memory for up to 20 minutes; free up disk space."
        library.update(current.meetingID) { $0.error = message }
        notifier?.post(title: "Recording can't be saved", body: message, important: true)
    }
}
