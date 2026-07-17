import Foundation

/// Derives the flood/ebb tendency of the tidal current at a location from a
/// harmonic-model velocity series and the predicted tide curve. Pure and
/// stateless so it's unit-testable without the model actor, the bundle, or a
/// database.
///
/// The idea: at most coastal locations the tidal current is rectilinear — it
/// runs one way while the tide rises (flood) and the opposite way while it
/// falls (ebb), with a location-specific lag that makes "is the tide rising?"
/// alone the wrong answer by up to hours in the passes. So we learn the local
/// flood DIRECTION by correlating a day of model velocities with the tide's
/// rise/fall, then classify the instantaneous current by which way it points
/// along that axis. Where the correlation is weak (rotary offshore tides,
/// near-slack flow) we fall back to the tide height's own direction.
enum CurrentPhaseEstimator {

    /// One velocity sample of the local series.
    struct Sample: Sendable {
        let t: Date
        let u: Double   // east, m/s
        let v: Double   // north, m/s
    }

    /// The learned flood axis at a location: a unit vector plus how cleanly
    /// the series separated along it. Cacheable — it drifts only on the
    /// spring/neap scale, so a day of validity is plenty.
    struct FloodDirection: Sendable, Equatable {
        let east: Double
        let north: Double
        /// |Σrising − Σfalling| / Σ|v| ∈ [0, 1]: ~1 for a rectilinear current
        /// in lockstep with the tide, → 0 for rotary or tide-uncorrelated flow.
        let quality: Double
    }

    /// Below this separation quality the flood axis is noise — use the tide
    /// height's direction instead. Pinned by CurrentPhaseEstimatorTests.
    static let qualityThreshold = 0.4
    /// Below this speed (m/s) the "now" vector's sign is numerically
    /// meaningless (near slack) — fall back rather than flip randomly.
    static let minSpeed = 0.03
    /// Half-step (seconds) of the central difference used for dh/dt.
    private static let riseStep: TimeInterval = 900

    /// The flood axis learned from `samples` (ideally ~25 hourly points
    /// spanning a full tidal day) against the tide curve `heightAt`. nil when
    /// the series or the curve can't support one (no samples, flat tide,
    /// all-slack water).
    ///
    /// Summing rising-tide velocities MINUS falling-tide velocities doubles
    /// the tidal signal while strongly suppressing steady residual flow
    /// (river outflow would otherwise drag the axis toward the river mouth).
    /// Suppression is near-total, not exact: the residual survives scaled by
    /// the rising/falling sample-count imbalance, at most a few samples of
    /// the 25 — pinned by the residual test's tolerance.
    static func floodDirection(samples: [Sample],
                               heightAt: (Date) -> Double?) -> FloodDirection? {
        var east = 0.0, north = 0.0, total = 0.0
        for s in samples {
            guard let rising = isRising(at: s.t, heightAt: heightAt) else { continue }
            let sign = rising ? 1.0 : -1.0
            east += sign * s.u
            north += sign * s.v
            total += (s.u * s.u + s.v * s.v).squareRoot()
        }
        let mag = (east * east + north * north).squareRoot()
        guard total > 0, mag > 0 else { return nil }
        return FloodDirection(east: east / mag, north: north / mag,
                              quality: mag / total)
    }

    /// Classify the instantaneous current `(u, v)` at `date`. Falls back to
    /// the tide height's direction when the flood axis is missing/weak or the
    /// flow is near slack; nil only when the tide curve is unavailable too —
    /// callers hide the phase row then.
    static func phase(u: Double, v: Double, at date: Date,
                      floodDirection: FloodDirection?,
                      heightAt: (Date) -> Double?) -> CurrentPhase? {
        if let dir = floodDirection, dir.quality >= qualityThreshold,
           (u * u + v * v).squareRoot() >= minSpeed {
            let along = u * dir.east + v * dir.north
            return CurrentPhase(tendency: along > 0 ? .flood : .ebb,
                                strength: nil, basis: .currentCorrelation)
        }
        guard let rising = isRising(at: date, heightAt: heightAt) else { return nil }
        return CurrentPhase(tendency: rising ? .flood : .ebb,
                            strength: nil, basis: .tideHeight)
    }

    /// Central-difference sign of dh/dt at `t`; nil when the curve has no
    /// value on either side. Exactly at an extremum the difference is ~0 and
    /// classifies as falling — a coin flip either way for the one instant the
    /// tide is turning.
    private static func isRising(at t: Date, heightAt: (Date) -> Double?) -> Bool? {
        guard let before = heightAt(t.addingTimeInterval(-riseStep)),
              let after = heightAt(t.addingTimeInterval(riseStep)) else { return nil }
        return after > before
    }
}
