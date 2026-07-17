import Foundation

/// The tidal-current state around the viewport — flood or ebb — derived on
/// device from the harmonic current model correlated with the predicted tide
/// (see `CurrentPhaseEstimator`). Replaces the print atlas's clock-hour chart
/// lookup as the source of the ↑/↓ indicator on the tide card.
struct CurrentPhase: Sendable, Equatable {
    enum Tendency: Sendable { case flood, ebb }

    /// Reserved for a future strength readout (Small/Medium/Large, in the
    /// spirit of the old atlas chart classes). nil renders as plain
    /// "Flood"/"Ebb" — arrow color/length and the speed card already convey
    /// strength.
    enum Strength: Sendable { case small, medium, large }

    /// How the tendency was decided: correlation of the current with the
    /// rising tide where the flow is rectilinear and tide-locked, or the tide
    /// height's own direction where it isn't (rotary or weak flow). Carried
    /// for logs and tests; the UI renders both identically.
    enum Basis: Sendable { case currentCorrelation, tideHeight }

    let tendency: Tendency
    let strength: Strength?
    let basis: Basis
}
