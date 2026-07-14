import Foundation

/// The bundled offline current source: decodes `current_model.b1` — harmonic
/// constituents for every water node of the SalishSeaCast domain, packed onto
/// a regular lat/lon mesh — and synthesizes current vectors for any hour with
/// no network at all. Sits between live SalishSeaCast (which it reproduces at
/// ~0.98 out-of-sample correlation) and the print atlas in MapViewModel's
/// fallback chain.
///
/// Binary layout (little-endian; producer is dev/model/b1_pack_grid.py and
/// the byte-level spec is dev/model/b1_verify_pack.py):
///   "SCTF1" · rows,cols UInt16 · lat0,lon0,dLat,dLon Float64 ·
///   nConst UInt8 + length-prefixed ascii names · row-major presence bitmap
///   (bit i = cell i is water) · per present cell: uMean,vMean Float32 then
///   per constituent uAmp,uPhase°,vAmp,vPhase° Float32.
///
/// An actor so the ~20k-node decode and the per-hour synthesis both run off
/// the main actor (MapViewModel awaits across the hop, like LiveDataService).
actor OfflineCurrentModel {

    static let shared = OfflineCurrentModel()

    private var field: TidalCurrentField?
    private var loadAttempted = false

    /// Model-synthesized vectors for `date`: one per water mesh node inside
    /// `viewport` plus the shared cull margin (so pans don't immediately hit
    /// empty edges), at the mesh's native resolution. No viewport yet → the
    /// whole domain, mirroring the live source's whole-domain field. Returns
    /// nil when the viewport doesn't overlap the model's water (or the asset
    /// failed to load) — callers fall through to the atlas.
    func currents(for date: Date, viewport: ChartBounds?) -> [CurrentVector]? {
        guard let field = loadedField() else { return nil }

        // Mesh index window covering the expanded viewport.
        var r0 = 0, r1 = field.rows - 1, c0 = 0, c1 = field.cols - 1
        if let vp = viewport {
            let e = vp.expanded(byFraction: ChartBounds.cullMarginFraction)
            r0 = max(r0, Int(((e.lat_min - field.lat0) / field.dLat).rounded(.up)))
            r1 = min(r1, Int(((e.lat_max - field.lat0) / field.dLat).rounded(.down)))
            c0 = max(c0, Int(((e.lon_min - field.lon0) / field.dLon).rounded(.up)))
            c1 = min(c1, Int(((e.lon_max - field.lon0) / field.dLon).rounded(.down)))
        }
        guard r0 <= r1, c0 <= c1 else { return nil }

        var out: [CurrentVector] = []
        for r in r0...r1 {
            let lat = field.lat0 + Double(r) * field.dLat
            for c in c0...c1 {
                guard let node = field.nodes[r * field.cols + c] else { continue }
                let lon = field.lon0 + Double(c) * field.dLon
                let (u, v) = TidalCurrentField.velocity(node, at: date)
                let speed = (u*u + v*v).squareRoot()
                // Compass bearing the flow is heading toward: 0°=N, 90°=E.
                // Weak flow keeps its real (small, nonzero) speed — the
                // particle layer reserves exactly 0 for genuine slack.
                var dir = atan2(u, v) * 180 / .pi
                if dir < 0 { dir += 360 }
                out.append(CurrentVector(lat: lat, lon: lon,
                                         speed_ms: speed, direction_deg: dir))
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Loading

    /// Lazily decode the bundled asset, once; a failure is remembered so the
    /// map doesn't re-attempt (and re-log) on every reload.
    private func loadedField() -> TidalCurrentField? {
        if field == nil, !loadAttempted {
            loadAttempted = true
            do {
                guard let url = Bundle.main.url(forResource: "current_model",
                                                withExtension: "b1") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                field = try Self.decode(try Data(contentsOf: url))
            } catch {
                // Non-fatal: the atlas tier still renders everywhere it charts.
                Log.map.error("offline current model failed to load: \(error, privacy: .public)")
            }
        }
        return field
    }

    enum DecodeError: Error { case badMagic, truncated }

    /// Parse the `.b1` bytes into a `TidalCurrentField`. Static and pure so
    /// tests can feed it raw data.
    static func decode(_ data: Data) throws -> TidalCurrentField {
        var cursor = Cursor(data)
        guard try cursor.bytes(5).elementsEqual("SCTF1".utf8) else {
            throw DecodeError.badMagic
        }
        let rows = Int(try cursor.uint16())
        let cols = Int(try cursor.uint16())
        let lat0 = try cursor.float64()
        let lon0 = try cursor.float64()
        let dLat = try cursor.float64()
        let dLon = try cursor.float64()

        let nConst = Int(try cursor.uint8())
        var names: [String] = []
        names.reserveCapacity(nConst)
        for _ in 0..<nConst {
            let len = Int(try cursor.uint8())
            names.append(String(decoding: try cursor.bytes(len), as: UTF8.self))
        }

        let cells = rows * cols
        let bitmap = try cursor.bytes((cells + 7) / 8)

        var nodes: [TidalCurrentField.Node?] = Array(repeating: nil, count: cells)
        for i in 0..<cells {
            guard bitmap[i >> 3] >> (i & 7) & 1 == 1 else { continue }
            let uMean = Double(try cursor.float32())
            let vMean = Double(try cursor.float32())
            var constituents: [String: TidalCurrentField.NodeConstituent] = [:]
            constituents.reserveCapacity(nConst)
            for name in names {
                constituents[name] = TidalCurrentField.NodeConstituent(
                    uAmp: Double(try cursor.float32()),
                    uPhase: Double(try cursor.float32()),
                    vAmp: Double(try cursor.float32()),
                    vPhase: Double(try cursor.float32()))
            }
            nodes[i] = TidalCurrentField.Node(constituents: constituents,
                                              uMean: uMean, vMean: vMean)
        }

        return TidalCurrentField(lat0: lat0, lon0: lon0, dLat: dLat, dLon: dLon,
                                 rows: rows, cols: cols, nodes: nodes)
    }

    /// Little-endian byte cursor over the packed asset.
    private struct Cursor {
        private let data: Data
        private var offset = 0
        init(_ data: Data) { self.data = data }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw DecodeError.truncated }
            defer { offset += n }
            let base = data.startIndex + offset
            return [UInt8](data[base ..< base + n])
        }

        private mutating func load<T>(_ type: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= data.count else {
                throw DecodeError.truncated
            }
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        mutating func uint8() throws -> UInt8 { try load(UInt8.self) }
        mutating func uint16() throws -> UInt16 {
            UInt16(littleEndian: try load(UInt16.self))
        }
        mutating func float32() throws -> Float {
            Float(bitPattern: UInt32(littleEndian: try load(UInt32.self)))
        }
        mutating func float64() throws -> Double {
            Double(bitPattern: UInt64(littleEndian: try load(UInt64.self)))
        }
    }
}
