import Foundation

/// Shared geo helpers. The Salish Sea spans only a few degrees of latitude,
/// so an equirectangular approximation (longitude scaled by cos lat) is
/// accurate for nearest-point picks at this scale.
enum GeoMath {
    /// Squared equirectangular distance in degrees², with longitude corrected
    /// by cos(query latitude). Cheap enough for per-point min scans; compare
    /// against squared thresholds.
    static func distanceSquared(fromLat: Double, fromLon: Double,
                                toLat: Double, toLon: Double) -> Double {
        let cosLat = cos(fromLat * .pi / 180)
        let dLat = toLat - fromLat
        let dLon = (toLon - fromLon) * cosLat
        return dLat * dLat + dLon * dLon
    }

    /// NEMO east/north velocity components → compass flow bearing in degrees
    /// (0 = N, flow *toward* — the convention the arrows, compass needle, and
    /// particle field all expect).
    static func flowBearing(east: Double, north: Double) -> Double {
        var dir = atan2(east, north) * 180 / .pi
        if dir < 0 { dir += 360 }
        return dir
    }
}
