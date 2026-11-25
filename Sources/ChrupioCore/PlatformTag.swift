import Foundation

extension Platform {
    /// Short upper-case label for the D1 platform tag box; `displayName` stays the full name (tooltips, headers).
    public var tag: String {
        switch self {
        case .meet: "MEET"
        case .teams: "TEAMS"
        case .slack: "SLACK"
        case .zoom: "ZOOM"
        case .other: "CALL"
        }
    }
}
