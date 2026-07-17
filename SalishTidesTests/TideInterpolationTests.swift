import Foundation
import Testing
@testable import SalishTides

struct TideCurveTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private var events: [TideEvent] {
        [
            TideEvent(time: t0, height: 1.0, isHigh: false),
            TideEvent(time: t0.addingTimeInterval(6 * 3600), height: 3.0, isHigh: true),
            TideEvent(time: t0.addingTimeInterval(12 * 3600), height: 0.5, isHigh: false),
        ]
    }

    @Test func clampsOutsideCoverage() {
        #expect(TideCurve.height(at: t0.addingTimeInterval(-3600), events: events) == 1.0)
        #expect(TideCurve.height(at: t0.addingTimeInterval(13 * 3600), events: events) == 0.5)
    }

    @Test func exactAtExtrema() {
        for e in events {
            #expect(TideCurve.height(at: e.time, events: events) == e.height)
        }
    }

    @Test func midpointIsMeanOfNeighbours() throws {
        // cos interpolation passes through the arithmetic mean at mid-span.
        let mid = try #require(TideCurve.height(at: t0.addingTimeInterval(3 * 3600), events: events))
        #expect(abs(mid - 2.0) < 1e-9)
    }

    @Test func quarterPointMatchesCosineForm() throws {
        let h = try #require(TideCurve.height(at: t0.addingTimeInterval(1.5 * 3600), events: events))
        let expected = 1.0 + (3.0 - 1.0) * (1 - cos(.pi * 0.25)) / 2
        #expect(abs(h - expected) < 1e-9)
    }

    @Test func zeroSpanDoesNotDivideByZero() {
        let dup = [
            TideEvent(time: t0, height: 1.0, isHigh: false),
            TideEvent(time: t0, height: 2.0, isHigh: true),
        ]
        #expect(TideCurve.height(at: t0, events: dup) == 1.0)
    }

    @Test func emptyEventsReturnsNil() {
        #expect(TideCurve.height(at: t0, events: []) == nil)
    }

    @Test func heightIfBracketedAgreesInsideAndDeclinesOutside() throws {
        // Inside coverage the two APIs are identical...
        for offset in [0.0, 1.5, 3, 6, 9, 12].map({ $0 * 3600 }) {
            let t = t0.addingTimeInterval(offset)
            #expect(TideCurve.heightIfBracketed(at: t, events: events)
                    == TideCurve.height(at: t, events: events))
        }
        // ...but outside, where height(at:) clamps to a constant (which a
        // central-difference probe would misread as "falling" → "Ebb"),
        // heightIfBracketed must return nil so the phase estimator can
        // decline instead of fabricating a verdict.
        #expect(TideCurve.heightIfBracketed(at: t0.addingTimeInterval(-1), events: events) == nil)
        #expect(TideCurve.heightIfBracketed(at: t0.addingTimeInterval(12 * 3600 + 1), events: events) == nil)
        #expect(TideCurve.heightIfBracketed(at: t0, events: []) == nil)
    }
}

struct LiveTideSeriesTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// 4 h of 10-minute samples ramping 0.0 → 2.4 m.
    private var series: LiveTideSeries {
        let samples = (0...24).map { i in
            (time: t0.addingTimeInterval(Double(i) * 600), height: Double(i) * 0.1)
        }
        return LiveTideSeries(gaugeName: "Test", samples: samples)
    }

    @Test func nilOutsideCoverage() {
        #expect(series.height(at: t0.addingTimeInterval(-1)) == nil)
        #expect(series.height(at: t0.addingTimeInterval(24 * 600 + 1)) == nil)
    }

    @Test func exactAtSamples() throws {
        let h = try #require(series.height(at: t0.addingTimeInterval(6000)))
        #expect(abs(h - 1.0) < 1e-9)
    }

    @Test func linearBetweenSamples() throws {
        let h = try #require(series.height(at: t0.addingTimeInterval(300)))
        #expect(abs(h - 0.05) < 1e-9)
    }

    @Test func blendEqualsFallbackAtEdge() throws {
        // At the first sample the blend weight is 0 — pure fallback, so the
        // handoff to the prediction curve is continuous.
        let h = try #require(series.blendedHeight(at: t0, fallback: 9.0))
        #expect(abs(h - 9.0) < 1e-9)
    }

    @Test func blendIsPureLiveInInterior() throws {
        // 2 h from both edges (> the 1 h blend band) — fallback ignored.
        let t = t0.addingTimeInterval(2 * 3600)
        let h = try #require(series.blendedHeight(at: t, fallback: 9.0))
        let raw = try #require(series.height(at: t))
        #expect(abs(h - raw) < 1e-9)
    }

    @Test func blendFallsBackOutsideCoverage() {
        #expect(series.blendedHeight(at: t0.addingTimeInterval(-3600), fallback: 9.0) == 9.0)
        #expect(series.blendedHeight(at: t0.addingTimeInterval(-3600), fallback: nil) == nil)
    }
}
