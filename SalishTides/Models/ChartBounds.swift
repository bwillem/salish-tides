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

    func expanded(byFraction f: Double) -> ChartBounds {
        let latMargin = (lat_max - lat_min) * f
        let lonMargin = (lon_max - lon_min) * f
        return ChartBounds(lat_min: lat_min - latMargin, lat_max: lat_max + latMargin,
                           lon_min: lon_min - lonMargin, lon_max: lon_max + lonMargin)
    }
}
