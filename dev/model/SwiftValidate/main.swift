import Foundation

// Validates the Swift TidalHarmonics engine against NOAA Seattle predictions —
// the same check tidepredict.py runs, so the Swift port must reproduce the
// Python numbers (corr ~0.997, RMS ~0.128 m). Compile together with the engine:
//   swiftc SalishTides/CurrentModel/TidalHarmonics.swift \
//          SalishTides/CurrentModel/TidalCurrentField.swift \
//          SalishTides/Models/AtlasIndex.swift \
//          dev/model/SwiftValidate/main.swift -o /tmp/validate

// Scalar synthesis for the NOAA tide-height check. Lives here (not in the app
// target) because the app never synthesizes a scalar series — the shipping
// path is TidalCurrentField.velocity, exercised by the smoke test below via
// the same astro/nodeFactors/equilibrium engine.
struct Term {
    let amp: Double      // component amplitude (m for tide height)
    let phase: Double    // Greenwich phase lag g (degrees)
}

func value(of terms: [(String, Term)], at date: Date) -> Double {
    let a = TidalHarmonics.astro(date)
    let byName = Dictionary(uniqueKeysWithValues: TidalHarmonics.constituents.map { ($0.name, $0) })
    var total = 0.0
    for (name, term) in terms {
        guard let c = byName[name] else { continue }
        let (f, u) = TidalHarmonics.nodeFactors(name, a.N)
        let V = TidalHarmonics.equilibrium(c, a)
        total += f * term.amp * cos((V + u - term.phase) * .pi / 180)
    }
    return total
}

struct Ref: Decodable {
    struct Con: Decodable { let name: String; let amp: Double; let phase: Double }
    struct Pred: Decodable { let t: String; let v: Double }
    let constituents: [Con]
    let predictions: [Pred]
}

let url = URL(fileURLWithPath: "dev/model/noaa_seattle_ref.json")
let ref = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: url))

let names = Set(TidalHarmonics.constituents.map { $0.name })
let terms = ref.constituents
    .filter { names.contains($0.name) }
    .map { ($0.name, Term(amp: $0.amp, phase: $0.phase)) }
print("Swift predicting Seattle with \(terms.count) constituents: \(terms.map { $0.0 })")

let cal = Calendar(identifier: .gregorian)
func parse(_ s: String) -> Date {
    // "2024-01-15 00:00" UTC
    let p = s.split { $0 == " " || $0 == "-" || $0 == ":" }.map { Int($0)! }
    var c = DateComponents()
    c.timeZone = TimeZone(identifier: "UTC")
    c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = p[3]; c.minute = p[4]
    var c2 = cal; c2.timeZone = TimeZone(identifier: "UTC")!
    return c2.date(from: c)!
}

var obs: [Double] = [], pred: [Double] = []
for p in ref.predictions {
    obs.append(p.v)
    pred.append(value(of: terms, at: parse(p.t)))
}

let n = Double(obs.count)
let mo = obs.reduce(0,+)/n, mp = pred.reduce(0,+)/n
let cov = zip(obs,pred).map { ($0-mo)*($1-mp) }.reduce(0,+)
let so = (obs.map { ($0-mo)*($0-mo) }.reduce(0,+)).squareRoot()
let sp = (pred.map { ($0-mp)*($0-mp) }.reduce(0,+)).squareRoot()
let corr = cov/(so*sp)
let sqErr: [Double] = zip(obs,pred).map { let d = $0-$1; return d*d }
let rms = (sqErr.reduce(0,+)/n).squareRoot()
let bias = zip(obs,pred).map { $1-$0 }.reduce(0,+)/n
print(String(format: "vs NOAA over %d hourly steps:", obs.count))
print(String(format: "  correlation = %.4f   RMS = %.3f m   bias = %+.3f m", corr, rms, bias))
print("  first 6h obs vs pred:")
for i in 0..<6 {
    print(String(format: "    %@  obs=%+.3f  pred=%+.3f", ref.predictions[i].t, obs[i], pred[i]))
}

// --- Vector (U/V) path smoke test -------------------------------------------
// A single-node field with one M2 constituent; the synthesized current must
// pulse over a tidal cycle. This exercises the exact shipping path —
// TidalCurrentField.velocity(ofNode:terms:) with hoisted synthesisTerms —
// that OfflineCurrentModel renders through.
print("\nVector path smoke test (synthetic M2 field):")
var coeffs = [Double](repeating: 0, count: TidalCurrentField.coeffStride)
coeffs[2] = 0.5   // M2 uAmp (M2 is index 0 in TidalHarmonics.constituents)
coeffs[3] = 0     // M2 uPhase
coeffs[4] = 0.3   // M2 vAmp
coeffs[5] = 90    // M2 vPhase
let field = TidalCurrentField(lat0: 48.7, lon0: -122.6, dLat: 0.01, dLon: 0.01,
                              rows: 1, cols: 1, nodeIndex: [0], nodeCount: 1,
                              coeffs: coeffs, droppedNodes: 0)
let base = parse("2024-01-15 00:00")
var speeds: [Double] = []
for hr in stride(from: 0, through: 12, by: 2) {
    let t = base.addingTimeInterval(Double(hr) * 3600)
    let synthTerms = TidalHarmonics.synthesisTerms(at: t)
    let (u, v) = field.velocity(ofNode: 0, terms: synthTerms)
    let speed = (u*u + v*v).squareRoot()
    speeds.append(speed)
    print(String(format: "  +%2dh  u=%+.3f v=%+.3f  speed=%.3f m/s", hr, u, v, speed))
}
let varied = (speeds.max() ?? 0) - (speeds.min() ?? 0) > 0.1
print("  pulses over the cycle: \(varied ? "yes ✓" : "no ✗")")
