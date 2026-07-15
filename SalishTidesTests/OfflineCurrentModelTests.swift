import Foundation
import Testing
@testable import SalishTides

/// Builds synthetic `.b1` assets byte-by-byte (the packer's format) so the
/// decoder's guards are pinned: a corrupt header or renamed constituent must
/// fail into the atlas fallback, never trap or silently mis-render.
struct OfflineCurrentModelTests {

    private static let engineNames = TidalHarmonics.constituents.map(\.name)
    private static let stride = TidalCurrentField.coeffStride   // 2 + 4×8 = 34

    private func makeAsset(rows: UInt16 = 2, cols: UInt16 = 2,
                           lat0: Double = 48, lon0: Double = -123,
                           dLat: Double = 0.01, dLon: Double = 0.01,
                           names: [String]? = nil,
                           presence: [Bool],
                           records: [[Float]]) -> Data {
        let names = names ?? Self.engineNames
        var d = Data("SCTF1".utf8)
        for v in [rows, cols] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        for v in [lat0, lon0, dLat, dLon] {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(UInt8(names.count))
        for n in names {
            d.append(UInt8(n.utf8.count))
            d.append(contentsOf: Array(n.utf8))
        }
        var bits = [UInt8](repeating: 0, count: (presence.count + 7) / 8)
        for (i, p) in presence.enumerated() where p { bits[i >> 3] |= 1 << (i & 7) }
        d.append(contentsOf: bits)
        for record in records {
            for v in record {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    /// A record with uMean/vMean then flat constituent values.
    private func record(uMean: Float = 0, vMean: Float = 0,
                        m2: (uAmp: Float, uPhase: Float, vAmp: Float, vPhase: Float) = (0, 0, 0, 0)) -> [Float] {
        var r = [Float](repeating: 0, count: Self.stride)
        r[0] = uMean; r[1] = vMean
        r[2] = m2.uAmp; r[3] = m2.uPhase; r[4] = m2.vAmp; r[5] = m2.vPhase
        return r
    }

    @Test func decodeRoundTrip() throws {
        let asset = makeAsset(presence: [true, false, false, true],
                              records: [record(uMean: 0.1, m2: (0.5, 10, 0.3, 90)),
                                        record(vMean: -0.2)])
        let field = try OfflineCurrentModel.decode(asset)
        #expect(field.rows == 2 && field.cols == 2)
        #expect(field.nodeCount == 2)
        #expect(field.droppedNodes == 0)
        #expect(field.nodeIndex == [0, -1, -1, 1])
        #expect(abs(field.coeffs[0] - 0.1) < 1e-6)                     // node 0 uMean
        #expect(abs(field.coeffs[2] - 0.5) < 1e-6)                     // node 0 M2 uAmp
        #expect(abs(field.coeffs[Self.stride + 1] + 0.2) < 1e-6)       // node 1 vMean
        #expect(abs(field.coverage.lat_max - 48.01) < 1e-9)
        #expect(abs(field.coverage.lon_min + 123) < 1e-9)
    }

    @Test func rejectsBadMagic() {
        var asset = makeAsset(presence: [true, false, false, false], records: [record()])
        asset[0] = UInt8(ascii: "X")
        #expect(throws: OfflineCurrentModel.DecodeError.self) {
            _ = try OfflineCurrentModel.decode(asset)
        }
    }

    @Test func rejectsTruncated() {
        let asset = makeAsset(presence: [true, false, false, false], records: [record()])
        #expect(throws: OfflineCurrentModel.DecodeError.self) {
            _ = try OfflineCurrentModel.decode(asset.dropLast(8))
        }
    }

    @Test func rejectsCorruptHeader() {
        // dLat == 0 (or NaN) previously survived decode and trapped later in
        // Int(Double) window math — must fail decode instead.
        for bad in [(dLat: 0.0, lat0: 48.0), (dLat: 0.01, lat0: Double.nan)] {
            let asset = makeAsset(lat0: bad.lat0, dLat: bad.dLat,
                                  presence: [true, false, false, false],
                                  records: [record()])
            #expect(throws: OfflineCurrentModel.DecodeError.self) {
                _ = try OfflineCurrentModel.decode(asset)
            }
        }
    }

    @Test func rejectsConstituentMismatch() {
        var names = Self.engineNames
        names[0] = "MX"   // renamed constituent must fail loudly, not render weak
        let asset = makeAsset(names: names,
                              presence: [true, false, false, false],
                              records: [record()])
        #expect(throws: OfflineCurrentModel.DecodeError.self) {
            _ = try OfflineCurrentModel.decode(asset)
        }
    }

    @Test func dropsNonFiniteNode() throws {
        var bad = record()
        bad[2] = .nan
        let asset = makeAsset(presence: [true, false, false, true],
                              records: [bad, record(uMean: 0.3)])
        let field = try OfflineCurrentModel.decode(asset)
        #expect(field.droppedNodes == 1)
        #expect(field.nodeIndex == [-1, -1, -1, 0])   // NaN node gone, other kept
        #expect(abs(field.coeffs[0] - 0.3) < 1e-6)
    }

    @Test func m2SynthesisPulsesOverACycle() throws {
        let asset = makeAsset(presence: [true, false, false, false],
                              records: [record(m2: (1.0, 0, 0, 0))])
        let field = try OfflineCurrentModel.decode(asset)
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        var speeds: [Double] = []
        for hr in 0...12 {
            let terms = TidalHarmonics.synthesisTerms(at: t0.addingTimeInterval(Double(hr) * 3600))
            let (u, v) = field.velocity(ofNode: 0, terms: terms)
            #expect(v == 0)                    // no V amplitude anywhere
            #expect(abs(u) < 1.2)              // bounded by amp × nodal factor
            speeds.append(abs(u))
        }
        // M2 period ≈ 12.42 h: over 13 hourly samples the magnitude must swing.
        #expect((speeds.max()! - speeds.min()!) > 0.5)
    }

    @Test func dryShorelineBandsTheWater() throws {
        // 3×3 mesh, single water cell in the centre → all 8 neighbours masked.
        var presence = [Bool](repeating: false, count: 9)
        presence[4] = true
        let asset = makeAsset(rows: 3, cols: 3, presence: presence, records: [record()])
        let field = try OfflineCurrentModel.decode(asset)
        let mask = OfflineCurrentModel.dryShoreline(of: field)
        #expect(mask.count == 8)
        #expect(mask.allSatisfy { $0.speed_ms == 0 })
        // No mask point on the water cell itself (48.01, -122.99).
        #expect(!mask.contains { abs($0.lat - 48.01) < 1e-9 && abs($0.lon + 122.99) < 1e-9 })
    }
}
