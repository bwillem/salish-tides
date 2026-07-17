import Foundation

/// SalishSeaCast (UBC EOAS) ERDDAP endpoints: URL grammar and JSON-table
/// decoding, kept pure (no networking — see `SalishSeaCastClient`) so both are
/// testable in isolation. The NEMO model publishes a rolling window (~5 days of
/// nowcast, ~1.5 days of forecast) refreshed daily; `LiveDataService` owns the
/// fetch/refresh policy.
enum SalishSeaCastAPI {

    static let base = "https://salishsea.eos.ubc.ca/erddap/griddap"

    // ── Model grid ───────────────────────────────────────────────────────
    // The NEMO grid is 898×398 curvilinear cells (~500 m). Requests subsample
    // by `gridStride` in both axes (~1 km spacing): full resolution is ~4× the
    // bytes for marginal visual gain at the app's zoom levels.
    // WARNING: reads as tunable, but stride 2 is baked in beyond the
    // `LiveDataStore.schemaVersion` cache key: `nativeLatLon`'s midpoint
    // averaging only interpolates correctly between *adjacent* strided cells,
    // and `stridedSpacingDeg`'s 0.005°-per-native-cell figure pairs with it —
    // a stride change must revisit both together.
    static let gridStride = 2
    static let nativeRows = 898   // gridY
    static let nativeCols = 398   // gridX
    static var stridedRows: Int { (nativeRows + gridStride - 1) / gridStride }
    static var stridedCols: Int { (nativeCols + gridStride - 1) / gridStride }
    /// Approximate latitude spacing of the strided grid — the resolution floor
    /// for any raster built from it (see `VelocityField.minCellSizeDeg`).
    /// Derived from the stride so a stride retune can't leave it stale
    /// (native cell ≈ 500 m ≈ 0.005° latitude).
    static var stridedSpacingDeg: Double { 0.005 * Double(gridStride) }

    /// Flattened strided-grid index for a native (gridY, gridX) pair.
    static func stridedIndex(gridY: Int, gridX: Int) -> Int {
        (gridY / gridStride) * stridedCols + (gridX / gridStride)
    }

    // ── Native-resolution windows ────────────────────────────────────────
    // The strided whole-domain slices drop ~3/4 of the model's wet velocity
    // cells in constricted water (the surviving samples near shore are often
    // the masked ones), so zoomed-in viewports fetch full-resolution
    // subwindows instead. A window is an inclusive native-index rectangle,
    // aligned to `windowQuantum` so panning reuses cached windows.

    /// Inclusive native-index rectangle on the model grid.
    struct NativeWindow: Sendable, Hashable {
        let y0: Int, y1: Int, x0: Int, x1: Int
        var cellCount: Int { (y1 - y0 + 1) * (x1 - x0 + 1) }
        var key: String { "\(y0):\(y1):\(x0):\(x1)" }
        func contains(_ other: NativeWindow) -> Bool {
            y0 <= other.y0 && y1 >= other.y1 && x0 <= other.x0 && x1 >= other.x1
        }
    }

    /// Window alignment (native cells). Coarse enough that a small pan maps
    /// to the same window, fine enough not to inflate requests much.
    static let windowQuantum = 16

    /// One native-resolution grid cell with velocity (water only).
    struct NativePoint: Sendable, Equatable {
        let y: UInt16       // native gridY
        let x: UInt16       // native gridX
        let east: Float     // m/s
        let north: Float    // m/s
    }

    /// The native-index window covering every strided cell whose coordinate
    /// falls in `latMin...latMax` / `lonMin...lonMax`, expanded by a stride
    /// margin, quantized, and clamped to the grid. nil when no strided cell
    /// is inside (viewport entirely off the model domain).
    static func nativeWindow(latMin: Double, latMax: Double,
                             lonMin: Double, lonMax: Double,
                             grid: LiveGrid) -> NativeWindow? {
        var sy0 = Int.max, sy1 = Int.min, sx0 = Int.max, sx1 = Int.min
        for i in 0..<grid.lat.count {
            let la = Double(grid.lat[i]), lo = Double(grid.lon[i])
            guard la >= latMin, la <= latMax, lo >= lonMin, lo <= lonMax else { continue }
            let sy = i / stridedCols, sx = i % stridedCols
            sy0 = min(sy0, sy); sy1 = max(sy1, sy)
            sx0 = min(sx0, sx); sx1 = max(sx1, sx)
        }
        guard sy0 <= sy1 else { return nil }
        let q = windowQuantum
        // Strided → native indices (+1 stride margin), then quantize outward.
        let y0 = max(0, ((sy0 - 1) * gridStride / q) * q)
        let x0 = max(0, ((sx0 - 1) * gridStride / q) * q)
        let y1 = min(nativeRows - 1, (((sy1 + 1) * gridStride) / q + 1) * q - 1)
        let x1 = min(nativeCols - 1, (((sx1 + 1) * gridStride) / q + 1) * q - 1)
        return NativeWindow(y0: y0, y1: y1, x0: x0, x1: x1)
    }

    /// lat/lon of a native cell, bilinearly interpolated from the strided
    /// geometry (the native curvilinear grid is smooth at ~500 m spacing, so
    /// midpoint interpolation is accurate to metres — no native-resolution
    /// geometry fetch needed). nil near the domain edge where a neighbour is
    /// missing.
    static func nativeLatLon(y: Int, x: Int, grid: LiveGrid) -> (lat: Double, lon: Double)? {
        func strided(_ sy: Int, _ sx: Int) -> (Double, Double)? {
            guard sy >= 0, sy < stridedRows, sx >= 0, sx < stridedCols else { return nil }
            let i = sy * stridedCols + sx
            let la = Double(grid.lat[i]), lo = Double(grid.lon[i])
            guard la.isFinite, lo.isFinite else { return nil }
            return (la, lo)
        }
        let sy = y / gridStride, sx = x / gridStride
        let oy = y % gridStride, ox = x % gridStride
        var sum = (lat: 0.0, lon: 0.0)
        var count = 0.0
        for dy in 0...(oy == 0 ? 0 : 1) {
            for dx in 0...(ox == 0 ? 0 : 1) {
                // Clamp the far neighbour at the grid edge (≤ half-cell error,
                // only on the outermost native row/col).
                let p = strided(min(sy + dy, stridedRows - 1), min(sx + dx, stridedCols - 1))
                guard let p else { return nil }
                sum.lat += p.0; sum.lon += p.1
                count += 1
            }
        }
        return (sum.lat / count, sum.lon / count)
    }

    /// One hourly native-resolution velocity subwindow.
    static func nativeCurrentsSliceURL(center: Date, window: NativeWindow) -> URL {
        let t = "[(\(iso(center)))]"
        let s = "[\(window.y0):1:\(window.y1)][\(window.x0):1:\(window.x1)]"
        return url(dataset: currentsDataset, query: "VelEast5\(t)\(s),VelNorth5\(t)\(s)")
    }

    /// Rows are [time, gridY, gridX, east, north]; land/masked cells have null
    /// velocities and are dropped. Same closest-match caveat as
    /// `parseCurrentsSlice` — callers must verify the returned center.
    static func parseNativeCurrentsSlice(_ data: Data) throws -> (center: Date, points: [NativePoint])? {
        let rows = try tableRows(data)
        guard let isoTime = rows.first?.first as? String,
              let epoch = TideBundleEvent.epochUTC(from: isoTime)
        else { return nil }

        var points: [NativePoint] = []
        points.reserveCapacity(rows.count / 2)
        for row in rows {
            guard row.count >= 5,
                  let y = (row[1] as? NSNumber)?.intValue,
                  let x = (row[2] as? NSNumber)?.intValue,
                  (0..<nativeRows).contains(y), (0..<nativeCols).contains(x),
                  let e = (row[3] as? NSNumber)?.floatValue,
                  let n = (row[4] as? NSNumber)?.floatValue
            else { continue }   // null velocity → land / masked
            points.append(NativePoint(y: UInt16(y), x: UInt16(x), east: e, north: n))
        }
        return (Date(timeIntervalSince1970: TimeInterval(epoch)), points)
    }

    // ── Datasets ─────────────────────────────────────────────────────────
    // Depth-averaged velocity over the upper ~5 m — the closest match to what
    // a vessel experiences underway.
    static let currentsDataset = "ubcSSfDepthAvgdCurrents1h"
    // Static lon/lat for every (gridY, gridX) cell of the model grid.
    static let bathymetryDataset = "ubcSSnBathymetryV21-08"

    /// A model "tide gauge": a fixed point where SalishSeaCast publishes a
    /// 10-minute sea-surface-height forecast series.
    struct Gauge: Sendable {
        let dataset: String
        let name: String
        let lat: Double
        let lon: Double
    }

    /// All published SSH forecast gauges (coordinates from the ERDDAP catalog).
    static let gauges: [Gauge] = [
        Gauge(dataset: "ubcSSfBoundaryBaySSH10m",      name: "Boundary Bay",       lat: 48.99837, lon: -122.9225),
        Gauge(dataset: "ubcSSfCampbellRiverSSH10m",    name: "Campbell River",     lat: 50.01995, lon: -125.2205),
        Gauge(dataset: "ubcSSfCherryPointSSH10m",      name: "Cherry Point",       lat: 48.86593, lon: -122.7617),
        Gauge(dataset: "ubcSSfFridayHarborSSH10m",     name: "Friday Harbor",      lat: 48.55370, lon: -123.0084),
        Gauge(dataset: "ubcSSfHalfmoonBaySSH10m",      name: "Halfmoon Bay",       lat: 49.50789, lon: -123.9098),
        Gauge(dataset: "ubcSSfNanaimoSSH10m",          name: "Nanaimo",            lat: 49.16660, lon: -123.9308),
        Gauge(dataset: "ubcSSfNeahBaySSH10m",          name: "Neah Bay",           lat: 48.39995, lon: -124.5979),
        Gauge(dataset: "ubcSSfNewWestminsterSSH10m",   name: "New Westminster",    lat: 49.20258, lon: -122.9066),
        Gauge(dataset: "ubcSSfPatriciaBaySSH10m",      name: "Patricia Bay",       lat: 48.65406, lon: -123.4549),
        Gauge(dataset: "ubcSSfPointAtkinsonSSH10m",    name: "Point Atkinson",     lat: 49.33216, lon: -123.2495),
        Gauge(dataset: "ubcSSfPortRenfrewSSH10m",      name: "Port Renfrew",       lat: 48.55712, lon: -124.4163),
        Gauge(dataset: "ubcSSfSandHeadsSSH10m",        name: "Sand Heads",         lat: 49.09974, lon: -123.2953),
        Gauge(dataset: "ubcSSfSandyCoveSSH10m",        name: "Sandy Cove",         lat: 49.33968, lon: -123.2287),
        Gauge(dataset: "ubcSSfSquamishSSH10m",         name: "Squamish",           lat: 49.69373, lon: -123.1540),
        Gauge(dataset: "ubcSSfVictoriaSSH10m",         name: "Victoria",           lat: 48.42570, lon: -123.3851),
        Gauge(dataset: "ubcSSfWoodwardsLandingSSH10m", name: "Woodwards Landing",  lat: 49.12522, lon: -123.0720),
    ]

    // ── URLs ─────────────────────────────────────────────────────────────
    // griddap query grammar: var[(timeValue)][yStart:stride:yStop][xStart:stride:xStop].
    // Parenthesised time values match the *closest* grid instant, so callers
    // must verify the returned timestamp (see parseCurrentsSlice).

    private static var stridedSelector: String {
        "[0:\(gridStride):\(nativeRows - 1)][0:\(gridStride):\(nativeCols - 1)]"
    }

    /// One hourly velocity field. `center` is the slice's interval-center
    /// instant (HH:30 for the hour starting at HH:00).
    static func currentsSliceURL(center: Date) -> URL {
        let t = "[(\(iso(center)))]"
        let s = stridedSelector
        return url(dataset: currentsDataset, query: "VelEast5\(t)\(s),VelNorth5\(t)\(s)")
    }

    /// Lon/lat for every strided grid cell (fetched once, cached forever).
    static func gridURL() -> URL {
        url(dataset: bathymetryDataset, query: "longitude\(stridedSelector),latitude\(stridedSelector)")
    }

    /// A gauge's 10-minute SSH series from `from` to the end of its window.
    static func sshURL(gauge: Gauge, from: Date) -> URL {
        url(dataset: gauge.dataset, query: "ssh[(\(iso(from))):(last)][0][0]")
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)   // "2026-07-10T14:30:00Z"
    }

    private static func url(dataset: String, query: String) -> URL {
        // urlQueryAllowed keeps (),:  but percent-encodes the [] that griddap
        // uses for its selectors — ERDDAP accepts either form.
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(base)/\(dataset).json?\(encoded)") else {
            fatalError("malformed SalishSeaCast URL for \(dataset)")
        }
        return url
    }

    // ── Response decoding ────────────────────────────────────────────────
    // Every ERDDAP .json response is {"table": {"columnNames": [...], "rows": [[...]]}}
    // with land/missing values as JSON null.

    enum ResponseError: Error {
        case malformed
    }

    /// One wet (water) grid cell of an hourly velocity field.
    struct WetPoint: Sendable, Equatable {
        let index: UInt32   // strided-grid index (see stridedIndex)
        let east: Float     // m/s
        let north: Float    // m/s
    }

    /// Lon/lat per strided-grid index; NaN where the response had no value.
    struct LiveGrid: Sendable {
        let lat: [Float]
        let lon: [Float]
    }

    /// Rows are [time, gridY, gridX, east, north]; land cells have null
    /// velocities and are dropped. Returns the slice's actual center instant —
    /// the caller must check it, since a closest-match query for an hour the
    /// model hasn't published yet silently returns a neighbouring slice.
    static func parseCurrentsSlice(_ data: Data) throws -> (center: Date, points: [WetPoint])? {
        let rows = try tableRows(data)
        guard let isoTime = rows.first?.first as? String,
              let epoch = TideBundleEvent.epochUTC(from: isoTime)
        else { return nil }

        var points: [WetPoint] = []
        points.reserveCapacity(rows.count / 2)
        for row in rows {
            guard row.count >= 5,
                  let y = (row[1] as? NSNumber)?.intValue,
                  let x = (row[2] as? NSNumber)?.intValue,
                  // Server data is untrusted: an out-of-range index would trap
                  // in the UInt32 conversion or poison the cached slice.
                  (0..<nativeRows).contains(y), (0..<nativeCols).contains(x),
                  let e = (row[3] as? NSNumber)?.floatValue,
                  let n = (row[4] as? NSNumber)?.floatValue
            else { continue }   // null velocity → land
            points.append(WetPoint(index: UInt32(stridedIndex(gridY: y, gridX: x)),
                                   east: e, north: n))
        }
        return (Date(timeIntervalSince1970: TimeInterval(epoch)), points)
    }

    /// Rows are [gridY, gridX, longitude, latitude].
    static func parseGrid(_ data: Data) throws -> LiveGrid {
        let rows = try tableRows(data)
        let count = stridedRows * stridedCols
        var lat = [Float](repeating: .nan, count: count)
        var lon = [Float](repeating: .nan, count: count)
        for row in rows {
            guard row.count >= 4,
                  let y = (row[0] as? NSNumber)?.intValue,
                  let x = (row[1] as? NSNumber)?.intValue,
                  (0..<nativeRows).contains(y), (0..<nativeCols).contains(x),
                  let lo = (row[2] as? NSNumber)?.floatValue,
                  let la = (row[3] as? NSNumber)?.floatValue
            else { continue }
            let idx = stridedIndex(gridY: y, gridX: x)
            lon[idx] = lo
            lat[idx] = la
        }
        guard lat.contains(where: { !$0.isNaN }) else { throw ResponseError.malformed }
        return LiveGrid(lat: lat, lon: lon)
    }

    /// Rows are [time, longitude, latitude, ssh]. Heights are metres above the
    /// geoid (≈ mean sea level) — see LiveDataService's datum calibration.
    static func parseSSH(_ data: Data) throws -> [(t: Int, ssh: Double)] {
        let rows = try tableRows(data)
        var out: [(t: Int, ssh: Double)] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard row.count >= 4,
                  let isoTime = row[0] as? String,
                  let epoch = TideBundleEvent.epochUTC(from: isoTime),
                  let ssh = (row[3] as? NSNumber)?.doubleValue
            else { continue }
            out.append((t: epoch, ssh: ssh))
        }
        return out.sorted { $0.t < $1.t }
    }

    private static func tableRows(_ data: Data) throws -> [[Any]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = obj["table"] as? [String: Any],
              let rows = table["rows"] as? [[Any]]
        else { throw ResponseError.malformed }
        return rows
    }

    // ── Blob packing ─────────────────────────────────────────────────────
    // Cache-on-disk formats (little endian). Bump LiveDataStore.schemaVersion
    // if either layout changes.

    /// [UInt32 index, Float east, Float north] × n.
    static func pack(_ points: [WetPoint]) -> Data {
        var data = Data(capacity: points.count * 12)
        for p in points {
            withUnsafeBytes(of: p.index.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.east.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.north.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpackPoints(_ data: Data) -> [WetPoint] {
        let recordSize = 12
        let count = data.count / recordSize
        var out: [WetPoint] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { buf in
            for i in 0..<count {
                let o = i * recordSize
                out.append(WetPoint(
                    index: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt32.self)),
                    east: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))),
                    north: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)))
                ))
            }
        }
        return out
    }

    /// [UInt16 y, UInt16 x, Float east, Float north] × n.
    static func pack(_ points: [NativePoint]) -> Data {
        var data = Data(capacity: points.count * 12)
        for p in points {
            withUnsafeBytes(of: p.y.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.x.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.east.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.north.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpackNativePoints(_ data: Data) -> [NativePoint] {
        let recordSize = 12
        let count = data.count / recordSize
        var out: [NativePoint] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { buf in
            for i in 0..<count {
                let o = i * recordSize
                out.append(NativePoint(
                    y: UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt16.self)),
                    x: UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: o + 2, as: UInt16.self)),
                    east: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))),
                    north: Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)))
                ))
            }
        }
        return out
    }

    /// [Float lat, Float lon] × (stridedRows × stridedCols), indexed by
    /// strided-grid index.
    static func pack(_ grid: LiveGrid) -> Data {
        var data = Data(capacity: grid.lat.count * 8)
        for i in 0..<grid.lat.count {
            withUnsafeBytes(of: grid.lat[i].bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: grid.lon[i].bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpackGrid(_ data: Data) -> LiveGrid {
        let count = data.count / 8
        var lat = [Float](repeating: .nan, count: count)
        var lon = [Float](repeating: .nan, count: count)
        data.withUnsafeBytes { buf in
            for i in 0..<count {
                lat[i] = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)))
                lon[i] = Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self)))
            }
        }
        return LiveGrid(lat: lat, lon: lon)
    }
}
