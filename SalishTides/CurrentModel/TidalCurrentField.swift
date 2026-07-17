import Foundation

/// A bundled grid of tidal-current harmonic constituents (one set per water
/// node) plus the per-node synthesizer that turns them into an east/north
/// velocity at any instant. This is the "Model" current source — offline
/// currents at full mesh resolution; the grid is produced offline from
/// SalishSeaCast (dev/model pipeline) and packed onto a regular lat/lon mesh.
///
/// Storage is flat structure-of-arrays: one `Int32` per mesh cell mapping to a
/// water-node ordinal, and one contiguous coefficient array — ~4 MB resident
/// for the 2.86 MB asset with zero per-node allocations. (The obvious
/// per-node `[String: Constituent]` dictionaries cost ~18 MB and a string
/// hash per constituent per node per synthesis.)
///
/// Synthesis reuses the NOAA-validated `TidalHarmonics` engine, applied to the
/// east (U) and north (V) components.
struct TidalCurrentField: Sendable {

    // Regular lat/lon mesh; row-major cell index = row*cols + col,
    // lat = lat0 + row*dLat, lon = lon0 + col*dLon.
    let lat0, lon0, dLat, dLon: Double
    let rows, cols: Int

    /// Water-node ordinal per mesh cell; -1 = land / no data.
    let nodeIndex: [Int32]
    let nodeCount: Int

    /// `nodeCount × coeffStride` doubles per node: uMean, vMean, then per
    /// constituent in `TidalHarmonics.constituents` order:
    /// uAmp, uPhase°, vAmp, vPhase°.
    let coeffs: [Double]

    /// Nodes dropped at decode for non-finite coefficients — 0 for a healthy
    /// asset; anything else is a packing bug worth a log line.
    let droppedNodes: Int

    static var coeffStride: Int { 2 + 4 * TidalHarmonics.constituents.count }

    /// Geographic bounding box of the mesh.
    var coverage: ChartBounds {
        ChartBounds(lat_min: lat0, lat_max: lat0 + Double(rows - 1) * dLat,
                    lon_min: lon0, lon_max: lon0 + Double(cols - 1) * dLon)
    }

    /// Whether any water node lies within `km` of the point, expressed as a
    /// grid probe of ceil(km / cell-edge) cells — used to tell a genuine
    /// coastline from the seam another model's pack-time mask carved out.
    /// Distance-based, NOT cell-based: the caller reasons in the masking
    /// distance (km), and this field's own resolution must not change the
    /// reach (a 2-cell probe on a 500 m mesh is 1 km; on a 4 km mesh, 8 km).
    func hasWater(lat: Double, lon: Double, withinKm km: Double) -> Bool {
        let cellDeg = min(dLat, dLon * GeoMath.lonScale(atLat: lat))
        guard cellDeg > 0, km > 0 else { return false }
        // No cap on the radius: the probe loops clamp to the grid anyway, and
        // capping would silently shrink the reach on a grid smaller than it.
        let radius = Int(((km / 111.0) / cellDeg).rounded(.up))
        return hasWater(lat: lat, lon: lon, withinCells: radius)
    }

    /// The mesh's own land/water verdict at a point: whether the CONTAINING
    /// cell is a water node. Distinct from the radius probes below — those
    /// answer "is water nearby", this answers "is the point itself on water",
    /// which is what a readout must ask before quoting a neighbouring node's
    /// current for a crosshair that is actually parked on a beach.
    func isWater(lat: Double, lon: Double) -> Bool {
        hasWater(lat: lat, lon: lon, withinCells: 0)
    }

    /// Whether any water node lies within `withinCells` mesh cells of the
    /// point — a cheap O(radius²) grid probe.
    func hasWater(lat: Double, lon: Double, withinCells radius: Int) -> Bool {
        let r = Int(((lat - lat0) / dLat).rounded())
        let c = Int(((lon - lon0) / dLon).rounded())
        guard r >= -radius, r < rows + radius,
              c >= -radius, c < cols + radius else { return false }
        for rr in max(0, r - radius)...min(rows - 1, r + radius) {
            for cc in max(0, c - radius)...min(cols - 1, c + radius) {
                if nodeIndex[rr * cols + cc] >= 0 { return true }
            }
        }
        return false
    }

    /// Mesh cell index of the water node nearest to (lat, lon), or nil when
    /// none lies within `maxDistanceKm`. Scans expanding square index rings
    /// from the containing cell; the best candidate in the first non-empty
    /// ring wins (exact enough at ring granularity for point lookups like the
    /// phase indicator's).
    func nearestWaterCell(lat: Double, lon: Double, maxDistanceKm: Double) -> Int? {
        let r = Int(((lat - lat0) / dLat).rounded())
        let c = Int(((lon - lon0) / dLon).rounded())
        let cosLat = GeoMath.lonScale(atLat: lat)
        // Ring reach in cells, from the smaller of the two cell edges so an
        // anisotropic mesh can't stop the scan short of maxDistanceKm.
        let cellDeg = min(dLat, dLon * cosLat)
        guard cellDeg > 0, maxDistanceKm > 0 else { return nil }
        let maxDistanceDeg = maxDistanceKm / 111.0
        // Cap the walk at the grid's own span: a huge reach on a fine mesh
        // must not turn an off-grid query into an O(reach²) scan.
        let maxRing = min(Int((maxDistanceDeg / cellDeg).rounded(.up)),
                          max(rows, cols))
        for ring in 0...maxRing {
            var best: (cell: Int, d2: Double)?
            for dr in -ring...ring {
                let rr = r + dr
                guard (0..<rows).contains(rr) else { continue }
                let onCap = abs(dr) == ring
                var dc = -ring
                while dc <= ring {
                    defer { dc += onCap ? 1 : 2 * ring }   // caps: full row; sides: ±ring only
                    let cc = c + dc
                    guard (0..<cols).contains(cc) else { continue }
                    let i = rr * cols + cc
                    guard nodeIndex[i] >= 0 else { continue }
                    let d2 = GeoMath.distanceSquared(
                        fromLat: lat, fromLon: lon,
                        toLat: lat0 + Double(rr) * dLat,
                        toLon: lon0 + Double(cc) * dLon, cosLat: cosLat)
                    if best == nil || d2 < best!.d2 { best = (i, d2) }
                }
                if ring == 0 { break }   // single cell; dc loop degenerates
            }
            if let best, best.d2 <= maxDistanceDeg * maxDistanceDeg {
                return best.cell
            }
        }
        return nil
    }

    /// East/north velocity (m/s) of one water node at the instant captured by
    /// `terms`. Callers hoist `TidalHarmonics.synthesisTerms(at:)` ONCE per
    /// pass — the astronomy is date-only, and recomputing it per node is ~20×
    /// the per-node cost of these 16 cosines.
    func velocity(ofNode node: Int, terms: [TidalHarmonics.SynthesisTerm]) -> (u: Double, v: Double) {
        let base = node * Self.coeffStride
        var u = coeffs[base], v = coeffs[base + 1]   // steady residual flow
        var o = base + 2
        for t in terms {
            u += t.f * coeffs[o]     * cos((t.arg - coeffs[o + 1]) * .pi / 180)
            v += t.f * coeffs[o + 2] * cos((t.arg - coeffs[o + 3]) * .pi / 180)
            o += 4
        }
        return (u, v)
    }
}
