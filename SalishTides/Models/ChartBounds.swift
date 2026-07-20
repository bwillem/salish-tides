import Foundation

/// A geographic lat/lon bounding box — the shared currency for viewport
/// culling, coverage checks, and fetch windows across the map stack.
/// (The name is a holdover from the print-atlas era it outlived.)
struct ChartBounds: Decodable, Sendable, Equatable {
    let lat_min: Double
    let lat_max: Double
    let lon_min: Double
    let lon_max: Double

    /// The app's supported region: the extent of the bundled offline basemap
    /// (`data/basemap/salish.pmtiles`). Outside this box there are no map tiles
    /// at all, so the camera is constrained to it and the locate button is
    /// disabled for a user beyond it.
    ///
    /// Must stay in sync with `BBOX` in `dev/basemap/build-pmtiles.sh` — the
    /// PMTiles header itself is useless here (tile-join rewrites it to global
    /// bounds), so the build script is the only source of truth.
    ///
    /// Note this is *narrower* than the current models: `webtide_nepac.b1`
    /// reaches 60°N and the tide-station set reaches 52.2°N. That data has no
    /// basemap under it, so it was never usably reachable.
    static let coverage = ChartBounds(lat_min: 46.92, lat_max: 51.20,
                                      lon_min: -128.23, lon_max: -122.05)

    /// Fraction of span added on each side when culling or fetching around
    /// the viewport, so pans don't immediately hit empty edges. Shared by
    /// MapViewModel's culling and LiveDataService's native windows so the
    /// two can't silently drift apart.
    static let cullMarginFraction = 0.2

    func intersects(_ other: ChartBounds) -> Bool {
        lat_max > other.lat_min && lat_min < other.lat_max &&
        lon_max > other.lon_min && lon_min < other.lon_max
    }

    func contains(lat: Double, lon: Double) -> Bool {
        lat >= lat_min && lat <= lat_max && lon >= lon_min && lon <= lon_max
    }

    func contains(_ other: ChartBounds) -> Bool {
        other.lat_min >= lat_min && other.lat_max <= lat_max &&
        other.lon_min >= lon_min && other.lon_max <= lon_max
    }

    /// The lowest zoom at which this box still covers a `width` × `height`
    /// point viewport — the floor that keeps the camera from zooming out past
    /// the edge of the data (see `MapLibreView.Coordinator.applyMinimumZoom`).
    ///
    /// Rotation-invariant by construction: a viewport turned by θ has an
    /// axis-aligned extent of (w·|cos θ| + h·|sin θ|) across and
    /// (w·|sin θ| + h·|cos θ|) down, both of which peak at the diagonal
    /// √(w² + h²). Sizing off the diagonal therefore holds at *any* bearing,
    /// which matters because the map rotates: a floor computed for north-up
    /// would let a rotated viewport overhang the box, and re-deriving it per
    /// frame during a rotate gesture would mean fighting the gesture with
    /// camera writes. The cost is roughly 0.4 of a zoom level of extra
    /// tightness versus the north-up-only floor — the whole box still fits on
    /// screen at the floor, just with a little margin.
    ///
    /// Returns the raw floor; callers clamp it against their zoom ceiling.
    /// Zero or negative dimensions (mid-layout) return nil — there's no
    /// meaningful viewport to fit against yet.
    func minimumZoomCovering(width: Double, height: Double) -> Double? {
        guard width > 0, height > 0 else { return nil }
        let diagonal = (width * width + height * height).squareRoot()
        // Web Mercator at zoom z spans 256·2^z points for 360° of longitude and
        // 2π of Mercator y, so the zoom that makes a span fill a screen
        // dimension is log2(dimension / (256 · span)).
        let lonZoom = log2(360 * diagonal / (Self.tileSize * (lon_max - lon_min)))
        let latZoom = log2(2 * .pi * diagonal / (Self.tileSize * mercatorHeight))
        return max(lonZoom, latZoom)
    }

    /// This box's height in Web Mercator y units (the projection's native
    /// vertical measure, total range 2π).
    var mercatorHeight: Double {
        func mercatorY(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        return mercatorY(lat_max) - mercatorY(lat_min)
    }

    /// Web Mercator tile edge in points.
    private static let tileSize: Double = 256

    func expanded(byFraction f: Double) -> ChartBounds {
        let latMargin = (lat_max - lat_min) * f
        let lonMargin = (lon_max - lon_min) * f
        return ChartBounds(lat_min: lat_min - latMargin, lat_max: lat_max + latMargin,
                           lon_min: lon_min - lonMargin, lon_max: lon_max + lonMargin)
    }
}
