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

extension String {
    /// Display form of a raw tide-station name (shared by the phase card and
    /// the on-map station marker). Two normalisations:
    /// 1. Keep only the first comma-separated component — some stations bundle a
    ///    location hierarchy ("Hanbury Point, Mosquito Pass, San Juan I."); the
    ///    first part is the specific spot and all we want to show.
    /// 2. Case: sources arrive inconsistently, so Title-Case the ALL-CAPS ones;
    ///    names that already contain a lowercase letter are assumed correct and
    ///    left untouched (so `.capitalized` doesn't mangle "McNeill"/"Fisher's").
    ///    Short (≤2-letter) tokens keep their caps, so directionals/abbreviations
    ///    survive — "NW ROCK" → "NW Rock", not "Nw Rock".
    var stationDisplayName: String {
        let first = split(separator: ",", maxSplits: 1).first.map(String.init) ?? self
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(where: \.isLowercase) else { return trimmed }
        return trimmed
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { word in
                guard word.filter(\.isLetter).count > 2 else { return String(word) }
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
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
//
// Two lookup APIs deliberately coexist:
// - `height(at:)` CLAMPS outside the events: the tide chart wants a curve
//   that holds the last known height at the data edge rather than a hole.
// - `heightIfBracketed(at:)` returns nil there instead: a rising/falling
//   probe (the flood/ebb estimator's central difference) must never see the
//   clamp — a constant reads as "falling" against the last rise, fabricating
//   an "Ebb" verdict at the bundled-data boundary. nil lets that caller
//   decline rather than report a phase it can't actually know.
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

    /// `height(at:)` without the edge clamp: nil when `t` is not bracketed by
    /// the events (strictly before the first or after the last extremum), so
    /// callers can tell "no data" from a real height — see the type comment
    /// for why both exist. Inside coverage the two agree exactly.
    static func heightIfBracketed(at t: Date, events: [TideEvent]) -> Double? {
        guard let first = events.first, let last = events.last,
              t >= first.time, t <= last.time else { return nil }
        return height(at: t, events: events)
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
              (1...9999).contains(y), (1...12).contains(mo),
              (1...daysInMonth(y, mo)).contains(d),
              (0...59).contains(mi), (0...60).contains(se),
              // ISO 8601 allows 24:00:00 as end-of-day (next-day midnight).
              (0...23).contains(h) || (h == 24 && mi == 0 && se == 0)
        else { return nil }
        return daysFromCivil(y, mo, d) * 86_400 + h * 3_600 + mi * 60 + se
    }

    // Days in month `m` of year `y`, standard Gregorian leap rule. The day
    // guard must be per-month, not a blanket 1...31: daysFromCivil happily
    // normalises overflow, so "2026-02-30" would otherwise parse and come
    // back as March 2 — a wrong instant, exactly what this parser promises
    // never to produce. Only called with `m` already validated to 1...12.
    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
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
