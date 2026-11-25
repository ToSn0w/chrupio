import AppKit
import Foundation
import Observation
import ChrupioAudio
import ChrupioCore
import os

private let log = Logger(subsystem: "Chrupio", category: "coordinator")

/// Detects meetings, records them, and runs transcription and summaries.
@MainActor
@Observable
final class MeetingCoordinator {
    static let shared = MeetingCoordinator()

    /// The meetings, their phases and every save.
    let library = MeetingLibrary(saver: MeetingSaver(store: MeetingStore()))
    var meetings: [Meeting] {
        get { library.meetings }
        set { library.meetings = newValue }
    }
    /// Starts and stops recordings and watches the running one.
    @ObservationIgnored private lazy var recorder = RecordingController(library: library)
    var recording: ActiveRecording? { recorder.recording }
    private(set) var detectedCandidate: MeetingCandidate?
    /// What the extension and Zoom report about the recorded call.
    @ObservationIgnored private lazy var live: LiveCallMonitor = {
        let monitor = LiveCallMonitor(library: library, recorder: recorder)
        monitor.notifier = notifier
        monitor.selfNames = { AppSettings.shared.selfNameList }
        monitor.saveDiagnostics = { AppSettings.shared.saveDiagnostics }
        return monitor
    }()
    /// Version the loaded extension reports; nil until it reports one (versions before 0.2.0 never do).
    var extensionVersion: String? { live.extensionVersion }
    private(set) var serverError: String?
    /// Chunks of each meeting still queued or being transcribed.
    var pendingChunks: [UUID: Int] { transcription.queue.pending }
    /// Each meeting's place in the pipeline (stopping, transcribing, diarizing, summarizing, summary failed).
    private var phases: MeetingPhases {
        get { library.phases }
        set { library.phases = newValue }
    }
    var summarizing: Set<UUID> { phases.summarizing }
    var lastError: String? {
        get { library.lastError }
        set { library.lastError = newValue }
    }
    /// The last Markdown export failure; cleared by the next successful export.
    private(set) var exportError: String?

    let settings = AppSettings.shared
    private let notifier = AppNotifier()
    private var store: MeetingStore { library.store }
    fileprivate var detector = MeetingDetector()
    private var server: ExtensionServer?
    private var timer: Timer?
    /// Edits by chrupio-mcp or a restore show up within a second; the 60 s scan in `tick` backs it up.
    private var folderWatch: FolderWatch?
    /// Embeds finished meetings for the MCP semantic_search tool, off the main thread; only reads meetings.
    @ObservationIgnored private lazy var semanticIndexer = SemanticIndexer(index: .standard(for: store))
    /// The chunk queue and the engines; each meeting's transcriber and routing are fixed when its audio is queued.
    /// Diarizations run one at a time, each with a deadline.
    @ObservationIgnored private lazy var finisher = TranscriptFinisher(
        library: library,
        transcription: TranscriptionScheduler(engines: AppSpeechEngines(), makeTranscriber: { MeetingCoordinator.settingsTranscriber() }),
        diarization: DiarizationScheduler { try await SpeakerDiarizer.diarize($0) })
    private var transcription: TranscriptionScheduler { finisher.transcription }
    private var diarization: DiarizationScheduler { finisher.diarization }
    private var queue: ChunkQueue { transcription.queue }
    /// False until the library is loaded off the main thread at launch; detection and manual starts wait for it.
    private var libraryLoaded = false
    /// Interrupted meetings and orphan recordings the write lock blocked at launch.
    @ObservationIgnored private lazy var orphans: OrphanRecoveryScheduler = {
        let scheduler = OrphanRecoveryScheduler(library: library, source: store)
        scheduler.environment = self
        return scheduler
    }()
    private let zoom = ZoomPoller()
    /// Keeps App Nap from throttling audio processing and transcription while there is work.
    private var activity: NSObjectProtocol?
    private var deliveries: ChunkDeliveries { recorder.deliveries }
    /// Segments a retranscription replaced, kept until their chunk transcribes again so a failure loses nothing.
    /// Summaries: fragments, post-call hold, retries, templates.
    @ObservationIgnored private lazy var summaries = SummaryScheduler(library: library)
    /// Summaries waiting for the current call to end.
    var postCallHold: PostCallHold { summaries.postCallHold }

    private var sleepObserver: NSObjectProtocol?
    /// meeting.json dates as this app last wrote or read them; a different date means another process changed it.

    private init() {
        library.hooks = self
        library.notifier = notifier
        summaries.environment = self
        summaries.notifier = notifier
        recorder.environment = self
        recorder.notifier = notifier
        // Nothing transcribes during a call, not even an earlier meeting's chunks: whisper competing with the call
        // for CPU spun the fans. `stopRecording` starts the queue again.
        transcription.mayStart = { [unowned self] in PostCallHold.mayTranscribe(recording: recording != nil) }
        transcription.prepareJob = { [unowned self] job, chunk, owner in prepareJob(&job, chunk: chunk, owner: owner) }
        finisher.environment = self
        finisher.notifier = notifier
        zoom.onSnapshot = { [unowned self] snapshot, includeParticipants, scannedAt in
            live.applyZoom(snapshot, includeParticipants: includeParticipants, scannedAt: scannedAt)
        }
        diarization.makeNaming = { [unowned self] in diarizationNaming() }
    }

    var activeMeeting: Meeting? {
        guard let id = recording?.meetingID else { return nil }
        return meetings.first { $0.id == id }
    }

    var micLevel: Float { recording?.recorder.micLevel ?? 0 }
    var systemLevel: Float { recording?.recorder.systemLevel ?? 0 }
    /// True while the mic or the call audio is being recorded as silence because its device is gone.
    var hasLostTrack: Bool { !(recording?.lostTracks.isEmpty ?? true) }

    /// A snapshot shows a connected extension rather than this Mac's state.
    var isExtensionConnected: Bool { DebugSnapshot.directory != nil || live.isExtensionConnected() }

    var isChromeRunning: Bool {
        DebugSnapshot.directory != nil || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    func start() {
        // Starts the login-shell lookup for claude (nvm, volta, bun) now, so it is done or running by the time
        // pending summaries are retried; each summary waits for it rather than failing as "not installed".
        _ = ClaudeCLIStore.shared.current()
        Task.detached(priority: .utility) {
            do { try await VADModel.ensureDownloaded() } catch { log.error("VAD model download failed: \(error.localizedDescription, privacy: .public)") }
            do { try await SpeakerDiarizer.prepare() } catch { log.error("diarizer model download failed: \(error.localizedDescription, privacy: .public)") }
            do { try await EchoCanceller.download() } catch { log.error("echo model download failed: \(error.localizedDescription, privacy: .public)") }
        }
        // The library (several MB of JSON) is read off the main thread; detection starts once it is in.
        let store = store
        let selfNames = settings.selfNameList
        Task {
            let (loaded, dates, blocked) = await Task.detached(priority: .userInitiated) { () -> ([Meeting], [UUID: Date], Int) in
                let orphans = store.recoverOrphans(lockTimeout: OrphanRecoveryScheduler.lockTimeout)
                for orphan in orphans.recovered { log.info("recovered orphan recording \(orphan.id, privacy: .public)") }
                if orphans.blocked > 0 { log.error("write lock held: \(orphans.blocked, privacy: .public) orphan recordings left for later") }
                Self.repairStoredMeetingsOnce(store: store, selfNames: selfNames)
                return (store.loadAll(), store.modificationDates(), orphans.blocked)
            }.value
            self.finishLaunch(loaded: loaded, modified: dates, blockedOrphans: blocked)
        }
        let live = live
        let server = ExtensionServer(version: Bundle.main.shortVersion, apiToken: LocalAPI.ensureToken(), onEdit: { [weak self] request in
            await self?.applyRemoteEdit(request) ?? (status: 503, response: LocalAPI.EditResponse(ok: false, message: "Chrupio is quitting"))
        }, onHello: { [weak live] version in
            Task { @MainActor in live?.hello(version) }
        }, onSnapshot: { [weak live] data in
            let platform = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["platform"] as? String ?? "call"
            // Runs off the main actor, so the setting is read from UserDefaults rather than AppSettings.
            if UserDefaults.standard.bool(forKey: "saveDiagnostics"), let url = SnapshotStore.default.save(data, platform: platform) { log.info("saved page snapshot \(url.lastPathComponent, privacy: .public)") }
            if let entry = CallDiagnostics.snapshotEntry(data), let key = entry.key {
                Task { @MainActor in live?.snapshot(entry.snapshot, key: key) }
            }
        }) { [weak live] event in
            Task { @MainActor in live?.handle(event) }
        }
        // A file left by a crash never points chrupio-mcp at a port this copy hasn't opened yet; another running
        // Chrupio of this account (a second copy started next to it) keeps its file.
        LocalAPI.clearStaleEndpoint()
        do {
            // While the port is busy (an old copy's closed connections hold it for up to 30 s) nothing is shown;
            // onFailure comes only once the retries run out.
            try server.start(onReady: { port in
                do { try LocalAPI.recordEndpoint(port: port) } catch { log.error("couldn't record the edit API port: \(error.localizedDescription, privacy: .public)") }
            }, onFailure: { [weak self] failure in
                // A listener that stopped no longer takes edits: chrupio-mcp writes the files directly instead.
                LocalAPI.clearOwnEndpoint()
                Task { @MainActor in self?.serverFailed(failure) }
            })
            self.server = server
        } catch {
            serverFailed(.couldNotListen(error.localizedDescription))
        }
        // A closed lid ends the call for us; recording through sleep would pad hours of silence.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording(holdingOffSleep: true)
                // A call still open after wake is a new meeting, not the one that was just stopped.
                self?.detector.reset()
            }
        }
    }

    /// Publishes the library loaded at launch, then starts the work that needs it.
    private func finishLaunch(loaded: [Meeting], modified: [UUID: Date], blockedOrphans: Int) {
        // Nothing records before this, but an external change may have been picked up already.
        let present = Set(meetings.map(\.id))
        meetings = (meetings + loaded.filter { !present.contains($0.id) }).sorted { $0.startedAt > $1.startedAt }
        if settings.selfNames.isEmpty, let usual = SelfNames.usual(in: meetings) { settings.selfNames = usual }
        library.saver.external = ExternalChanges(known: modified)
        libraryLoaded = true
        orphans.launchFinished(blockedOrphans: blockedOrphans)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.5
        folderWatch = FolderWatch(root: store.root) { [weak self] in
            Task { @MainActor in self?.reloadExternalChanges() }
        }
        folderWatch?.start()
        // Backfill the semantic index once launch work has settled; meetings already indexed are skipped.
        let indexer = semanticIndexer
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(30))
            indexer.enqueue(loaded)
        }
        // Notes written before 0600 was the rule: tighten them once per launch, off the main thread, even with
        // export off (the notes already on disk are still readable). A missing folder is left alone.
        let notesFolder = URL(fileURLWithPath: settings.exportFolderPath, isDirectory: true)
        let isDefault = MeetingExporter.isDefaultFolder(notesFolder)
        Task.detached(priority: .utility) {
            let changed = FilePermissions.tighten(folder: notesFolder, includingFolder: isDefault)
            if changed > 0 { log.info("made \(changed) note file(s) private") }
        }
    }

    private func serverFailed(_ failure: ExtensionServer.Failure) {
        switch failure {
        case .couldNotListen:
            serverError = "Chrupio couldn't open port \(ExtensionServer.defaultPort) for the Chrome extension. Another program may be using it; quit it, then quit and reopen Chrupio."
        case .stoppedListening:
            serverError = "Chrupio stopped listening on port \(ExtensionServer.defaultPort) for the Chrome extension. Quit and reopen Chrupio."
        }
        log.error("extension server failed: \(failure.message, privacy: .public)")
    }

    // MARK: - Detection

    private func tick() {
        updateActivity()
        let now = Date()
        library.retryDeferredSaves(now: now)
        library.reloadExternalChangesIfDue(now: now)
        runAudioRetentionIfDue(now: now)
        summaries.retryPendingIfDue(now: now)
        orphans.retryBlockedIfDue(now: now)
        let candidates = currentCandidates(now: now)
        detectedCandidate = candidates.first
        if recording != nil {
            live.tick(now: now)
            if recorder.tick(now: now) {
                // Don't start again on the same open tab or app until it goes away.
                if detector.active == nil, let candidate = detectedCandidate { detector.adopt(candidate, now: now) }
                return
            }
        }
        guard settings.autoRecord || recording?.candidateKey != nil else {
            detector.reset()
            return
        }
        switch detector.update(candidates: candidates, now: now) {
        case .start(let candidate):
            guard settings.autoRecord, recording == nil else { return }
            startRecording(candidate: candidate)
        case .handOver(let candidate):
            live.handOver(to: candidate)
        case .stop:
            if recording?.candidateKey != nil { stopRecording() }
        case nil:
            break
        }
    }

    static let browserFallbackEndGrace: TimeInterval = 5

    private func currentCandidates(now: Date) -> [MeetingCandidate] {
        var candidates = live.candidates(now: now)
        let micUsers = ProcessAudioMonitor.processesUsingMicrophone()

        zoom.poll(now: now, recordingZoom: recording?.sourceKey == "zoom")
        if let zoom = zoom.snapshot, zoom.isRunning, zoom.hasMeetingWindow || ProcessAudioMonitor.isZoomUsingMicrophone(micUsers) {
            candidates.append(MeetingCandidate(key: "zoom", platform: .zoom, title: zoom.title.map { $0 == "Zoom Meeting" ? "Zoom meeting" : $0 }))
        }

        if settings.detectWithoutExtension {
            // Without the extension, a known meeting app holding the mic is treated as a call.
            let browserBusy = candidates.contains { $0.key.hasPrefix("chrome-tab:") }
            for process in micUsers {
                guard let app = KnownMeetingApp.match(process) else { continue }
                if app.isBrowser && browserBusy { continue }
                let key = "app:\(app.id)"
                if !candidates.contains(where: { $0.key == key }) {
                    // A browser keeps one mic grant across calls, so its brief release is the only sign that one call ended
                    // and the next began (two Slack huddles 10 s apart merged under the default grace).
                    candidates.append(MeetingCandidate(key: key, platform: app.platform, title: app.title,
                                                       endGrace: app.isBrowser ? Self.browserFallbackEndGrace : nil))
                }
            }
        }
        return candidates
    }

    private func updateActivity() {
        let busy = recording != nil || transcription.isTranscribing || !queue.jobs.isEmpty || !phases.summarizing.isEmpty || !phases.diarizing.isEmpty
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording and transcribing a meeting")
        } else if !busy, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    /// Cleans meetings stored before attendee cleaning and self names, once; a dated backup is made first.
    /// Runs off the main thread at launch: it may read the whole library twice.
    nonisolated private static func repairStoredMeetingsOnce(store: MeetingStore, selfNames: [String]) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: MeetingRepair.doneKey) else { return }
        let names = selfNames.isEmpty ? [SelfNames.usual(in: store.loadAll())].compactMap { $0 } : selfNames
        do {
            let result = try MeetingRepair.run(store: store, selfNames: names)
            defaults.set(true, forKey: MeetingRepair.doneKey)
            log.info("repaired \(result.changed, privacy: .public) meetings; backup at \(result.backup.path, privacy: .public)")
        } catch {
            log.error("meeting repair failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording

    func startManualRecording() {
        guard recording == nil, libraryLoaded else { return }
        startRecording(candidate: detectedCandidate ?? MeetingCandidate(key: "manual", platform: .other, title: nil), manual: true)
    }

    private func startRecording(candidate: MeetingCandidate, manual: Bool = false) {
        recorder.start(candidate, manual: manual)
    }

    /// Problems that would leave this recording silent or untranscribed.
    func setupProblem() -> String? {
        switch Permissions.microphoneStatus {
        case .denied, .restricted:
            return "Microphone access is off, so your voice isn't recorded. Turn on Chrupio in System Settings > Privacy & Security > Microphone."
        default: break
        }
        if Transcriber.findWhisperCLI() == nil {
            return "whisper.cpp is missing from Chrupio.app, so this meeting can't be transcribed yet. Reinstall Chrupio from the latest release, then use More > Retranscribe audio."
        }
        if !settings.whisperModel.isDownloaded {
            return "The \(settings.whisperModel.name) speech model isn't downloaded. Download it in Settings > Transcription, then use More > Retranscribe audio."
        }
        return nil
    }

    /// Quitting: stops the recording, waits for every recorder stop still flushing its last chunks (including one
    /// started just before the quit), then for every queued save. The caller bounds the wait.
    func prepareForQuit() async {
        await recorder.stopAndWait()
        await library.flush()
        // Edits from chrupio-mcp go to the meeting files once the app's in-memory copy is saved.
        LocalAPI.clearOwnEndpoint()
    }

    /// - Parameter holdingOffSleep: the Mac is about to sleep; keep it awake until the last chunks are on disk.
    func stopRecording(holdingOffSleep: Bool = false) { recorder.stop(holdingOffSleep: holdingOffSleep) }

    // MARK: - Transcription

    private func enqueue(_ chunk: AudioChunk, for meetingID: UUID) { finisher.enqueue(chunk, for: meetingID) }
    private func finishIfReady(_ meetingID: UUID) { finisher.finishIfReady(meetingID) }

    /// Names seen so far help whisper spell them. Each chunk's language is detected on its own; the meeting's
    /// language so far only corrects a doubtful guess.
    private func prepareJob(_ job: inout TranscriptionJob, chunk: AudioChunk, owner: UUID?) {
        let context = meetingContext
        if let meeting = owner.flatMap({ id in meetings.first { $0.id == id } }) {
            let profile = context?.profile(for: meeting.title)
            job.transcriber.vocabulary = meeting.attendees + [meeting.selfName].compactMap { $0 } + (profile?.attendees ?? [])
            job.transcriber.terms = Self.unique((context?.terms(for: meeting.title) ?? []) + Transcriber.terms(from: settings.vocabulary))
            job.transcriber.meetingLanguage = finisher.votedLanguage(meeting.id) ?? meeting.language
            job.routing = job.routing.pinned(toConfirmed: finisher.confirmedLanguage(meeting.id))
            job.transcriber.previousText = TranscriptAssembler.previousText(meeting.segments, before: chunk)
        }
        job.boostTerms = SpeechVocabulary.boostTerms(job.transcriber.terms + job.transcriber.vocabulary)
        job.boostAliases = context?.boostAliases ?? [:]
        job.cancelEcho = chunk.track == .mic && settings.echoCancellation
        if let context { job.correct = { @Sendable text in context.correct(text) } }
    }

    /// Names the diarized voices from the speaker prints, and learns them, under the prints' lock: another meeting
    /// or an assignment learning now would be overwritten.
    private func diarizationNaming() -> DiarizationScheduler.Naming {
        let context = meetingContext
        let canonical: @Sendable (String) -> String = { context?.canonicalName($0) ?? PersonName.stripMarkers($0) }
        let printsURL = speakerPrintsURL
        return { diarization, meeting, voices in
            var copy = meeting
            try SpeakerPrints.update(at: printsURL) { prints in
                prints = prints.normalized(canonical)
                let outcome = DiarizationNaming.names(for: diarization, meeting: copy, prints: prints)
                DiarizationNaming.apply(diarization, names: outcome.names, to: &copy)
                DiarizationNaming.learn(outcome, diarization: diarization, meetingID: meeting.id, into: &prints)
                voices = DiarizationNaming.voices(diarization, names: outcome.names)
            }
            return copy.segments
        }
    }

    // MARK: - Summaries

    /// Writes the meeting's summary; `force` (the user's own "Summarize") summarizes a fragment too.
    func summarize(_ meetingID: UUID, force: Bool = false) { summaries.summarize(meetingID, force: force) }

    // MARK: - Editing

    @ObservationIgnored private lazy var editor: MeetingEditor = {
        let editor = MeetingEditor(library: library, summaries: summaries, finisher: finisher)
        editor.environment = self
        return editor
    }()

    func rename(_ meetingID: UUID, to title: String) { editor.rename(meetingID, to: title) }

    /// Recording, transcribing, diarizing or summarizing; such meetings can't be deleted.
    func isBusy(_ meetingID: UUID) -> Bool {
        recording?.meetingID == meetingID || pendingChunks[meetingID] != nil || queue.finishing.contains(meetingID)
            || phases[meetingID] == .diarizing || phases[meetingID]?.isSummarizing == true || retaining == meetingID
    }

    // MARK: Audio retention

    /// The meeting whose audio the retention pass is compressing or deleting now.
    private var retaining: UUID?
    private var retentionRunning = false
    private let launchedAt = Date()
    private static let retentionKey = "audioRetentionLastRun"

    /// Once per launch and at most once a day: compresses transcribed meetings' WAV chunks to Opus and deletes audio
    /// of meetings older than 30 days. One meeting at a time at background priority, never during a call.
    private func runAudioRetentionIfDue(now: Date = Date()) {
        let last = UserDefaults.standard.object(forKey: Self.retentionKey) as? Date
        // Not in the first minutes after launch, when leftover chunks and model downloads run.
        guard now.timeIntervalSince(launchedAt) > 300, !retentionRunning, recording == nil, settings.keepAudio, AudioRetention.isDue(lastRun: last, now: now) else { return }
        let store = store
        let plan = AudioRetention.plan(meetings, now: now, hasAudio: { AudioCompression.hasAudio(in: store.audioDirectory(for: $0)) },
                                       hasUncompressed: { AudioCompression.hasUncompressed(in: store.audioDirectory(for: $0)) },
                                       isBusy: { isBusy($0) || diarization.queue.pending.contains($0) })
        UserDefaults.standard.set(now, forKey: Self.retentionKey)
        guard !plan.isEmpty else { return }
        retentionRunning = true
        log.info("audio retention: \(plan.count, privacy: .public) meeting(s)")
        Task { await runRetention(plan) }
    }

    private func runRetention(_ plan: [AudioRetention.Action]) async {
        defer { retentionRunning = false }
        for action in plan {
            let id = action.meetingID
            // Checked again per meeting: a call may have started, or the meeting been retranscribed, since planning.
            guard recording == nil, let meeting = meetings.first(where: { $0.id == id }),
                  AudioRetention.allows(action, meeting, busy: isBusy(id) || diarization.queue.pending.contains(id))
            else { continue }
            retaining = id
            let store = store
            let result = await Task.detached(priority: .background) { () -> Result<Int, Error> in
                switch action {
                case .delete:
                    store.deleteAudio(id)
                    return .success(0)
                case .compress:
                    guard let executable = Bundle.main.executableURL else { return .success(0) }
                    let (done, skipped) = store.compressAudioIsolated(id, executable: executable, arguments: [CompressChunkCommand.flag],
                                                                      timeout: CompressChunkCommand.timeout)
                    if !skipped.isEmpty { log.error("kept as WAV (compression failed or hung): \(skipped.joined(separator: ", "), privacy: .public)") }
                    return .success(done)
                }
            }.value
            retaining = nil
            switch (action, result) {
            case (.compress, .success(let count)): log.info("compressed \(count, privacy: .public) chunk(s) of \(id, privacy: .public)")
            case (.delete, .success): log.info("deleted audio of \(id, privacy: .public) (older than 30 days)")
            case (_, .failure(let error)): log.error("audio retention failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func delete(_ meeting: Meeting) {
        if isBusy(meeting.id) { return }
        summaries.forget(meeting.id)
        library.delete(meeting)
    }

    func audioFolder(for meetingID: UUID) -> URL { store.audioDirectory(for: meetingID) }

    // MARK: Fragments, templates and follow-ups

    /// The meetings a fragment can be merged into.
    func mergeNeighbours(of meeting: Meeting) -> (previous: Meeting?, next: Meeting?) {
        MeetingMerge.neighbours(of: meeting, in: meetings)
    }

    /// Folds `sourceID` into `targetID` (transcripts by time, attendees, notes and audio), deletes the source and
    /// writes the target's summary again.
    func merge(_ sourceID: UUID, into targetID: UUID) { editor.merge(sourceID, into: targetID) }

    /// Picks the summary template by hand and writes the summary with it.
    func setSummaryTemplate(_ meetingID: UUID, _ template: SummaryTemplate) { summaries.setTemplate(meetingID, template) }

    /// Meetings whose follow-up message is being drafted.
    private(set) var draftingFollowUp: Set<UUID> = []

    /// Drafts a recap message with Claude and puts it on the clipboard; `done` gets nil or the error.
    func draftFollowUp(_ meetingID: UUID, done: @escaping @MainActor (String?) -> Void) {
        guard settings.claudeSummaries else { done("Claude summaries are off in Settings."); return }
        guard !draftingFollowUp.contains(meetingID), let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        draftingFollowUp.insert(meetingID)
        let configDir = settings.claudeConfigDir
        Task {
            defer { self.draftingFollowUp.remove(meetingID) }
            // Waits for a login-shell lookup still running at launch instead of reporting "not installed".
            guard let executable = await ClaudeCLIStore.shared.locate(force: false) else {
                done(ClaudeSummarizerError.notInstalled.localizedDescription)
                return
            }
            var claude = ClaudeSummarizer(executable: executable, configDir: configDir)
            claude.isEnabled = { await MainActor.run { AppSettings.shared.claudeSummaries } }
            do {
                let text = try await claude.draftFollowUp(meeting)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                done(nil)
            } catch is ClaudeSummariesOff {
                // Turned off while drafting: a stop the user asked for, not a failure.
                log.info("follow-up draft stopped: summaries off")
                done(ClaudeSummariesOff().localizedDescription)
            } catch {
                log.error("follow-up draft failed: \(error.localizedDescription, privacy: .public)")
                done(error.localizedDescription)
            }
        }
    }

    func dismissError(_ meetingID: UUID) { editor.dismissError(meetingID) }
    /// Ticks or reopens an action item from the summary view.
    func setActionItem(_ meetingID: UUID, number: Int, done: Bool) { editor.setActionItem(meetingID, number: number, done: done) }
    /// The notes the user types in the meeting window; empty text clears them.
    func setTypedNotes(_ meetingID: UUID, _ text: String) { editor.setTypedNotes(meetingID, text) }
    func removeNote(_ meetingID: UUID, noteID: UUID) { editor.removeNote(meetingID, noteID: noteID) }
    /// Applies an edit to the in-memory meeting and saves it, so a later save can't undo it.
    @discardableResult
    func apply(_ edit: MeetingEdit, to meetingID: UUID) throws -> String { try editor.apply(edit, to: meetingID) }

    /// A reported or typed name in the project roster's spelling.
    func canonicalName(_ name: String) -> String {
        meetingContext?.canonicalName(name) ?? PersonName.stripMarkers(name)
    }

    /// Names a voice from the transcript (the "Speaker N" picker).
    func assignSpeaker(_ meetingID: UUID, speaker: String, name: String) {
        do { _ = try apply(.assignSpeaker(speaker: speaker, name: name), to: meetingID) } catch {
            log.error("naming \(speaker) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Who the picker offers for a voice in `meeting`.
    func speakerCandidates(for meeting: Meeting) -> [String] {
        let context = meetingContext
        let expected = meeting.expectedAttendees ?? context?.expectedAttendees(for: meeting.title) ?? []
        var withExpected = meeting
        withExpected.expectedAttendees = expected
        return withExpected.speakerCandidates(roster: (context?.people ?? []).map(\.name))
    }

    /// Edits sent by `chrupio-mcp` through the local API.
    func applyRemoteEdit(_ request: LocalAPI.EditRequest) -> (status: Int, response: LocalAPI.EditResponse) { editor.applyRemoteEdit(request) }

    private func reloadExternalChanges() { library.reloadExternalChanges() }

    /// Mirrors a finished meeting to the Markdown folder. Runs on one serial queue so writes stay in order.
    private func export(_ meeting: Meeting) {
        guard let exporter = settings.exporter, MeetingExporter.isExportable(meeting) else { return }
        Self.exportQueue.async { [weak self] in
            let failure: String?
            do {
                try exporter.export(meeting)
                failure = nil
            } catch {
                log.error("export failed: \(error.localizedDescription, privacy: .public)")
                failure = "Couldn't write \(meeting.title) to the notes folder: \(error.localizedDescription)"
            }
            Task { @MainActor in self?.exportError = failure }
        }
    }

    /// Re-exports every finished meeting, e.g. after the folder changes. Returns how many were written and
    /// the first error. With `old`, the meetings' files there are removed once all were written without error.
    func exportAll(movingFrom old: URL? = nil) async -> (written: Int, error: String?) {
        guard let exporter = settings.exporter else { return (0, nil) }
        let snapshot = meetings
        return await withCheckedContinuation { continuation in
            Self.exportQueue.async {
                let result = exporter.exportAll(snapshot)
                if let old, result.error == nil {
                    MeetingExporter.removeExports(in: old, ids: snapshot.map(\.id))
                }
                continuation.resume(returning: (result.written, result.error?.localizedDescription))
            }
        }
    }

    private static let exportQueue = DispatchQueue(label: "com.chrupio.export", qos: .utility)

    /// Re-runs transcription over the saved audio chunks of a meeting.
    func retranscribe(_ meetingID: UUID) { finisher.retranscribe(meetingID) }

    // MARK: - Voices and project context

    private let contextFile = MeetingContextFile()

    var meetingContext: MeetingContext? { contextFile.context(at: settings.contextFile) }

    private var voicePrintsURL: URL { store.root.deletingLastPathComponent().appendingPathComponent("voices.json") }
    private var speakerPrintsURL: URL { store.root.deletingLastPathComponent().appendingPathComponent("speaker-prints.json") }

    /// Names remote lines the live signals missed by voice, and learns the voices the live signals did name.
    func attributeVoices(_ meeting: inout Meeting) {
        let liveNames = Set(meeting.segments.compactMap { segment -> String? in
            if case .remote(let name?) = segment.speaker { return name } else { return nil }
        })
        var prints = VoicePrints.load(from: voicePrintsURL)
        VoiceAttribution.apply(to: &meeting, prints: prints)
        guard !liveNames.isEmpty else { return }
        prints.learn(from: meeting, liveNames: liveNames)
        do { try prints.save(to: voicePrintsURL) } catch {
            log.error("voice prints not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func settingsTranscriber() -> Transcriber {
        let settings = AppSettings.shared
        return Transcriber(model: settings.whisperModel, language: settings.language, preferredLanguage: settings.preferredLanguage,
                           terms: Transcriber.terms(from: settings.vocabulary))
    }

    private func makeRouting() -> EngineRouting {
        EngineRouting(parakeetEnabled: settings.parakeetForPolish, language: settings.whisperModel.isEnglishOnly ? "en" : settings.language)
    }

    /// Cheap enough to call from view bodies: lists the folder without reading the sidecars.
    func hasAudio(_ meetingID: UUID) -> Bool {
        AudioCompression.hasAudio(in: store.audioDirectory(for: meetingID))
    }
}

extension MeetingCoordinator: RecordingControllerEnvironment {
    var captureSystemAudio: Bool { settings.captureSystemAudio }

    func makeRecorder(directory: URL, onChunk: @escaping AudioRecorder.ChunkHandler) -> AudioRecording {
        AudioRecorder(directory: directory, onChunk: onChunk)
    }

    func prepare(_ meeting: inout Meeting, for candidate: MeetingCandidate) {
        live.prepare(&meeting, for: candidate)
    }

    func recordingStarted(_ meeting: Meeting, candidate: MeetingCandidate, manual: Bool) {
        pinTranscriber(meeting.id)
        live.recordingStarted(meeting.id, key: candidate.key)
        if manual, candidate.key != "manual" { detector.adopt(candidate, now: Date()) }
    }

    func recordingFailed(candidate: MeetingCandidate, manual: Bool) {
        if manual { detector.reset() } else { detector.adopt(candidate, now: Date()) }
    }

    func recordingStopped(_ meetingID: UUID, hadMeeting: Bool) {
        if hadMeeting { transcription.startFinishing(meetingID) }
        // Work held during the call: earlier meetings waiting to diarize, then their summaries.
        for other in queue.finishing.sorted(by: { $0.uuidString < $1.uuidString }) where other != meetingID {
            finishIfReady(other)
        }
        summaries.releaseHeld()
    }

    func chunkArrived(_ chunk: AudioChunk, for meetingID: UUID) {
        enqueue(chunk, for: meetingID)
        finishIfReady(meetingID)
    }

    func lastChunksArrived(_ chunks: [AudioChunk], for meetingID: UUID) {
        for chunk in chunks { enqueue(chunk, for: meetingID) }
        transcription.processJobs()
        finishIfReady(meetingID)
    }
}

extension MeetingCoordinator: MeetingEditorEnvironment {
    func learnAssignment(_ edit: MeetingEdit, before: Meeting) {
        let url = speakerPrintsURL, context = meetingContext
        Task.detached(priority: .utility) {
            SpeakerPrints.learnAssignment(edit, before: before, at: url) { context?.canonicalName($0) ?? PersonName.stripMarkers($0) }
        }
    }
}

extension MeetingCoordinator: TranscriptFinisherEnvironment {
    var autoSummarize: Bool { settings.autoSummarize }
    var preferredLanguage: String? { settings.preferredLanguage.isEmpty ? nil : settings.preferredLanguage }
    var recordingMeetingID: UUID? { recording?.meetingID }
    func deliveriesDone(_ id: UUID) -> Bool { deliveries.isEmpty(id) }
    func savedChunks(_ id: UUID) -> [AudioChunk] { AudioChunkScanner.chunks(in: store.audioDirectory(for: id)) }
    func pinEngines(_ id: UUID) {
        pinTranscriber(id)
    }

    /// Pins the transcriber and notes its whisper model (the one the transcriber really uses) in the statistics;
    /// no save when the statistics already name that model.
    private func pinTranscriber(_ id: UUID) {
        let transcriber = Self.settingsTranscriber()
        transcription.fix(id, transcriber: transcriber, routing: makeRouting())
        let model = transcriber.model.name
        guard library.meeting(id)?.transcriptionStats?.whisperModel != model else { return }
        library.update(id) {
            var stats = $0.transcriptionStats ?? TranscriptionStats()
            stats.whisperModel = model
            $0.transcriptionStats = stats
        }
    }

    func applyContext(_ meeting: inout Meeting) {
        let context = meetingContext
        let canonical: @Sendable (String) -> String = { context?.canonicalName($0) ?? PersonName.stripMarkers($0) }
        meeting.canonicalizeNames(canonical)
        if let expected = context?.expectedAttendees(for: meeting.title), !expected.isEmpty { meeting.expectedAttendees = expected }
    }

    func releaseEngines() {
        Task {
            await EchoCanceller.shared.release()
            await ParakeetTranscriber.shared.release()
        }
    }

    func discard(_ meeting: Meeting) { delete(meeting) }
    func summarizeTranscribed(_ id: UUID) { summarize(id) }
}

extension MeetingCoordinator: OrphanRecoveryEnvironment {
    var minimumMeetingSeconds: TimeInterval { settings.minimumMeetingSeconds }
    func isQueued(_ id: UUID) -> Bool { queue.finishing.contains(id) }
    func summarizeInterrupted(_ id: UUID) { summarize(id) }
    func finishWithoutAudio(_ id: UUID) {
        transcription.startFinishing(id)
        finishIfReady(id)
    }
}

extension MeetingCoordinator: SummarySchedulerEnvironment {
    var isRecording: Bool { recording != nil }
    var claudeEnabled: Bool { settings.claudeSummaries }

    func isTranscriptOpen(_ id: UUID) -> Bool {
        recording?.meetingID == id || pendingChunks[id] != nil || queue.finishing.contains(id)
    }

    func expectedAttendees(for title: String) -> [String]? { meetingContext?.expectedAttendees(for: title) }

    func makeSummarizer(for meeting: Meeting) -> MeetingSummarizing {
        let context = meetingContext
        let transcript = TranscriptFormatter.plainText(meeting.segments)
        // Action item owners are checked against these besides the meeting's own people.
        let knownPeople = (context?.people ?? []).map(\.name) + SpeakerPrints.load(from: speakerPrintsURL).people.keys.sorted()
        var claude = ClaudeSummarizer(executable: URL(fileURLWithPath: "/nonexistent/claude"), configDir: settings.claudeConfigDir,
                                      context: context?.summaryPrompt(for: meeting, transcript: transcript))
        claude.partGuidance = context?.localSummaryGuidance(for: meeting, transcript: transcript)
        claude.ticketPrefix = context?.resolvedTicketPrefix
        claude.knownPeople = knownPeople
        claude.template = SummaryTemplate.resolved(for: meeting)
        claude.timeout = ClaudeSummarizer.timeout(forTranscriptCharacters: transcript.count)
        // Asked before every Claude call, so turning the switch off stops a long summary between its parts.
        claude.isEnabled = { await MainActor.run { AppSettings.shared.claudeSummaries } }
        return LocatingClaudeSummarizer(claude: claude)
    }

    func activityChanged() { updateActivity() }
}

extension MeetingCoordinator: MeetingLibraryHooks {
    var keepAudio: Bool { settings.keepAudio }

    func saved(_ meeting: Meeting) {
        export(meeting)
        semanticIndexer.enqueue(meeting)
    }

    func loadedExternally(_ meeting: Meeting) { semanticIndexer.enqueue(meeting) }

    func removed(_ id: UUID) {
        if let exporter = settings.exporter {
            Self.exportQueue.async { exporter.remove(id) }
        }
        semanticIndexer.index.remove(id)
    }
}

/// Finds `claude` when the summary starts, so a login-shell lookup still running at launch is waited for
/// instead of failing the summary as "not installed".
private struct LocatingClaudeSummarizer: MeetingSummarizing {
    var claude: ClaudeSummarizer

    func summarize(_ meeting: Meeting) async throws -> MeetingSummary {
        var claude = claude
        if let executable = await ClaudeCLIStore.shared.locate(force: false) {
            claude.executable = executable
        } else {
            // The placeholder path stays, so `summarize` reports it in its usual order (an empty transcript first).
            log.error("Claude Code not found; the summary can't be written")
        }
        return try await claude.summarize(meeting)
    }
}

/// Desktop apps (and browsers) that count as "in a call" when they hold the microphone.
struct KnownMeetingApp {
    let id: String
    let platform: Platform
    let title: String
    let isBrowser: Bool
    let bundlePrefixes: [String]

    static let all: [KnownMeetingApp] = [
        KnownMeetingApp(id: "chrome", platform: .other, title: "Browser call", isBrowser: true, bundlePrefixes: ["com.google.Chrome"]),
        KnownMeetingApp(id: "teams", platform: .teams, title: "Microsoft Teams", isBrowser: false, bundlePrefixes: ["com.microsoft.teams"]),
        KnownMeetingApp(id: "slack", platform: .slack, title: "Slack Huddle", isBrowser: false, bundlePrefixes: ["com.tinyspeck.slackmacgap"]),
    ]

    static func match(_ process: ProcessAudioMonitor.AudioProcess) -> KnownMeetingApp? {
        let bundleID = process.bundleID
            ?? NSRunningApplication(processIdentifier: process.pid)?.bundleIdentifier
            ?? ""
        return all.first { app in app.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
