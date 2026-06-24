import Foundation
import Observation

@MainActor
@Observable
final class MapViewModel {
    var currentDate: Date = .now
    var currentVectors: [CurrentVector] = []
    var currentSelections: [ChartSelection] = []
    var isMigrating = false
    var migrationProgress: Double = 0
    var migrationError: String?
    var visibleViewport: ChartBounds?
    var crosshairSpeed: Double?

    // Nearest tide station to the crosshair + its hi/lo events spanning the
    // visible time window (drives TideChartView).
    var tideStation: TideStation?
    var tideEvents: [TideEvent] = []

    // Convenience for views that only need one selection (e.g. phase indicator)
    var currentSelection: ChartSelection? { currentSelections.first }

    private let selectors: [(VolumeSpec, ChartSelector)]
    private let atlasIndex: AtlasIndex

    init() {
        // Build one selector per unique lookup resource — Vol 1 and Vol 3 share a file,
        // so we load it once and reuse it for both volume IDs.
        var loaded: [String: AtlasLookupTable] = [:]
        var built: [(VolumeSpec, ChartSelector)] = []
        for spec in atlasVolumes {
            let table: AtlasLookupTable
            if let cached = loaded[spec.lookupResource] {
                table = cached
            } else if let url = Bundle.main.url(forResource: spec.lookupResource, withExtension: "json"),
                      let data = try? Data(contentsOf: url),
                      let decoded = try? JSONDecoder().decode(AtlasLookupTable.self, from: data) {
                table = decoded
                loaded[spec.lookupResource] = decoded
            } else {
                continue
            }
            built.append((spec, ChartSelector(volume: spec.id, table: table)))
        }
        self.selectors = built
        self.atlasIndex = (try? AtlasIndex.load()) ?? AtlasIndex.empty
    }

    func initialize() async {
        do {
            try await VectorDatabase.shared.setup()
            try await TideDatabase.shared.setup()

            if await DatabaseMigrator.shared.needsMigration {
                isMigrating = true
            }

            try await DatabaseMigrator.shared.migrate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.migrationProgress = fraction
                }
            }

            migrationProgress = 1.0
            isMigrating = false

            try await TideDatabase.shared.loadStations()

            await loadVectors(for: currentDate)
        } catch {
            migrationError = error.localizedDescription
            isMigrating = false
        }
    }

    func setTime(_ date: Date) async {
        currentDate = date
        await loadVectors(for: date)
    }

    func updateViewport(_ bounds: ChartBounds) async {
        visibleViewport = bounds
        await loadVectors(for: currentDate)
    }

    private func loadVectors(for date: Date) async {
        // Find all volumes whose geographic bounds intersect the current viewport.
        // If no viewport yet, include all volumes so any initial chart load works.
        let activeSelectors = selectors.filter { spec, _ in
            guard let vp = visibleViewport else { return true }
            return spec.bounds.intersects(vp)
        }

        var selections: [ChartSelection] = []
        var vectors: [CurrentVector] = []

        for (spec, selector) in activeSelectors {
            guard let sel = selector.selection(for: date) else { continue }
            selections.append(sel)

            // Use atlas index for viewport-based region culling when available (Vol 1);
            // fall back to all regions for volumes without an index.
            let regions: [String]
            if spec.atlasIndexResource != nil {
                regions = atlasIndex.regions(forChart: sel.chart, intersecting: visibleViewport)
            } else {
                regions = spec.regions
            }
            guard !regions.isEmpty else { continue }

            do {
                let vecs = try await VectorDatabase.shared.vectors(volume: spec.id, chart: sel.chart, regions: regions)
                vectors.append(contentsOf: vecs)
            } catch {
                // Non-fatal: one volume failing doesn't hide the others
            }
        }

        currentSelections = selections
        currentVectors = vectors
        crosshairSpeed = nearestSpeed(in: vectors, viewport: visibleViewport)

        await updateTides(for: date)
    }

    // Pick the nearest station to the crosshair and fetch a ±18 h window of
    // hi/lo events (wide enough that the ±6 h chart always has bracketing
    // extrema for interpolation).
    private func updateTides(for date: Date) async {
        guard let vp = visibleViewport else {
            tideStation = nil; tideEvents = []
            return
        }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        guard let station = await TideDatabase.shared.nearestStation(lat: cLat, lon: cLon) else {
            tideStation = nil; tideEvents = []
            return
        }
        let from = date.addingTimeInterval(-18 * 3600)
        let to = date.addingTimeInterval(18 * 3600)
        let events = (try? await TideDatabase.shared.events(stationID: station.id, from: from, to: to)) ?? []
        tideStation = station
        tideEvents = events
    }

    private func nearestSpeed(in vectors: [CurrentVector], viewport: ChartBounds?) -> Double? {
        guard let vp = viewport else { return nil }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        return vectors
            .filter { $0.isSignificant }
            .min(by: {
                let d1 = ($0.lat - cLat) * ($0.lat - cLat) + ($0.lon - cLon) * ($0.lon - cLon)
                let d2 = ($1.lat - cLat) * ($1.lat - cLat) + ($1.lon - cLon) * ($1.lon - cLon)
                return d1 < d2
            })
            .map { $0.speedKnots }
    }
}
