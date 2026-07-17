import Foundation

actor DatabaseMigrator {
    static let shared = DatabaseMigrator()
    private init() {}

    // Gates the expensive one-time population — set only after every record is
    // inserted, so an interrupted first launch can't leave a partial table.
    // Tide hi/lo predictions only: the print-atlas vector migration is gone
    // (the harmonic models replaced the atlas), but upgraded installs still
    // carry its artifacts — see cleanUpLegacyVectorStore.
    private static let tideKey = "tideDBMigrated_v1"
    private static let legacyVectorKey = "vectorDBMigrated_v9"
    // In-flight migration, memoized so a re-entrant call AWAITS the real
    // work instead of returning "done" against a half-populated table (a
    // bare isRunning guard would fall through to success while the first
    // caller is still mid-insert). Cleared on completion either way; a
    // failure is retried by the next call, as before.
    private var inFlight: Task<Void, Error>?

    private var needsTides: Bool { !UserDefaults.standard.bool(forKey: Self.tideKey) }

    var needsMigration: Bool {
        inFlight == nil && needsTides
    }

    func migrate(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Join, don't skip: any caller that lands during a suspension of the
        // running migration gets the same completion (and the same error).
        if let running = inFlight {
            return try await running.value
        }
        cleanUpLegacyVectorStore()
        guard needsTides else { return }
        let task = Task { try await runMigration(progress: progress) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func runMigration(progress: @Sendable (Double) -> Void) async throws {
        // Decode errors must propagate (not silently mark the migration done).
        let tideStations = try loadTideBundle().stations
        let total = Double(tideStations.count)
        var completed = 0

        for s in tideStations {
            let record = TideStationRecord(
                id: s.key, name: s.name, lat: s.lat, lon: s.lon,
                datum: s.datum, source: s.src)
            let events = s.events.map {
                TideEventRecord(
                    station_id: s.key,
                    t: Int($0.time.timeIntervalSince1970),
                    height: $0.height, is_high: $0.isHigh)
            }
            try await TideDatabase.shared.insertStation(record, events: events)
            completed += 1
            progress(total > 0 ? Double(completed) / total : 1)
        }
        UserDefaults.standard.set(true, forKey: Self.tideKey)
    }

    /// Upgraded installs carry the retired atlas vector store (tens of MB in
    /// Application Support) and its migration flag. Delete both once; fresh
    /// installs pay only a file-existence check.
    private func cleanUpLegacyVectorStore() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first else { return }
        for name in ["vectors.sqlite", "vectors.sqlite-wal", "vectors.sqlite-shm"] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyVectorKey)
    }

    // MARK: - Bundle loading

    private func loadTideBundle() throws -> TideBundle {
        guard let url = Bundle.main.url(forResource: "tides_2026", withExtension: "json", subdirectory: "tides") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TideBundle.self, from: data)
    }
}
