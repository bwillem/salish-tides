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

/// Selectable base map styles, for trying out different looks during
/// development. Three light + three dark MapTiler styles; resolves to the
/// offline stub style when no MapTiler key is configured.
enum Basemap: String, CaseIterable, Identifiable {
    // Light
    case ocean, topo, streets
    // Dark
    case datavizDark, streetsDark, basicDark

    var id: String { rawValue }

    static let light: [Basemap] = [.ocean, .topo, .streets]
    static let dark:  [Basemap] = [.datavizDark, .streetsDark, .basicDark]

    var label: String {
        switch self {
        case .ocean:       "Ocean"
        case .topo:        "Topographic"
        case .streets:     "Streets"
        case .datavizDark: "Dataviz Dark"
        case .streetsDark: "Streets Dark"
        case .basicDark:   "Basic Dark"
        }
    }

    /// MapTiler hosted style id (`.../maps/<id>/style.json`).
    private var maptilerStyleID: String {
        switch self {
        case .ocean:       "ocean"
        case .topo:        "topo-v2"
        case .streets:     "streets-v2"
        case .datavizDark: "dataviz-dark"
        case .streetsDark: "streets-v2-dark"
        case .basicDark:   "basic-v2-dark"
        }
    }

    /// Resolved style URL. Falls back to the bundled offline stub style when
    /// `key` is empty, so the app still renders with no MapTiler key.
    func styleURL(key: String) -> URL? {
        guard !key.isEmpty else {
            return Bundle.main.url(forResource: "stub-style", withExtension: "json")
        }
        return URL(string: "https://api.maptiler.com/maps/\(maptilerStyleID)/style.json?key=\(key)")
    }
}
