import Foundation
import UIKit

struct CurrentVector: Codable, Sendable {
    let lat: Double
    let lon: Double
    let speed_ms: Double
    let direction_deg: Double

    var speedKnots: Double { speed_ms * 1.944 }

    // Cull near-zero vectors — they're visual noise
    var isSignificant: Bool { speed_ms >= 0.02 }
}

extension CurrentVector {
    var lineColor: UIColor {
        switch speedKnots {
        case ..<0.5:  return UIColor(red: 0.13, green: 0.40, blue: 0.67, alpha: 1)
        case ..<1.5:  return UIColor(red: 0.45, green: 0.68, blue: 0.82, alpha: 1)
        case ..<3.0:  return UIColor(red: 1.00, green: 1.00, blue: 0.75, alpha: 1)
        case ..<4.5:  return UIColor(red: 0.96, green: 0.43, blue: 0.26, alpha: 1)
        default:      return UIColor(red: 0.84, green: 0.19, blue: 0.15, alpha: 1)
        }
    }

    var lineWidth: Double { max(1.0, min(3.0, speedKnots * 0.8)) }
}

extension UIColor {
    var rgbaComponents: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}
