import os

/// App loggers. The offline-first fallback policy means several failures are
/// deliberately swallowed (live data degrades to cached, cached to atlas) —
/// these make those swallow sites diagnosable in the field without changing
/// the behavior. View in Console.app under the app's subsystem.
enum Log {
    private static let subsystem = "com.bguenther.salishtides"

    static let live = Logger(subsystem: subsystem, category: "live")
    static let map = Logger(subsystem: subsystem, category: "map")
}
