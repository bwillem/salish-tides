import Foundation

/// MapTiler API key, read from the build config (`Config/Secrets.xcconfig` →
/// Info.plist `MAPTILER_KEY`). Empty when unset — callers fall back to the
/// bundled offline stub style. Never committed; see Config/Base.xcconfig.
enum MapConfig {
    static var maptilerKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "MAPTILER_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Base map style for the chart. `.system` keeps the app's offline Day/Night
/// stub basemap (the shipping default); the rest are MapTiler styles for
/// evaluating water-first looks during development. No street basemaps — this
/// is a boating app, so the options are bathymetric / imagery / minimal.
/// MapTiler styles need a `MAPTILER_KEY`; without one they fall back to the
/// offline stub, so the app always renders.
enum Basemap: String, CaseIterable, Identifiable {
    /// Offline Day/Night stub basemap (default — see MapLibreView).
    case system

    // Light / day
    case ocean, topographic, satellite
    // Dark / night
    case datavizDark, satelliteHybrid

    var id: String { rawValue }

    static let light: [Basemap] = [.ocean, .topographic, .satellite]
    static let dark:  [Basemap] = [.datavizDark, .satelliteHybrid]

    var label: String {
        switch self {
        case .system:          "Default (Day / Night)"
        case .ocean:           "Ocean — bathymetry"
        case .topographic:     "Topographic"
        case .satellite:       "Satellite"
        case .datavizDark:     "Dataviz Dark"
        case .satelliteHybrid: "Satellite Hybrid"
        }
    }

    /// MapTiler hosted style id (`.../maps/<id>/style.json`); `nil` for `.system`.
    private var maptilerStyleID: String? {
        switch self {
        case .system:          nil
        case .ocean:           "ocean"
        case .topographic:     "topo-v2"
        case .satellite:       "satellite"
        case .datavizDark:     "dataviz-dark"
        case .satelliteHybrid: "hybrid"
        }
    }

    /// Hosted MapTiler style URL, or `nil` for the offline default / when no
    /// key is configured — callers fall back to the per-scheme stub style.
    func styleURL(key: String) -> URL? {
        guard let id = maptilerStyleID, !key.isEmpty else { return nil }
        return URL(string: "https://api.maptiler.com/maps/\(id)/style.json?key=\(key)")
    }
}
