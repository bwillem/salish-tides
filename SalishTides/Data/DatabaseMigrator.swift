import Foundation

actor DatabaseMigrator {
    static let shared = DatabaseMigrator()
    private init() {}

    // Gates the expensive one-time population. This guarantees *completeness*
    // (set only after every record is inserted), which a row-count check
    // couldn't — an interrupted first launch would leave a partial table.
    // Keep the version suffix in lockstep with VectorDatabase.schemaVersion:
    // a schema bump drops the table, so the population key must change too,
    // otherwise needsMigration stays false and the fresh table is left empty.
    private static let migratedKey = "vectorDBMigrated_v4"
    private var isRunning = false

    var needsMigration: Bool {
        !isRunning && !UserDefaults.standard.bool(forKey: Self.migratedKey)
    }

    func migrate(progress: @Sendable (Double) -> Void) async throws {
        guard !isRunning, !UserDefaults.standard.bool(forKey: Self.migratedKey) else { return }
        isRunning = true
        defer { isRunning = false }

        let total = Double(atlasVolumes.reduce(0) { $0 + $1.maxChart * $1.regions.count })
        var completed = 0

        for spec in atlasVolumes {
            for chart in 1...spec.maxChart {
                for region in spec.regions {
                    let vectors = try loadVectors(spec: spec, chart: chart, region: region)
                    let records = vectors.map { v in
                        VectorRecord(
                            volume: spec.id, chart: chart, region: region,
                            lat: v.lat, lon: v.lon,
                            speed_ms: v.speed_ms, direction_deg: v.direction_deg
                        )
                    }
                    try await VectorDatabase.shared.insert(records)
                    completed += 1
                    progress(Double(completed) / total)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: Self.migratedKey)
    }

    private func loadVectors(spec: VolumeSpec, chart: Int, region: String) throws -> [CurrentVector] {
        let name = "map_\(chart)_\(region)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: spec.mapSubdirectory) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CurrentVector].self, from: data)
    }
}
