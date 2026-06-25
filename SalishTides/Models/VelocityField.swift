import Foundation

/// A regular grid of current velocity sampled from the discrete `CurrentVector`
/// set, ready to upload as a GPU texture for particle advection. Velocities are
/// in metres per second, split into east (`u`) and north (`v`) components.
///
/// Cells are laid out row-major with **row 0 at the north edge** (`lat_max`) and
/// **col 0 at the west edge** (`lon_min`), so the array maps directly onto a
/// Metal texture whose origin is top-left and whose `v` texture coordinate grows
/// downward. Cells with no underlying vector are left at zero (still water / land
/// / off-coverage) — the data has no slack vectors, so zero reliably means
/// "no current here".
struct VelocityField: Sendable {
    /// Monotonic identity (the load generation that produced it). Lets the
    /// renderer skip re-uploading the GPU texture when the field is unchanged —
    /// important during a scrub, where the view re-renders ~11×/s but the field
    /// is held constant.
    let id: UInt64
    let bounds: ChartBounds
    let cols: Int
    let rows: Int
    /// Interleaved (east, north) m/s per cell. Count == cols * rows * 2.
    let uv: [Float]

    /// Builds a field over `bounds`, binning the significant vectors into a grid
    /// whose longer screen axis has `maxCellsAcross` cells (cells are kept
    /// roughly square on screen by scaling longitude with cos(latitude)).
    /// Returns nil for a degenerate (zero-span) bbox.
    init?(id: UInt64, vectors: [CurrentVector], bounds: ChartBounds, maxCellsAcross: Int) {
        let latSpan = bounds.lat_max - bounds.lat_min
        let lonSpan = bounds.lon_max - bounds.lon_min
        guard latSpan > 0, lonSpan > 0 else { return nil }

        let centerLat = (bounds.lat_min + bounds.lat_max) / 2
        let cosLat = max(0.1, cos(centerLat * .pi / 180))
        let screenLon = lonSpan * cosLat

        var c: Int, r: Int
        if screenLon >= latSpan {
            c = maxCellsAcross
            r = max(2, Int((Double(maxCellsAcross) * latSpan / screenLon).rounded()))
        } else {
            r = maxCellsAcross
            c = max(2, Int((Double(maxCellsAcross) * screenLon / latSpan).rounded()))
        }

        // Don't make the grid finer than the source data (~0.006° spacing): a finer
        // grid leaves empty cells between data points (clustering) and needs a fill
        // that bleeds onto land. At the data resolution each cell holds ~one point,
        // so bilinear sampling is continuous and the coast bleed is ~half a cell.
        let cellSizeDeg = 0.006
        c = min(c, max(2, Int((lonSpan / cellSizeDeg).rounded(.up))))
        r = min(r, max(2, Int((latSpan / cellSizeDeg).rounded(.up))))

        let cells = c * r
        var sumU = [Float](repeating: 0, count: cells)
        var sumV = [Float](repeating: 0, count: cells)
        var count = [Float](repeating: 0, count: cells)

        for vec in vectors where vec.isSignificant {
            let fx = (vec.lon - bounds.lon_min) / lonSpan
            let fy = (bounds.lat_max - vec.lat) / latSpan   // north → row 0
            guard fx >= 0, fx < 1, fy >= 0, fy < 1 else { continue }
            let col = min(c - 1, Int(fx * Double(c)))
            let row = min(r - 1, Int(fy * Double(r)))
            let theta = vec.direction_deg * .pi / 180
            let idx = row * c + col
            sumU[idx] += Float(vec.speed_ms * sin(theta))   // east
            sumV[idx] += Float(vec.speed_ms * cos(theta))   // north
            count[idx] += 1
        }

        var out = [Float](repeating: 0, count: cells * 2)
        for i in 0..<cells where count[i] > 0 {
            out[i * 2]     = sumU[i] / count[i]
            out[i * 2 + 1] = sumV[i] / count[i]
        }

        self.id = id
        self.bounds = bounds
        self.cols = c
        self.rows = r
        self.uv = out
    }
}
