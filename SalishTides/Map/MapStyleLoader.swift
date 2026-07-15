import Foundation
import SwiftUI

/// Resolves the MapLibre style URL for a `(Basemap, appearance)` pair.
///
/// Every basemap is a bundled style JSON carrying placeholders that are filled in
/// at load time and written to a temp file MapLibre loads:
///   • `{{MAPTILER_KEY}}` — the MapTiler key (never committed) for online styles.
///   • `{{LOCAL_TILES}}`  — a `pmtiles://`/`mbtiles://` URL for the style's bundled
///     offline tile archive (see `Basemap.bundledArchive`).
///
/// If a style can't be resolved (missing key, missing archive, or I/O error) we
/// fall back to `.standard`, and finally to a flat water-coloured style with no
/// dependencies — so the map never blanks, even if the bundled tile archive is
/// absent.
enum MapStyleLoader {

    static func styleURL(for basemap: Basemap, dark: Bool) -> URL? {
        if let url = resolvedStyleURL(for: basemap, dark: dark) { return url }
        // Offline-safe fallback: the bundled-offline Standard style.
        if basemap != .standard, let url = resolve(.standard, dark: dark) { return url }
        // Last resort, with zero external dependencies: a flat water-coloured
        // style so the map is never blank even if the bundled tile archive is
        // missing (e.g. a checkout that hasn't run dev/basemap/build-pmtiles.sh).
        // The current-arrow overlay still draws on top.
        return fallbackStyleURL(dark: dark)
    }

    /// The style URL for *this exact* basemap, or `nil` if it genuinely can't be
    /// produced (a network style with no MapTiler key, a missing bundled archive,
    /// an I/O error). Unlike `styleURL`, it never substitutes a different style.
    ///
    /// Callers that must know whether *this* style is really available — the
    /// offline-pack download in particular — use this: packing the Standard
    /// fallback under Ocean's identity produces a pack that can never finish
    /// (its tiles live in a local `pmtiles://` archive, not on the network).
    static func resolvedStyleURL(for basemap: Basemap, dark: Bool) -> URL? {
        resolve(basemap, dark: dark)
    }

    /// A minimal style with no sources — just a solid water background matching
    /// the real basemap's tone — guaranteed to render. The single safety net
    /// that keeps `styleURL` from ever handing MapLibre a nil/blank style.
    private static func fallbackStyleURL(dark: Bool) -> URL? {
        let water = dark ? "#0f1c28" : "#cfdce6"   // mirrors standard-{dark,light}.json
        let json = """
        {"version":8,"name":"Fallback","sources":{},"layers":[\
        {"id":"background","type":"background","paint":{"background-color":"\(water)"}}]}
        """
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("style-fallback-\(dark ? "dark" : "light").json")
        return (try? json.write(to: dest, atomically: true, encoding: .utf8)) == nil ? nil : dest
    }

    /// Read the bundled style, inject any placeholders it contains, write the
    /// result to a temp file. Returns `nil` if a required substitution can't be
    /// satisfied (so the caller can fall back).
    private static func resolve(_ basemap: Basemap, dark: Bool) -> URL? {
        let resource = basemap.styleResource(dark: dark)
        guard let src = Bundle.main.url(forResource: resource, withExtension: "json"),
              var json = try? String(contentsOf: src, encoding: .utf8) else {
            return nil
        }

        if json.contains(keyPlaceholder) {
            let key = MapConfig.maptilerKey
            guard !key.isEmpty else { return nil }
            json = json.replacingOccurrences(of: keyPlaceholder, with: key)
        }

        if json.contains(tilesPlaceholder) {
            guard let tiles = localTilesURL(for: basemap) else { return nil }
            json = json.replacingOccurrences(of: tilesPlaceholder, with: tiles)
        }

        // Rewrite on every call: the injected local-tiles path is an absolute
        // bundle URL that changes between installs, so a cached temp file could go
        // stale. The cost is a ~20 KB write on a (rare) style/theme switch.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("style-\(resource).json")
        do {
            try json.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        } catch {
            // Caller falls back to the bundled/flat style.
            Log.map.error("style write failed for \(resource, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// A `pmtiles://`/`mbtiles://` URL for a basemap's bundled archive (in the
    /// app's `basemap/` resource folder), or `nil` if it isn't present.
    private static func localTilesURL(for basemap: Basemap) -> String? {
        guard let archive = basemap.bundledArchive else { return nil }
        let name = (archive as NSString).deletingPathExtension
        let ext  = (archive as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "basemap") else {
            return nil
        }
        switch ext {
        case "pmtiles": return "pmtiles://" + url.absoluteString   // → pmtiles://file:///…
        case "mbtiles": return "mbtiles://" + url.path             // → mbtiles:///…
        default:        return nil
        }
    }

    private static let keyPlaceholder   = "{{MAPTILER_KEY}}"
    private static let tilesPlaceholder = "{{LOCAL_TILES}}"
}
