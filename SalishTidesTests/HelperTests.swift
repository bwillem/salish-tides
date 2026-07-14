import Foundation
import Testing
@testable import SalishTides

struct LRUCacheTests {

    @Test func evictsLeastRecentlyUsedPastLimit() {
        var cache = LRUCache<Int, String>(limit: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        cache.insert("c", for: 3)
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 2) == "b")
        #expect(cache.value(for: 3) == "c")
    }

    @Test func readRefreshesRecency() {
        var cache = LRUCache<Int, String>(limit: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        _ = cache.value(for: 1)      // 1 is now most recent
        cache.insert("c", for: 3)    // evicts 2, not 1
        #expect(cache.value(for: 1) == "a")
        #expect(cache.value(for: 2) == nil)
    }

    @Test func reinsertUpdatesValueWithoutGrowth() {
        var cache = LRUCache<Int, String>(limit: 2)
        cache.insert("a", for: 1)
        cache.insert("a2", for: 1)
        cache.insert("b", for: 2)
        #expect(cache.value(for: 1) == "a2")
        #expect(cache.value(for: 2) == "b")
    }

    @Test func removeValue() {
        var cache = LRUCache<Int, String>(limit: 2)
        cache.insert("a", for: 1)
        cache.removeValue(for: 1)
        #expect(cache.value(for: 1) == nil)
    }
}

struct GeoMathTests {

    @Test func flowBearingCompassConvention() {
        // Flow *toward*, 0 = north, clockwise.
        #expect(abs(GeoMath.flowBearing(east: 0, north: 1) - 0) < 1e-9)
        #expect(abs(GeoMath.flowBearing(east: 1, north: 0) - 90) < 1e-9)
        #expect(abs(GeoMath.flowBearing(east: 0, north: -1) - 180) < 1e-9)
        #expect(abs(GeoMath.flowBearing(east: -1, north: 0) - 270) < 1e-9)
        #expect(abs(GeoMath.flowBearing(east: 1, north: 1) - 45) < 1e-9)
    }

    @Test func distanceScalesLongitudeByCosLat() {
        // At 60°N, cos = 0.5: one degree of longitude counts as half a degree.
        let dLon = GeoMath.distanceSquared(fromLat: 60, fromLon: 0, toLat: 60, toLon: 1)
        #expect(abs(dLon - 0.25) < 1e-9)
        let dLat = GeoMath.distanceSquared(fromLat: 60, fromLon: 0, toLat: 61, toLon: 0)
        #expect(abs(dLat - 1.0) < 1e-9)
    }
}

struct ChartBoundsTests {
    private let bounds = ChartBounds(lat_min: 48, lat_max: 50, lon_min: -125, lon_max: -122)

    @Test func containsIsInclusive() {
        #expect(bounds.contains(lat: 48, lon: -125))
        #expect(bounds.contains(lat: 49, lon: -123))
        #expect(!bounds.contains(lat: 47.99, lon: -123))
        #expect(!bounds.contains(lat: 49, lon: -121.99))
    }

    @Test func expandedAddsFractionOfSpanPerSide() {
        let e = bounds.expanded(byFraction: 0.2)
        #expect(abs(e.lat_min - (48 - 0.4)) < 1e-9)
        #expect(abs(e.lat_max - (50 + 0.4)) < 1e-9)
        #expect(abs(e.lon_min - (-125 - 0.6)) < 1e-9)
        #expect(abs(e.lon_max - (-122 + 0.6)) < 1e-9)
    }

    @Test func intersects() {
        #expect(bounds.intersects(ChartBounds(lat_min: 49, lat_max: 51, lon_min: -124, lon_max: -123)))
        #expect(!bounds.intersects(ChartBounds(lat_min: 51, lat_max: 52, lon_min: -124, lon_max: -123)))
    }
}
