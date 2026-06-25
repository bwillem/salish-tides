import Foundation

actor DatabaseMigrator {
    static let shared = DatabaseMigrator()
    private init() {}

    // Gates the expensive one-time population — set only after every record is
    // inserted, so an interrupted first launch can't leave a partial table.
    // Keep vectorKey's version in lockstep with VectorDatabase.schemaVersion: a
    // schema bump drops the table, so the population key must change too or the
    // fresh table is left empty. v4 = corrected Vol 2-4 georeferencing.
    private static let vectorKey = "vectorDBMigrated_v5"
    // Tide hi/lo predictions (independent of the vector schema).
    private static let tideKey = "tideDBMigrated_v1"
    private var isRunning = false

    private var needsVectors: Bool { !UserDefaults.standard.bool(forKey: Self.vectorKey) }
    private var needsTides: Bool { !UserDefaults.standard.bool(forKey: Self.tideKey) }

    var needsMigration: Bool {
        !isRunning && (needsVectors || needsTides)
    }

    func migrate(progress: @Sendable (Double) -> Void) async throws {
        guard !isRunning, needsVectors || needsTides else { return }
        isRunning = true
        defer { isRunning = false }

        let doVectors = needsVectors
        let doTides = needsTides

        let vectorUnits = doVectors
            ? atlasVolumes.reduce(0) { $0 + $1.maxChart * $1.regions.count } : 0
        // Decode errors must propagate (not silently mark the migration done).
        let tideStations = doTides ? try loadTideBundle().stations : []
        let total = Double(vectorUnits + tideStations.count)
        var completed = 0
        func bump() { completed += 1; progress(total > 0 ? Double(completed) / total : 1) }

        if doVectors {
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
                        bump()
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: Self.vectorKey)
        }

        if doTides {
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
                bump()
            }
            UserDefaults.standard.set(true, forKey: Self.tideKey)
        }
    }

    // MARK: - Bundle loading

    private func loadVectors(spec: VolumeSpec, chart: Int, region: String) throws -> [CurrentVector] {
        let name = "map_\(chart)_\(region)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: spec.mapSubdirectory) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CurrentVector].self, from: data)
    }

    private func loadTideBundle() throws -> TideBundle {
        guard let url = Bundle.main.url(forResource: "tides_2026", withExtension: "json", subdirectory: "tides") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TideBundle.self, from: data)
    }
}
