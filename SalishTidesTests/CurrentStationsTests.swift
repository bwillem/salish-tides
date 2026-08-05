import Foundation
import Testing
@testable import SalishTides

/// Pins the SCST1 decoder and the on-device current-station predictor. The
/// predictions are checked against golden values produced by the reference
/// packer (`dev/model/tidepredict.py`) for Dodd Narrows, so the Swift engine
/// and the Python fit that generated the bundled constants can't silently drift.
struct CurrentStationsTests {

    private static let names = TidalHarmonics.constituents.map(\.name)

    // Dodd Narrows (CHS 07487), fitted constants from current_stations_pack.py.
    private static let doddAmp: [Double]   = [5.52031, 1.3118, 1.03111, 0.45562, 1.50464, 0.68883, 0.4313, 0.0901]
    private static let doddPhase: [Double] = [254.215, 282.926, 229.938, 283.348, 145.949, 124.164, 145.468, 143.708]
    private static let doddZ0 = 0.1391

    /// (epochSec, signed knots) from tidepredict for the same constants.
    private static let golden: [(t: Int, signed: Double)] = [
        (1754560800, -0.8518),
        (1754582400, -0.1633),
        (1754640000,  3.0908),
    ]

    private func asset(names: [String] = CurrentStationsTests.names,
                       amp: [Double] = CurrentStationsTests.doddAmp,
                       phase: [Double] = CurrentStationsTests.doddPhase,
                       events: [(t: UInt32, kind: UInt8, spd: Float)] = []) -> Data {
        var d = Data("SCST1".utf8)
        d.append(UInt8(names.count))
        for n in names { d.append(UInt8(n.utf8.count)); d.append(contentsOf: Array(n.utf8)) }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f32(_ v: Float)  { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        u16(1)                                  // one station
        d.append(UInt8("07487".utf8.count)); d.append(contentsOf: Array("07487".utf8))
        d.append(UInt8("Dodd Narrows".utf8.count)); d.append(contentsOf: Array("Dodd Narrows".utf8))
        f64(49.1344); f64(-123.8171)
        f32(355); f32(155); f32(Float(Self.doddZ0))
        for i in 0..<names.count { f32(Float(amp[i])); f32(Float(phase[i])) }
        u32(UInt32(events.count))
        for e in events { u32(e.t); d.append(e.kind); f32(e.spd) }
        return d
    }

    @Test func decodesStationAndFields() throws {
        let s = try #require(CurrentStationStore.decode(asset()))
        #expect(s.count == 1)
        let dodd = s[0]
        #expect(dodd.code == "07487")
        #expect(dodd.name == "Dodd Narrows")
        #expect(abs(dodd.floodDir - 355) < 1e-4)
        #expect(dodd.amp.count == Self.names.count)
    }

    @Test func predictionMatchesReferencePacker() throws {
        let dodd = try #require(CurrentStationStore.decode(asset()))[0]
        for g in Self.golden {
            let date = Date(timeIntervalSince1970: TimeInterval(g.t))
            let got = dodd.signedSpeedKn(at: date)
            // f32 storage + reference rounding: a couple hundredths of a knot.
            #expect(abs(got - g.signed) < 0.02,
                    "t=\(g.t): got \(got), expected \(g.signed)")
        }
    }

    @Test func currentPicksFloodOrEbbAxis() throws {
        let dodd = try #require(CurrentStationStore.decode(asset()))[0]
        // golden[2] is +3.09 (flood) → bearing floodDir; golden[0] is −0.85 (ebb).
        #expect(dodd.current(at: Date(timeIntervalSince1970: 1754640000)).bearingDeg == 355)
        #expect(dodd.current(at: Date(timeIntervalSince1970: 1754560800)).bearingDeg == 155)
    }

    @Test func surroundingEventsBracketTheInstant() throws {
        let evs: [(t: UInt32, kind: UInt8, spd: Float)] = [
            (1_000, 0, 0), (2_000, 1, 6.5), (3_000, 0, 0),
        ]
        let dodd = try #require(CurrentStationStore.decode(asset(events: evs)))[0]
        let (prev, next) = dodd.surroundingEvents(Date(timeIntervalSince1970: 2_500))
        #expect(prev?.kind == .maxFlood)
        #expect(next?.date == Date(timeIntervalSince1970: 3_000))
    }

    @Test func rejectsBadMagicAndConstituentMismatch() {
        var bad = Data("XXXX1".utf8); bad.append(contentsOf: [0])
        #expect(CurrentStationStore.decode(bad) == nil)
        // right magic, wrong constituent name set → refuse (constants unusable).
        var wrong = Self.names; wrong[0] = "ZZ"
        #expect(CurrentStationStore.decode(asset(names: wrong)) == nil)
    }

    @Test func truncatedAssetFailsCleanly() {
        let full = asset()
        #expect(CurrentStationStore.decode(full.prefix(full.count - 4)) == nil)
    }
}
