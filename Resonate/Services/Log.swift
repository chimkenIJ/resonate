import OSLog

/// App logging. Shows in Console.app and `log show` under subsystem com.ishajain.Resonate.
nonisolated enum Log {
    static let account = Logger(subsystem: "com.ishajain.Resonate", category: "account")
    static let data = Logger(subsystem: "com.ishajain.Resonate", category: "data")
    static let speech = Logger(subsystem: "com.ishajain.Resonate", category: "speech")
}
