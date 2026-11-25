import AppKit
import ApplicationServices
import Foundation

/// Reads Zoom's meeting window and participant list through the macOS Accessibility API.
public enum ZoomMonitor {
    public struct Snapshot: Sendable, Equatable {
        public var isRunning: Bool
        public var hasMeetingWindow: Bool
        public var title: String?
        public var participants: [String]
        public var selfName: String?
        /// Who Zoom marks as talking right now ("Talking: Anna Nowak", a tile labelled "Anna Nowak, talking").
        public var activeSpeakers: [String] = []
        /// Names on video tiles; the participant list is closed during most calls.
        public var tileNames: [String] = []
        /// Distinct labels in the meeting window, kept to tune the parsing from real calls.
        public var labels: [String] = []
        /// Titles of Zoom's windows; newer Zoom builds name the meeting window differently.
        public var windowTitles: [String] = []
        /// Every window of the Zoom process: the Accessibility windows with their roles, then the window server's
        /// list, which also has windows on other Spaces and the floating meeting controls. Logged in the probe.
        public var windows: [WindowInfo] = []
    }

    public struct WindowInfo: Sendable, Equatable {
        /// "ax" for an Accessibility window, "cg" for the window server's list.
        public var source: String
        public var title: String?
        public var role: String?
        public var subrole: String?
        /// Window server only: layer (0 for normal windows), whether it is on screen now, and its size.
        public var layer: Int?
        public var onScreen: Bool?
        public var size: String?

        public init(source: String, title: String?, role: String? = nil, subrole: String? = nil,
                    layer: Int? = nil, onScreen: Bool? = nil, size: String? = nil) {
            self.source = source
            self.title = title
            self.role = role
            self.subrole = subrole
            self.layer = layer
            self.onScreen = onScreen
            self.size = size
        }

        public var json: AnyJSON {
            var object: [String: AnyJSON] = ["source": .string(source)]
            if let title { object["title"] = .string(title) }
            if let role { object["role"] = .string(role) }
            if let subrole { object["subrole"] = .string(subrole) }
            if let layer { object["layer"] = .number(Double(layer)) }
            if let onScreen { object["onScreen"] = .bool(onScreen) }
            if let size { object["size"] = .string(size) }
            return .object(object)
        }
    }

    /// Which Accessibility windows the label walk reads. A window titled like a meeting wins. Otherwise, when exactly
    /// one window that isn't Zoom's home or settings window is a standard window, that is taken as the meeting window
    /// (the floating controls and dialogs have other subroles). Otherwise every window but home and settings, as before.
    public static func labelWindows(_ windows: [WindowInfo]) -> [Int] {
        let meeting = windows.indices.filter { windows[$0].title.map(isMeetingWindowTitle) ?? false }
        if !meeting.isEmpty { return meeting }
        let others = windows.indices.filter { !isHomeWindowTitle(windows[$0].title ?? "") }
        let standard = others.filter { windows[$0].subrole == kAXStandardWindowSubrole as String }
        return standard.count == 1 ? standard : others
    }

    /// The window server's entries for `pid`, including off-screen windows (other Spaces, minimized, hidden).
    /// Titles need Screen Recording permission; without it they are nil.
    public static func windowServerWindows(pid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) == pid } ?? false }.map { entry in
            let bounds = entry[kCGWindowBounds as String] as? [String: Any]
            let size = bounds.flatMap { b -> String? in
                guard let width = b["Width"] as? Double, let height = b["Height"] as? Double else { return nil }
                return "\(Int(width))x\(Int(height))"
            }
            return WindowInfo(source: "cg", title: entry[kCGWindowName as String] as? String,
                              layer: entry[kCGWindowLayer as String] as? Int,
                              onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false, size: size)
        }
    }

    public static let bundleID = "us.zoom.xos"

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Elements one walk of the window tree may visit; a busy gallery view has thousands, and each costs an IPC call.
    public static let maxVisited = 500

    /// - Parameter includeLabels: walks the meeting window for talking indicators and tile names. Detection needs
    ///   only the window titles, so the walk runs only while a Zoom call is recorded.
    public static func snapshot(includeParticipants: Bool, includeLabels: Bool = true) -> Snapshot {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return Snapshot(isRunning: false, hasMeetingWindow: false, title: nil, participants: [], selfName: nil)
        }
        guard isAccessibilityTrusted else {
            return Snapshot(isRunning: true, hasMeetingWindow: false, title: nil, participants: [], selfName: nil)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Child elements use the system-wide timeout (6 s by default), not the app element's.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let windows: [AXUIElement] = attribute(element, kAXWindowsAttribute) ?? []
        let axWindows = windows.map { window in
            WindowInfo(source: "ax", title: attribute(window, kAXTitleAttribute), role: attribute(window, kAXRoleAttribute),
                       subrole: attribute(window, kAXSubroleAttribute))
        }
        let titles = axWindows.compactMap(\.title)
        let meetingTitle = titles.first(where: isMeetingWindowTitle)

        var participants: [String] = []
        var selfName: String?
        var visited = 0
        for window in windows where includeParticipants {
            collectParticipants(in: window, depth: 0, visited: &visited, insideList: false, names: &participants, selfName: &selfName)
        }
        var seen = Set<String>()
        participants = participants.filter { seen.insert($0.lowercased()).inserted }
        var snapshot = Snapshot(isRunning: true, hasMeetingWindow: meetingTitle != nil, title: meetingTitle,
                                participants: participants, selfName: selfName)
        snapshot.windowTitles = titles
        // The full list is for the probe, written with the participant scan.
        if includeParticipants { snapshot.windows = axWindows + windowServerWindows(pid: app.processIdentifier) }
        if includeLabels {
            var labels: [String] = []
            var labelsVisited = 0
            // Called only while Zoom holds the mic or shows a meeting; a call window with a title the list doesn't know
            // (a meeting topic, a new Zoom build) is still walked, only the home and settings windows are skipped.
            let meetingWindows = labelWindows(axWindows).map { windows[$0] }
            for window in meetingWindows {
                collectLabels(in: window, depth: 0, visited: &labelsVisited, labels: &labels)
            }
            var unique = Set<String>()
            labels = labels.filter { unique.insert($0).inserted }
            snapshot.labels = Array(labels.prefix(200))
            snapshot.activeSpeakers = labels.compactMap { Self.speakerName(fromLabel: $0) }
            snapshot.tileNames = labels.compactMap { Self.tileName(fromLabel: $0) }
        }
        return snapshot
    }

    /// The speaker a label marks as talking: "Talking: Anna Nowak", "Anna Nowak is talking", "Anna Nowak, Speaking".
    public static func speakerName(fromLabel label: String) -> String? {
        for regex in speakerPatterns {
            guard let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let range = Range(match.range(at: 1), in: label) else { continue }
            let first = String(label[range]).components(separatedBy: ",").first!
            let name = parenthesized.stringByReplacingMatches(in: first, range: NSRange(first.startIndex..., in: first), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2, name.count <= 60, name.split(separator: " ").count <= 4, !Self.notNames.contains(where: {
                name.lowercased() == $0 || name.lowercased().hasPrefix($0 + " ")
            }) { return name }
        }
        return nil
    }

    // Built once: a scan parses up to a few hundred labels every couple of seconds.
    static let speakerPatterns: [NSRegularExpression] = [
        #"^(?:talking|speaking|active speaker|mówi)\s*:\s*(.+)$"#,
        // The keyword must end the label, or chat lines like "Stop talking about it" would name "Stop".
        #"^(.+?)(?:,\s*|\s+is\s+|\s+)(?:talking|speaking|mówi)(?:\s+now)?\s*\.?$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    static let parenthesized = try! NSRegularExpression(pattern: #"\s*\([^)]*\)"#)
    static let openParenthesis = try! NSRegularExpression(pattern: #"\s*\([^)]*\)?"#)
    static let tileState = try! NSRegularExpression(pattern: #"\b(?:video|audio|camera|muted|unmuted|talking|speaking)\b"#,
                                                                        options: [.caseInsensitive])
    static let meMarker = try! NSRegularExpression(pattern: #"\((?:[^)]*\b)?me\)"#, options: [.caseInsensitive])

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Openings of sentences that end in "talking"/"speaking" but aren't a person.
    static let notNames = ["not", "no one", "nobody", "someone", "everyone", "i", "you", "we", "they", "he", "she", "who", "stop", "start", "keep", "was", "were"]

    /// The person on a video tile: "Anna Nowak, Video on", "Anna Nowak (Host), computer audio unmuted".
    public static func tileName(fromLabel label: String) -> String? {
        let parts = label.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.dropFirst().contains(where: { matches(tileState, $0) }) else { return nil }
        return parseParticipantRow(label)?.name
    }


    private static func collectLabels(in element: AXUIElement, depth: Int, visited: inout Int, labels: inout [String]) {
        visited += 1
        guard depth < 16, visited <= maxVisited else { return }
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let text: String = attribute(element, name) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2, trimmed.count <= 120 { labels.append(trimmed) }
            }
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children {
            collectLabels(in: child, depth: depth + 1, visited: &visited, labels: &labels)
        }
    }

    /// Zoom windows that are never the call itself.
    public static func isHomeWindowTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasPrefix("zoom workplace") || lower == "settings"
    }

    public static func isMeetingWindowTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasPrefix("zoom meeting") || lower.hasPrefix("zoom webinar")
            || lower == "meeting" || lower.hasPrefix("participants")
    }

    /// Parses one participant row label, e.g. "Anna Nowak (Host, me), Computer audio muted, Video off".
    public static func parseParticipantRow(_ label: String) -> (name: String, isMe: Bool)? {
        let first = label.components(separatedBy: ",").first ?? label
        let isMe = matches(meMarker, label)
        let name = openParenthesis.stringByReplacingMatches(in: first, range: NSRange(first.startIndex..., in: first), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = ["participants", "invite", "mute all", "more", "search", "chat", "waiting room", "in the meeting"]
        guard name.count >= 2, name.count <= 60, !junk.contains(where: { name.lowercased().hasPrefix($0) }) else { return nil }
        return (name, isMe)
    }

    private static func collectParticipants(in element: AXUIElement, depth: Int, visited: inout Int, insideList: Bool,
                                            names: inout [String], selfName: inout String?) {
        visited += 1
        guard depth < 14, visited <= maxVisited else { return }
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        let title: String = attribute(element, kAXTitleAttribute) ?? ""
        let description: String = attribute(element, kAXDescriptionAttribute) ?? ""
        let isList = insideList || title.lowercased().hasPrefix("participants") || description.lowercased().hasPrefix("participants")

        if isList, role == kAXRowRole as String || role == "AXCell" {
            let label = !description.isEmpty ? description : title.isEmpty ? firstStaticText(in: element) ?? "" : title
            if let parsed = parseParticipantRow(label) {
                names.append(parsed.name)
                if parsed.isMe { selfName = parsed.name }
            }
            return
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children {
            collectParticipants(in: child, depth: depth + 1, visited: &visited, insideList: isList, names: &names, selfName: &selfName)
        }
    }

    private static func firstStaticText(in element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole as String, let value: String = attribute(element, kAXValueAttribute), !value.isEmpty {
            return value
        }
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children {
            if let text = firstStaticText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
