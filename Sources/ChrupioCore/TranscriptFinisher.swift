import Foundation

/// What finishing a transcript asks the rest of the app: settings, the live recording, the project context, the
/// voice prints and the summary.
@MainActor
public protocol TranscriptFinisherEnvironment: AnyObject {
    var keepAudio: Bool { get }
    var autoSummarize: Bool { get }
    var minimumMeetingSeconds: TimeInterval { get }
    /// The language the user prefers when a chunk's guess is doubtful; nil when none is set.
    var preferredLanguage: String? { get }
    /// The meeting being recorded now, if any.
    var recordingMeetingID: UUID? { get }
    /// Every chunk the recorder produced for the meeting has reached the main actor.
    func deliveriesDone(_ id: UUID) -> Bool
    /// The saved chunks in the meeting's audio folder.
    func savedChunks(_ id: UUID) -> [AudioChunk]
    /// Pins the meeting's transcriber and engine routing to the current settings before its audio is queued again.
    func pinEngines(_ id: UUID)
    /// Project context: canonical names and expected attendees.
    func applyContext(_ meeting: inout Meeting)
    /// Names remote lines by voice and learns the voices the live signals named.
    func attributeVoices(_ meeting: inout Meeting)
    /// No call and no chunks left: the speech models can be unloaded.
    func releaseEngines()
    /// Deletes a recording too short to keep.
    func discard(_ meeting: Meeting)
    func summarizeTranscribed(_ id: UUID)
    /// Transcription or diarization started or ended: App Nap may need holding off or may be allowed again.
    func activityChanged()
}

/// Takes a meeting from its last chunk to a final transcript: chunk results merged and saved (throttled), the
/// meeting's language voted, a retranscribe's replaced lines put back on failure, a short recording discarded, the
/// call audio diarized, and the meeting completed and summarized.
@MainActor
public final class TranscriptFinisher {
    public let transcription: TranscriptionScheduler
    public let diarization: DiarizationScheduler
    private let library: MeetingLibrary
    public weak var environment: TranscriptFinisherEnvironment?
    public weak var notifier: MeetingNotifying?
    /// Speakers named while their meeting was diarizing; given once its lines are final.
    public var diarizationEdits = DiarizationEdits()
    /// When each meeting was last saved for a finished chunk; chunk saves are throttled to one per 30 s.
    private var lastChunkPersist: [UUID: Date] = [:]
    /// Lines a retranscribe removed; put back for chunks that fail.
    private var replacedSegments: [UUID: [TranscriptSegment]] = [:]
    private var languageVotes: [UUID: LanguageVote] = [:]

    public init(library: MeetingLibrary, transcription: TranscriptionScheduler, diarization: DiarizationScheduler) {
        self.library = library
        self.transcription = transcription
        self.diarization = diarization
        transcription.onFinished = { [unowned self] chunk, meetingID, result, engine, seconds in
            finishChunk(chunk, meetingID: meetingID, result: result, engine: engine, seconds: seconds)
        }
        diarization.meeting = { id in library.meeting(id) }
        diarization.onDropped = { [unowned self] id in
            library.phases.send(.diarizationFinished, to: id)
            environment?.activityChanged()
        }
        diarization.onFinished = { [unowned self] id, segments, voices, failures in
            finishDiarizing(id, segments: segments, voices: voices, failures: failures)
        }
    }

    public var queue: ChunkQueue { transcription.queue }

    /// The meeting's language so far, from the chunks transcribed.
    public func votedLanguage(_ meetingID: UUID) -> String? { languageVotes[meetingID].flatMap { $0.confirmed ?? $0.majority } }

    /// The language three moments in a row agreed on, nil until then.
    public func confirmedLanguage(_ meetingID: UUID) -> String? { languageVotes[meetingID]?.confirmed }

    /// - Parameter first: goes ahead of the queue (a chunk redone on Parakeet, so the transcript fills in from the start).
    public func enqueue(_ chunk: AudioChunk, for meetingID: UUID, first: Bool = false) {
        guard !chunk.isSilent else {
            if environment?.keepAudio == false { MeetingLibrary.removeChunkFiles(chunk) }
            return
        }
        transcription.enqueue(chunk, for: meetingID, first: first)
        environment?.activityChanged()
        transcription.processJobs()
    }

    /// The scheduler starts the next chunk after this.
    func finishChunk(_ chunk: AudioChunk, meetingID: UUID?, result: Result<TranscriptionPipeline.ChunkResult, Error>,
                       engine: SpeechEngine = .whisper, seconds: TimeInterval = 0, now: Date = Date()) {
        guard let meetingID, let environment, let index = library.index(of: meetingID) else { return }
        var stats = library.meetings[index].transcriptionStats ?? TranscriptionStats()
        let failed = if case .failure = result { true } else { false }
        stats.record(engine: engine, audioSeconds: chunk.duration, computeSeconds: seconds, failed: failed)
        library.meetings[index].transcriptionStats = stats
        switch result {
        case .success(let prepared):
            if library.meetings[index].language == nil,
               let language = languageVotes[meetingID, default: LanguageVote(preferred: environment.preferredLanguage)]
                   .record(prepared.language, speechCount: prepared.speechCount, at: chunk.startOffset) {
                library.meetings[index].language = language
            }
            // Names show up in the live transcript (MCP, panel) instead of only after the call; only the new lines are named.
            TranscriptionPipeline.merge(prepared.segments, into: &library.meetings[index])
            // Delete the audio only once the text it became is safely on disk.
            // System audio stays until the call ends: the diarizer tells the voices apart from all of it at once.
            if !environment.keepAudio, chunk.track == .mic { library.removeAfterSave(chunk, of: meetingID) }
            // Saved at most every 30 s while chunks finish, and once when the meeting finishes; the audio stays until then.
            if now.timeIntervalSince(lastChunkPersist[meetingID] ?? .distantPast) >= TranscriptionPipeline.persistInterval {
                lastChunkPersist[meetingID] = now
                library.persist(library.meetings[index])
            }
            finishIfReady(meetingID)
            return
        case .failure(let error):
            if let replaced = replacedSegments[meetingID] {
                let old = replaced.filter { TranscriptAssembler.removing([$0], coveredBy: [chunk]).isEmpty }
                library.meetings[index].segments = (library.meetings[index].segments + old).sorted { $0.start < $1.start }
            }
            // Keep the audio so the meeting can be retranscribed once the problem is fixed.
            library.meetings[index].error = "Part of the audio couldn't be transcribed: \(error.localizedDescription) Fix it, then use More > Retranscribe audio."
            CoreLog.coordinator.error("transcription failed: \(error.localizedDescription, privacy: .public)")
        }
        library.persist(library.meetings[index])
        finishIfReady(meetingID)
    }

    /// Finishes the meeting once every chunk is in and transcribed: a short recording is discarded, call audio is
    /// diarized, anything else completes now.
    public func finishIfReady(_ meetingID: UUID) {
        guard let environment else { return }
        let recording = environment.recordingMeetingID != nil
        // Echo removal and diarization wait for the call to end, like transcription; stopping resumes them.
        guard queue.isReady(meetingID, recording: recording, deliveriesDone: environment.deliveriesDone(meetingID)),
              let index = library.index(of: meetingID) else { return }
        let failures = transcription.finish(meetingID)
        lastChunkPersist[meetingID] = nil
        if !recording, queue.jobs.isEmpty { environment.releaseEngines() }
        replacedSegments[meetingID] = nil
        let languages = languageVotes.removeValue(forKey: meetingID)
        var meeting = library.meetings[index]

        let discardable = library.phases.send(.transcribed, to: meetingID) == .transcribing(discardIfShort: true)
        if discardable, meeting.duration < environment.minimumMeetingSeconds {
            CoreLog.coordinator.info("discarding short meeting \(meetingID, privacy: .public)")
            environment.discard(meeting)
            notifier?.post(title: "Recording discarded",
                           body: "\(meeting.title) was shorter than \(Int(environment.minimumMeetingSeconds)) seconds. Change the minimum in Settings.")
            return
        }
        // Tells the summary which language to write in when nothing was pinned.
        if meeting.language == nil { meeting.language = languages?.majority }
        meeting.segments = TranscriptAssembler.removeEcho(meeting.segments)
        environment.applyContext(&meeting)
        SpeakerAttribution.apply(to: &meeting)
        let system = environment.savedChunks(meetingID).filter { $0.track == .system && !$0.isSilent }
        guard !system.isEmpty, meeting.segments.contains(where: { !$0.speaker.isMe }) else {
            environment.attributeVoices(&meeting)
            complete(meeting, failures: failures)
            return
        }
        library.meetings[index] = meeting
        library.persist(meeting)
        library.phases.send(.diarizationStarted, to: meetingID)
        environment.activityChanged()
        diarization.enqueue(meetingID, system: system, failures: failures)
    }

    /// Re-runs transcription over the saved audio chunks of a meeting.
    public func retranscribe(_ meetingID: UUID) {
        guard let environment, environment.recordingMeetingID != meetingID, queue.pending[meetingID] == nil,
              library.phases[meetingID]?.isSummarizing != true,
              // Queuing a chunk that is still in flight would leave the meeting "transcribing" forever.
              !queue.finishing.contains(meetingID), library.phases[meetingID] != .diarizing, environment.deliveriesDone(meetingID),
              let index = library.index(of: meetingID) else { return }
        let chunks = environment.savedChunks(meetingID)
        guard !chunks.isEmpty else {
            library.update(meetingID) { $0.error = "No saved audio for this meeting. Turn on Keep audio in Settings to allow retranscribing." }
            return
        }
        // Replace only what this audio covers; with Keep audio off, chunks transcribed earlier are already gone.
        let kept = TranscriptAssembler.removing(library.meetings[index].segments, coveredBy: chunks)
        replacedSegments[meetingID] = library.meetings[index].segments.filter { !kept.contains($0) }
        library.meetings[index].segments = kept
        // Detect again: the settings or the model may have changed since the first pass.
        library.meetings[index].language = nil
        library.meetings[index].transcriptionStats = nil
        library.meetings[index].status = .transcribing
        library.meetings[index].error = nil
        library.meetings[index].summaryError = nil
        library.persist(library.meetings[index])
        transcription.startFinishing(meetingID)
        library.phases.send(.transcriptionQueued, to: meetingID)
        environment.pinEngines(meetingID)
        for chunk in chunks { enqueue(chunk, for: meetingID) }
        finishIfReady(meetingID)
    }

    /// Puts the diarized lines back, or names voices the older way when the diarizer couldn't run.
    func finishDiarizing(_ meetingID: UUID, segments: [TranscriptSegment]?, voices: [String: [Float]]?, failures: Int) {
        library.phases.send(.diarizationFinished, to: meetingID)
        environment?.activityChanged()
        guard var meeting = library.meeting(meetingID) else { return }
        // Starts from the meeting as it is now, so edits made while diarizing stay; waiting names are given here.
        // Voices first, so a waiting name moves its label's voice too.
        meeting.speakerVoices = voices
        diarizationEdits.finish(meetingID, meeting: &meeting, diarized: segments)
        if segments == nil { environment?.attributeVoices(&meeting) }
        complete(meeting, failures: failures)
    }

    private func complete(_ meeting: Meeting, failures: Int) {
        guard let environment, let index = library.index(of: meeting.id) else { return }
        var meeting = meeting
        let meetingID = meeting.id
        meeting.status = failures > 0 && meeting.segments.isEmpty ? .failed : .done
        library.meetings[index] = meeting
        let deleteAudio = !environment.keepAudio && failures == 0
        let store = library.store
        library.persist(meeting) { saved in if saved, deleteAudio { store.deleteAudio(meetingID) } }
        if meeting.status == .failed {
            notifier?.post(title: "Couldn't transcribe meeting", body: meeting.error ?? meeting.title)
        } else if meeting.segments.isEmpty {
            notifier?.post(title: "No speech captured", body: "\(meeting.title) has no transcript. Check the microphone and system audio permissions.")
        } else if environment.autoSummarize {
            environment.summarizeTranscribed(meetingID)
        } else {
            notifier?.post(title: "Meeting notes ready", body: meeting.title)
        }
    }
}
