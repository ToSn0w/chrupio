import Foundation
import Observation

/// What the Chrome extension and the Zoom scans tell about the call being recorded: who talks (speaker events,
/// stamped when sent), who attends, the user's own name, the title and URL, and the probes saved for diagnosis.
@MainActor
@Observable
public final class LiveCallMonitor {
    public private(set) var lastExtensionContact: Date?
    /// Version the loaded extension reports; nil until it reports one (versions before 0.2.0 never do).
    public private(set) var extensionVersion: String?

    @ObservationIgnored public private(set) var tracker = BrowserMeetingTracker()
    @ObservationIgnored private var diagnostics = CallDiagnostics()
    @ObservationIgnored private let library: MeetingLibrary
    @ObservationIgnored private let recorder: RecordingController
    @ObservationIgnored public weak var notifier: MeetingNotifying?
    /// The user's own names from Settings.
    @ObservationIgnored public var selfNames: () -> [String] = { [] }
    /// "Save diagnostics" in Settings (off by default): probe.json is written only while this returns true.
    @ObservationIgnored public var saveDiagnostics: () -> Bool = { false }

    public init(library: MeetingLibrary, recorder: RecordingController) {
        self.library = library
        self.recorder = recorder
    }

    public func isExtensionConnected(now: Date = Date()) -> Bool {
        guard let lastExtensionContact else { return false }
        // The extension pings every 30 s; allow for a couple of missed pings while Chrome suspends it.
        return now.timeIntervalSince(lastExtensionContact) < 90
    }

    public func hello(_ version: String?, now: Date = Date()) {
        lastExtensionContact = now
        extensionVersion = version
    }

    public func handle(_ event: ExtensionEvent, now: Date = Date()) {
        lastExtensionContact = now
        extensionVersion = event.extensionVersion
        tracker.record(event, now: now)
        recordSpeakers(event, now: now)
        if let probe = event.probe {
            let key = BrowserMeetingTracker.key(tabId: event.tabId, callId: event.callId)
            diagnostics.record(probe: probe, key: key)
            if let recording = recorder.recording, recording.sourceKey == key { writeProbe(["extension": probe], for: recording.meetingID) }
        }
    }

    /// A page snapshot (the call showed nobody) goes into the meeting's probe.json next to the probe.
    public func snapshot(_ snapshot: AnyJSON, key: String) {
        diagnostics.record(snapshot: snapshot, key: key)
        if let recording = recorder.recording, recording.sourceKey == key { writeProbe(["snapshot": snapshot], for: recording.meetingID) }
    }

    public func candidates(now: Date) -> [MeetingCandidate] { tracker.candidates(now: now) }

    /// A new recording takes what the call already showed: the user's name and the people in it.
    public func prepare(_ meeting: inout Meeting, for candidate: MeetingCandidate) {
        if let state = tracker.state(forKey: candidate.key) {
            meeting.selfName = state.selfName
            meeting.mergeAttendees(state.participants ?? [])
        }
        meeting.applySelf(selfNames())
    }

    /// The extension sends its first probe on joining, before the recording starts.
    public func recordingStarted(_ meetingID: UUID, key: String) {
        let early = diagnostics.entries(for: key)
        if !early.isEmpty { writeProbe(early, for: meetingID) }
    }

    /// probe.json is diagnostics only: a failed write is logged and the call goes on.
    private func writeProbe(_ entries: [String: AnyJSON], for id: UUID) {
        guard saveDiagnostics() else { return }
        do { try library.store.writeProbe(entries, for: id) } catch {
            CoreLog.coordinator.error("probe.json write failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every heartbeat and speaker change is counted, stamped when the extension sent it; sampling the tracker on the
    /// 2 s tick instead lost half of them and dated the rest up to 2 s late. Heartbeats of the same speakers extend one
    /// event, so the meeting (and its open views) changes only when someone else starts talking.
    private func recordSpeakers(_ event: ExtensionEvent, now: Date) {
        guard event.type == .meeting, let speakers = event.activeSpeakers, !speakers.isEmpty, let current = recorder.recording,
              current.sourceKey == BrowserMeetingTracker.key(tabId: event.tabId, callId: event.callId),
              let index = library.index(of: current.meetingID) else { return }
        let sent = SpeakerEvent.date(ts: event.ts, received: now)
        let at = sent.timeIntervalSince(library.meetings[index].startedAt)
        var finished: SpeakerEvent?
        recorder.modify { finished = $0.speakerRun.record(speakers, at: at) }
        if let finished { library.meetings[index].speakerEvents.append(finished) }
    }

    /// A vague detection ("Chrome uses the mic") became a specific one (a Meet tab): keep recording, update the meeting.
    public func handOver(to candidate: MeetingCandidate) {
        guard let current = recorder.recording, current.candidateKey != nil else { return }
        recorder.modify {
            $0.candidateKey = candidate.key
            $0.sourceKey = candidate.key
        }
        recordingStarted(current.meetingID, key: candidate.key)
        library.update(current.meetingID) { meeting in
            if meeting.title == meeting.platform.displayName || meeting.platform == .other {
                meeting.title = candidate.title ?? candidate.platform.displayName
            }
            meeting.platform = candidate.platform
            meeting.url = meeting.url ?? candidate.url
        }
    }

    /// A Zoom scan landed: who talks, and every 10 s the participants, go into the recorded Zoom meeting.
    public func applyZoom(_ snapshot: ZoomMonitor.Snapshot, includeParticipants: Bool, scannedAt: Date) {
        guard let current = recorder.recording, current.sourceKey == "zoom", let index = library.index(of: current.meetingID) else { return }
        var meeting = library.meetings[index]
        let selfNames = selfNames()
        let speakers = snapshot.activeSpeakers.filter { !meeting.isSelf($0, others: selfNames) }
        // Scans are a few seconds apart, so a longer gap still continues the run.
        if !speakers.isEmpty {
            let at = scannedAt.timeIntervalSince(meeting.startedAt)
            var finished: SpeakerEvent?
            recorder.modify { finished = $0.speakerRun.record(speakers, at: at, maxGap: 8) }
            if let finished { meeting.speakerEvents.append(finished) }
        }
        if includeParticipants {
            if let selfName = snapshot.selfName { meeting.selfName = selfName }
            meeting.mergeAttendees(snapshot.participants + snapshot.tileNames)
            meeting.applySelf(selfNames)
            writeProbe(["zoomLabels": .array(snapshot.labels.map(AnyJSON.string)),
                        "zoomWindows": .array(snapshot.windowTitles.map(AnyJSON.string)),
                        "zoomWindowDetails": .array(snapshot.windows.map(\.json)),
                        "zoomSpeakers": .array(snapshot.activeSpeakers.map(AnyJSON.string))], for: meeting.id)
        }
        guard meeting != library.meetings[index] else { return }
        library.meetings[index] = meeting
        // Speaker events alone are saved with the next chunk or attendee change.
        if includeParticipants { library.persist(meeting) }
    }

    /// The 2 s tick: the call's attendees, self name, title and URL go into the recorded meeting, saved at once when
    /// they change; speaker events at least every 30 s. Warns once when the extension never says who speaks.
    public func tick(now: Date) {
        guard let recording = recorder.recording else { return }
        updateMetadata(recording, now: now)
        checkSpeakerDetection(now: now)
    }

    private func updateMetadata(_ recording: ActiveRecording, now: Date) {
        guard let index = library.index(of: recording.meetingID) else { return }
        var meeting = library.meetings[index]
        let before = meeting

        if let key = recording.sourceKey, let state = tracker.state(forKey: key) {
            meeting.mergeAttendees(state.participants ?? [])
            if let selfName = state.selfName, !selfName.isEmpty { meeting.selfName = selfName }
            meeting.applySelf(selfNames())
            if let title = state.title, !title.isEmpty, meeting.title == meeting.platform.displayName { meeting.title = title }
            meeting.url = meeting.url ?? state.url
        }

        // Attendee or title changes save at once; speaker events (added as they arrive) at least every 30 s.
        if meeting != before { library.meetings[index] = meeting }
        if meeting != before || now.timeIntervalSince(recording.lastLivePersist) >= 30 {
            var open: SpeakerEvent?
            recorder.modify {
                $0.lastLivePersist = now
                // The saved meeting shows who is talking up to now; the next heartbeat starts a new run.
                open = $0.speakerRun.close()
            }
            if let open {
                meeting.speakerEvents.append(open)
                library.meetings[index] = meeting
            }
            library.persist(meeting)
        }
    }

    /// The extension lists people but never says who speaks: its page selectors no longer match (075C8CAD had 0 events).
    private func checkSpeakerDetection(now: Date) {
        guard let current = recorder.recording, !current.warnedNoSpeakers, let key = current.sourceKey,
              let state = tracker.state(forKey: key),
              let meeting = library.meeting(current.meetingID),
              let message = state.missingSpeakersWarning(speakerEventCount: meeting.speakerEvents.count,
                                                         elapsed: now.timeIntervalSince(current.startedAt),
                                                         diagnosticsSaved: saveDiagnostics()) else { return }
        recorder.modify { $0.warnedNoSpeakers = true }
        CoreLog.coordinator.warning("no speaker events for \(current.meetingID, privacy: .public) from \(key, privacy: .public), extension \(self.extensionVersion ?? "unknown", privacy: .public)")
        writeProbe(["app": .object([
            "problem": .string("no speaker events"),
            "participants": .array((state.participants ?? []).map(AnyJSON.string)),
            "extensionVersion": .string(extensionVersion ?? "unknown"),
            "elapsed": .number(now.timeIntervalSince(current.startedAt))
        ])], for: current.meetingID)
        notifier?.post(title: "Can't tell who is speaking", body: message)
    }
}
