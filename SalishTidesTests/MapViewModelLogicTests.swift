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
}
