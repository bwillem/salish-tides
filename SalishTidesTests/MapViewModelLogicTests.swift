import Foundation
import Testing
@testable import SalishTides

/// MapViewModel's pure decision logic: hour snapping (epoch-based, so the DST
/// fall-back's repeated wall-clock hour can't mis-snap) and the crosshair
/// fine/coarse acceptance-radius choice (probes the fine field's actual
/// water, never its axis-aligned bounding box).
struct MapViewModelLogicTests {

    private func utcDate(_ year: Int, _ month: Int, _ day: Int,
                         _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day,
                                             hour: hour, minute: minute, second: second))!
    }

    // MARK: - snapToHour

    @Test func snapsToNearestHour() {
        #expect(MapViewModel.snapToHour(utcDate(2026, 7, 16, 12, 20))
                == utcDate(2026, 7, 16, 12, 0))
        #expect(MapViewModel.snapToHour(utcDate(2026, 7, 16, 12, 40))
                == utcDate(2026, 7, 16, 13, 0))
    }

    @Test func snapsCorrectlyInsideDSTFallBackRepeatedHour() {
        // 2026-11-01 09:30 UTC is 01:30 PST — the SECOND pass through the
        // 1 AM wall-clock hour after fall-back. A wall-clock round-trip via
        // Calendar.salish resolves the ambiguous 01:00 to its earlier (PDT)
        // occurrence and snaps to 09:00 UTC; the true nearest hour is 10:00.
        #expect(MapViewModel.snapToHour(utcDate(2026, 11, 1, 9, 30))
                == utcDate(2026, 11, 1, 10, 0))
    }

    @Test func halfHourBoundaryRoundsUp() {
        #expect(MapViewModel.snapToHour(utcDate(2026, 7, 16, 12, 30))
                == utcDate(2026, 7, 16, 13, 0))
        #expect(MapViewModel.snapToHour(utcDate(2026, 7, 16, 12, 29, 59))
                == utcDate(2026, 7, 16, 12, 0))
    }

    // MARK: - crosshairUsesCoarseRadius

    /// Minimal synthetic field: a regular mesh with water at the given cell
    /// indices. `coeffs` stays empty — the radius decision only probes
    /// `nodeIndex`, never synthesizes.
    private func makeField(lat0: Double = 48, lon0: Double = -123,
                           d: Double = 0.005, rows: Int = 4, cols: Int = 4,
                           waterCells: [Int]) -> TidalCurrentField {
        var nodeIndex = [Int32](repeating: -1, count: rows * cols)
        for (ordinal, cell) in waterCells.enumerated() { nodeIndex[cell] = Int32(ordinal) }
        return TidalCurrentField(lat0: lat0, lon0: lon0, dLat: d, dLon: d,
                                 rows: rows, cols: cols,
                                 nodeIndex: nodeIndex, nodeCount: waterCells.count,
                                 coeffs: [], droppedNodes: 0)
    }

    @Test func fineWheneverWebTideDoesNotContribute() {
        #expect(MapViewModel.crosshairUsesCoarseRadius(
            webTideContributes: false, centre: (lat: 48.5, lon: -123.5),
            fineField: nil) == false)
    }

    @Test func fineWhenFineWaterIsWithinReachOfCentre() {
        // Water node at (48, -123); centre ~300 m away — the fine search
        // would find it, so the fine radius is correct.
        let field = makeField(waterCells: [0])
        #expect(MapViewModel.crosshairUsesCoarseRadius(
            webTideContributes: true, centre: (lat: 48.002, lon: -123.002),
            fineField: field) == false)
    }

    @Test func coarseWhenCentreIsFarFromFineWater() {
        // Water only at (48, -123); centre ~55 km away. This is the regime
        // the old bbox test got wrong: an axis-aligned box around a rotated
        // domain can contain such a point even though no fine node is
        // anywhere near it, wrongly forcing the fine radius.
        let field = makeField(waterCells: [0])
        #expect(MapViewModel.crosshairUsesCoarseRadius(
            webTideContributes: true, centre: (lat: 48.5, lon: -123.5),
            fineField: field) == true)
    }

    @Test func coarseWhenFineFieldUnloadedOrCentreUnknown() {
        // An unloaded fine field (or no centre yet) can't justify narrowing.
        let field = makeField(waterCells: [0])
        #expect(MapViewModel.crosshairUsesCoarseRadius(
            webTideContributes: true, centre: (lat: 48.0, lon: -123.0),
            fineField: nil) == true)
        #expect(MapViewModel.crosshairUsesCoarseRadius(
            webTideContributes: true, centre: nil, fineField: field) == true)
    }

    // MARK: - centreIsWater (crosshair land/water verdict)

    @Test func waterWhenContainingCellIsWet() {
        // Cell 0 is water; a point within half a cell of its node is ON it.
        let field = makeField(waterCells: [0])
        #expect(MapViewModel.centreIsWater(fields: [field],
                                           lat: 48.001, lon: -123.001) == true)
    }

    @Test func landWhenEveryCoveringFieldSaysDry() {
        // Point sits on a dry cell inside the grid — land, even though water
        // exists one cell over (inside the crosshair acceptance radius). This
        // is the beach-adjacent case: nearby nodes must not be quoted.
        let field = makeField(waterCells: [1])   // water at (48, -122.995)
        #expect(MapViewModel.centreIsWater(fields: [field],
                                           lat: 48.0, lon: -123.0) == false)
    }

    @Test func wetVerdictFromAnyFieldWins() {
        // A dry verdict from one grid (e.g. SalishSea's rotated-domain bbox
        // over west-coast water, or WebTide's pack-masked seam) must not
        // overrule another field's wet containing cell.
        let dryHere = makeField(waterCells: [15])            // covers, all dry near origin
        let wetHere = makeField(d: 0.036, waterCells: [0])   // coarse mesh, wet at origin
        #expect(MapViewModel.centreIsWater(fields: [dryHere, wetHere],
                                           lat: 48.0, lon: -123.0) == true)
    }

    @Test func nilWhenNoFieldCoversThePoint() {
        // Off every mesh: no land evidence either way — the caller's radius
        // search stays the only judge.
        let field = makeField(waterCells: [0])
        #expect(MapViewModel.centreIsWater(fields: [field],
                                           lat: 50.0, lon: -130.0) == nil)
        #expect(MapViewModel.centreIsWater(fields: [],
                                           lat: 48.0, lon: -123.0) == nil)
    }

    // MARK: - VectorSpatialIndex (per-frame crosshair lookup)

    private func makeVector(lat: Double, lon: Double,
                            speed: Double = 0.5) -> CurrentVector {
        CurrentVector(lat: lat, lon: lon, speed_ms: speed, direction_deg: 90)
    }

    /// Deterministic pseudo-scatter (no RNG — reproducible), spanning several
    /// bins around a Salish-Sea-like centre.
    private func scatter(_ n: Int) -> [CurrentVector] {
        (0..<n).map { i in
            let f = Double(i)
            return makeVector(lat: 48.5 + sin(f * 0.7) * 0.08,
                              lon: -123.3 + cos(f * 1.3) * 0.12,
                              speed: 0.1 + Double(i % 7) * 0.1)
        }
    }

    @Test func indexAgreesWithBruteForceScan() {
        let vectors = scatter(200)
        let index = VectorSpatialIndex(vectors: vectors, binDeg: 0.033)
        let queries: [(Double, Double)] = [(48.5, -123.3), (48.56, -123.21),
                                           (48.44, -123.4), (48.58, -123.42)]
        for (lat, lon) in queries {
            for radius in [0.015, 0.033] {
                let cosLat = cos(lat * .pi / 180)
                func d2(_ v: CurrentVector) -> Double {
                    GeoMath.distanceSquared(fromLat: lat, fromLon: lon,
                                            toLat: v.lat, toLon: v.lon, cosLat: cosLat)
                }
                let brute = vectors.min { d2($0) < d2($1) }
                    .flatMap { d2($0) <= radius * radius ? $0 : nil }
                #expect(index.nearest(lat: lat, lon: lon,
                                      maxDistanceDeg: radius) == brute)
            }
        }
    }

    @Test func indexLongitudinalReachIsCosScaled() {
        // The radius metric cos-scales longitude, so a vector nearly
        // radius/cos(lat) away in RAW longitude degrees is still in range —
        // more than one square bin over. A fixed 3×3 probe would miss it.
        let lat = 48.5, cosLat = cos(lat * .pi / 180)
        let radius = 0.033
        let v = makeVector(lat: lat, lon: -123.0 + (radius * 0.95) / cosLat)
        let index = VectorSpatialIndex(vectors: [v], binDeg: radius)
        #expect(index.nearest(lat: lat, lon: -123.0, maxDistanceDeg: radius) == v)
    }

    @Test func indexRespectsRadiusAndEmptiness() {
        let v = makeVector(lat: 48.5, lon: -123.3)
        let index = VectorSpatialIndex(vectors: [v], binDeg: 0.033)
        // Just out of range latitudinally → nil, not the nearest-anyway.
        #expect(index.nearest(lat: 48.5 + 0.04, lon: -123.3,
                              maxDistanceDeg: 0.033) == nil)
        let empty = VectorSpatialIndex(vectors: [], binDeg: 0.033)
        #expect(empty.nearest(lat: 48.5, lon: -123.3, maxDistanceDeg: 0.033) == nil)
    }
}
