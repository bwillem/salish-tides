import Foundation

// Validates the Swift TidalHarmonics engine against NOAA Seattle predictions —
// the same check tidepredict.py runs, so the Swift port must reproduce the
// Python numbers (corr ~0.997, RMS ~0.128 m). Compile together with the engine:
//   swiftc SalishTides/CurrentModel/TidalHarmonics.swift dev/model/SwiftValidate/main.swift -o /tmp/validate

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
    .map { ($0.name, TidalHarmonics.Term(amp: $0.amp, phase: $0.phase)) }
print("Swift predicting Seattle with \(terms.count) constituents: \(terms.map { $0.0 })")

var fmt = DateComponents()
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
_ = fmt

var obs: [Double] = [], pred: [Double] = []
for p in ref.predictions {
    obs.append(p.v)
    pred.append(TidalHarmonics.value(of: terms, at: parse(p.t)))
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

// --- Vector (U/V) path + grid sampler smoke test ---------------------------
// A uniform 2×2 field with a single M2 constituent; check the synthesized
// current rotates/pulses over a tidal cycle and that bilinear sampling at the
// centre returns a finite vector.
print("\nVector path smoke test (synthetic M2 field):")
let m2 = TidalCurrentField.NodeConstituent(uAmp: 0.5, uPhase: 0, vAmp: 0.3, vPhase: 90)
let node = TidalCurrentField.Node(constituents: ["M2": m2])
let field = TidalCurrentField(lat0: 48.7, lon0: -122.6, dLat: 0.01, dLon: 0.01,
                              rows: 2, cols: 2, nodes: [node, node, node, node])
let base = parse("2024-01-15 00:00")
var speeds: [Double] = []
for hr in stride(from: 0, through: 12, by: 2) {
    let t = base.addingTimeInterval(Double(hr) * 3600)
    if let cur = field.current(lat: 48.705, lon: -122.595, at: t) {
        speeds.append(cur.speed_ms)
        print(String(format: "  +%2dh  speed=%.3f m/s  dir=%5.1f°", hr, cur.speed_ms, cur.direction_deg))
    }
}
let varied = (speeds.max() ?? 0) - (speeds.min() ?? 0) > 0.1
print("  pulses over the cycle: \(varied ? "yes ✓" : "no ✗")")
