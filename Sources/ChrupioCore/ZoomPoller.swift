import Foundation

/// Decides when Zoom's windows are scanned and runs one scan at a time off the main thread: Accessibility calls can
/// block for seconds when Zoom is busy. Detection uses the previous result, at most one tick old.
@MainActor
public final class ZoomPoller {
    /// How often Zoom's windows are checked for a call start when no Zoom call is recorded.
    public static let detectionInterval: TimeInterval = 5
    /// How often the participant list is read during a recorded Zoom call.
    public static let participantsInterval: TimeInterval = 10

    public private(set) var snapshot: ZoomMonitor.Snapshot?
    public private(set) var isScanning = false
    private var lastParticipantsScan = Date.distantPast
    private var lastDetectionScan = Date.distantPast
    private let scan: @Sendable (_ includeParticipants: Bool, _ includeLabels: Bool) -> ZoomMonitor.Snapshot

    /// A scan landed; `scannedAt` is when it started, since the scan can take seconds.
    public var onSnapshot: (ZoomMonitor.Snapshot, _ includeParticipants: Bool, _ scannedAt: Date) -> Void = { _, _, _ in }

    public init(scan: @escaping @Sendable (Bool, Bool) -> ZoomMonitor.Snapshot = { ZoomMonitor.snapshot(includeParticipants: $0, includeLabels: $1) }) {
        self.scan = scan
    }

    /// Talking indicators are read on every poll during a recorded Zoom call; otherwise a window-title check every
    /// `detectionInterval`.
    public func poll(now: Date, recordingZoom: Bool) {
        guard recordingZoom || now.timeIntervalSince(lastDetectionScan) >= Self.detectionInterval else { return }
        lastDetectionScan = now
        // One scan at a time: a separate participant scan always found this one still running and never ran.
        let participantsDue = recordingZoom && now.timeIntervalSince(lastParticipantsScan) > Self.participantsInterval
        if start(includeParticipants: participantsDue, includeLabels: recordingZoom), participantsDue {
            lastParticipantsScan = now
        }
    }

    private func start(includeParticipants: Bool, includeLabels: Bool) -> Bool {
        guard !isScanning else { return false }
        isScanning = true
        let scan = scan
        Task.detached(priority: .utility) {
            let started = Date()
            let snapshot = scan(includeParticipants, includeLabels)
            await self.landed(snapshot, includeParticipants: includeParticipants, scannedAt: started)
        }
        return true
    }

    private func landed(_ snapshot: ZoomMonitor.Snapshot, includeParticipants: Bool, scannedAt: Date) {
        isScanning = false
        self.snapshot = snapshot
        onSnapshot(snapshot, includeParticipants, scannedAt)
    }
}
