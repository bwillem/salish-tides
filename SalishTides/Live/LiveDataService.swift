import Foundation
import Observation

/// Chart-datum-corrected live water levels for one station, interpolated from
/// a paired SalishSeaCast gauge's 10-minute SSH series.
struct LiveTideSeries: Sendable {
    let gaugeName: String
    /// Ascending (time, metres above the paired station's own datum).
    let samples: [(time: Date, height: Double)]

    /// Linearly interpolated height; nil outside coverage, where callers fall
    /// back to the bundled prediction curve.
    func height(at t: Date) -> Double? {
        guard let first = samples.first, let last = samples.last,
              t >= first.time, t <= last.time else { return nil }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return a.height }
        let f = t.timeIntervalSince(a.time) / span
        return a.height + (b.height - a.height) * f
    }

    func covers(_ t: Date) -> Bool { height(at: t) != nil }

    // The live series and the prediction curve generally disagree by the
    // instantaneous surge at any moment, so a hard switch at the coverage
    // edge would draw a visible step. Fade live into the fallback over the
    // last hour of coverage instead.
    private static let edgeBlend: TimeInterval = 3600

    /// `height(at:)` cross-faded into `fallback` near the coverage edges:
    /// pure live in the interior, pure fallback outside, continuous between.
    func blendedHeight(at t: Date, fallback: Double?) -> Double? {
        guard let raw = height(at: t) else { return fallback }
        guard let fallback, let first = samples.first, let last = samples.last else { return raw }
        let edgeDistance = min(t.timeIntervalSince(first.time), last.time.timeIntervalSince(t))
        let w = min(1, max(0, edgeDistance / Self.edgeBlend))
        return raw * w + fallback * (1 - w)
    }
}

/// Fetches, caches, and serves real-time SalishSeaCast model data — surface
/// currents and water levels — as a silent enhancement over the bundled
/// offline data. Everything it fetches lands in `LiveDataStore`, so data
/// downloaded at the dock keeps working underway; when neither the cache nor
/// the network can cover a request, callers get nil and fall back to the
/// atlas/predictions. Fetching (and rendering, via nil returns) is disabled
/// entirely by `AppSettings.offlineOnly`.
@MainActor
@Observable
final class LiveDataService {

    // Forecast horizon prefetched ahead of now, plus a small backfill so a
    // scrub just behind now stays live. The dataset usually extends further;
    // hours outside this window are still fetched on demand when scrubbed to.
    private static let horizonHours = 36
    private static let backfillHours = 2
    // A slice refetched after this age picks up the day's newer model run.
    private static let sliceMaxAge: TimeInterval = 12 * 3600
    private static let sshMaxAge: TimeInterval = 6 * 3600
    // An hour that failed to fetch (network error, or the model hasn't
    // published it) isn't retried on demand until this elapses — otherwise
    // scrubbing across the forecast edge would refire a request per pass.
    private static let sliceRetryDelay: TimeInterval = 15 * 60
    // SSH history fetched/kept behind now. Sized for datum calibration: the
    // longer the window, the more a sustained storm surge is diluted out of
    // the calibration mean. Must stay comfortably inside the dataset's
    // rolling ~5-day history or the whole series request errors out.
    private static let sshHistory: TimeInterval = 84 * 3600
    // Widest on-demand window — the rolling dataset spans roughly −5 days to
    // +1.5 days around now; beyond that a request can't succeed.
    private static let onDemandPast: TimeInterval = -4.5 * 86400
    private static let onDemandFuture: TimeInterval = 2.5 * 86400
    // Only pair a station to a gauge within ~15 km: an additive datum
    // correction can't fix the amplitude/phase differences that build up over
    // larger separations, and the bundled predictions are the safer source.
    private static let gaugeMaxDistanceDeg = 0.14
    // Cached, unpacked vector slices kept in memory (scrubbing revisits
    // hours; ~0.5 MB per entry).
    private static let vectorCacheLimit = 8

    private let settings: AppSettings
    private let network: NetworkMonitor
    private let client = SalishSeaCastClient()
    private let store = LiveDataStore.shared

    /// Bumped when freshly fetched data affects what's on screen; ContentView
    /// observes this and asks the MapViewModel to reload.
    private(set) var dataGeneration = 0

    /// Hour key the map is currently rendering (set by MapViewModel), so a
    /// background prefetch only triggers a reload when it changes visible data.
    var displayedHourKey: Int?

    private var ready = false
    private var setupTask: Task<Void, Never>?
    private var grid: SalishSeaCastAPI.LiveGrid?
    private var sliceIndex: [Int: Date] = [:]                       // hourKey → fetchedAt
    private var sliceRetryAfter: [Int: Date] = [:]                  // hourKey → don't retry before
    private var vectorCache: [Int: [CurrentVector]] = [:]
    private var vectorCacheOrder: [Int] = []                        // LRU, most recent last
    private var slicesInFlight: Set<Int> = []
    private var sshSeries: [String: [(t: Int, ssh: Double)]] = [:]  // gauge dataset → series
    private var sshFetchedAt: [String: Date] = [:]                  // gauge dataset → fetchedAt
    private var sshGeneration = 0
    private var calibrationCache: [String: Double] = [:]
    private var refreshing = false
    private var landMaskCache: [CurrentVector]?

    init(settings: AppSettings, network: NetworkMonitor) {
        self.settings = settings
        self.network = network
    }

    private var fetchingAllowed: Bool { !settings.offlineOnly && network.isOnline }

    /// Hour bucket for a moment in time — slices are keyed by the epoch second
    /// of their hour's start.
    static func hourKey(for date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 3600) * 3600
    }

    /// The dataset's time axis holds interval centers: the slice covering the
    /// hour starting at `hourKey` sits at HH:30.
    private static func sliceCenter(hourKey: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(hourKey) + 1800)
    }

    // MARK: - Lifecycle

    /// Long-running entry point (run from ContentView's `.task`): open the
    /// cache, then re-check staleness periodically while the app is open.
    /// Foreground/network/toggle transitions call `kick()` in between.
    func start() async {
        await ensureReady()
        while !Task.isCancelled {
            kick()
            try? await Task.sleep(for: .seconds(600))
        }
    }

    /// Nudge the refresh loop — cheap and safe to call on any trigger.
    func kick() {
        guard ready, fetchingAllowed, !refreshing else { return }
        refreshing = true
        Task {
            await refresh()
            refreshing = false
        }
    }

    private func ensureReady() async {
        guard !ready else { return }
        // Coalesce concurrent callers (start() and the first currents() race
        // at launch) onto one setup pass; on failure the task slot clears so
        // a later call can retry.
        if setupTask == nil {
            setupTask = Task { await self.performSetup() }
        }
        await setupTask?.value
        if !ready { setupTask = nil }
    }

    private func performSetup() async {
        do {
            try await store.setup()
            // Everything cached is served even when offline — that's the point.
            grid = try await store.loadGrid()
            sshSeries = try await store.sshSeries()
            sshFetchedAt = await loadSSHFetchStamps()
            let cutoff = Self.hourKey(for: Date().addingTimeInterval(-48 * 3600))
            try await store.deleteSlices(before: cutoff)
            sliceIndex = try await store.sliceIndex()
            ready = true
        } catch {
            // Cache unavailable — live data stays off; offline data still works.
        }
    }

    // Per-gauge fetch stamps persist as one JSON dict in live_meta.
    private static let sshStampsKey = "ssh_fetched_at_by_gauge"

    private func loadSSHFetchStamps() async -> [String: Date] {
        guard let raw = try? await store.meta(Self.sshStampsKey),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return dict.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func saveSSHFetchStamps() async {
        let dict = sshFetchedAt.mapValues(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(dict),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? await store.setMeta(Self.sshStampsKey, raw)
    }

    // MARK: - Refresh

    private func refresh() async {
        guard ready, fetchingAllowed else { return }

        // Grid geometry first — without lon/lat nothing else renders.
        if grid == nil {
            guard let fetched = try? await client.fetchGrid() else { return }
            try? await store.saveGrid(fetched)
            grid = fetched
        }

        await refreshSSHIfStale()

        // Prefetch hourly current fields nearest-first, so the hours the user
        // is most likely looking at arrive before the far end of the horizon.
        let nowKey = Self.hourKey(for: Date())
        let wanted = (-Self.backfillHours...Self.horizonHours)
            .map { nowKey + $0 * 3600 }
            .sorted { abs($0 - nowKey) < abs($1 - nowKey) }
        for hourKey in wanted {
            guard fetchingAllowed, !Task.isCancelled else { return }
            if let fetchedAt = sliceIndex[hourKey],
               Date().timeIntervalSince(fetchedAt) < Self.sliceMaxAge { continue }
            if let retryAt = sliceRetryAfter[hourKey], retryAt > Date() { continue }
            await fetchSlice(hourKey: hourKey)
        }

        let cutoff = Self.hourKey(for: Date().addingTimeInterval(-48 * 3600))
        try? await store.deleteSlices(before: cutoff)
        sliceIndex = sliceIndex.filter { $0.key >= cutoff }
    }

    private func refreshSSHIfStale() async {
        // Staleness is tracked per gauge: a partial success (flaky link, one
        // dataset down) must not freeze the failed gauges' older series as
        // "fresh" for the next 6 h.
        let now = Date()
        let stale = SalishSeaCastAPI.gauges.filter { gauge in
            guard sshSeries[gauge.dataset] != nil,
                  let fetchedAt = sshFetchedAt[gauge.dataset] else { return true }
            return now.timeIntervalSince(fetchedAt) >= Self.sshMaxAge
        }
        guard !stale.isEmpty else { return }

        // Trailing history feeds the datum calibration (see sshHistory);
        // everything after now feeds the chart, out to the forecast's end.
        let from = now.addingTimeInterval(-Self.sshHistory)
        var fetched: [String: [(t: Int, ssh: Double)]] = [:]
        await withTaskGroup(of: (String, [(t: Int, ssh: Double)])?.self) { group in
            for gauge in stale {
                group.addTask { [client] in
                    guard let samples = try? await client.fetchSSH(gauge: gauge, from: from),
                          samples.count >= 2 else { return nil }
                    return (gauge.dataset, samples)
                }
            }
            for await result in group {
                if let (dataset, samples) = result { fetched[dataset] = samples }
            }
        }
        guard !fetched.isEmpty else { return }

        for (dataset, samples) in fetched {
            try? await store.replaceSSH(gauge: dataset, samples: samples)
            sshSeries[dataset] = samples
            sshFetchedAt[dataset] = now
        }
        await saveSSHFetchStamps()
        sshGeneration += 1
        calibrationCache = [:]
        dataGeneration += 1
    }

    private func fetchSlice(hourKey: Int) async {
        guard !slicesInFlight.contains(hourKey) else { return }
        slicesInFlight.insert(hourKey)
        defer { slicesInFlight.remove(hourKey) }
        do {
            guard let (center, points) = try await client.fetchCurrentsSlice(
                      center: Self.sliceCenter(hourKey: hourKey)),
                  Self.hourKey(for: center) == hourKey
            else {
                // Closest-match gave a different hour → not published yet.
                sliceRetryAfter[hourKey] = Date().addingTimeInterval(Self.sliceRetryDelay)
                return
            }
            try await store.saveSlice(hourKey: hourKey, points: points, fetchedAt: Date())
            sliceIndex[hourKey] = Date()
            sliceRetryAfter[hourKey] = nil
            vectorCache[hourKey] = nil
            vectorCacheOrder.removeAll { $0 == hourKey }
            if hourKey == displayedHourKey { dataGeneration += 1 }
        } catch {
            // Network hiccup or hour outside the dataset — the map falls back
            // to the atlas and the periodic refresh retries after the delay.
            sliceRetryAfter[hourKey] = Date().addingTimeInterval(Self.sliceRetryDelay)
        }
    }

    // MARK: - Lookup (called by MapViewModel)

    /// Live current vectors for the hour containing `date`, or nil when live
    /// data can't/shouldn't be shown (offline-only, no coverage) — callers
    /// fall back to the bundled atlas. A cache miss for a plausible hour kicks
    /// off an on-demand fetch; `dataGeneration` bumps when it lands.
    func currents(for date: Date) async -> [CurrentVector]? {
        guard !settings.offlineOnly else { return nil }
        await ensureReady()
        guard ready, let grid else { return nil }

        let hourKey = Self.hourKey(for: date)
        if let cached = vectorCache[hourKey] {
            touchCache(hourKey)
            return cached
        }

        if sliceIndex[hourKey] != nil,
           let points = try? await store.loadSlicePoints(hourKey: hourKey) {
            // Re-check after the suspension: an interleaved call for the same
            // hour (scrub tick vs. data-generation refresh) may have already
            // cached it — inserting twice would desync the LRU order.
            if let cached = vectorCache[hourKey] {
                touchCache(hourKey)
                return cached
            }
            // The ~17k-point trig conversion is pure; keep it off the main
            // actor so a scrub-time cache miss can't eat into frame budget.
            let vectors = await Task.detached(priority: .userInitiated) {
                Self.vectors(from: points, grid: grid)
            }.value
            vectorCache[hourKey] = vectors
            touchCache(hourKey)
            if vectorCacheOrder.count > Self.vectorCacheLimit {
                vectorCache[vectorCacheOrder.removeFirst()] = nil
            }
            return vectors
        }

        let offset = TimeInterval(hourKey) - Date().timeIntervalSince1970
        if fetchingAllowed, offset > Self.onDemandPast, offset < Self.onDemandFuture,
           sliceRetryAfter[hourKey].map({ $0 <= Date() }) ?? true {
            Task { await fetchSlice(hourKey: hourKey) }
        }
        return nil
    }

    /// Mark an hour most-recently-used (LRU order, most recent last).
    private func touchCache(_ hourKey: Int) {
        vectorCacheOrder.removeAll { $0 == hourKey }
        vectorCacheOrder.append(hourKey)
    }

    /// Dry (land) model cells adjacent to at least one wet cell — the model's
    /// shoreline band — as zero-speed vectors. The particle renderer feeds
    /// these into its interpolation as "wetness 0" points so particles die at
    /// the model coastline instead of coasting ~1 km onto land past the
    /// outermost wet point. NEMO's land mask is time-invariant, so the band is
    /// computed once from any cached slice and reused for the app's lifetime.
    /// nil when live data can't be shown (offline-only, cold cache) — the
    /// atlas needs no mask, its renderer behavior is unchanged without one.
    func landMask() async -> [CurrentVector]? {
        guard !settings.offlineOnly else { return nil }
        await ensureReady()
        guard ready, let grid else { return nil }
        if let cached = landMaskCache { return cached }
        guard let hourKey = sliceIndex.keys.max(),
              let points = try? await store.loadSlicePoints(hourKey: hourKey)
        else { return nil }
        // Re-check after the suspension: a concurrent caller may have already
        // computed and cached the mask.
        if let cached = landMaskCache { return cached }
        let mask = await Task.detached(priority: .userInitiated) {
            Self.dryShoreline(wet: points, grid: grid)
        }.value
        landMaskCache = mask
        return mask
    }

    /// The strided-grid cells with no velocity (land) that touch a wet cell,
    /// 8-connected. Pure; runs off the main actor.
    private nonisolated static func dryShoreline(wet points: [SalishSeaCastAPI.WetPoint],
                                                 grid: SalishSeaCastAPI.LiveGrid) -> [CurrentVector] {
        let rows = SalishSeaCastAPI.stridedRows
        let cols = SalishSeaCastAPI.stridedCols
        let cells = rows * cols
        var isWet = [Bool](repeating: false, count: cells)
        for p in points where Int(p.index) < cells { isWet[Int(p.index)] = true }

        var seen = [Bool](repeating: false, count: cells)
        var out: [CurrentVector] = []
        for p in points {
            let i = Int(p.index)
            guard i < cells else { continue }
            let sy = i / cols, sx = i % cols
            for dy in -1...1 {
                for dx in -1...1 where (dy, dx) != (0, 0) {
                    let ny = sy + dy, nx = sx + dx
                    guard (0..<rows).contains(ny), (0..<cols).contains(nx) else { continue }
                    let n = ny * cols + nx
                    guard !isWet[n], !seen[n] else { continue }
                    seen[n] = true
                    guard n < grid.lat.count,
                          grid.lat[n].isFinite, grid.lon[n].isFinite else { continue }
                    out.append(CurrentVector(lat: Double(grid.lat[n]),
                                             lon: Double(grid.lon[n]),
                                             speed_ms: 0, direction_deg: 0))
                }
            }
        }
        return out
    }

    /// Live water-level series for `station` on its own datum, or nil when no
    /// gauge is near enough / no data / calibration isn't possible yet.
    func liveTideSeries(for station: TideStation) async -> LiveTideSeries? {
        guard !settings.offlineOnly, ready,
              let gauge = Self.nearestGauge(lat: station.lat, lon: station.lon),
              let raw = sshSeries[gauge.dataset], raw.count >= 2,
              let k = await calibration(gauge: gauge, station: station, samples: raw)
        else { return nil }
        let samples = raw.map {
            (time: Date(timeIntervalSince1970: TimeInterval($0.t)), height: $0.ssh - k)
        }
        return LiveTideSeries(gaugeName: gauge.name, samples: samples)
    }

    // MARK: - Conversion & calibration

    /// NEMO east/north components → the app's speed + compass flow bearing
    /// (0 = N, the convention `VelocityField`/arrows expect). Nonisolated so
    /// callers can run it off the main actor.
    private nonisolated static func vectors(from points: [SalishSeaCastAPI.WetPoint],
                                            grid: SalishSeaCastAPI.LiveGrid) -> [CurrentVector] {
        var out: [CurrentVector] = []
        out.reserveCapacity(points.count)
        for p in points {
            let i = Int(p.index)
            guard i < grid.lat.count else { continue }
            let lat = Double(grid.lat[i]), lon = Double(grid.lon[i])
            guard lat.isFinite, lon.isFinite else { continue }
            let e = Double(p.east), n = Double(p.north)
            var dir = atan2(e, n) * 180 / .pi
            if dir < 0 { dir += 360 }
            out.append(CurrentVector(lat: lat, lon: lon,
                                     speed_ms: (e * e + n * n).squareRoot(),
                                     direction_deg: dir))
        }
        return out
    }

    private static func nearestGauge(lat: Double, lon: Double) -> SalishSeaCastAPI.Gauge? {
        let cosLat = cos(lat * .pi / 180)
        func dist2(_ g: SalishSeaCastAPI.Gauge) -> Double {
            let dLat = g.lat - lat
            let dLon = (g.lon - lon) * cosLat
            return dLat * dLat + dLon * dLon
        }
        guard let gauge = SalishSeaCastAPI.gauges.min(by: { dist2($0) < dist2($1) }),
              dist2(gauge) <= gaugeMaxDistanceDeg * gaugeMaxDistanceDeg else { return nil }
        return gauge
    }

    /// The model's ssh is height above the geoid (≈ local mean sea level); the
    /// app's stations use chart datum (CD/MLLW). Rather than bundling a datum
    /// constant per gauge, calibrate empirically: over the trailing few days,
    /// the mean difference between the model's ssh and the station's own
    /// predicted heights is the datum offset plus the mean surge over the
    /// window. Tidal-phase error averages out within a lunar day; sustained
    /// surge does not — the multi-day window only dilutes it (a 1-day surge
    /// biases the mean ~3.5× less than over a single day), which is the
    /// accepted residual error of this approach. The corrected series is
    /// then ssh − K.
    private func calibration(gauge: SalishSeaCastAPI.Gauge, station: TideStation,
                             samples: [(t: Int, ssh: Double)]) async -> Double? {
        let cacheKey = "\(gauge.dataset)|\(station.id)|\(sshGeneration)"
        if let k = calibrationCache[cacheKey] { return k }

        let now = Date()
        let windowStart = now.addingTimeInterval(-Self.sshHistory)
        // Extra margin so every sample in the window has bracketing extrema —
        // TideCurve clamps outside its events, which would skew the mean.
        guard let events = try? await TideDatabase.shared.events(
                  stationID: station.id,
                  from: windowStart.addingTimeInterval(-15 * 3600),
                  to: now.addingTimeInterval(15 * 3600)),
              let firstEvent = events.first?.time, let lastEvent = events.last?.time
        else { return nil }

        var sum = 0.0
        var count = 0
        for s in samples {
            let t = Date(timeIntervalSince1970: TimeInterval(s.t))
            guard t >= windowStart, t <= now, t >= firstEvent, t <= lastEvent,
                  let predicted = TideCurve.height(at: t, events: events) else { continue }
            sum += s.ssh - predicted
            count += 1
        }
        // Most of a tidal cycle (≥ 20 h of 10-min samples), or the mean is a
        // phase artifact rather than a datum.
        guard count >= 120 else { return nil }
        let k = sum / Double(count)
        calibrationCache[cacheKey] = k
        return k
    }
}
