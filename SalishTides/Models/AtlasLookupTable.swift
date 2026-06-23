import Foundation

struct AtlasLookupTable: Decodable, Sendable {
    let year: Int
    let timezone: String
    let mapCount: Int
    let phases: [String: [Int]]
    let grid: [String: [String: [Int?]]]
}

enum Tendency: Sendable {
    case flood, ebb
}

struct ChartSelection: Sendable {
    let chart: Int
    let phase: String
    let tendency: Tendency
}

// Chart selection is a table lookup keyed to America/Vancouver local hour.
// Do NOT use device-local calendar — the table is keyed to Pacific time with DST baked in.
final class ChartSelector: Sendable {
    private let table: AtlasLookupTable
    private let cal: Calendar

    init(table: AtlasLookupTable) {
        self.table = table
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        self.cal = c
    }

    func selection(for date: Date) -> ChartSelection? {
        let p = cal.dateComponents([.year, .month, .day, .hour], from: date)
        guard let year = p.year, year == table.year,
              let month = p.month, let day = p.day, let hour = p.hour,
              let row = table.grid[String(month)]?[String(day)],
              row.count > hour
        else { return nil }

        // One null exists: grid["3"]["8"][2] — the DST spring-forward skipped hour
        let chart = row[hour] ?? (hour > 0 ? row[hour - 1] : nil) ?? (hour < 23 ? row[hour + 1] : nil)
        guard let c = chart else { return nil }

        #if DEBUG
        let matchCount = table.phases.values.filter { $0.count >= 2 && c >= $0[0] && c <= $0[1] }.count
        assert(matchCount <= 1, "Chart \(c) matches \(matchCount) phase ranges — overlapping boundaries in lookup table")
        #endif

        for (name, lohi) in table.phases where lohi.count >= 2 && c >= lohi[0] && c <= lohi[1] {
            let tendency: Tendency = name.contains("flood") ? .flood : .ebb
            return ChartSelection(chart: c, phase: name, tendency: tendency)
        }
        return ChartSelection(chart: c, phase: "unknown", tendency: .flood)
    }

    static func load() throws -> ChartSelector {
        guard let url = Bundle.main.url(forResource: "atlas_lookup_2026", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let table = try JSONDecoder().decode(AtlasLookupTable.self, from: data)
        return ChartSelector(table: table)
    }
}
