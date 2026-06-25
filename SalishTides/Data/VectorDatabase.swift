import Foundation
import GRDB

struct VectorRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "vectors"
    var volume: Int
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

    // Bump whenever the `vectors` table layout OR the bundled JSON changes.
    // setup() drops and recreates the table when the on-disk version is older,
    // so existing installs can't be left with a stale layout or stale data.
    // The DB is a pure derived cache rebuilt from bundled JSON, so dropping
    // is always safe — DatabaseMigrator repopulates it.
    // v8: slack dot markers (atlas draws these where current is below the
    // min-arrow threshold), subsampled to ~2 km, so weak areas are not blank.
    private static let schemaVersion = 8

    private init() {}

    func setup() throws {
        let dbURL = try Self.dbURL()
        let p = try DatabasePool(path: dbURL.path)
        try p.write { db in
            let onDisk = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if onDisk < Self.schemaVersion {
                try db.execute(sql: "DROP TABLE IF EXISTS \(VectorRecord.databaseTableName)")
            }
            try db.create(table: VectorRecord.databaseTableName, ifNotExists: true) { t in
                t.column("volume", .integer).notNull()
                t.column("chart", .integer).notNull()
                t.column("region", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("speed_ms", .double).notNull()
                t.column("direction_deg", .double).notNull()
                t.uniqueKey(["volume", "chart", "region", "lat", "lon"])
            }
            try db.create(
                index: "vectors_by_volume_chart",
                on: VectorRecord.databaseTableName,
                columns: ["volume", "chart", "region"],
                ifNotExists: true
            )
            if onDisk < Self.schemaVersion {
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
        self.pool = p
    }

    func insert(_ records: [VectorRecord]) throws {
        guard let pool else { return }
        try pool.write { db in
            for record in records {
                try record.insert(db, onConflict: .ignore)
            }
        }
    }

    func vectors(volume: Int, chart: Int, regions: [String]) throws -> [CurrentVector] {
        guard let pool, !regions.isEmpty else { return [] }
        return try pool.read { db in
            let placeholders = databaseQuestionMarks(count: regions.count)
            var args: [DatabaseValueConvertible] = [volume, chart]
            args += regions as [DatabaseValueConvertible]
            let sql = "SELECT * FROM vectors WHERE volume = ? AND chart = ? AND region IN (\(placeholders))"
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
