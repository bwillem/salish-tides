import Foundation

struct CurrentVector: Codable, Sendable, Equatable {
    let lat: Double
    let lon: Double
    let speed_ms: Double
    let direction_deg: Double

    var speedKnots: Double { speed_ms * 1.944 }

    // Cull near-zero vectors — they're visual noise
    var isSignificant: Bool { speed_ms >= 0.02 }
}
