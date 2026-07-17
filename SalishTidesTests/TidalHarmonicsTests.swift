import Foundation
import Testing
@testable import SalishTides

/// Pins the TidalHarmonics engine to NOAA ground truth so CI catches a phase-
/// convention or nodal-factor regression — the only other harmonic test
/// (`m2SynthesisPulsesOverACycle`) still passes with V+u+g or f ≡ 1.
///
/// Reference data provenance: NOAA CO-OPS Seattle (station 9447130, MLLW),
/// harmonic constituents and hourly predictions for 2024-01-15…17 UTC, copied
/// from `dev/model/noaa_seattle_ref.json` — the same dataset
/// `dev/model/SwiftValidate/main.swift` validates against (correlation 0.997,
/// RMS 0.128 m, max error 0.255 m over 72 hourly steps using the engine's 8
/// of NOAA's 34 published constituents). Hardcoded here, not bundled: the
/// test target stays resource-free and the numbers are load-bearing anyway.
struct TidalHarmonicsTests {

    /// Seattle (amp m, Greenwich phase g °) for the engine's constituents,
    /// in `TidalHarmonics.constituents` order (M2 S2 N2 K2 K1 O1 P1 Q1).
    private static let seattle: [(amp: Double, g: Double)] = [
        (1.063, 10.8), (0.268, 36.8), (0.214, 341.1), (0.079, 37.7),
        (0.834, 276.8), (0.459, 254.6), (0.257, 276.2), (0.073, 248.9),
    ]

    /// A single-node field with Seattle's constituents packed into the U
    /// component (uAmp = amp, uPhase = g), so `velocity().u` IS the predicted
    /// tide height — the check runs through the exact shipping synthesis path
    /// (`TidalCurrentField.velocity` with hoisted `synthesisTerms`), phase
    /// subtraction and nodal factors included, not a test-local reimplementation.
    private static func seattleField() -> TidalCurrentField {
        var coeffs = [Double](repeating: 0, count: TidalCurrentField.coeffStride)
        for (i, c) in seattle.enumerated() {
            coeffs[2 + 4 * i] = c.amp
            coeffs[2 + 4 * i + 1] = c.g
        }
        return TidalCurrentField(lat0: 47.6, lon0: -122.3, dLat: 0.01, dLon: 0.01,
                                 rows: 1, cols: 1, nodeIndex: [0], nodeCount: 1,
                                 coeffs: coeffs, droppedNodes: 0)
    }

    @Test func reproducesNOAASeattlePredictions() {
        // Six NOAA hourly predictions (UTC epoch, height m MLLW), chosen so
        // the tolerance discriminates the phase convention: at these instants
        // the correct engine (V + u − g) errs ≤ 0.194 m — all of it the
        // 8-vs-34 constituent truncation SwiftValidate quantifies — while the
        // flipped convention (V + u + g) errs 0.95…1.85 m. Tolerance 0.30 m:
        // headroom over the dataset-wide truncation ceiling (0.255 m), a
        // 3×–6× margin below the flipped-sign error.
        let noaa: [(epoch: Double, height: Double)] = [
            (1_705_309_200, -2.438),   // 2024-01-15 09:00
            (1_705_341_600, +1.496),   // 2024-01-15 18:00
            (1_705_420_800, +1.811),   // 2024-01-16 16:00
            (1_705_424_400, +1.927),   // 2024-01-16 17:00
            (1_705_460_400, +0.312),   // 2024-01-17 03:00
            (1_705_500_000, +0.264),   // 2024-01-17 14:00
        ]
        let field = Self.seattleField()
        for point in noaa {
            let terms = TidalHarmonics.synthesisTerms(at: Date(timeIntervalSince1970: point.epoch))
            let (u, v) = field.velocity(ofNode: 0, terms: terms)
            #expect(v == 0)   // nothing packed into V
            #expect(abs(u - point.height) < 0.30,
                    "epoch \(Int(point.epoch)): predicted \(u), NOAA \(point.height)")
        }
    }

    // The NOAA comparison above can't resolve f/u errors on its own — the
    // constituent-truncation noise (~0.13 m RMS) swamps the few-cm nodal
    // modulation — so pin those directly against golden values computed from
    // the Schureman approximations at N = 20.136962680193° (the ascending-
    // node longitude on 2024-01-15, matching the NOAA window above).

    @Test func nodalFactorsMatchSchuremanAtReferenceNode() {
        let N = 20.136962680192994
        // (name, f, u°). f is far from 1 here (K2: 1.299, O1: 1.173) — an
        // engine that silently defaulted f to 1 or dropped u fails these.
        let expected: [(name: String, f: Double, u: Double)] = [
            ("M2", 0.9655326536857621, -0.7367280671867168),
            ("S2", 1.0, 0.0),                                 // solar: no modulation
            ("N2", 0.9655326536857621, -0.7367280671867168),  // shares M2's factors
            ("K2", 1.2992317447330088, -5.66768812855705),
            ("K1", 1.1072562499456995, -2.6106109151841324),
            ("O1", 1.1733474674027178, 2.8518337554519593),
            ("P1", 1.0, 0.0),                                 // solar: no modulation
            ("Q1", 1.1733474674027178, 2.8518337554519593),   // shares O1's factors
        ]
        for e in expected {
            let (f, u) = TidalHarmonics.nodeFactors(e.name, N)
            #expect(abs(f - e.f) < 1e-6, "\(e.name) f")
            #expect(abs(u - e.u) < 1e-6, "\(e.name) u")
        }
    }

    @Test func astroAndSynthesisTermsMatchGoldenValues() {
        // Golden mean longitudes at 2024-01-15 00:00 UTC (the reference
        // window's first instant), from the Meeus polynomial the engine
        // ports; 1e-6° tolerance absorbs any libm/ordering jitter while
        // pinning the values to well under a second of tidal phase.
        let date = Date(timeIntervalSince1970: 1_705_276_800)
        let a = TidalHarmonics.astro(date)
        #expect(abs(a.tau - 313.4681495863915) < 1e-6)
        #expect(abs(a.s - 340.48929631727515) < 1e-6)
        #expect(abs(a.h - 293.95744590366667) < 1e-6)
        #expect(abs(a.p - 341.42048121285416) < 1e-6)
        #expect(abs(a.N - 20.136962680192994) < 1e-6)
        #expect(abs(a.pp - 283.3506591416755) < 1e-6)

        // And the hoisted terms carry f AND arg = V + u (u with its sign —
        // arg is deliberately un-normalised; cos is periodic):
        //   M2 (index 0): V = 626.936299…, u = −0.736728… → 626.199571…
        //   K1 (index 4): V = 743.957446…, u = −2.610611… → 741.346835…
        let terms = TidalHarmonics.synthesisTerms(at: date)
        #expect(terms.count == TidalHarmonics.constituents.count)
        #expect(abs(terms[0].f - 0.9655326536857621) < 1e-6)
        #expect(abs(terms[0].arg - 626.1995711055963) < 1e-6)
        #expect(abs(terms[4].f - 1.1072562499456995) < 1e-6)
        #expect(abs(terms[4].arg - 741.3468349884826) < 1e-6)
    }
}
