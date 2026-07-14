import Foundation

/// On-device harmonic tidal predictor.
///
/// Turns a set of harmonic constituents (amplitude + Greenwich phase) into a
/// value at any instant — the same math as XTide/utide, applied here to the
/// east (U) and north (V) current components so we can synthesize a current
/// vector anywhere, any time, fully offline.
///
/// The astronomical engine (Doodson equilibrium argument + nodal corrections)
/// was developed and validated in Python against NOAA's published tide
/// predictions (correlation 0.997 over the 8 major constituents) and ported
/// here verbatim; `dev/model/tidepredict.py` is the reference, and the Swift
/// port is checked against the same NOAA dataset in `dev/model/SwiftValidate`.
///
/// All state is immutable, so the type is trivially `Sendable` / thread-safe.
enum TidalHarmonics {

    /// The eight major constituents the SalishSeaCast / Foreman model resolves.
    /// `doodson` are the coefficients on (τ, s, h, p, N, pp); `offset` is the
    /// species phase constant in quarter-circles (×90°).
    struct Constituent: Sendable {
        let name: String
        let doodson: (Double, Double, Double, Double, Double, Double)
        let offset: Double
    }

    static let constituents: [Constituent] = [
        Constituent(name: "M2", doodson: (2,  0,  0, 0, 0, 0), offset:  0),
        Constituent(name: "S2", doodson: (2,  2, -2, 0, 0, 0), offset:  0),
        Constituent(name: "N2", doodson: (2, -1,  0, 1, 0, 0), offset:  0),
        Constituent(name: "K2", doodson: (2,  2,  0, 0, 0, 0), offset:  0),
        Constituent(name: "K1", doodson: (1,  1,  0, 0, 0, 0), offset:  1),
        Constituent(name: "O1", doodson: (1, -1,  0, 0, 0, 0), offset: -1),
        Constituent(name: "P1", doodson: (1,  1, -2, 0, 0, 0), offset: -1),
        Constituent(name: "Q1", doodson: (1, -2,  0, 1, 0, 0), offset: -1),
    ]

    /// Mean astronomical longitudes (degrees) plus mean lunar time τ at `date`.
    struct Astro: Sendable {
        let tau, s, h, p, N, pp: Double
    }

    private static func deg2rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func cosd(_ d: Double) -> Double { cos(deg2rad(d)) }
    private static func sind(_ d: Double) -> Double { sin(deg2rad(d)) }
    private static func mod360(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r
    }

    static func astro(_ date: Date) -> Astro {
        // Unix epoch (1970-01-01 00:00 UTC) = Julian Day 2440587.5
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let T = (jd - 2451545.0) / 36525.0
        let s  = 218.3164477 + 481267.88123421 * T   // moon mean longitude
        let h  = 280.4664490 + 36000.7698231  * T    // sun mean longitude
        let p  = 83.3532430  + 4069.0137110   * T    // lunar perigee
        let N  = 125.0445479 - 1934.1362891   * T    // ascending node
        let pp = 282.9373348 + 1.7195366      * T    // solar perigee
        // UT hour-of-day
        let dayFrac = date.timeIntervalSince1970 / 86400.0
        let ut = (dayFrac - floor(dayFrac)) * 24.0
        let tau = 15.0 * ut - s + h                  // mean lunar time
        return Astro(tau: mod360(tau), s: mod360(s), h: mod360(h),
                     p: mod360(p), N: mod360(N), pp: mod360(pp))
    }

    /// Approximate Schureman nodal amplitude factor `f` and phase `u` (degrees)
    /// as a function of the ascending-node longitude `N` (degrees).
    static func nodeFactors(_ name: String, _ N: Double) -> (f: Double, u: Double) {
        switch name {
        case "M2", "N2":
            return (1.0004 - 0.0373 * cosd(N) + 0.0002 * cosd(2*N), -2.14 * sind(N))
        case "K2":
            return (1.0241 + 0.2863 * cosd(N) + 0.0083 * cosd(2*N),
                    -17.74 * sind(N) + 0.68 * sind(2*N))
        case "K1":
            return (1.0060 + 0.1150 * cosd(N) - 0.0088 * cosd(2*N),
                    -8.86 * sind(N) + 0.68 * sind(2*N))
        case "O1", "Q1":
            return (1.0089 + 0.1871 * cosd(N) - 0.0147 * cosd(2*N),
                    10.80 * sind(N) - 1.34 * sind(2*N))
        default:
            return (1.0, 0.0)   // S2, P1 — solar, no nodal modulation
        }
    }

    /// Equilibrium argument V (degrees) for a constituent at `a`.
    static func equilibrium(_ c: Constituent, _ a: Astro) -> Double {
        let d = c.doodson
        return d.0*a.tau + d.1*a.s + d.2*a.h + d.3*a.p + d.4*a.N + d.5*a.pp
             + c.offset * 90.0
    }

    /// Date-dependent factors for every constituent (in `constituents` order),
    /// hoisted once per synthesis pass: nodal amplitude factor `f` and the full
    /// phase argument `V + u` (degrees). A node's contribution is then just
    /// `f·A·cos(arg − g)` per component — see `TidalCurrentField.velocity`.
    struct SynthesisTerm: Sendable {
        let f: Double
        let arg: Double
    }

    static func synthesisTerms(at date: Date) -> [SynthesisTerm] {
        let a = astro(date)
        return constituents.map { c in
            let (f, u) = nodeFactors(c.name, a.N)
            return SynthesisTerm(f: f, arg: equilibrium(c, a) + u)
        }
    }
}
