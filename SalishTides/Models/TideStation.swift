import Foundation

// A tide-prediction station (NOAA CO-OPS or CHS IWLS). Heights are in metres
// above the station's own datum (MLLW for NOAA, Chart Datum for CHS) — datums
// are kept distinct and never compared across stations.
struct TideStation: Sendable, Identifiable {
    let id: String          // "NOAA:9444090" / "CHS:07795"
    let name: String
    let lat: Double
    let lon: Double
    let datum: String       // "MLLW" | "CD"
    let source: String      // "NOAA" | "CHS"
}

// A single high- or low-water extremum.
struct TideEvent: Sendable {
    let time: Date
    let height: Double      // metres above station datum
    let isHigh: Bool
}

// Reconstructs a continuous tide curve from discrete hi/lo events using the
// standard tidal cosine interpolation between consecutive extrema — smooth,
// flat at each turn, and exact at the predicted highs/lows.
enum TideCurve {
    static func height(at t: Date, events: [TideEvent]) -> Double? {
        guard let first = events.first, let last = events.last else { return nil }
        if t <= first.time { return first.height }
        if t >= last.time { return last.height }
        for i in 1..<events.count {
            let a = events[i - 1], b = events[i]
            if t >= a.time && t <= b.time {
                let span = b.time.timeIntervalSince(a.time)
                guard span > 0 else { return a.height }
                let frac = t.timeIntervalSince(a.time) / span
                return a.height + (b.height - a.height) * (1 - cos(.pi * frac)) / 2
            }
        }
        return nil
    }
}

// MARK: - Bundle decoding (data/tides/tides_2026.json)

// Top-level bundle file written by dev/tides/fetch_tides.py.
struct TideBundle: Decodable {
    let year: Int
    let datums: [String: String]
    let stations: [TideBundleStation]
}

struct TideBundleStation: Decodable {
    let key: String
    let src: String
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let datum: String
    let events: [TideBundleEvent]

    var station: TideStation {
        TideStation(id: key, name: name, lat: lat, lon: lon, datum: datum, source: src)
    }
}

// Each event is a compact heterogeneous triple: [iso8601_utc, height, "H"|"L"].
struct TideBundleEvent: Decodable {
    let time: Date
    let height: Double
    let isHigh: Bool

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let iso = try c.decode(String.self)
        guard let epoch = Self.epochUTC(from: iso) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "bad ISO date: \(iso)")
        }
        time = Date(timeIntervalSince1970: TimeInterval(epoch))
        height = try c.decode(Double.self)
        isHigh = try c.decode(String.self) == "H"
    }

    // Parse a "YYYY-MM-DDThh:mm:ss[.fff]Z" UTC string to Unix epoch seconds.
    // Pure/Sendable and far cheaper than a Foundation formatter over ~200k events.
    // Also used on server responses, so every field is range-checked: an
    // unbounded year would overflow (trap) in daysFromCivil, and this parser
    // must never crash — or return a wrong instant — on hostile input.
    static func epochUTC(from s: String) -> Int? {
        let parts = s.split(whereSeparator: { "-T:Z".contains($0) })
        guard parts.count >= 6,
              let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              let h = Int(parts[3]), let mi = Int(parts[4])
        else { return nil }
        // Fractional seconds ("56.5") are truncated. '.' must NOT be a
        // general separator: a mangled field like "12:34.5" would shift its
        // digits into the seconds slot and parse to a wrong instant instead
        // of nil. Any non-fraction trailing characters are malformed.
        let secField = parts[5]
        let secDigits = secField.prefix(while: { $0.isASCII && $0.isNumber })
        guard let se = Int(secDigits),
              secDigits.endIndex == secField.endIndex || secField[secDigits.endIndex] == ".",
              (1...9999).contains(y), (1...12).contains(mo), (1...31).contains(d),
              (0...59).contains(mi), (0...60).contains(se),
              // ISO 8601 allows 24:00:00 as end-of-day (next-day midnight).
              (0...23).contains(h) || (h == 24 && mi == 0 && se == 0)
        else { return nil }
        return daysFromCivil(y, mo, d) * 86_400 + h * 3_600 + mi * 60 + se
    }

    // Days since Unix epoch for a proleptic-Gregorian date (Hinnant's algorithm).
    private static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
