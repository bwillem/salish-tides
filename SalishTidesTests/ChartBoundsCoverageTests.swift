import Foundation
import Testing
@testable import SalishTides

/// The camera clamp's pure arithmetic: the supported-region constant and the
/// zoom floor derived from it. The floor is what stops the user zooming out
/// past the edge of the bundled basemap, so a regression here reads as blank
/// grey around a shrunken map rather than as a crash.
struct ChartBoundsCoverageTests {

    // MARK: - The coverage constant

    /// Mirrors `BBOX` in dev/basemap/build-pmtiles.sh, which is the source of
    /// truth (the .pmtiles header is not — tile-join rewrites it to global
    /// bounds). The build script fails loudly if these drift; this pins the
    /// value from the app side too.
    @Test func coverageMatchesTheBundledBasemapExtent() {
        let c = ChartBounds.coverage
        #expect(c.lat_min == 46.92)
        #expect(c.lat_max == 51.20)
        #expect(c.lon_min == -128.23)
        #expect(c.lon_max == -122.05)
    }

    @Test func coverageContainsTheSalishSeaAndExcludesBeyond() {
        let c = ChartBounds.coverage
        #expect(c.contains(lat: 48.65, lon: -123.40))   // Sidney BC
        #expect(c.contains(lat: 48.72, lon: -123.14))   // Boundary Pass
        #expect(c.contains(lat: 47.60, lon: -122.33))   // Seattle
        #expect(!c.contains(lat: 37.33, lon: -122.01))  // Cupertino
        #expect(!c.contains(lat: 57.00, lon: -135.00))  // SE Alaska (WebTide reaches
                                                        // here; the basemap does not)
        #expect(!c.contains(lat: 52.18, lon: -128.43))  // northernmost tide station
    }

    // MARK: - Zoom floor

    @Test func floorIsHighEnoughToCoverTheViewport() throws {
        let c = ChartBounds.coverage
        // iPad Pro 13" portrait, in points.
        let z = try #require(c.minimumZoomCovering(width: 1024, height: 1366))
        // At the floor the box must span at least the viewport's diagonal in
        // both axes — that's the property the whole clamp rests on.
        let worldPoints = 256 * pow(2, z)
        let lonSpanOnScreen = (c.lon_max - c.lon_min) / 360 * worldPoints
        let latSpanOnScreen = c.mercatorHeight / (2 * .pi) * worldPoints
        let diagonal = (1024.0 * 1024 + 1366 * 1366).squareRoot()
        #expect(lonSpanOnScreen >= diagonal - 0.001)
        #expect(latSpanOnScreen >= diagonal - 0.001)
    }

    @Test func floorIsRotationInvariant() throws {
        let c = ChartBounds.coverage
        let w = 1024.0, h = 1366.0
        let floor = try #require(c.minimumZoomCovering(width: w, height: h))
        // A viewport turned by θ has axis-aligned extents w|cosθ|+h|sinθ| and
        // w|sinθ|+h|cosθ|. At the floor the box's on-screen span must still
        // cover both, at every bearing — that is what "rotation-invariant"
        // buys, and it's the property a rotate gesture at minimum zoom leans
        // on. (Note this compares against the box's rendered span directly;
        // re-running minimumZoomCovering on the rotated extents would apply
        // the diagonal twice and prove nothing.)
        let worldPoints = 256 * pow(2, floor)
        let boxWidthOnScreen = (c.lon_max - c.lon_min) / 360 * worldPoints
        let boxHeightOnScreen = c.mercatorHeight / (2 * .pi) * worldPoints
        for degrees in stride(from: 0.0, to: 180.0, by: 5.0) {
            let t = degrees * .pi / 180
            let rotatedW = w * abs(cos(t)) + h * abs(sin(t))
            let rotatedH = w * abs(sin(t)) + h * abs(cos(t))
            #expect(boxWidthOnScreen >= rotatedW - 0.001,
                    "at bearing \(degrees)° the viewport is \(rotatedW)pt wide, box spans \(boxWidthOnScreen)pt")
            #expect(boxHeightOnScreen >= rotatedH - 0.001,
                    "at bearing \(degrees)° the viewport is \(rotatedH)pt tall, box spans \(boxHeightOnScreen)pt")
        }
    }

    @Test func largerViewportsNeedTighterFloors() throws {
        let c = ChartBounds.coverage
        let phone = try #require(c.minimumZoomCovering(width: 402, height: 874))
        let pad = try #require(c.minimumZoomCovering(width: 1024, height: 1366))
        #expect(phone < pad)
        // Sanity: both land in a plausible band for this box, well inside the
        // app's z14 ceiling. The iPad value is what the running app measured.
        #expect(phone > 7 && phone < 9)
        #expect(pad > 8 && pad < 10)
    }

    @Test func degenerateViewportsYieldNoFloor() {
        let c = ChartBounds.coverage
        // Mid-layout, before the view has real bounds — callers must leave the
        // provisional minimum alone rather than compute a nonsense floor.
        #expect(c.minimumZoomCovering(width: 0, height: 0) == nil)
        #expect(c.minimumZoomCovering(width: 1024, height: 0) == nil)
        #expect(c.minimumZoomCovering(width: -1, height: 100) == nil)
    }

    @Test func mercatorHeightMatchesTheProjection() {
        // Mercator y = ln(tan(π/4 + φ/2)); the box spans ~0.11 of the
        // projection's 2π range at these latitudes.
        let h = ChartBounds.coverage.mercatorHeight
        #expect(h > 0.11 && h < 0.12)
    }
}
