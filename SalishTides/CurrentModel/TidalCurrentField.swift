import Foundation

/// A bundled grid of tidal-current harmonic constituents (one set per water
/// node) plus the on-device sampler that turns it into a current vector at any
/// lat/lon and time. This is the "Model" current source that fills the bays the
/// print atlas doesn't chart; the grid itself is produced offline from
/// SalishSeaCast (or supplied by UBC-MOAD) and packed onto a regular lat/lon
/// mesh so device lookup is a plain bilinear interpolation.
///
/// Synthesis reuses the NOAA-validated `TidalHarmonics` engine, applied to the
/// east (U) and north (V) components.
struct TidalCurrentField: Sendable {

    /// Per-constituent harmonic for one node: amplitude + Greenwich phase for
    /// the east (U) and north (V) current components.
    struct NodeConstituent: Sendable {
        let uAmp, uPhase, vAmp, vPhase: Double
    }

    /// One grid node: its constituents keyed by name (M2, K1, …).
    struct Node: Sendable {
        let constituents: [String: NodeConstituent]
    }

    // Regular lat/lon mesh. `nodes` is row-major: index = row*cols + col,
    // row indexes latitude (lat0 + row*dLat), col indexes longitude.
    let lat0, lon0, dLat, dLon: Double
    let rows, cols: Int
    let nodes: [Node?]            // nil = land / no data

    private func node(_ r: Int, _ c: Int) -> Node? {
        guard r >= 0, r < rows, c >= 0, c < cols else { return nil }
        return nodes[r * cols + c]
    }

    /// Predict the current at one node and time → east/north velocity (m/s).
    static func velocity(_ node: Node, at date: Date) -> (u: Double, v: Double) {
        let a = TidalHarmonics.astro(date)
        var u = 0.0, v = 0.0
        for c in TidalHarmonics.constituents {
            guard let comp = node.constituents[c.name] else { continue }
            let (f, nu) = TidalHarmonics.nodeFactors(c.name, a.N)
            let V = TidalHarmonics.equilibrium(c, a)
            let arg = V + nu
            u += f * comp.uAmp * cos((arg - comp.uPhase) * .pi / 180)
            v += f * comp.vAmp * cos((arg - comp.vPhase) * .pi / 180)
        }
        return (u, v)
    }

    /// Bilinearly-interpolated current at an arbitrary lat/lon and time.
    /// Returns nil if the point isn't surrounded by enough water nodes.
    func current(lat: Double, lon: Double, at date: Date) -> CurrentVector? {
        let fr = (lat - lat0) / dLat
        let fc = (lon - lon0) / dLon
        let r0 = Int(floor(fr)), c0 = Int(floor(fc))
        let tr = fr - Double(r0), tc = fc - Double(c0)

        // Interpolate the predicted U/V (not the raw constituents — phase
        // interpolation is unsafe across wraps), weighting only water corners.
        var su = 0.0, sv = 0.0, sw = 0.0
        let corners = [(r0, c0, (1-tr)*(1-tc)), (r0, c0+1, (1-tr)*tc),
                       (r0+1, c0, tr*(1-tc)),   (r0+1, c0+1, tr*tc)]
        for (r, c, w) in corners {
            guard w > 0, let n = node(r, c) else { continue }
            let (u, v) = Self.velocity(n, at: date)
            su += u * w; sv += v * w; sw += w
        }
        guard sw > 0.5 else { return nil }   // mostly land → no usable current
        let u = su / sw, v = sv / sw
        let speed = (u*u + v*v).squareRoot()
        // Compass bearing the flow is heading toward: 0°=N, 90°=E.
        var dir = atan2(u, v) * 180 / .pi
        if dir < 0 { dir += 360 }
        return CurrentVector(lat: lat, lon: lon, speed_ms: speed, direction_deg: dir)
    }
}
