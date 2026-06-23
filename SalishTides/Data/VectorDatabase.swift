import Foundation
import GRDB

struct VectorRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "vectors"
    var chart: Int
    var region: String
    var lat: Double
    var lon: Double
    var speed_ms: Double
    var direction_deg: Double

    var asVector: CurrentVector {
        CurrentVector(lat: lat, lon: lon, speed_ms: speed_ms, direction_deg: direction_deg)
    }
}

actor VectorDatabase {
    static let shared = VectorDatabase()
    private var pool: DatabasePool?

    private init() {}

    func setup() throws {
        let dbURL = try Self.dbURL()
        let p = try DatabasePool(path: dbURL.path)
        try p.write { db in
            try db.create(table: VectorRecord.databaseTableName, ifNotExists: true) { t in
                t.column("chart", .integer).notNull()
                t.column("region", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("speed_ms", .double).notNull()
                t.column("direction_deg", .double).notNull()
                // Unique constraint prevents duplicate rows on repeated migration runs
                t.uniqueKey(["chart", "region", "lat", "lon"])
            }
        }
        self.pool = p
    }

    func insert(_ records: [VectorRecord]) throws {
        guard let pool else { return }
        try pool.write { db in
            for record in records {
                // INSERT OR IGNORE: silently skips rows that violate the unique constraint,
                // making migration safe to re-run after an interrupted first launch.
                try record.insert(db, onConflict: .ignore)
            }
        }
    }

    func vectors(chart: Int, regions: [String]) throws -> [CurrentVector] {
        guard let pool, !regions.isEmpty else { return [] }
        return try pool.read { db in
            let placeholders = databaseQuestionMarks(count: regions.count)
            var args: [DatabaseValueConvertible] = [chart]
            args += regions as [DatabaseValueConvertible]
            let sql = "SELECT * FROM vectors WHERE chart = ? AND region IN (\(placeholders))"
            return try VectorRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map(\.asVector)
        }
    }

    private static func dbURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("vectors.sqlite")
    }
}
