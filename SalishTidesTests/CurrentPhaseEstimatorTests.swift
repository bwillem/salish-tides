import Foundation
import Testing
@testable import SalishTides

/// Pins the flood/ebb estimator on synthetic tides and currents: a
/// rectilinear tide-locked current must classify by direction, residual flow
/// must not bias the learned axis, and anything the correlation can't call
/// must fall back to the tide curve — never flip on noise.
struct CurrentPhaseEstimatorTests {

    /// One M2-ish cycle: 12.42 h. All scenarios share it.
    private static let period: TimeInterval = 12.42 * 3600
    private static let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Synthetic tide h(t) = cos(2πt/T): falls over the first half-period,
    /// rises over the second.
    private func height(at t: Date) -> Double? {
        cos(2 * .pi * t.timeIntervalSince(Self.t0) / Self.period)
    }

    /// 25 hourly samples spanning ±12 h of `center`, the window MapViewModel
    /// feeds the estimator.
    private func samples(around center: Date,
                         velocity: (Date) -> (u: Double, v: Double)) -> [CurrentPhaseEstimator.Sample] {
        (-12...12).map { hr in
            let t = center.addingTimeInterval(Double(hr) * 3600)
            let (u, v) = velocity(t)
            return CurrentPhaseEstimator.Sample(t: t, u: u, v: v)
        }
    }

    /// Rectilinear current locked to the tide: flows toward (1, 0.5)·k while
    /// the tide rises, reverses while it falls, amplitude 1 m/s.
    private func tideLocked(_ t: Date) -> (u: Double, v: Double) {
        let s = -sin(2 * .pi * t.timeIntervalSince(Self.t0) / Self.period)
        return (u: s / 1.118, v: 0.5 * s / 1.118)   // unit-speed axis (1, 0.5)/|·|
    }

    @Test func tideLockedCurrentClassifiesByDirection() throws {
        let center = Self.t0.addingTimeInterval(Self.period)   // arbitrary
        let dir = CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: tideLocked), heightAt: height)
        let d = try #require(dir)
        // Clean rectilinear separation: quality ~1, axis ≈ (1, 0.5) normalized.
        #expect(d.quality > 0.9)
        #expect(abs(d.east - 0.894) < 0.02 && abs(d.north - 0.447) < 0.02)

        // Mid-rise (t = 0.75 T): strong flood. Mid-fall (t = 0.25 T): strong ebb.
        let rise = Self.t0.addingTimeInterval(0.75 * Self.period)
        let fall = Self.t0.addingTimeInterval(0.25 * Self.period)
        for (t, expected): (Date, CurrentPhase.Tendency) in [(rise, .flood), (fall, .ebb)] {
            let (u, v) = tideLocked(t)
            let phase = CurrentPhaseEstimator.phase(u: u, v: v, at: t,
                                                    floodDirection: d, heightAt: height)
            #expect(phase == CurrentPhase(tendency: expected, strength: nil,
                                          basis: .currentCorrelation))
        }
    }

    @Test func reversedCurrentLearnsReversedAxis() throws {
        // Same current with the axis flipped: the learned flood direction must
        // flip with it, so the tendency at a rising instant is STILL flood.
        let reversed = { (t: Date) -> (u: Double, v: Double) in
            let (u, v) = self.tideLocked(t)
            return (-u, -v)
        }
        let center = Self.t0.addingTimeInterval(Self.period)
        let d = try #require(CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: reversed), heightAt: height))
        #expect(d.east < -0.85)   // axis flipped

        let rise = Self.t0.addingTimeInterval(0.75 * Self.period)
        let (u, v) = reversed(rise)
        let phase = CurrentPhaseEstimator.phase(u: u, v: v, at: rise,
                                                floodDirection: d, heightAt: height)
        #expect(phase?.tendency == .flood)
        #expect(phase?.basis == .currentCorrelation)
    }

    @Test func residualFlowCancelsOutOfTheAxis() throws {
        // A strong steady set (0.5 m/s due north) rides on the tidal signal.
        // Rising-minus-falling summation must cancel it: same axis, and the
        // tendency at mid-fall stays ebb even though the raw vector is bent.
        let withResidual = { (t: Date) -> (u: Double, v: Double) in
            let (u, v) = self.tideLocked(t)
            return (u, v + 0.5)
        }
        let center = Self.t0.addingTimeInterval(Self.period)
        let d = try #require(CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: withResidual), heightAt: height))
        #expect(abs(d.east - 0.894) < 0.05 && abs(d.north - 0.447) < 0.05)

        let fall = Self.t0.addingTimeInterval(0.25 * Self.period)
        let (u, v) = withResidual(fall)
        let phase = CurrentPhaseEstimator.phase(u: u, v: v, at: fall,
                                                floodDirection: d, heightAt: height)
        #expect(phase?.tendency == .ebb)
    }

    @Test func tideUncorrelatedCurrentFallsBackToTideHeight() {
        // A current oscillating at TWICE the tide's frequency completes a full
        // cycle inside each rising half — the signed sums wash out, quality
        // collapses, and the phase must come from the tide curve instead.
        let uncorrelated = { (t: Date) -> (u: Double, v: Double) in
            (u: cos(4 * .pi * t.timeIntervalSince(Self.t0) / Self.period), v: 0.0)
        }
        let center = Self.t0.addingTimeInterval(Self.period)
        let d = CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: uncorrelated), heightAt: height)
        if let d { #expect(d.quality < CurrentPhaseEstimator.qualityThreshold) }

        let rise = Self.t0.addingTimeInterval(0.75 * Self.period)
        let (u, v) = uncorrelated(rise)
        let phase = CurrentPhaseEstimator.phase(u: u, v: v, at: rise,
                                                floodDirection: d, heightAt: height)
        #expect(phase == CurrentPhase(tendency: .flood, strength: nil, basis: .tideHeight))
    }

    @Test func nearSlackFallsBackToTideHeight() throws {
        // Good axis, but the instantaneous flow is below minSpeed — its sign is
        // numerically meaningless, so the tide curve decides.
        let center = Self.t0.addingTimeInterval(Self.period)
        let d = try #require(CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: tideLocked), heightAt: height))
        let fall = Self.t0.addingTimeInterval(0.25 * Self.period)
        let phase = CurrentPhaseEstimator.phase(u: 0.001, v: 0.001, at: fall,
                                                floodDirection: d, heightAt: height)
        #expect(phase == CurrentPhase(tendency: .ebb, strength: nil, basis: .tideHeight))
    }

    @Test func noTideCurveMeansNoPhase() {
        let center = Self.t0.addingTimeInterval(Self.period)
        let none: (Date) -> Double? = { _ in nil }
        #expect(CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: tideLocked), heightAt: none) == nil)
        #expect(CurrentPhaseEstimator.phase(u: 1, v: 0, at: center,
                                            floodDirection: nil, heightAt: none) == nil)
    }

    @Test func allSlackWaterYieldsNoAxis() {
        let center = Self.t0.addingTimeInterval(Self.period)
        let still = { (_: Date) -> (u: Double, v: Double) in (0, 0) }
        #expect(CurrentPhaseEstimator.floodDirection(
            samples: samples(around: center, velocity: still), heightAt: height) == nil)
    }
}
