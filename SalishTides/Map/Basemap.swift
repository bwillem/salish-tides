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
/// with no network. `.satellite` is a MapTiler style that streams when online and
/// is cached by MapLibre's ambient cache, so it keeps working offline over waters
/// you've already viewed. Each style has a light + dark variant (bundled JSON), so
/// a Day→Night flip offline still renders.
enum Basemap: String, CaseIterable, Identifiable {
    case standard
    // Temporarily removed from the picker: Ocean is the least legible basemap and
    // needs its own current-arrow palette for contrast, which we haven't done yet.
    // To revive, uncomment this case and every `.ocean` branch below (label,
    // bundledArchive, supportsOfflineDownload, styleResource) — the ocean-*.json
    // styles are still bundled. Note: Ocean streams online only (its raster-DEM
    // sources can't be packed offline; see supportsOfflineDownload).
    // case ocean
    case satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:  "Standard"
        // case .ocean:     "Ocean — bathymetry"
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
        // case .ocean:     nil                 // online until an open bathymetry archive is sourced
        case .satellite: nil                 // online — imagery is impractical / licence-bound offline
        }
    }

    /// Online-only until cached. A style with a `bundledArchive` always works offline.
    var requiresNetwork: Bool { bundledArchive == nil }

    /// Whether selecting this style while online should pre-download an offline
    /// pack (so it works offline everywhere, not just where the ambient cache
    /// happened to capture). Neither current style qualifies: satellite imagery is
    /// far too large to pack, and standard already ships bundled. (Ocean, when
    /// revived, is also online-only — its two raster-DEM sources plus several
    /// vector sources can't be packed on-device; the pack stalls on any tile the
    /// key's plan can't serve.)
    var supportsOfflineDownload: Bool {
        switch self {
        // case .ocean:               false
        case .standard, .satellite: false
        }
    }

    /// Bundled style-JSON resource for the given appearance.
    /// Satellite is imagery — one style for both appearances.
    func styleResource(dark: Bool) -> String {
        switch self {
        case .standard:  dark ? "standard-dark" : "standard-light"
        // case .ocean:     dark ? "ocean-dark"    : "ocean-light"
        case .satellite: "satellite"
        }
    }
}
