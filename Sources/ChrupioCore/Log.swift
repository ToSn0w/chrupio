import os

/// Unified logging for the core library. Read with `log stream --predicate 'subsystem == "Chrupio"'`.
public enum CoreLog {
    public static let process = Logger(subsystem: "Chrupio", category: "process")
    public static let store = Logger(subsystem: "Chrupio", category: "store")
    public static let lock = Logger(subsystem: "Chrupio", category: "lock")
    /// The token and endpoint files of the app's local edit API.
    public static let localAPI = Logger(subsystem: "Chrupio", category: "local-api")
    public static let semantic = Logger(subsystem: "Chrupio", category: "semantic")
    /// The app's meeting pipeline (schedulers the coordinator drives); same category the coordinator logs under.
    public static let coordinator = Logger(subsystem: "Chrupio", category: "coordinator")
}
