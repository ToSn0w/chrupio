import Foundation

/// "62% · 303/488 MB" under a model download. Decimal megabytes, like the model sizes shown elsewhere.
public enum DownloadProgressText {
    public static func text(completed: Int64, total: Int64) -> String {
        guard total > 0 else { return "\(megabytes(completed)) MB" }
        let percent = Int(min(100, max(0, completed * 100 / total)))
        return "\(percent)% · \(megabytes(completed))/\(megabytes(total)) MB"
    }

    static func megabytes(_ bytes: Int64) -> Int { Int((Double(max(0, bytes)) / 1_000_000).rounded()) }
}
