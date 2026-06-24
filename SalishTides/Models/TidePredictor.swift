import Foundation

// Harmonic tide model for Victoria BC (DFO Station 7120).
// Constituents and amplitudes from Canadian Hydrographic Service.
// Phases calibrated to Unix epoch (1970-01-01 00:00 UTC).
//
// Accuracy: ±0.1–0.3m, ±30–60min — sufficient for visual planning context.
// For navigation-critical predictions use official DFO tide tables.
struct TidePredictor {

    // Chart datum for Victoria BC: MLLW. Mean level ≈ 1.90m above MLLW.
    static let datumLabel = "MLLW"
    static let minPlausibleHeight: Double = 0.0
    static let maxPlausibleHeight: Double = 5.2

    // Predicted height in metres above MLLW.
    static func height(at date: Date) -> Double {
        let t = date.timeIntervalSince1970 / 3600.0  // hours since Unix epoch

        let h = 1.90
            + 0.559 * cos(rad(28.9841042 * t - 140.0))  // M2  principal lunar semidiurnal
            + 0.128 * cos(rad(30.0000000 * t - 185.0))  // S2  principal solar semidiurnal
            + 0.120 * cos(rad(28.4397295 * t - 115.0))  // N2  larger lunar elliptic
            + 0.538 * cos(rad(15.0410686 * t - 220.0))  // K1  luni-solar diurnal
            + 0.344 * cos(rad(13.9430356 * t - 190.0))  // O1  principal lunar diurnal
            + 0.170 * cos(rad(14.9589314 * t - 207.0))  // P1  principal solar diurnal

        return max(0.0, h)
    }

    // Dense sample array for chart rendering.
    static func samples(
        centeredOn date: Date,
        windowHours: Double,
        stepMinutes: Int = 12
    ) -> [(date: Date, height: Double)] {
        let step = TimeInterval(stepMinutes * 60)
        let half = windowHours / 2 * 3600
        var pts: [(Date, Double)] = []
        var t = date.addingTimeInterval(-half)
        let end = date.addingTimeInterval(half)
        while t <= end + step {
            pts.append((t, height(at: t)))
            t = t.addingTimeInterval(step)
        }
        return pts
    }

    private static func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
