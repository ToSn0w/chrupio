import Foundation

/// Something that looks like an ongoing meeting.
public struct MeetingCandidate: Sendable, Equatable {
    /// Stable identity, e.g. "chrome-tab:42" or "zoom".
    public var key: String
    public var platform: Platform
    public var title: String?
    public var url: String?
    /// Key of a vaguer candidate for the same call (e.g. "Chrome holds the mic" for a Meet tab)
    /// whose recording this one should take over instead of starting a new meeting.
    public var replaces: String?
    /// Overrides the detector's end grace for this candidate.
    public var endGrace: TimeInterval?

    public init(key: String, platform: Platform, title: String? = nil, url: String? = nil, replaces: String? = nil, endGrace: TimeInterval? = nil) {
        self.key = key
        self.platform = platform
        self.title = title
        self.url = url
        self.replaces = replaces
        self.endGrace = endGrace
    }
}

/// Debounced start/stop decisions from periodic candidate snapshots.
public struct MeetingDetector: Sendable {
    public enum Action: Sendable, Equatable {
        case start(MeetingCandidate)
        /// The running recording now belongs to a more specific candidate.
        case handOver(MeetingCandidate)
        case stop
    }

    /// How long a candidate must persist before recording starts.
    public var startDelay: TimeInterval
    /// How long the active meeting may be missing before recording stops.
    public var endGrace: TimeInterval

    public private(set) var active: MeetingCandidate?
    private var lastSeenActive: Date?
    private var firstSeen: [String: Date] = [:]

    public init(startDelay: TimeInterval = 3, endGrace: TimeInterval = 15) {
        self.startDelay = startDelay
        self.endGrace = endGrace
    }

    public mutating func update(candidates: [MeetingCandidate], now: Date) -> Action? {
        if let current = active {
            if let match = candidates.first(where: { $0.key == current.key }) {
                // Keep the freshest title/url (Meet fills the title in after joining).
                active = match
                lastSeenActive = now
                return nil
            }
            if let successor = candidates.first(where: { $0.replaces == current.key }) {
                active = successor
                lastSeenActive = now
                return .handOver(successor)
            }
            if now.timeIntervalSince(lastSeenActive ?? now) >= current.endGrace ?? endGrace {
                reset()
                return .stop
            }
            return nil
        }

        let keys = Set(candidates.map(\.key))
        firstSeen = firstSeen.filter { keys.contains($0.key) }
        for candidate in candidates {
            let since = firstSeen[candidate.key] ?? now
            firstSeen[candidate.key] = since
            if now.timeIntervalSince(since) >= startDelay {
                active = candidate
                lastSeenActive = now
                firstSeen = [:]
                return .start(candidate)
            }
        }
        return nil
    }

    /// Forget the active meeting without emitting `.stop` (e.g. after the user stopped manually).
    public mutating func reset() {
        active = nil
        lastSeenActive = nil
        firstSeen = [:]
    }

    /// Mark a candidate as already handled so it doesn't start again until it disappears.
    public mutating func adopt(_ candidate: MeetingCandidate, now: Date) {
        active = candidate
        lastSeenActive = now
        firstSeen = [:]
    }
}

/// Keeps the latest state reported by each Chrome tab.
public struct BrowserMeetingTracker: Sendable {
    public struct TabState: Sendable {
        public var event: ExtensionEvent
        public var lastSeen: Date
    }

    /// Heartbeats arrive every 3 s; after this long without one the tab is considered gone.
    public var staleAfter: TimeInterval
    public private(set) var tabs: [Int: TabState] = [:]
    /// `ts` of each tab's last "ended", so a heartbeat that was in flight can't revive the call.
    private var endedAt: [Int: Double] = [:]

    public init(staleAfter: TimeInterval = 12) {
        self.staleAfter = staleAfter
    }

    public mutating func record(_ event: ExtensionEvent, now: Date) {
        var event = event
        // The URL is opened from the app; only web meeting links belong there.
        if let url = event.url, URL(string: url)?.scheme?.lowercased() != "https" { event.url = nil }
        switch event.type {
        case .meeting:
            if let ts = event.ts, let ended = endedAt[event.tabId], ts <= ended { return }
            endedAt[event.tabId] = nil
            tabs[event.tabId] = TabState(event: event, lastSeen: now)
        case .ended:
            tabs[event.tabId] = nil
            endedAt[event.tabId] = event.ts ?? now.timeIntervalSince1970 * 1000
            if endedAt.count > 200, let oldest = endedAt.min(by: { $0.value < $1.value })?.key { endedAt[oldest] = nil }
        }
    }

    public static func key(tabId: Int, callId: Int?) -> String {
        "chrome-tab:\(tabId)" + (callId.map { "#\($0)" } ?? "")
    }

    public mutating func candidates(now: Date) -> [MeetingCandidate] {
        tabs = tabs.filter { now.timeIntervalSince($0.value.lastSeen) < staleAfter }
        return tabs
            .filter { $0.value.event.inMeeting == true }
            .sorted { $0.key < $1.key }
            .map { tabId, state in
                MeetingCandidate(key: Self.key(tabId: tabId, callId: state.event.callId), platform: state.event.platform,
                                 title: state.event.title, url: state.event.url, replaces: "app:chrome")
            }
    }

    public func state(forKey key: String) -> ExtensionEvent? {
        tab(forKey: key)?.event
    }

    /// When the tab last reported; each heartbeat carries fresh active speakers.
    public func lastSeen(forKey key: String) -> Date? {
        tab(forKey: key)?.lastSeen
    }

    /// The tab's state while it is still in the same call the key names.
    private func tab(forKey key: String) -> TabState? {
        guard key.hasPrefix("chrome-tab:") else { return nil }
        let id = key.dropFirst("chrome-tab:".count).split(separator: "#", maxSplits: 1).first.flatMap { Int($0) }
        guard let id, let state = tabs[id], Self.key(tabId: id, callId: state.event.callId) == key else { return nil }
        return state
    }
}
