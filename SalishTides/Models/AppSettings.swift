import SwiftUI
import Observation

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
    var showCrosshair: Bool {
        didSet { defaults.set(showCrosshair, forKey: Keys.showCrosshair) }
    }
    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var clockFormat: ClockFormat {
        didSet { defaults.set(clockFormat.rawValue, forKey: Keys.clockFormat) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.speedUnit  = defaults.string(forKey: Keys.speedUnit).flatMap(SpeedUnit.init) ?? .knots
        self.heightUnit = defaults.string(forKey: Keys.heightUnit).flatMap(HeightUnit.init) ?? .metres
        self.appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init) ?? .system
        self.clockFormat = defaults.string(forKey: Keys.clockFormat).flatMap(ClockFormat.init) ?? .twentyFourHour
        // Bool keys default to `true` (feature visible) when never set.
        self.showCrosshair = defaults.object(forKey: Keys.showCrosshair) as? Bool ?? true
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

    /// Timeline readout, e.g. "Jun 24 at 17:00" / "Jun 24 at 5:00 PM".
    func formatTimelineDate(_ date: Date) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) at \(formatClock(date))"
    }

    /// Time-of-day only: "17:00" / "5:00 PM".
    func formatClock(_ date: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
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
        static let showCrosshair = "settings.showCrosshair"
        static let appearance    = "settings.appearance"
        static let clockFormat   = "settings.clockFormat"
    }
}
