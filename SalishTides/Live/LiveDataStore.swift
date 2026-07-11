import Foundation
import GRDB

/// On-disk cache for fetched SalishSeaCast data (`live.sqlite`). Unlike the
/// bundled vector/tide databases this one is written at runtime — but it holds
/// nothing that can't be re-fetched, so schema bumps just drop and recreate.
actor LiveDataStore {
    static let shared = LiveDataStore()

    // Bump when the schema OR a packed-blob layout changes (see
    // SalishSeaCastAPI's pack/unpack). Combined with the grid stride so a
    // stride retune also invalidates cached geometry/slices.
    private static let schemaVersion = 1

    private var pool: DatabasePool?

    private init() {}

    func setup() throws {
        let p = try DatabasePool(path: Self.dbURL().path)
        try p.write { db in
            let expected = Self.schemaVersion * 1000 + SalishSeaCastAPI.gridStride
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version != expected {
                for table in ["live_blobs", "live_current_slices", "live_ssh", "live_meta"] {
                    try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
                }
                try db.execute(sql: "PRAGMA user_version = \(expected)")
            }
            try db.create(table: "live_blobs", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("data", .blob).notNull()
            }
            try db.create(table: "live_current_slices", ifNotExists: true) { t in
                t.primaryKey("t", .integer)                  // slice hour start, epoch s (UTC)
                t.column("fetched_at", .integer).notNull()
                t.column("data", .blob).notNull()            // packed WetPoints
            }
            try db.create(table: "live_ssh", ifNotExists: true) { t in
                t.column("gauge", .text).notNull()           // gauge dataset id
                t.column("t", .integer).notNull()            // epoch s (UTC)
                t.column("ssh", .double).notNull()           // metres above geoid
                t.uniqueKey(["gauge", "t"])
            }
            try db.create(table: "live_meta", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        pool = p
    }

    // ── Grid geometry ────────────────────────────────────────────────────

    func saveGrid(_ grid: SalishSeaCastAPI.LiveGrid) throws {
        guard let pool else { return }
        let blob = SalishSeaCastAPI.pack(grid)
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO live_blobs (key, data) VALUES ('grid', ?)",
                           arguments: [blob])
        }
    }

    func loadGrid() throws -> SalishSeaCastAPI.LiveGrid? {
        guard let pool else { return nil }
        let blob = try pool.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM live_blobs WHERE key = 'grid'")
        }
        return blob.map(SalishSeaCastAPI.unpackGrid)
    }

    // ── Hourly current slices ────────────────────────────────────────────

    func saveSlice(hourKey: Int, points: [SalishSeaCastAPI.WetPoint], fetchedAt: Date) throws {
        guard let pool else { return }
        let blob = SalishSeaCastAPI.pack(points)
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO live_current_slices (t, fetched_at, data) VALUES (?, ?, ?)",
                arguments: [hourKey, Int(fetchedAt.timeIntervalSince1970), blob])
        }
    }

    /// hourKey → fetchedAt for every cached slice (drives staleness checks).
    func sliceIndex() throws -> [Int: Date] {
        guard let pool else { return [:] }
        return try pool.read { db in
            var index: [Int: Date] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT t, fetched_at FROM live_current_slices")
            for row in rows {
                index[row["t"]] = Date(timeIntervalSince1970: TimeInterval(row["fetched_at"] as Int))
            }
            return index
        }
    }

    func loadSlicePoints(hourKey: Int) throws -> [SalishSeaCastAPI.WetPoint]? {
        guard let pool else { return nil }
        let blob = try pool.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM live_current_slices WHERE t = ?",
                              arguments: [hourKey])
        }
        return blob.map(SalishSeaCastAPI.unpackPoints)
    }

    func deleteSlices(before hourKey: Int) throws {
        guard let pool else { return }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM live_current_slices WHERE t < ?", arguments: [hourKey])
        }
    }

    // ── SSH series ───────────────────────────────────────────────────────

    /// Replaces a gauge's whole series — each fetch spans the full window we
    /// care about, so replacement doubles as pruning.
    func replaceSSH(gauge: String, samples: [(t: Int, ssh: Double)]) throws {
        guard let pool else { return }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM live_ssh WHERE gauge = ?", arguments: [gauge])
            let insert = try db.makeStatement(sql: "INSERT INTO live_ssh (gauge, t, ssh) VALUES (?, ?, ?)")
            for s in samples {
                try insert.execute(arguments: [gauge, s.t, s.ssh])
            }
        }
    }

    /// All cached series, keyed by gauge dataset id, ascending in time.
    func sshSeries() throws -> [String: [(t: Int, ssh: Double)]] {
        guard let pool else { return [:] }
        return try pool.read { db in
            var out: [String: [(t: Int, ssh: Double)]] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT gauge, t, ssh FROM live_ssh ORDER BY gauge, t")
            for row in rows {
                out[row["gauge"], default: []].append((t: row["t"], ssh: row["ssh"]))
            }
            return out
        }
    }

    // ── Meta ─────────────────────────────────────────────────────────────

    func meta(_ key: String) throws -> String? {
        guard let pool else { return nil }
        return try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM live_meta WHERE key = ?", arguments: [key])
        }
    }

    func setMeta(_ key: String, _ value: String) throws {
        guard let pool else { return }
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO live_meta (key, value) VALUES (?, ?)",
                           arguments: [key, value])
        }
    }

    private static func dbURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return dir.appendingPathComponent("live.sqlite")
    }
}
