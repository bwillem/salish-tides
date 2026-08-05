import Foundation

/// A CHS tidal-current station — a point where the raster current models can't
/// help because the channel is narrower than a grid cell (Dodd Narrows, Seymour
/// Narrows, Sechelt/Skookumchuck, ...), so the model masks the throat as land
/// and understates the flow by 5–10×.
///
/// Predictions come from CHS: the app's 8 harmonic constituents fitted offline
/// to each station's along-axis current (`dev/model/current_stations_pack.py`),
/// in `TidalHarmonics`' own Greenwich-phase convention so they synthesize on
/// device with that engine — plus the exact CHS slack/max events for precise
/// timing where the harmonic curve alone is soft (the violent rapids).
///
/// The current here is rectilinear: a signed scalar along the flood/ebb axis,
/// positive on flood (toward `floodDir`), negative on ebb (toward `ebbDir`).
struct CurrentStation: Sendable, Identifiable {
    let code: String            // CHS station code, e.g. "07487"
    let name: String            // "Dodd Narrows"
    let lat, lon: Double
    let floodDir, ebbDir: Double   // compass bearing the current flows TOWARD
    let z0: Double                 // mean along-axis current (knots)
    /// Amplitude (knots) and Greenwich phase (degrees) per constituent, in
    /// `TidalHarmonics.constituents` order.
    let amp: [Double]
    let phase: [Double]
    /// Slack / max-flood / max-ebb events, ascending by time.
    let events: [CurrentEvent]

    var id: String { code }

    /// Signed along-axis current (knots) at `date`: `+` flood, `−` ebb.
    /// Pass hoisted `terms` when synthesizing many stations for one instant.
    func signedSpeedKn(terms: [TidalHarmonics.SynthesisTerm]) -> Double {
        var v = z0
        for k in 0..<amp.count {
            let t = terms[k]
            v += t.f * amp[k] * cos((t.arg - phase[k]) * .pi / 180)
        }
        return v
    }

    func signedSpeedKn(at date: Date) -> Double {
        signedSpeedKn(terms: TidalHarmonics.synthesisTerms(at: date))
    }

    /// Current as (speed knots, compass bearing flow-toward) at `date`.
    func current(at date: Date) -> (speedKn: Double, bearingDeg: Double) {
        let s = signedSpeedKn(at: date)
        return (abs(s), s >= 0 ? floodDir : ebbDir)
    }

    /// The event at or after `date`, then the one before it — what a card needs
    /// to say "next slack in 40 min, then max ebb 6.5 kn". nil ends when the
    /// bundled event window runs out.
    func surroundingEvents(_ date: Date) -> (previous: CurrentEvent?, next: CurrentEvent?) {
        // events is ascending; small N per station, a linear scan is fine.
        var prev: CurrentEvent?
        for e in events {
            if e.date >= date { return (prev, e) }
            prev = e
        }
        return (prev, nil)
    }
}

/// A current station's predicted state at one instant — enough to place and
/// label a glass marker on the map. `speedKn` is unsigned; `isFlood` carries
/// the direction so the marker glyph can point flood vs ebb.
struct CurrentStationReading: Sendable, Equatable, Identifiable {
    let code: String
    let name: String
    let lat, lon: Double
    let speedKn: Double
    let bearingDeg: Double   // compass bearing the current flows toward
    let isFlood: Bool
    var id: String { code }
}

/// A predicted slack or peak (extrema) at a current station.
struct CurrentEvent: Sendable {
    enum Kind: UInt8 { case slack = 0, maxFlood = 1, maxEbb = 2 }
    let date: Date
    let kind: Kind
    let speedKn: Double
}

/// Decodes the bundled `current_stations.b1` (SCST1; producer
/// `dev/model/sctf_stations.py`) into `CurrentStation`s. Any malformation
/// yields an empty set — the passes simply fall back to the raster, never a
/// trap or a mis-decode.
enum CurrentStationStore {

    /// Bundled stations, decoded once. Empty if the asset is missing/corrupt.
    static let all: [CurrentStation] = {
        guard let url = Bundle.main.url(forResource: "current_stations", withExtension: "b1"),
              let data = try? Data(contentsOf: url),
              let stations = decode(data)
        else { return [] }
        return stations
    }()

    /// SCST1 layout — see `dev/model/sctf_stations.py`. Returns nil on any
    /// structural problem or a constituent set that doesn't match the engine.
    static func decode(_ data: Data) -> [CurrentStation]? {
        var c = Cursor(data)
        guard c.match("SCST1") else { return nil }
        guard let nConst = c.u8() else { return nil }
        var names: [String] = []
        for _ in 0..<nConst {
            guard let s = c.string() else { return nil }
            names.append(s)
        }
        // The bundled constants are meaningless unless they line up with the
        // engine's constituent order — refuse a mismatched asset.
        guard names == TidalHarmonics.constituents.map(\.name) else { return nil }

        guard let count = c.u16() else { return nil }
        var out: [CurrentStation] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let code = c.string(), let name = c.string(),
                  let lat = c.f64(), let lon = c.f64(),
                  let flood = c.f32(), let ebb = c.f32(), let z0 = c.f32()
            else { return nil }
            var amp = [Double](), phase = [Double]()
            amp.reserveCapacity(Int(nConst)); phase.reserveCapacity(Int(nConst))
            for _ in 0..<nConst {
                guard let a = c.f32(), let p = c.f32() else { return nil }
                amp.append(Double(a)); phase.append(Double(p))
            }
            guard let nEv = c.u32() else { return nil }
            var events = [CurrentEvent]()
            events.reserveCapacity(Int(nEv))
            for _ in 0..<nEv {
                guard let t = c.u32(), let kindRaw = c.u8(), let spd = c.f32(),
                      let kind = CurrentEvent.Kind(rawValue: kindRaw)
                else { return nil }
                events.append(CurrentEvent(date: Date(timeIntervalSince1970: TimeInterval(t)),
                                           kind: kind, speedKn: Double(spd)))
            }
            out.append(CurrentStation(code: code, name: name, lat: lat, lon: lon,
                                      floodDir: Double(flood), ebbDir: Double(ebb),
                                      z0: Double(z0), amp: amp, phase: phase, events: events))
        }
        return out
    }

    /// Little-endian byte reader; every accessor bounds-checks and returns nil
    /// past the end so a truncated asset fails the decode rather than trapping.
    private struct Cursor {
        let d: Data
        var o: Int
        init(_ d: Data) { self.d = d; self.o = d.startIndex }

        mutating func match(_ s: String) -> Bool {
            let b = Array(s.utf8)
            guard o + b.count <= d.endIndex else { return false }
            for (i, byte) in b.enumerated() where d[o + i] != byte { return false }
            o += b.count
            return true
        }
        mutating func u8() -> UInt8? {
            guard o + 1 <= d.endIndex else { return nil }
            defer { o += 1 }
            return d[o]
        }
        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard o + n <= d.endIndex else { return nil }
            defer { o += n }
            return Array(d[o..<o + n])
        }
        mutating func u16() -> UInt16? { bytes(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 } }
        mutating func u32() -> UInt32? {
            bytes(4).map { UInt32($0[0]) | UInt32($0[1]) << 8 | UInt32($0[2]) << 16 | UInt32($0[3]) << 24 }
        }
        mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
        mutating func f64() -> Double? {
            guard let b = bytes(8) else { return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(b[i]) << (8 * i) }
            return Double(bitPattern: bits)
        }
        mutating func string() -> String? {
            guard let len = u8(), let b = bytes(Int(len)) else { return nil }
            return String(decoding: b, as: UTF8.self)
        }
    }
}
