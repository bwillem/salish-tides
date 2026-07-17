import Foundation

/// The bundled offline current source: decodes `current_model.b1` — harmonic
/// constituents for every water node of the SalishSeaCast domain, packed onto
/// a regular lat/lon mesh — and synthesizes current vectors for any hour with
/// no network at all. The fallback tier below live SalishSeaCast (which it
/// reproduces at ~0.98 out-of-sample correlation) in MapViewModel's chain.
///
/// Binary layout (little-endian; producer is dev/model/b1_pack_grid.py and
/// the byte-level spec is dev/model/b1_verify_pack.py):
///   "SCTF1" · rows,cols UInt16 · lat0,lon0,dLat,dLon Float64 ·
///   nConst UInt8 + length-prefixed ascii names · row-major presence bitmap
///   (bit i = cell i is water) · per present cell: uMean,vMean Float32 then
///   per constituent uAmp,uPhase°,vAmp,vPhase° Float32. Components are
///   geographic east/north (the packer rotates NEMO's grid-aligned u/v).
///
/// An actor so the ~20k-node decode and the per-hour synthesis both run off
/// the main actor (MapViewModel awaits across the hop, like LiveDataService).
actor OfflineCurrentModel {

    static let shared = OfflineCurrentModel()

    private var field: TidalCurrentField?
    private var loadAttempted = false
    // One-entry synthesis cache: scrubbing revisits hours and viewport-debounce
    // reloads re-request the same (hour, window) — resynthesis is pure waste.
    private var lastSynthesis: (date: Date, window: Window, vectors: [CurrentVector])?
    private var landMaskCache: [CurrentVector]?

    private struct Window: Equatable { let r0, r1, c0, c1: Int }

    /// Model-synthesized vectors for `date`: one per water mesh node inside
    /// `viewport` plus the shared cull margin (so pans don't immediately hit
    /// empty edges), at the mesh's native resolution. No viewport yet → the
    /// whole domain, mirroring the live source's whole-domain field. Returns
    /// nil when the viewport doesn't overlap the model's water (or the asset
    /// failed to load) — the map shows no current data there.
    func currents(for date: Date, viewport: ChartBounds?) -> [CurrentVector]? {
        guard let field = loadedField() else { return nil }

        // Mesh index window covering the expanded viewport. decode() has
        // validated the header (dLat/dLon finite and > 0), so the divisions
        // and Int conversions here can't trap.
        var r0 = 0, r1 = field.rows - 1, c0 = 0, c1 = field.cols - 1
        if let vp = viewport {
            let e = vp.expanded(byFraction: ChartBounds.cullMarginFraction)
            r0 = max(r0, Int(((e.lat_min - field.lat0) / field.dLat).rounded(.up)))
            r1 = min(r1, Int(((e.lat_max - field.lat0) / field.dLat).rounded(.down)))
            c0 = max(c0, Int(((e.lon_min - field.lon0) / field.dLon).rounded(.up)))
            c1 = min(c1, Int(((e.lon_max - field.lon0) / field.dLon).rounded(.down)))
        }
        guard r0 <= r1, c0 <= c1 else { return nil }

        let window = Window(r0: r0, r1: r1, c0: c0, c1: c1)
        if let last = lastSynthesis, last.date == date, last.window == window {
            return last.vectors.isEmpty ? nil : last.vectors
        }

        // The astronomy is date-only: hoist it once, ~20× less work than
        // recomputing per node.
        let terms = TidalHarmonics.synthesisTerms(at: date)
        var out: [CurrentVector] = []
        for r in r0...r1 {
            let lat = field.lat0 + Double(r) * field.dLat
            let rowBase = r * field.cols
            for c in c0...c1 {
                let node = Int(field.nodeIndex[rowBase + c])
                guard node >= 0 else { continue }
                let lon = field.lon0 + Double(c) * field.dLon
                let (u, v) = field.velocity(ofNode: node, terms: terms)
                // Weak flow keeps its real (small, nonzero) speed — the
                // particle layer reserves exactly 0 for genuine slack.
                out.append(CurrentVector(lat: lat, lon: lon,
                                         speed_ms: (u*u + v*v).squareRoot(),
                                         direction_deg: GeoMath.flowBearing(east: u, north: v)))
            }
        }
        lastSynthesis = (date, window, out)
        return out.isEmpty ? nil : out
    }

    /// Geographic bounding box of the model mesh, or nil when the asset
    /// didn't load.
    func coverage() -> ChartBounds? {
        loadedField()?.coverage
    }

    /// Velocity series at the water node nearest to (lat, lon) — one east/
    /// north pair per date — plus that node's mesh cell index so callers can
    /// key caches by location bucket. nil when no water lies within
    /// `maxDistanceKm` (or the asset failed to load). Cheap: a ring search
    /// plus |dates| single-node syntheses, microseconds against the per-load
    /// full-field pass.
    func velocitySeries(lat: Double, lon: Double, dates: [Date],
                        maxDistanceKm: Double) -> (cell: Int, series: [(u: Double, v: Double)])? {
        guard let field = loadedField(),
              let cell = field.nearestWaterCell(lat: lat, lon: lon,
                                                maxDistanceKm: maxDistanceKm)
        else { return nil }
        let node = Int(field.nodeIndex[cell])
        let series = dates.map { date in
            field.velocity(ofNode: node, terms: TidalHarmonics.synthesisTerms(at: date))
        }
        return (cell, series)
    }

    /// Dry mesh cells 8-adjacent to water, as zero-speed vectors — the same
    /// coastline barrier band the live tier derives from NEMO dry cells
    /// (LiveDataService.dryShoreline), so the particle layer clips at the
    /// shoreline when the model renders. The mesh is time-invariant, so this
    /// is computed once and cached for the app's lifetime.
    func landMask() -> [CurrentVector]? {
        guard let field = loadedField() else { return nil }
        if let cached = landMaskCache { return cached }
        let mask = Self.dryShoreline(of: field)
        landMaskCache = mask
        return mask
    }

    /// Pure so it's unit-testable without the actor or the bundled asset.
    static func dryShoreline(of field: TidalCurrentField) -> [CurrentVector] {
        var out: [CurrentVector] = []
        var seen = [Bool](repeating: false, count: field.rows * field.cols)
        for r in 0..<field.rows {
            for c in 0..<field.cols where field.nodeIndex[r * field.cols + c] >= 0 {
                for dr in -1...1 {
                    for dc in -1...1 where (dr, dc) != (0, 0) {
                        let nr = r + dr, nc = c + dc
                        guard (0..<field.rows).contains(nr),
                              (0..<field.cols).contains(nc) else { continue }
                        let i = nr * field.cols + nc
                        guard field.nodeIndex[i] < 0, !seen[i] else { continue }
                        seen[i] = true
                        out.append(CurrentVector(
                            lat: field.lat0 + Double(nr) * field.dLat,
                            lon: field.lon0 + Double(nc) * field.dLon,
                            speed_ms: 0, direction_deg: 0))
                    }
                }
            }
        }
        return out
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
                let decoded = try Self.decode(try Data(contentsOf: url))
                if decoded.droppedNodes > 0 {
                    // The packer asserts finiteness, so any drop here means a
                    // packing bug slipped through — render the rest, but say so.
                    Log.map.error("offline current model: dropped \(decoded.droppedNodes) non-finite nodes")
                }
                field = decoded
            } catch {
                // Non-fatal: the map simply shows no offline currents.
                Log.map.error("offline current model failed to load: \(error, privacy: .public)")
            }
        }
        return field
    }

    enum DecodeError: Error { case badMagic, truncated, badHeader, constituentMismatch }

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
        // Header sanity: the window math divides by dLat/dLon and converts
        // the result with Int(Double), which TRAPS on non-finite input — a
        // corrupt header must fail decode here, not trap there.
        guard rows > 0, cols > 0, rows * cols <= 4_000_000,
              lat0.isFinite, lon0.isFinite,
              dLat.isFinite, dLat > 0, dLon.isFinite, dLon > 0
        else { throw DecodeError.badHeader }

        let nConst = Int(try cursor.uint8())
        var names: [String] = []
        names.reserveCapacity(nConst)
        for _ in 0..<nConst {
            let len = Int(try cursor.uint8())
            names.append(String(decoding: try cursor.bytes(len), as: UTF8.self))
        }
        // The synthesizer is keyed to TidalHarmonics' fixed constituent set;
        // a mismatch (renamed constituent, added overtide) must fail loudly,
        // not silently drop tidal energy.
        guard names == TidalHarmonics.constituents.map(\.name) else {
            throw DecodeError.constituentMismatch
        }

        let cells = rows * cols
        let bitmap = try cursor.bytes((cells + 7) / 8)
        var present = 0
        for i in 0..<cells where bitmap[i >> 3] >> (i & 7) & 1 == 1 { present += 1 }

        // One bulk read for the whole body — a per-scalar cursor pays ~700k
        // withUnsafeBytes round-trips on this asset.
        let stride = TidalCurrentField.coeffStride
        let floats = try cursor.float32Array(present * stride)

        var nodeIndex = [Int32](repeating: -1, count: cells)
        var coeffs = [Double]()
        coeffs.reserveCapacity(present * stride)
        var kept: Int32 = 0
        var dropped = 0
        var ordinal = 0
        for i in 0..<cells where bitmap[i >> 3] >> (i & 7) & 1 == 1 {
            let base = ordinal * stride
            ordinal += 1
            // A NaN coefficient would flow into speed/direction and poison
            // the particle raster — drop the node, keep the field.
            guard floats[base ..< base + stride].allSatisfy(\.isFinite) else {
                dropped += 1
                continue
            }
            nodeIndex[i] = kept
            kept += 1
            for k in 0..<stride { coeffs.append(Double(floats[base + k])) }
        }

        return TidalCurrentField(lat0: lat0, lon0: lon0, dLat: dLat, dLon: dLon,
                                 rows: rows, cols: cols,
                                 nodeIndex: nodeIndex, nodeCount: Int(kept),
                                 coeffs: coeffs, droppedNodes: dropped)
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

        /// Bulk Float32 read — one buffer access for the whole array.
        mutating func float32Array(_ count: Int) throws -> [Float] {
            guard offset + count * 4 <= data.count else { throw DecodeError.truncated }
            let start = offset
            offset += count * 4
            return data.withUnsafeBytes { raw in
                (0..<count).map {
                    Float(bitPattern: UInt32(littleEndian:
                        raw.loadUnaligned(fromByteOffset: start + $0 * 4, as: UInt32.self)))
                }
            }
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
        mutating func float64() throws -> Double {
            Double(bitPattern: UInt64(littleEndian: try load(UInt64.self)))
        }
    }
}
