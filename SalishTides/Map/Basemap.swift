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
/// Offline-first: a style with a `bundledArchive` (local tiles in the app) works
/// with no network. `.ocean` and `.satellite` are MapTiler styles that stream
/// when online and are cached by MapLibre's ambient cache, so they keep working
/// offline over waters you've already viewed. Each style has a light + dark
/// variant (bundled JSON), so a Day→Night flip offline still renders.
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

    /// A local tile archive bundled in the app's `basemap/` resource folder that
    /// backs this style offline, or `nil` for online-only styles. The extension
    /// selects the source mechanism: `.pmtiles` → vector (`pmtiles://`),
    /// `.mbtiles` → raster (`mbtiles://`). The matching style JSON references the
    /// archive through a `{{LOCAL_TILES}}` placeholder, injected at load time.
    ///
    /// This is the single switch that decides *which* basemap ships offline:
    /// give a style a bundled archive (+ a `{{LOCAL_TILES}}` source) and it works
    /// with no network; leave it `nil` and it streams.
    var bundledArchive: String? {
        switch self {
        case .standard:  "salish.pmtiles"   // Protomaps vector — the offline baseline
        case .ocean:     nil                 // online until an open bathymetry archive is sourced
        case .satellite: nil                 // online — imagery is impractical / licence-bound offline
        }
    }

    /// Online-only until cached. A style with a `bundledArchive` always works offline.
    var requiresNetwork: Bool { bundledArchive == nil }

    /// Bundled style-JSON resource for the given appearance.
    /// Satellite is imagery — one style for both appearances.
    func styleResource(dark: Bool) -> String {
        switch self {
        case .standard:  dark ? "standard-dark" : "standard-light"
        case .ocean:     dark ? "ocean-dark"    : "ocean-light"
        case .satellite: "satellite"
        }
    }
}
