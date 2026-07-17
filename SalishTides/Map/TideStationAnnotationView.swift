import SwiftUI
import UIKit
import MapLibre

/// The tide station feeding the phase card, as a map annotation. Exactly one
/// exists at a time — the nearest station to the crosshair (the same one
/// MapViewModel.updateTides resolves) — and the coordinator swaps the whole
/// annotation when that station changes rather than moving it, so MapLibre
/// never has to KVO-track a coordinate change.
final class TideStationAnnotation: NSObject, MLNAnnotation {
    let coordinate: CLLocationCoordinate2D
    let stationID: String
    /// Display-normalised station name (first locality segment, Title-Cased).
    let name: String

    init(station: TideStation) {
        self.coordinate = CLLocationCoordinate2D(latitude: station.lat, longitude: station.lon)
        self.stationID = station.id
        self.name = station.name.stationDisplayName
    }
}

/// Marker for the tide station driving the phase card: a neutral badge carrying
/// a tendency arrow (↑ flood / ↓ ebb, matching the phase card's arrow) over a
/// slowly pulsing ring — glyph-marked and ink-neutral, so it reads as chrome
/// rather than data and can't be mistaken for the plain blue user-location dot
/// — plus a name pill revealed on tap (MapLibre selection) or when the
/// crosshair centres on the station (see the coordinator's proximity check).
final class TideStationAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "tide-station"

    // 44 pt hit target (HIG minimum) around a 26 pt badge; the pulse ring and
    // the name pill draw outside the bounds (clipsToBounds = false), which is
    // fine — neither needs to be tappable.
    private static let hitSize: CGFloat = 44
    private static let badgeSize: CGFloat = 26
    private static let pulseRadius: CGFloat = 13
    private static let pulseScale: CGFloat = 2.2

    private let pulseLayer = CAShapeLayer()
    private let badge = UIView()
    private let glyph = UIImageView()
    private let labelPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let nameLabel = UILabel()

    // The two independent reveal triggers for the name pill. Selection is
    // MapLibre's tap-to-select (tap the badge → select, tap open water →
    // deselect); nearCrosshair is pushed by the coordinator's screen-space
    // proximity check while the map moves.
    private var nearCrosshair = false

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.hitSize, height: Self.hitSize)
        clipsToBounds = false

        // Pulse ring behind the badge, centred; scale + fade animate from this
        // base geometry. Colour is set in applyColors (CGColor doesn't adapt).
        let r = Self.pulseRadius
        pulseLayer.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).cgPath
        pulseLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.addSublayer(pulseLayer)

        badge.frame = CGRect(x: (Self.hitSize - Self.badgeSize) / 2,
                             y: (Self.hitSize - Self.badgeSize) / 2,
                             width: Self.badgeSize, height: Self.badgeSize)
        badge.backgroundColor = .stationMarker
        badge.layer.cornerRadius = Self.badgeSize / 2
        // Muted rim: themed ink at low alpha (set in applyColors), so the
        // marker separates from the basemap without popping like a bright pin.
        badge.layer.borderWidth = 1.5
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = 0.3
        badge.layer.shadowRadius = 3
        badge.layer.shadowOffset = CGSize(width: 0, height: 1)
        badge.isUserInteractionEnabled = false
        addSubview(badge)

        glyph.image = Self.glyphImage(for: nil)
        // Themed ink: light on the deep Night fill, dark on the Day slate —
        // readable without the badge having to be bright.
        glyph.tintColor = .label
        glyph.contentMode = .center
        glyph.frame = badge.bounds
        badge.addSubview(glyph)

        // Name pill: a small glass capsule above the badge, echoing the app's
        // floating-card surfaces (ultra-thin material + hairline edge) and the
        // phase card's caption type. Hidden until selected / crosshair-near.
        nameLabel.font = .stCaption
        nameLabel.textColor = .label
        nameLabel.textAlignment = .center
        labelPill.layer.cornerCurve = .continuous
        labelPill.layer.borderWidth = Elevation.cardBorderWidth
        labelPill.layer.borderColor = UIColor(Elevation.cardBorderColor).cgColor
        labelPill.clipsToBounds = true
        labelPill.contentView.addSubview(nameLabel)
        labelPill.alpha = 0
        addSubview(labelPill)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "The tide chart shows predictions for this station."

        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.applyColors()
        }

        // CAAnimations are dropped whenever the layer leaves the render tree
        // (backgrounding included — didMoveToWindow doesn't fire for that), so
        // restart on foreground; also restart/stop when Reduce Motion flips.
        // Selector-based observers self-remove on dealloc; both notifications
        // post on the main thread, matching this class's MainActor isolation.
        for name in [UIApplication.didBecomeActiveNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(pulseNeedsRestart),
                                                   name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pulseNeedsRestart() { startPulse() }

    /// The tide/current tendency shown on the badge — ↑ flood, ↓ ebb, a
    /// neutral ↕ while unknown (no selection yet). Kept in lockstep with the
    /// phase card's arrow by the coordinator as the user scrubs the timeline.
    func setTendency(_ tendency: CurrentPhase.Tendency?) {
        guard tendency != appliedTendency else { return }
        appliedTendency = tendency
        glyph.image = Self.glyphImage(for: tendency)
    }

    // Starts as a value setTendency can never receive, so the first real
    // tendency (including nil) always applies.
    private var appliedTendency: CurrentPhase.Tendency?? = CurrentPhase.Tendency??.none

    private static func glyphImage(for tendency: CurrentPhase.Tendency?) -> UIImage? {
        let name = switch tendency {
        case .flood: "arrow.up"
        case .ebb: "arrow.down"
        case nil: "arrow.up.and.down"
        }
        return UIImage(systemName: name,
                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    }

    func configure(name: String) {
        nameLabel.text = name
        accessibilityLabel = "Tide station: \(name)"
        // Same insets as the status pills (§ContentView): sm horizontal, xs
        // vertical, capsule corner.
        let size = nameLabel.intrinsicContentSize
        let w = size.width + 2 * Spacing.sm, h = size.height + 2 * Spacing.xs
        nameLabel.frame = CGRect(x: 0, y: 0, width: w, height: h)
        // Centred above the badge, clear of the pulse ring at full scale.
        // bounds + center, not frame: the reveal animation leaves a translation
        // transform on the pill, and frame is undefined under a transform.
        labelPill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        labelPill.center = CGPoint(x: bounds.midX,
                                   y: badge.frame.minY - Spacing.sm - h / 2)
        labelPill.layer.cornerRadius = h / 2
    }

    /// Pushed by the coordinator's screen-space proximity check as the map
    /// moves: true while the crosshair sits within its reticle of the station.
    func setNearCrosshair(_ near: Bool) {
        guard near != nearCrosshair else { return }
        nearCrosshair = near
        updatePillVisibility(animated: true)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updatePillVisibility(animated: animated)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nearCrosshair = false
        labelPill.alpha = 0
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPulse() }
    }

    private func updatePillVisibility(animated: Bool) {
        let visible = isSelected || nearCrosshair
        let animations = {
            self.labelPill.alpha = visible ? 1 : 0
            self.labelPill.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 3)
        }
        animated ? UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut,
                                  animations: animations)
                 : animations()
    }

    private func applyColors() {
        pulseLayer.fillColor = UIColor.stationMarker.resolvedColor(with: traitCollection).cgColor
        badge.layer.borderColor = UIColor.label.resolvedColor(with: traitCollection)
            .withAlphaComponent(0.4).cgColor
    }

    /// (Re)arms the pulse: a slow expanding ring fading out from the badge.
    /// With Reduce Motion on, the ring holds still as a faint halo instead —
    /// the marker stays visually distinct without the animation.
    private func startPulse() {
        pulseLayer.removeAnimation(forKey: "pulse")
        guard !UIAccessibility.isReduceMotionEnabled else {
            pulseLayer.opacity = 0.18
            pulseLayer.transform = CATransform3DMakeScale(1.5, 1.5, 1)
            return
        }
        pulseLayer.transform = CATransform3DIdentity

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = Self.pulseScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 2.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.opacity = 0  // rest state between/under the animation
        pulseLayer.add(group, forKey: "pulse")
    }
}
