import Foundation
import Observation

@MainActor
@Observable
final class MapViewModel {
    // Committed/loaded hour — drives the (hourly) current-chart vectors.
    var currentDate: Date = .now
    // Live, continuous time under the scrubbing cursor — drives the tide chart
    // and the readout every frame. Equal to currentDate when not scrubbing.
    // The map does NOT observe this, so per-frame updates stay cheap.
    var displayDate: Date = .now
    var currentVectors: [CurrentVector] = []
    // Full-resolution (viewport-culled, unthinned) vectors for the particle
    // field raster — currentVectors is display-thinned for the arrows and
    // would starve/bias the field.
    var currentFieldVectors: [CurrentVector] = []
    // Zero-speed "dry land" points bounding the live model's coastline,
    // culled (not thinned — it's a contiguous barrier band) like the vectors.
    // Empty when the atlas renders (it has no land mask) — the particle layer
    // treats an empty mask as all-water.
    var currentLandMask: [CurrentVector] = []
    var currentSelections: [ChartSelection] = []
    var isMigrating = false
    var migrationProgress: Double = 0
    var migrationError: String?
    var visibleViewport: ChartBounds?
    var crosshairSpeed: Double?
    /// Flow direction (compass degrees, 0 = N) of the current at the crosshair,
    /// from the same nearest vector as `crosshairSpeed`.
    var crosshairDirection: Double?

    // Nearest tide station to the crosshair + its hi/lo events spanning the
    // visible time window (drives TideChartView).
    var tideStation: TideStation?
    var tideEvents: [TideEvent] = []

    // Which source produced the rendered current field, in fallback order:
    // live SalishSeaCast → bundled harmonic model → bundled atlas. The vectors
    // themselves flow through the same currentVectors property; this only
    // carries provenance for the UI.
    enum CurrentSource { case live, model, atlas }
    var currentSource: CurrentSource = .atlas
    /// Live currents rendering right now — drives the "Online mode" badge.
    var isLiveCurrents: Bool { currentSource == .live }
    var liveTideSeries: LiveTideSeries?

    // Convenience for views that only need one selection (e.g. phase indicator)
    var currentSelection: ChartSelection? { currentSelections.first }

    private let liveData: LiveDataService?
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

    // Throttles current-chart reloads while scrubbing the timeline: the tide
    // chart scrolls smoothly every frame, but the hourly vectors reload at most
    // ~11×/s (leading + trailing edge), each guarded by loadGeneration.
    private var scrubLoadTask: Task<Void, Never>?
    private var lastScrubLoadAt = Date.distantPast
    private let scrubThrottle: TimeInterval = 0.09

    // Target arrow count across the longer screen axis. Down-sampling bins
    // vectors into a grid sized from the viewport span, so on-screen density
    // stays roughly constant as the user zooms instead of collapsing into mush.
    private let thinTargetAcross = 70.0

    init(liveData: LiveDataService? = nil) {
        self.liveData = liveData
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
        scrubLoadTask?.cancel()
        currentDate = date
        displayDate = date
        await loadVectors(for: date)
    }

    // Live scrub from the timeline tape. Updates displayDate every frame (cheap —
    // only the tide chart and readout observe it) and throttles the heavier
    // current-chart reload to hour granularity so the map stays smooth.
    func scrub(to date: Date) {
        displayDate = date
        let snapped = Self.snapToHour(date)
        guard snapped != currentDate else {
            // Already on this hour — but a trailing load scheduled for an older
            // target may still be pending; cancel it or it fires 90 ms from now
            // and drags currentDate back to that stale hour mid-drag.
            scrubLoadTask?.cancel()
            return
        }

        if Date().timeIntervalSince(lastScrubLoadAt) >= scrubThrottle {
            // Supersede any pending trailing load — otherwise an older hour could
            // fire after this one and win on loadGeneration (stale map state).
            scrubLoadTask?.cancel()
            lastScrubLoadAt = Date()
            currentDate = snapped
            Task { await loadVectors(for: snapped) }
        } else {
            // Trailing edge: make sure the latest hour loads even mid-throttle.
            scrubLoadTask?.cancel()
            scrubLoadTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self else { return }
                self.lastScrubLoadAt = Date()
                self.currentDate = snapped
                await self.loadVectors(for: snapped)
            }
        }
    }

    private static func snapToHour(_ date: Date) -> Date {
        let cal = Calendar.salish
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var top = c; top.minute = 0; top.second = 0
        let base = cal.date(from: top) ?? date
        return (c.minute ?? 0) >= 30 ? base.addingTimeInterval(3600) : base
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

    /// Reload for the current committed time — used when new live data arrives
    /// or the offline-only setting flips, so the map reflects the new source.
    func refresh() async {
        await loadVectors(for: currentDate)
    }

    private func loadVectors(for date: Date) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        // Live SalishSeaCast field for this hour, when available. The service
        // needs to know the on-screen hour either way, so its background
        // prefetch can trigger a reload the moment visible data lands.
        liveData?.displayedHourKey = LiveDataService.hourKey(for: date)
        let liveField = await liveData?.currents(for: date)
        guard generation == loadGeneration else { return }

        // Cull the whole-domain live field to the viewport (with margin, so
        // pans don't immediately hit empty edges) BEFORE choosing the source:
        // an empty result means the viewport is outside the model's coverage
        // (or all land at this resolution), and the atlas must take over —
        // its charts extend beyond the NEMO domain (e.g. Queen Charlotte
        // Strait in Vol 4).
        var liveVectors: [CurrentVector]? = liveField.flatMap { field in
            let culled = viewportFiltered(field)
            return culled.isEmpty ? nil : culled
        }

        // At navigation zooms, upgrade the strided field to the native-
        // resolution window — the stride drops ~3/4 of the model's wet cells
        // in constricted water (whole bays vanish). Strided keeps rendering
        // until the window lands, so the upgrade is seamless.
        if liveVectors != nil, visibleViewport != nil,
           let native = await liveData?.nativeCurrents(for: date, viewport: visibleViewport!) {
            guard generation == loadGeneration else { return }
            let culled = viewportFiltered(native)
            if !culled.isEmpty { liveVectors = culled }
        }

        // Middle tier: the bundled harmonic model. Synthesized on device from
        // packed SalishSeaCast constituents, so anywhere the live field would
        // render but can't (offline, cold cache, forecast horizon) still gets
        // full-resolution model water instead of the atlas's sparse arrows.
        // nil when the viewport is off the model domain → atlas takes over.
        var modelVectors: [CurrentVector]?
        if liveVectors == nil {
            modelVectors = await OfflineCurrentModel.shared.currents(for: date,
                                                                     viewport: visibleViewport)
            guard generation == loadGeneration else { return }
        }

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

        // Chart selections are always computed — they drive the flood/ebb phase
        // indicator regardless of which source renders the vectors. The atlas
        // DB is only queried when there's no live or model field to show.
        for (spec, selector) in activeSelectors {
            guard let sel = selector.selection(for: date) else { continue }
            selections.append(sel)
            guard liveVectors == nil, modelVectors == nil else { continue }

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
                Log.map.error("atlas vectors failed (vol \(spec.id), chart \(sel.chart)): \(error, privacy: .public)")
            }
        }

        if let liveVectors {
            vectors = liveVectors
        } else if let modelVectors {
            vectors = modelVectors
        }

        // The live coastline mask, culled like the vectors. Only meaningful
        // when live vectors render — the atlas has no dry cells to mask with.
        var landMask: [CurrentVector] = []
        if liveVectors != nil, let mask = await liveData?.landMask() {
            landMask = viewportFiltered(mask)
        }

        guard generation == loadGeneration else { return }
        // Provenance reflects what is actually rendered: a tier is nil (and
        // the next one populated `vectors`) whenever its cull came up empty.
        currentSource = liveVectors != nil ? .live : modelVectors != nil ? .model : .atlas
        currentSelections = selections
        // Crosshair readout uses the full-resolution set; only the rendered
        // layer is down-sampled.
        let crosshairVector = nearestVector(in: vectors, viewport: visibleViewport)
        crosshairSpeed = crosshairVector?.speedKnots
        crosshairDirection = crosshairVector?.direction_deg
        // Arrows get the display-density thinned set; the particle field gets
        // full-resolution data (the raster does its own averaging — feeding it
        // the fastest-per-bin thinned picks would bias speeds and starve its
        // 160-across grid). The mask stays unthinned too: it's a barrier band,
        // and thinning (arbitrary pick per bin at speed 0) punches holes in it.
        // Only assign on change — every reassignment re-runs the map update
        // and a particle field rebuild via Observation.
        let thinnedVectors = thinned(vectors, for: visibleViewport)
        if thinnedVectors != currentVectors { currentVectors = thinnedVectors }
        let fieldVectors = viewportFiltered(vectors)
        if fieldVectors != currentFieldVectors { currentFieldVectors = fieldVectors }
        if landMask != currentLandMask { currentLandMask = landMask }

        await updateTides(for: date, generation: generation)
    }

    /// Points within the viewport plus the shared cull margin, so pans don't
    /// immediately hit empty edges. No viewport yet → everything.
    private func viewportFiltered(_ points: [CurrentVector]) -> [CurrentVector] {
        guard let vp = visibleViewport else { return points }
        let expanded = vp.expanded(byFraction: ChartBounds.cullMarginFraction)
        return points.filter { expanded.contains(lat: $0.lat, lon: $0.lon) }
    }

    // Pick the nearest station to the crosshair and fetch a ±18 h window of
    // hi/lo events (wide enough that the ±6 h chart always has bracketing
    // extrema for interpolation). Honors the same load-generation guard as the
    // vector path so a slow fetch can't overwrite a newer scrub/pan's result.
    private func updateTides(for date: Date, generation: Int) async {
        guard let vp = visibleViewport else {
            tideStation = nil; tideEvents = []; liveTideSeries = nil
            return
        }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        guard let station = await TideDatabase.shared.nearestStation(lat: cLat, lon: cLon) else {
            guard generation == loadGeneration else { return }
            tideStation = nil; tideEvents = []; liveTideSeries = nil
            return
        }
        // Wide enough to cover the live scrub: the chart centre (displayDate) can
        // run ahead of the throttled currentDate during a fast drag.
        let from = date.addingTimeInterval(-30 * 3600)
        let to = date.addingTimeInterval(30 * 3600)
        let events = (try? await TideDatabase.shared.events(stationID: station.id, from: from, to: to)) ?? []
        // Live model water levels refine the drawn curve where they cover it;
        // the bundled hi/lo events still anchor everything outside coverage.
        let live = await liveData?.liveTideSeries(for: station)
        // A newer load started while we were awaiting — drop these stale results.
        guard generation == loadGeneration else { return }
        tideStation = station
        tideEvents = events
        liveTideSeries = live
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
        let cosLat = GeoMath.lonScale(atLat: centerLat)
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
        return spec.bounds.contains(lat: c.lat, lon: c.lon) ? 0 : 1
    }

    // Beyond this, the nearest current vector is too far to be "under" the
    // crosshair — i.e. it's on land or off the atlas coverage, so report no speed
    // (the data has no slack vectors; current exists only where there's flow).
    private let crosshairMaxDistanceDeg = 0.015  // ≈ 1.6 km

    private func nearestVector(in vectors: [CurrentVector], viewport: ChartBounds?) -> CurrentVector? {
        guard let vp = viewport else { return nil }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        // Hoisted: min(by:) evaluates dist2 ~2× per element over the full-
        // resolution set on the main actor during scrubs.
        let cosLat = cos(cLat * .pi / 180)
        func dist2(_ v: CurrentVector) -> Double {
            GeoMath.distanceSquared(fromLat: cLat, fromLon: cLon,
                                    toLat: v.lat, toLon: v.lon, cosLat: cosLat)
        }
        guard let nearest = vectors.filter({ $0.isSignificant }).min(by: { dist2($0) < dist2($1) }),
              dist2(nearest) <= crosshairMaxDistanceDeg * crosshairMaxDistanceDeg
        else { return nil }
        return nearest
    }
}
