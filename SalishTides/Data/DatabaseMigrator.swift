import Foundation

// Runs once on first launch: loads all 344 JSON files into the SQLite vector database.
// Self-contained and idempotent — safe to call unconditionally; guards against concurrent runs.
actor DatabaseMigrator {
    static let shared = DatabaseMigrator()
    private init() {}

    private static let migratedKey = "vectorDBMigrated_v2"
    private var isRunning = false

    // True only when migration has not completed AND is not currently running.
    var needsMigration: Bool {
        !isRunning && !UserDefaults.standard.bool(forKey: Self.migratedKey)
    }

    func migrate(progress: @Sendable (Double) -> Void) async throws {
        // Guard: already done or already running — both are no-ops
        guard !isRunning, !UserDefaults.standard.bool(forKey: Self.migratedKey) else { return }
        isRunning = true
        defer { isRunning = false }

        let regions = ["A", "B", "C", "D", "E", "F", "G", "H"]
        let total = Double(43 * regions.count)
        var completed = 0

        for chart in 1...43 {
            for region in regions {
                let vectors = try loadVectors(chart: chart, region: region)
                let records = vectors.map { v in
                    VectorRecord(
                        chart: chart, region: region,
                        lat: v.lat, lon: v.lon,
                        speed_ms: v.speed_ms, direction_deg: v.direction_deg
                    )
                }
                try await VectorDatabase.shared.insert(records)
                completed += 1
                progress(Double(completed) / total)
            }
        }

        UserDefaults.standard.set(true, forKey: Self.migratedKey)
    }

    private func loadVectors(chart: Int, region: String) throws -> [CurrentVector] {
        let name = "map_\(chart)_\(region)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "maps") else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CurrentVector].self, from: data)
    }
}
