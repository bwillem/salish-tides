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
    // Per-volume region index for viewport culling, keyed by volume id.
    private let atlasIndexes: [Int: AtlasIndex]

    // Monotonic token so a slow multi-volume load can't overwrite the results
    // of a newer request (rapid time-scrub / pan). Incremented on the main
    // actor, captured per call, re-checked after every await.
    private var loadGeneration = 0

    // Coalesces the burst of regionDidChange callbacks during an active
    // pan/zoom into a single reload once movement settles.
    private var viewportReloadTask: Task<Void, Never>?
    private let viewportDebounce: Duration = .milliseconds(200)

    // Target arrow count across the longer screen axis. Down-sampling bins
    // vectors into a grid sized from the viewport span, so on-screen density
    // stays roughly constant as the user zooms instead of collapsing into mush.
    private let thinTargetAcross = 70.0

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

        var indexes: [Int: AtlasIndex] = [:]
        for spec in atlasVolumes {
            guard let resource = spec.atlasIndexResource else { continue }
            if let index = try? AtlasIndex.load(resource: resource) {
                indexes[spec.id] = index
            }
        }
        self.atlasIndexes = indexes
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

    func updateViewport(_ bounds: ChartBounds) {
        visibleViewport = bounds
        // Debounce: cancel any pending reload and reschedule. A continuous pan
        // keeps cancelling, so the DB work runs once, after the map settles.
        viewportReloadTask?.cancel()
        let delay = viewportDebounce
        viewportReloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.loadVectors(for: self.currentDate)
        }
    }

    private func loadVectors(for date: Date) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        // Find all volumes whose geographic bounds intersect the current viewport.
        // If no viewport yet, include all volumes so any initial chart load works.
        // Rank volumes containing the viewport center first, so currentSelection
        // (.first) reflects the water the user is actually looking at.
        let center = visibleViewport.map {
            (lat: ($0.lat_min + $0.lat_max) / 2, lon: ($0.lon_min + $0.lon_max) / 2)
        }
        let activeSelectors = selectors
            .filter { spec, _ in
                guard let vp = visibleViewport else { return true }
                return spec.bounds.intersects(vp)
            }
            .sorted { lhs, rhs in
                rank(lhs.0, center: center) < rank(rhs.0, center: center)
            }

        var selections: [ChartSelection] = []
        var vectors: [CurrentVector] = []

        for (spec, selector) in activeSelectors {
            guard let sel = selector.selection(for: date) else { continue }
            selections.append(sel)

            // Use the volume's index for viewport-based region culling when
            // available; fall back to all regions if the index failed to load.
            let regions: [String]
            if let index = atlasIndexes[spec.id] {
                regions = index.regions(forChart: sel.chart, intersecting: visibleViewport)
            } else {
                regions = spec.regions
            }
            guard !regions.isEmpty else { continue }

            do {
                let vecs = try await VectorDatabase.shared.vectors(volume: spec.id, chart: sel.chart, regions: regions)
                // A newer load started while we were awaiting — drop these stale results.
                guard generation == loadGeneration else { return }
                vectors.append(contentsOf: vecs)
            } catch {
                // Non-fatal: one volume failing doesn't hide the others
            }
        }

        guard generation == loadGeneration else { return }
        currentSelections = selections
        // Crosshair readout uses the full-resolution set; only the rendered
        // layer is down-sampled.
        crosshairSpeed = nearestSpeed(in: vectors, viewport: visibleViewport)
        currentVectors = thinned(vectors, for: visibleViewport)

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

    private struct Cell: Hashable { let x: Int; let y: Int }

    // Bin vectors into viewport-sized cells, keeping the fastest per cell —
    // strong currents are the ones worth showing, and the cell size shrinks as
    // the user zooms in, so detail returns naturally at close range.
    private func thinned(_ vectors: [CurrentVector], for viewport: ChartBounds?) -> [CurrentVector] {
        guard let vp = viewport else { return vectors }
        let latSpan = vp.lat_max - vp.lat_min
        let lonSpan = vp.lon_max - vp.lon_min
        guard latSpan > 0, lonSpan > 0 else { return vectors }

        // Square-ish cells on screen: a degree of longitude is shorter than a
        // degree of latitude by cos(lat), so widen the longitude cell to match.
        let centerLat = (vp.lat_min + vp.lat_max) / 2
        let cosLat = max(0.1, cos(centerLat * .pi / 180))
        let screenSpan = max(latSpan, lonSpan * cosLat)
        let cellLat = screenSpan / thinTargetAcross
        let cellLon = cellLat / cosLat
        guard cellLat > 0, cellLon > 0 else { return vectors }

        var best: [Cell: CurrentVector] = [:]
        best.reserveCapacity(vectors.count)
        for v in vectors {
            let cell = Cell(x: Int((v.lon / cellLon).rounded(.down)),
                            y: Int((v.lat / cellLat).rounded(.down)))
            if let existing = best[cell] {
                if v.speed_ms > existing.speed_ms { best[cell] = v }
            } else {
                best[cell] = v
            }
        }
        return Array(best.values)
    }

    // 0 if the volume's bounds contain the viewport center, else 1 — used only
    // to order active volumes; ties keep their original (volume-id) order.
    private func rank(_ spec: VolumeSpec, center: (lat: Double, lon: Double)?) -> Int {
        guard let c = center else { return 0 }
        let b = spec.bounds
        let contains = c.lat >= b.lat_min && c.lat <= b.lat_max &&
                       c.lon >= b.lon_min && c.lon <= b.lon_max
        return contains ? 0 : 1
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
