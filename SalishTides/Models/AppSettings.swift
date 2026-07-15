import SwiftUI
import Observation
import UIKit

// MARK: - Salish Sea local time

extension TimeZone {
    /// Every tide/current time in the app is shown in Salish Sea local time —
    /// the app is region-specific, so times are "local to the water" regardless
    /// of the device's timezone. The underlying data is tz-agnostic (UTC).
    static let salish = TimeZone(identifier: "America/Vancouver")!
}

extension Calendar {
    /// Gregorian calendar fixed to `TimeZone.salish`.
    static let salish: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .salish
        return c
    }()
}

// MARK: - Unit & Appearance Choices

/// Current-speed display unit. Canonical storage everywhere is knots
/// (`CurrentVector.speedKnots`); these convert from knots at the readout.
enum SpeedUnit: String, CaseIterable, Identifiable {
    case knots, kmh, ms

    var id: String { rawValue }

    /// Full name shown in the settings picker.
    var label: String {
        switch self {
        case .knots: "Knots"
        case .kmh:   "Kilometres / hour"
        case .ms:    "Metres / second"
        }
    }

    /// Compact suffix shown next to a value ("3.2 kn").
    var abbreviation: String {
        switch self {
        case .knots: "kn"
        case .kmh:   "km/h"
        case .ms:    "m/s"
        }
    }

    func value(fromKnots knots: Double) -> Double {
        switch self {
        case .knots: knots
        case .kmh:   knots * 1.852
        case .ms:    knots * 0.514444
        }
    }
}

/// Tide-height display unit. Canonical storage is metres (station datum).
enum HeightUnit: String, CaseIterable, Identifiable {
    case metres, feet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .metres: "Metres"
        case .feet:   "Feet"
        }
    }

    var abbreviation: String {
        switch self {
        case .metres: "m"
        case .feet:   "ft"
        }
    }

    func value(fromMetres metres: Double) -> Double {
        switch self {
        case .metres: metres
        case .feet:   metres * 3.280839895
        }
    }
}

/// Appearance override. `.system` defers to the device setting — the default,
/// since the basemap (not the OS appearance) is the real visual context here.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// `nil` means "follow the system", which is what `.preferredColorScheme`
    /// expects to opt out of an override.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

/// Clock format for every time display (timeline readout, tape, chart axis).
/// Defaults to 24-hour — standard for marine/nautical use.
enum ClockFormat: String, CaseIterable, Identifiable {
    case twentyFourHour, twelveHour

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twentyFourHour: "24-hour"
        case .twelveHour:     "12-hour"
        }
    }

    var is24Hour: Bool { self == .twentyFourHour }
}

/// How tidal current is drawn on the map. Particles (animated flow) is the
/// default; arrows are the static fallback and the automatic substitute when
/// Reduce Motion or Low Power Mode is on (see `AppSettings.effectiveCurrentStyle`).
enum CurrentStyle: String, CaseIterable, Identifiable {
    case particles, arrows

    var id: String { rawValue }

    var label: String {
        switch self {
        case .particles: "Particles"
        case .arrows:    "Arrows"
        }
    }
}

// MARK: - Settings Store

/// App-wide user preferences, persisted to `UserDefaults` and observed by the
/// views. Mirrors the existing `MapViewModel` pattern: an `@Observable` injected
/// through the SwiftUI environment so both SwiftUI views and the MapLibre
/// representable can react without prop-drilling.
@MainActor
@Observable
final class AppSettings {

    var speedUnit: SpeedUnit {
        didSet { defaults.set(speedUnit.rawValue, forKey: Keys.speedUnit) }
    }
    var heightUnit: HeightUnit {
        didSet { defaults.set(heightUnit.rawValue, forKey: Keys.heightUnit) }
    }
    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var clockFormat: ClockFormat {
        didSet { defaults.set(clockFormat.rawValue, forKey: Keys.clockFormat) }
    }
    var currentStyle: CurrentStyle {
        didSet { defaults.set(currentStyle.rawValue, forKey: Keys.currentStyle) }
    }

    /// Selected base map style (see Settings → Map Style).
    var basemap: Basemap {
        didSet { defaults.set(basemap.rawValue, forKey: Keys.basemap) }
    }

    /// Disables live SalishSeaCast data entirely — no fetching, and cached
    /// live data is not rendered — so the app behaves exactly like the pure
    /// offline build. Off by default: live data is a silent enhancement.
    var offlineOnly: Bool {
        didSet { defaults.set(offlineOnly, forKey: Keys.offlineOnly) }
    }

    /// Raw values of network styles that have been viewed online and are thus
    /// cached for offline use. Lets the picker stay usable offline for styles
    /// the user already has, while gating ones they don't.
    private(set) var offlineReadyStyles: Set<String> {
        didSet { defaults.set(Array(offlineReadyStyles), forKey: Keys.offlineReadyStyles) }
    }

    // Mirrors the accessibility / power state; updated via notifications so
    // `effectiveCurrentStyle` re-evaluates (and observers re-render) when the
    // user toggles Reduce Motion or Low Power Mode while the app is running.
    private(set) var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled
    private(set) var lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// The style actually rendered: particles unless the user picked arrows, or
    /// Reduce Motion / Low Power Mode forces the static fallback.
    var effectiveCurrentStyle: CurrentStyle {
        (currentStyle == .arrows || reduceMotion || lowPowerMode) ? .arrows : .particles
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.speedUnit  = defaults.string(forKey: Keys.speedUnit).flatMap(SpeedUnit.init) ?? .knots
        self.heightUnit = defaults.string(forKey: Keys.heightUnit).flatMap(HeightUnit.init) ?? .metres
        self.appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init) ?? .system
        self.clockFormat = defaults.string(forKey: Keys.clockFormat).flatMap(ClockFormat.init) ?? .twentyFourHour
        self.currentStyle = defaults.string(forKey: Keys.currentStyle).flatMap(CurrentStyle.init) ?? .particles
        self.basemap    = defaults.string(forKey: Keys.basemap).flatMap(Basemap.init) ?? .standard
        self.offlineOnly = defaults.object(forKey: Keys.offlineOnly) as? Bool ?? false
        self.offlineReadyStyles = Set(defaults.stringArray(forKey: Keys.offlineReadyStyles) ?? [])

        observeAccessibilityAndPower()
    }

    private func observeAccessibilityAndPower() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reduceMotion = UIAccessibility.isReduceMotionEnabled }
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    // MARK: Basemap availability

    /// Whether `basemap` can be selected right now: the bundled standard style
    /// always; network styles only when online or already cached offline.
    func isSelectable(_ basemap: Basemap, online: Bool) -> Bool {
        !basemap.requiresNetwork || online || offlineReadyStyles.contains(basemap.rawValue)
    }

    /// Record that a network style has been shown online (so its tiles are now
    /// in the ambient cache and it stays selectable offline). Idempotent.
    func markOfflineReady(_ basemap: Basemap) {
        guard basemap.requiresNetwork, !offlineReadyStyles.contains(basemap.rawValue) else { return }
        offlineReadyStyles.insert(basemap.rawValue)
    }

    // MARK: Formatting helpers

    /// "3.2 kn" — used by the phase panel and any speed readout.
    func formatSpeed(knots: Double, fractionDigits: Int = 1) -> String {
        let v = speedUnit.value(fromKnots: knots)
        return "\(v.formatted(.number.precision(.fractionLength(fractionDigits)))) \(speedUnit.abbreviation)"
    }

    /// "2.4 m" — used by the tide chart cursor and axis labels.
    func formatHeight(metres: Double, fractionDigits: Int = 1) -> String {
        let v = heightUnit.value(fromMetres: metres)
        return "\(v.formatted(.number.precision(.fractionLength(fractionDigits)))) \(heightUnit.abbreviation)"
    }

    /// Compact hour-tick label for the tape and chart axis: "17:00" / "5 PM".
    /// Cheap (no `DateFormatter`) — these are redrawn every frame while dragging.
    func hourTickLabel(hour: Int) -> String {
        if clockFormat.is24Hour {
            return String(format: "%02d:00", hour)
        }
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    /// Timeline readout, e.g. "Jun 24, 17:00" / "Jun 24, 5:00 PM".
    func formatTimelineDate(_ date: Date) -> String {
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.timeZone = .salish
        return "\(date.formatted(dayStyle)), \(formatClock(date))"
    }

    /// Time-of-day only: "17:00" / "5:00 PM".
    func formatClock(_ date: Date) -> String {
        let cal = Calendar.salish
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        if clockFormat.is24Hour {
            return String(format: "%02d:%02d", h, m)
        }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }

    private enum Keys {
        static let speedUnit     = "settings.speedUnit"
        static let heightUnit    = "settings.heightUnit"
        static let appearance    = "settings.appearance"
        static let clockFormat   = "settings.clockFormat"
        static let currentStyle  = "settings.currentStyle"
        static let basemap       = "settings.basemap"
        static let offlineOnly   = "settings.offlineOnly"
        static let offlineReadyStyles = "settings.offlineReadyStyles"
    }
}
