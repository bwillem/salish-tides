import Foundation

/// MapTiler API key, read from the build config (`Config/Secrets.xcconfig` →
/// Info.plist `MAPTILER_KEY`). Empty when unset. Never committed; bundled style
/// JSONs carry a `{{MAPTILER_KEY}}` placeholder that is replaced at load time.
enum MapConfig {
    static var maptilerKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "MAPTILER_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// The chart's base map style.
///
/// Offline-first: `.standard` always works (bundled stub, no key). `.ocean` and
/// `.satellite` are MapTiler styles that stream when online and are cached by
/// MapLibre's ambient cache, so they keep working offline over waters you've
/// already viewed. Each style has a light + dark variant (bundled JSON), so a
/// Day→Night flip offline still renders.
enum Basemap: String, CaseIterable, Identifiable {
    case standard
    case ocean
    case satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:  "Standard"
        case .ocean:     "Ocean — bathymetry"
        case .satellite: "Satellite"
        }
    }

    /// Online-only until cached. `.standard` is bundled and always available.
    var requiresNetwork: Bool { self != .standard }

    /// Bundled style-JSON resource for the given appearance, or `nil` for
    /// `.standard` (which uses the stub styles handled in `MapLibreView`).
    /// Satellite is imagery — one style for both appearances.
    func styleResource(dark: Bool) -> String? {
        switch self {
        case .standard:  nil
        case .ocean:     dark ? "ocean-dark" : "ocean-light"
        case .satellite: "satellite"
        }
    }
}
