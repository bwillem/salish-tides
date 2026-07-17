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
    // Zero-speed "dry land" points bounding the rendering tier's coastline,
    // culled (not thinned — it's a contiguous barrier band) like the vectors.
    // The particle layer treats an empty mask as all-water.
    var currentLandMask: [CurrentVector] = []
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

    // Flood/ebb state of the current around the viewport centre, rederived
    // every load from the harmonic model + tide curve (CurrentPhaseEstimator).
    // nil (row hidden) when neither the model nor the tide curve can say.
    var currentPhase: CurrentPhase?

    // Which source produced the rendered current field, in fallback order:
    // live SalishSeaCast → bundled harmonic model. nil until a load completes
    // (or when the viewport is off all coverage), so no badge shows. The
    // vectors themselves flow through the same currentVectors property; this
    // only carries provenance for the UI.
    enum CurrentSource { case live, model }
    var currentSource: CurrentSource?
    /// Live currents rendering right now — drives the "Online mode" badge.
    var isLiveCurrents: Bool { currentSource == .live }
    var liveTideSeries: LiveTideSeries?

    private let liveData: LiveDataService?

    // Monotonic token so a slow multi-volume load can't overwrite the results
    // of a newer request (rapid time-scrub / pan). Incremented ONLY in
    // scheduleLoad, synchronously at request time; re-checked after every
    // await inside the load.
    private var loadGeneration = 0

    // The in-flight load, retained so the next request can cancel it — a
    // superseded load then abandons its remaining synthesis at the next
    // await instead of running to completion. See scheduleLoad.
    private var loadTask: Task<Void, Never>?

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

    // Fixed reference latitude for the thinning grid's cell shape. Using the
    // live viewport centre reshaped the grid on every north/south pan; a
    // constant keeps cells stable across the region — the squareness error over
    // the Salish Sea's latitude range (~48–50°N) is negligible.
    private static let thinRefLat = 48.7

    init(liveData: LiveDataService? = nil) {
        self.liveData = liveData
    }

    func initialize() async {
        do {
            try await TideDatabase.shared.setup()

            if await DatabaseMigrator.shared.needsMigration {
                isMigrating = true
                // Fresh baseline per attempt (Retry re-runs migrate), so the
                // monotonic clamp below can't pin the bar at a previous
                // attempt's high-water mark.
                migrationProgress = 0
            }

            try await DatabaseMigrator.shared.migrate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The per-callback unstructured tasks aren't guaranteed to
                    // start in order — clamp so the bar can only advance.
                    self.migrationProgress = max(self.migrationProgress, fraction)
                }
            }

            migrationProgress = 1.0
            isMigrating = false

            try await TideDatabase.shared.loadStations()

            await scheduleLoad(for: currentDate).value
        } catch {
            migrationError = error.localizedDescription
            isMigrating = false
        }
    }

    func setTime(_ date: Date) async {
        scrubLoadTask?.cancel()
        currentDate = date
        displayDate = date
        await scheduleLoad(for: date).value
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
            scheduleLoad(for: snapped)
        } else {
            // Trailing edge: make sure the latest hour loads even mid-throttle.
            scrubLoadTask?.cancel()
            scrubLoadTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self else { return }
                self.lastScrubLoadAt = Date()
                self.currentDate = snapped
                self.scheduleLoad(for: snapped)
            }
        }
    }

    /// Nearest hour by pure epoch rounding. Deliberately NOT wall-clock
    /// components: round-tripping through Calendar.salish mis-snaps inside
    /// the DST fall-back's repeated hour (Nov 1 01:30 PST resolves the
    /// ambiguous 01:00 wall time to its earlier, PDT occurrence, landing an
    /// hour early in UTC). Epoch math also matches how LiveDataService's
    /// hourKey buckets hours. Internal static + pure so it's unit-testable.
    nonisolated static func snapToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded() * 3600)
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
            self.scheduleLoad(for: self.currentDate)
        }
    }

    /// Reload for the current committed time — used when new live data arrives
    /// or the offline-only setting flips, so the map reflects the new source.
    func refresh() async {
        await scheduleLoad(for: currentDate).value
    }

    /// The single entry point for every vector load. Two invariants live here:
    ///
    /// 1. The newest REQUEST wins, not the newest task to start: the
    ///    generation token is taken synchronously, on the main actor, before
    ///    any await. Unstructured tasks don't start in FIFO order, so a token
    ///    taken inside the task body would let a late-starting stale load
    ///    outnumber the newest request and publish wrong-hour vectors.
    /// 2. Superseded loads stop working: the previous task is cancelled, and
    ///    loadVectors re-checks cancellation alongside every generation
    ///    guard, so an obsolete load abandons its remaining synthesis at the
    ///    next await instead of running to completion for nothing.
    ///
    /// Callers that must observe completion (setTime, refresh, initialize)
    /// await the returned task's `.value`.
    @discardableResult
    private func scheduleLoad(for date: Date) -> Task<Void, Never> {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        let task = Task { await loadVectors(for: date, generation: generation) }
        loadTask = task
        return task
    }

    private func loadVectors(for date: Date, generation: Int) async {
        // No viewport yet (the first frames after launch, before MapLibre
        // reports a region): bail before any work. The unculled fallback in
        // viewportFiltered/thinned would otherwise publish the WHOLE domain —
        // order 10⁵ vectors from both models — into a synchronous main-thread
        // feature build. Nothing is lost: the map's first regionDidChange
        // lands in updateViewport, whose debounced reload populates the map.
        guard visibleViewport != nil else { return }

        // Live SalishSeaCast field for this hour, when available. The service
        // needs to know the on-screen hour either way, so its background
        // prefetch can trigger a reload the moment visible data lands.
        liveData?.displayedHourKey = LiveDataService.hourKey(for: date)
        let liveField = await liveData?.currents(for: date)
        guard generation == loadGeneration, !Task.isCancelled else { return }

        // Cull the whole-domain live field to the viewport (with margin, so
        // pans don't immediately hit empty edges) BEFORE choosing the source:
        // an empty result means the viewport is outside the live coverage
        // (or all land at this resolution), and the harmonic model takes over.
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
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let culled = viewportFiltered(native)
            if !culled.isEmpty { liveVectors = culled }
        }

        // Harmonic-model tiers. The salishSea model duplicates the live
        // field's domain (both are the NEMO footprint), so it contributes
        // only when live doesn't render. webTide's cells were dropped near
        // SalishSeaCast water at PACK time, so it is disjoint from BOTH the
        // salishSea model and the live field — it always contributes, which
        // is what makes the coast seamless online: live water renders live,
        // and the coast beyond it still gets WebTide arrows in the same
        // frame. No runtime overlap logic. Everything nil (viewport off
        // every domain) → the map shows no current data there.
        var modelVectors: [CurrentVector] = []
        var contributing: [OfflineCurrentModel] = []
        for model in OfflineCurrentModel.all {
            if liveVectors != nil, model === OfflineCurrentModel.salishSea { continue }
            if let v = await model.currents(for: date, viewport: visibleViewport) {
                modelVectors += v
                contributing.append(model)
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }

        let vectors = (liveVectors ?? []) + modelVectors

        // The coastline mask, culled like the vectors. Every tier provides
        // one (live from cached wet cells, models from their own meshes) so
        // particles clip at the shoreline. Lower-priority models filter
        // their dry-shoreline band against the higher-priority fields: the
        // pack-time mask makes foreign-covered water read as "land" to them,
        // and an unfiltered band would kill particles along the model seam.
        var landMask: [CurrentVector] = []
        if liveVectors != nil, let mask = await liveData?.landMask() {
            landMask = viewportFiltered(mask)
        }
        // Fields collect OUTSIDE the contributing check: the crosshair's
        // land/water verdict below needs them even when the viewport renders
        // live-only. At each mask call the array holds exactly the models
        // EARLIER in `.all` — the higher-priority fields the seam filter
        // excludes against.
        var loadedFields: [TidalCurrentField] = []
        for model in OfflineCurrentModel.all {
            if contributing.contains(where: { $0 === model }),
               let mask = await model.landMask(excludingShorelineNear: loadedFields) {
                landMask += viewportFiltered(mask)
            }
            if let field = await model.loadedFieldIfAvailable() {
                loadedFields.append(field)
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }

        // Crosshair acceptance radius scales with the source under the
        // CENTRE, not just whatever contributes somewhere in the viewport:
        // on the ~4 km WebTide mesh the default ~1.6 km radius would miss
        // every node and read "—" over open water, but widening it while the
        // centre sits in the dense Salish Sea field would let a crosshair on
        // land report a channel's current from 3.7 km away. The decision
        // probes the fine field's actual water (crosshairUsesCoarseRadius);
        // the await is resolved BEFORE the final guard so every published
        // property below updates in one uninterrupted main-actor stretch.
        let webTideContributes = contributing.contains { $0 === OfflineCurrentModel.webTide }
        let fineField = webTideContributes
            ? await OfflineCurrentModel.salishSea.loadedFieldIfAvailable() : nil

        guard generation == loadGeneration, !Task.isCancelled else { return }
        let centre = visibleViewport.map { (lat: ($0.lat_min + $0.lat_max) / 2,
                                            lon: ($0.lon_min + $0.lon_max) / 2) }
        let coarse = Self.crosshairUsesCoarseRadius(
            webTideContributes: webTideContributes,
            centre: centre,
            fineField: fineField)
        // Provenance reflects what is actually rendered: a tier is nil (and
        // the next one populated `vectors`) whenever its cull came up empty.
        currentSource = liveVectors != nil ? .live : !modelVectors.isEmpty ? .model : nil
        // A crosshair parked ON land must read "—" even when water (and its
        // nodes) sit inside the acceptance radius — quoting the channel next
        // to the beach makes no sense. The models' own grids are the arbiter
        // (500 m in the Salish Sea): if some field's containing cell is wet
        // the point is water; if every covering field says dry it's land; if
        // no grid covers it at all, the radius search stays the only judge.
        let onLand = centre.map {
            Self.centreIsWater(fields: loadedFields, lat: $0.lat, lon: $0.lon) == false
        } ?? false
        // Crosshair readout uses the full-resolution set; only the rendered
        // layer is down-sampled.
        let crosshairVector = onLand ? nil
            : nearestVector(in: vectors, viewport: visibleViewport,
                            maxDistanceDeg: coarse
                                ? Self.crosshairMaxDistanceCoarseDeg
                                : Self.crosshairMaxDistanceDeg)
        crosshairSpeed = crosshairVector?.speedKnots
        // Speed publishes even at slack ("0.0 kn" over water is information;
        // "—" is reserved for land / off coverage), but a sub-significance
        // vector's bearing is numerical noise — the card falls back to its
        // reticle glyph when direction is nil.
        crosshairDirection = (crosshairVector?.isSignificant ?? false)
            ? crosshairVector?.direction_deg : nil
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
            tideStation = nil; tideEvents = []; liveTideSeries = nil; currentPhase = nil
            return
        }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        // nearestStation is unbounded, and the station registry thins out fast
        // north of the Salish Sea — beyond the cap, a "nearest" station's curve
        // and phase are simply wrong for the viewport, so show no tide card
        // rather than a misleading one.
        guard let station = await TideDatabase.shared.nearestStation(lat: cLat, lon: cLon),
              GeoMath.distanceSquared(fromLat: cLat, fromLon: cLon,
                                      toLat: station.lat, toLon: station.lon,
                                      cosLat: cos(cLat * .pi / 180))
                <= Self.stationMaxDistanceDeg * Self.stationMaxDistanceDeg
        else {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            tideStation = nil; tideEvents = []; liveTideSeries = nil; currentPhase = nil
            return
        }
        // Wide enough to cover the live scrub: the chart centre (displayDate) can
        // run ahead of the throttled currentDate during a fast drag.
        let from = date.addingTimeInterval(-30 * 3600)
        let to = date.addingTimeInterval(30 * 3600)
        // Empty is the designed fallback (the tide card simply shows no
        // curve), but a failing DB read is a diagnosable defect, not routine
        // absence — log it so "no tide data" in the field can be told apart
        // from genuinely missing events.
        var events: [TideEvent] = []
        do {
            events = try await TideDatabase.shared.events(stationID: station.id, from: from, to: to)
        } catch {
            Log.map.error("tide events query failed for station \(station.id, privacy: .public): \(error, privacy: .public)")
        }
        // Live model water levels refine the drawn curve where they cover it;
        // the bundled hi/lo events still anchor everything outside coverage.
        let live = await liveData?.liveTideSeries(for: station)
        // A newer load started while we were awaiting — drop these stale results.
        guard generation == loadGeneration, !Task.isCancelled else { return }
        tideStation = station
        tideEvents = events
        liveTideSeries = live
        await updatePhase(for: date, generation: generation)
    }

    // MARK: - Flood/ebb phase

    /// No model water within this range of the viewport centre → the phase
    /// falls back to the tide curve alone.
    private static let phaseMaxDistanceKm = 3.0
    /// Tide stations farther than this (≈100 km) from the viewport centre are
    /// ignored entirely — see updateTides.
    private static let stationMaxDistanceDeg = 0.9
    /// Hourly samples spanning ±12 h — a full tidal day, so both flood and ebb
    /// phases of both inequal cycles contribute to the learned axis.
    private static let floodDirWindow = Array(-12...12)

    /// Cache key for a learned flood axis: it's a property of (place, tide
    /// curve, spring/neap state), so bucket by model + cell + station + UTC
    /// day (cell indices alone collide across models).
    private struct FloodDirKey: Hashable {
        let model: String
        let cell: Int
        let stationID: String
        let day: Int
    }
    private var floodDirCache = LRUCache<FloodDirKey, CurrentPhaseEstimator.FloodDirection>(limit: 64)

    /// Rederive `currentPhase` at the viewport centre for the loaded hour.
    /// Always harmonic-model-based (never the live field), so the indicator is
    /// deterministic and identical online and offline. Runs after updateTides
    /// because it needs the freshly loaded station + events.
    private func updatePhase(for date: Date, generation: Int) async {
        guard let vp = visibleViewport, let station = tideStation, !tideEvents.isEmpty else {
            if generation == loadGeneration { currentPhase = nil }
            return
        }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        let events = tideEvents
        // heightIfBracketed, not height: the chart's edge clamp reads as
        // "falling" to the estimator's central difference, which would pin the
        // indicator to "Ebb" at the bundled data's boundary. nil makes the
        // estimator decline (row hides) instead of fabricating a tendency.
        let heightAt: (Date) -> Double? = { TideCurve.heightIfBracketed(at: $0, events: events) }

        // First model (in priority order) with water near the centre wins;
        // the flood-axis series must come from the same model as the sample.
        var covering: (model: OfflineCurrentModel, cell: Int, u: Double, v: Double)?
        for model in OfflineCurrentModel.all {
            if let now = await model.velocitySeries(
                lat: cLat, lon: cLon, dates: [date],
                maxDistanceKm: Self.phaseMaxDistanceKm) {
                covering = (model, now.cell, now.series[0].u, now.series[0].v)
                break
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }
        guard let covering else {
            // Off every model's water (open ocean, far north): the tide curve
            // alone still gives a defensible rising/falling answer.
            guard generation == loadGeneration, !Task.isCancelled else { return }
            currentPhase = CurrentPhaseEstimator.phase(u: 0, v: 0, at: date,
                                                       floodDirection: nil,
                                                       heightAt: heightAt)
            return
        }

        let key = FloodDirKey(model: covering.model.resourceName,
                              cell: covering.cell, stationID: station.id,
                              day: Int(date.timeIntervalSince1970 / 86_400))
        var floodDir = floodDirCache.value(for: key)
        if floodDir == nil {
            let dates = Self.floodDirWindow.map { date.addingTimeInterval(Double($0) * 3600) }
            if let day = await covering.model.velocitySeries(
                lat: cLat, lon: cLon, dates: dates,
                maxDistanceKm: Self.phaseMaxDistanceKm) {
                let samples = zip(dates, day.series).map {
                    CurrentPhaseEstimator.Sample(t: $0, u: $1.u, v: $1.v)
                }
                floodDir = CurrentPhaseEstimator.floodDirection(samples: samples,
                                                                heightAt: heightAt)
                if let floodDir { floodDirCache.insert(floodDir, for: key) }
            }
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        currentPhase = CurrentPhaseEstimator.phase(u: covering.u, v: covering.v,
                                                   at: date, floodDirection: floodDir,
                                                   heightAt: heightAt)
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

        // Size the cell from the LONGER screen axis, expressed in
        // longitude-degrees so it's invariant under panning at a fixed zoom:
        // lonSpan is constant in Web Mercator, and dividing latSpan by the
        // centre-latitude cos() divides out the Mercator latitude stretch, so
        // both terms depend only on zoom, not on where you've panned. (latSpan
        // alone drifts ~6% across the region's latitude range — enough for a big
        // north–south pan to nudge the quantized size across a rung and snap the
        // whole grid mid-pan.)
        let cosCenter = GeoMath.lonScale(atLat: (vp.lat_min + vp.lat_max) / 2)
        let rawCellLon = max(lonSpan, latSpan / cosCenter) / thinTargetAcross

        // Snap to a fixed 2^(k/4) ladder so the grid is a stable function of
        // zoom, not of the exact viewport: a pan yields the IDENTICAL grid, and
        // it steps only across real zoom changes (where the map rebuilds
        // anyway). Only the fastest vector per bin is drawn, so an unstable grid
        // re-picks winners and makes arrows blink in and out of an unmoved map
        // section — this keeps them put.
        let cellLon = Self.quantizedCell(rawCellLon)
        // Square-ish cells: a longitude degree is shorter than a latitude degree
        // by cos(lat). Use a FIXED reference latitude for the cell shape so it
        // doesn't change as you pan (squareness error over ~48–50°N is negligible).
        let cellLat = cellLon * GeoMath.lonScale(atLat: Self.thinRefLat)
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
        // Deterministic order so the downstream `!=` change check doesn't fire
        // on dictionary reordering alone (an identical set in a new order would
        // otherwise trigger a redundant full arrow/particle rebuild).
        return best.values.sorted {
            $0.lat != $1.lat ? $0.lat < $1.lat : $0.lon < $1.lon
        }
    }

    // Snap a cell size to a fixed 2^(k/4) ladder (quarter-octave rungs, ~1.19×
    // apart) so the thinning grid is a stable function of zoom rather than of
    // the exact viewport, keeping bins identical across pans. See thinned().
    private static func quantizedCell(_ size: Double) -> Double {
        guard size > 0, size.isFinite else { return size }
        let step = 0.25
        return pow(2, (log2(size) / step).rounded() * step)
    }

    // Beyond this, the nearest current vector is too far to be "under" the
    // crosshair — i.e. it's on land or off coverage, so report no speed.
    // The coarse radius applies when the ~4 km WebTide mesh serves the
    // viewport centre (see crosshairUsesCoarseRadius): it matches that
    // mesh's own land resolution, so "on land" stays meaningful.
    private nonisolated static let crosshairMaxDistanceDeg = 0.015        // ≈ 1.6 km
    private nonisolated static let crosshairMaxDistanceCoarseDeg = 0.033  // ≈ 3.7 km

    /// Whether the crosshair readout should accept vectors out to the coarse
    /// (~3.7 km) radius instead of the fine (~1.6 km) one. Pure + internal
    /// static so it's unit-testable.
    ///
    /// The fine radius is correct exactly when Salish Sea water sits close
    /// enough for the fine search to find a node — so probe the fine field's
    /// ACTUAL water within that radius, never its bounding box: the bbox is
    /// axis-aligned around the ~29°-rotated NEMO domain, so it contains
    /// west-coast Vancouver Island water that has no SSC node at all, and a
    /// bbox test there forced the fine radius where only WebTide's ~4 km
    /// mesh has nodes (speed card "—" over covered water). An unloaded fine
    /// field (or no centre yet) can't justify narrowing, so it stays coarse.
    nonisolated static func crosshairUsesCoarseRadius(
        webTideContributes: Bool,
        centre: (lat: Double, lon: Double)?,
        fineField: TidalCurrentField?
    ) -> Bool {
        guard webTideContributes else { return false }
        guard let centre, let fineField else { return true }
        // The probe reach IS the fine acceptance radius, converted to km.
        let fineReachKm = crosshairMaxDistanceDeg * 111.0
        return !fineField.hasWater(lat: centre.lat, lon: centre.lon,
                                   withinKm: fineReachKm)
    }

    /// The models' land/water verdict at a point, across every loaded field:
    /// - `true`  — some field's containing cell is a water node (the point is
    ///   on water; a dry verdict from a lower-resolution or pack-masked field
    ///   never overrules it),
    /// - `false` — at least one field's grid covers the point and every one
    ///   that does says dry: the point is land,
    /// - `nil`   — no grid covers the point (open ocean off every mesh);
    ///   the caller has no land evidence and should fall back to its own rule.
    nonisolated static func centreIsWater(fields: [TidalCurrentField],
                                          lat: Double, lon: Double) -> Bool? {
        var covered = false
        for field in fields {
            if field.isWater(lat: lat, lon: lon) { return true }
            if field.coverage.contains(lat: lat, lon: lon) { covered = true }
        }
        return covered ? false : nil
    }

    private func nearestVector(in vectors: [CurrentVector], viewport: ChartBounds?,
                               maxDistanceDeg: Double = crosshairMaxDistanceDeg) -> CurrentVector? {
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
        // No significance filter: the harmonic model emits real slack-water
        // speeds, and "0.0 kn" over water is information (slack!) while "—"
        // means off coverage / on land. The caller suppresses the DIRECTION
        // below the significance threshold instead — a near-zero vector's
        // bearing is numerical noise, but its magnitude is an honest zero.
        guard let nearest = vectors.min(by: { dist2($0) < dist2($1) }),
              dist2(nearest) <= maxDistanceDeg * maxDistanceDeg
        else { return nil }
        return nearest
    }
}
