import Foundation

/// The meeting's date for the summary prompt, and the check on the dates the model works out from it.
public enum ActionItemDates {
    /// A deadline further out than this is taken for a mistake.
    static let maximumDaysAhead = 366

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar(timeZone)
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    /// "Date: 2026-11-12 (Thursday)\n", in the Mac's time zone.
    public static func headerLine(_ date: Date, timeZone: TimeZone = .current) -> String {
        "Date: \(formatter("yyyy-MM-dd (EEEE)", timeZone).string(from: date))\n"
    }

    /// `text` when it is a real YYYY-MM-DD date from the meeting's day to `maximumDaysAhead` days later, else nil.
    public static func valid(_ text: String?, meetingStart: Date, timeZone: TimeZone = .current) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = formatter("yyyy-MM-dd", timeZone).date(from: text) else { return nil }
        let calendar = calendar(timeZone)
        let day = calendar.startOfDay(for: meetingStart)
        guard let days = calendar.dateComponents([.day], from: day, to: date).day, (0...maximumDaysAhead).contains(days) else { return nil }
        return text
    }
}
