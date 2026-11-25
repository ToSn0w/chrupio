import Foundation

extension PersonName {
    /// Whether two reported names are one person: "Łukasz Zurek", "Lukasz Zurek" and "Łukasz Żurek" are.
    public static func same(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return key(stripMarkers(a)) == key(stripMarkers(b))
    }
}

/// The user's own names ("Your name(s)" in Settings), used when a call doesn't say which participant is the user.
public enum SelfNames {
    /// Names typed one per line or comma.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The self name most stored meetings have; nil when none has one.
    public static func usual(in meetings: [Meeting]) -> String? {
        let names = meetings.compactMap(\.selfName).filter { !$0.isEmpty }
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        // Ties go to the alphabet, so the result is the same on every launch.
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }
}

extension Meeting {
    /// Whether `name` is the user: the meeting's self name or one of `others` (the configured names).
    public func isSelf(_ name: String, others: [String] = []) -> Bool {
        ([selfName].compactMap { $0 } + others).contains { PersonName.same(name, $0) }
    }

    /// Gives the meeting the first configured name when the call reported none, and takes the user off the attendees.
    public mutating func applySelf(_ configured: [String]) {
        if (selfName ?? "").isEmpty, let first = configured.first { selfName = first }
        let me = self
        attendees.removeAll { me.isSelf($0, others: configured) }
    }
}

/// One-off clean-up of meetings stored before attendee cleaning and self names: junk attendees dropped,
/// role markers ("Marek Unverified") stripped everywhere the name appears, the user off the attendee list.
public enum MeetingRepair {
    public static let doneKey = "meetingRepair1Done"

    /// Fixes one meeting; true when anything changed.
    @discardableResult
    public static func repair(_ meeting: inout Meeting, selfNames: [String]) -> Bool {
        let before = meeting
        var renamed: [String: String] = [:]
        for name in meeting.attendees + meeting.segments.compactMap({ if case .remote(let n?) = $0.speaker { n } else { nil } }) {
            let clean = PersonName.stripMarkers(name)
            if clean != name, !clean.isEmpty { renamed[name] = clean }
        }
        meeting.canonicalizeNames(PersonName.stripMarkers)
        if var summary = meeting.summary {
            // Longest first, so "Marek (Unverified)" isn't left as "Marek (".
            for (old, new) in renamed.sorted(by: { $0.key.count > $1.key.count }) {
                summary.markdown = summary.markdown.replacingOccurrences(of: old, with: new)
            }
            meeting.summary = summary
        }
        meeting.applySelf(selfNames)
        return meeting != before
    }

    /// Copies every meeting.json a dated sibling (`meetings-backup-YYYYMMDD`), then repairs every meeting in place.
    public static func run(store: MeetingStore, selfNames: [String], now: Date = Date()) throws -> (backup: URL, changed: Int) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        let parent = store.root.deletingLastPathComponent()
        var backup = parent.appendingPathComponent("\(store.root.lastPathComponent)-backup-\(formatter.string(from: now))", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = parent.appendingPathComponent("\(store.root.lastPathComponent)-backup-\(formatter.string(from: now))-\(suffix)", isDirectory: true)
            suffix += 1
        }
        // Only meeting.json is rewritten, so only it is copied; audio would make the backup gigabytes.
        for id in store.modificationDates().keys {
            let dir = backup.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: store.directory(for: id).appendingPathComponent("meeting.json"),
                                             to: dir.appendingPathComponent("meeting.json"))
        }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var changed = 0
        try store.withWriteLock {
            for var meeting in store.loadAll() where repair(&meeting, selfNames: selfNames) {
                try store.writeUnlocked(meeting)
                changed += 1
            }
        }
        return (backup, changed)
    }
}
