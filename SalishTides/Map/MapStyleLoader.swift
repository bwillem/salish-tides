import Foundation
import SwiftUI

/// Resolves the MapLibre style URL for a `(Basemap, appearance)` pair.
///
/// `.standard` uses the bundled stub styles directly. MapTiler styles are
/// bundled with a `{{MAPTILER_KEY}}` placeholder (so the key is never committed);
/// at load time the key is injected and the result written to a temp file that
/// MapLibre loads. If the key is missing or anything fails, we fall back to the
/// always-available stub so the map never goes blank.
enum MapStyleLoader {

    static func styleURL(for basemap: Basemap, dark: Bool) -> URL? {
        let fallback = MapLibreView.styleURL(for: dark ? .dark : .light)

        guard let resource = basemap.styleResource(dark: dark) else {
            return fallback   // .standard
        }
        guard let src = Bundle.main.url(forResource: resource, withExtension: "json"),
              var json = try? String(contentsOf: src, encoding: .utf8) else {
            return fallback
        }

        if json.contains(placeholder) {
            let key = MapConfig.maptilerKey
            guard !key.isEmpty else { return fallback }
            json = json.replacingOccurrences(of: placeholder, with: key)
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("style-\(resource).json")
        do {
            try json.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        } catch {
            return fallback
        }
    }

    private static let placeholder = "{{MAPTILER_KEY}}"
}
