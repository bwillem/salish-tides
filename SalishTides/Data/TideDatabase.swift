import Foundation
import GRDB

struct TideStationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tide_stations"
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var datum: String
    var source: String

    var asStation: TideStation {
        TideStation(id: id, name: name, lat: lat, lon: lon, datum: datum, source: source)
    }
}

struct TideEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tide_events"
    var station_id: String
    var t: Int           // epoch seconds (UTC) — fast range queries + ordering
    var height: Double
    var is_high: Bool

    var asEvent: TideEvent {
        TideEvent(time: Date(timeIntervalSince1970: TimeInterval(t)), height: height, isHigh: is_high)
    }
}

actor TideDatabase {
    static let shared = TideDatabase()
    private var pool: DatabasePool?

    // Station registry is tiny (~142) — held in memory for O(n) nearest lookup.
    private var stations: [TideStation] = []

    private init() {}

    func setup() throws {
        let p = try DatabasePool(path: Self.dbURL().path)
        try p.write { db in
            try db.create(table: TideStationRecord.databaseTableName, ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("datum", .text).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(table: TideEventRecord.databaseTableName, ifNotExists: true) { t in
                t.column("station_id", .text).notNull()
                t.column("t", .integer).notNull()
                t.column("height", .double).notNull()
                t.column("is_high", .boolean).notNull()
                t.uniqueKey(["station_id", "t"])
            }
            try db.create(
                index: "tide_events_by_station_time",
                on: TideEventRecord.databaseTableName,
                columns: ["station_id", "t"],
                ifNotExists: true
            )
        }
        self.pool = p
    }

    func insertStation(_ record: TideStationRecord, events: [TideEventRecord]) throws {
        guard let pool else { return }
        try pool.write { db in
            try record.insert(db, onConflict: .ignore)
            for e in events {
                try e.insert(db, onConflict: .ignore)
            }
        }
    }

    // Load the in-memory station registry from the DB (call after setup/migration).
    func loadStations() throws {
        guard let pool else { return }
        stations = try pool.read { db in
            try TideStationRecord.fetchAll(db).map(\.asStation)
        }
    }

    // Nearest station to a coordinate (simple equirectangular distance — fine at
    // this latitude/scale for picking the closest of ~142 stations).
    func nearestStation(lat: Double, lon: Double) -> TideStation? {
        stations.min(by: {
            GeoMath.distanceSquared(fromLat: lat, fromLon: lon, toLat: $0.lat, toLon: $0.lon) <
            GeoMath.distanceSquared(fromLat: lat, fromLon: lon, toLat: $1.lat, toLon: $1.lon)
        })
    }

    // Hi/lo events for a station within a time window (inclusive).
    func events(stationID: String, from: Date, to: Date) throws -> [TideEvent] {
        guard let pool else { return [] }
        let lo = Int(from.timeIntervalSince1970)
        let hi = Int(to.timeIntervalSince1970)
        return try pool.read { db in
            try TideEventRecord
                .fetchAll(db, sql: """
                    SELECT * FROM tide_events
                    WHERE station_id = ? AND t BETWEEN ? AND ?
                    ORDER BY t
                    """, arguments: [stationID, lo, hi])
                .map(\.asEvent)
        }
    }

    private static func dbURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return dir.appendingPathComponent("tides.sqlite")
    }
}
