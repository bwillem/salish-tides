import Foundation

/// Shared geo helpers. The Salish Sea spans only a few degrees of latitude,
/// so an equirectangular approximation (longitude scaled by cos lat) is
/// accurate for nearest-point picks at this scale.
enum GeoMath {
    /// Squared equirectangular distance in degrees², with longitude corrected
    /// by cos(query latitude). Compare against squared thresholds.
    static func distanceSquared(fromLat: Double, fromLon: Double,
                                toLat: Double, toLon: Double) -> Double {
        distanceSquared(fromLat: fromLat, fromLon: fromLon,
                        toLat: toLat, toLon: toLon,
                        cosLat: cos(fromLat * .pi / 180))
    }

    /// Same distance with a caller-hoisted cosine — for min-scans over
    /// thousands of points, where recomputing cos per comparison adds up
    /// (nearestVector runs on the main actor during scrubs).
    static func distanceSquared(fromLat: Double, fromLon: Double,
                                toLat: Double, toLon: Double,
                                cosLat: Double) -> Double {
        let dLat = toLat - fromLat
        let dLon = (toLon - fromLon) * cosLat
        return dLat * dLat + dLon * dLon
    }

    /// Ground (and, on a conformal map, screen) length of one degree of
    /// longitude relative to one degree of latitude at `lat`, clamped away
    /// from zero near the poles. Divide an east–west degree offset by this
    /// to keep geometry ground-true.
    static func lonScale(atLat lat: Double) -> Double {
        max(0.1, cos(lat * .pi / 180))
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
