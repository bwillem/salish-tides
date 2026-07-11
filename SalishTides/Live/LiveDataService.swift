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
    // Widest on-demand window — the rolling dataset spans roughly −5 days to
    // +1.5 days around now; beyond that a request can't succeed.
    private static let onDemandPast: TimeInterval = -4.5 * 86400
    private static let onDemandFuture: TimeInterval = 2.5 * 86400
    // Only pair a station to a gauge within ~15 km: an additive datum
    // correction can't fix the amplitude/phase differences that build up over
    // larger separations, and the bundled predictions are the safer source.
    private static let gaugeMaxDistanceDeg = 0.14
    // Cached, unpacked vector slices kept in memory (scrubbing revisits hours).
    private static let vectorCacheLimit = 4

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
    private var grid: SalishSeaCastAPI.LiveGrid?
    private var sliceIndex: [Int: Date] = [:]                       // hourKey → fetchedAt
    private var vectorCache: [Int: [CurrentVector]] = [:]
    private var vectorCacheOrder: [Int] = []
    private var slicesInFlight: Set<Int> = []
    private var sshSeries: [String: [(t: Int, ssh: Double)]] = [:]  // gauge dataset → series
    private var sshGeneration = 0
    private var calibrationCache: [String: Double] = [:]
    private var refreshing = false

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
        do {
            try await store.setup()
            // Everything cached is served even when offline — that's the point.
            grid = try await store.loadGrid()
            sshSeries = try await store.sshSeries()
            let cutoff = Self.hourKey(for: Date().addingTimeInterval(-48 * 3600))
            try await store.deleteSlices(before: cutoff)
            sliceIndex = try await store.sliceIndex()
            ready = true
        } catch {
            // Cache unavailable — live data stays off; offline data still works.
        }
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
            await fetchSlice(hourKey: hourKey)
        }

        let cutoff = Self.hourKey(for: Date().addingTimeInterval(-48 * 3600))
        try? await store.deleteSlices(before: cutoff)
        sliceIndex = sliceIndex.filter { $0.key >= cutoff }
    }

    private func refreshSSHIfStale() async {
        let fetchedAt = (try? await store.meta("ssh_fetched_at"))
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.sshMaxAge,
           !sshSeries.isEmpty { return }

        // Trailing ~26 h feeds the datum calibration (a full tidal day);
        // everything after feeds the chart, out to the forecast's end.
        let from = Date().addingTimeInterval(-26 * 3600)
        var fetched: [String: [(t: Int, ssh: Double)]] = [:]
        await withTaskGroup(of: (String, [(t: Int, ssh: Double)])?.self) { group in
            for gauge in SalishSeaCastAPI.gauges {
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
        }
        try? await store.setMeta("ssh_fetched_at", String(Date().timeIntervalSince1970))
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
            else { return }   // closest-match gave a different hour → not published
            try await store.saveSlice(hourKey: hourKey, points: points, fetchedAt: Date())
            sliceIndex[hourKey] = Date()
            vectorCache[hourKey] = nil
            vectorCacheOrder.removeAll { $0 == hourKey }
            if hourKey == displayedHourKey { dataGeneration += 1 }
        } catch {
            // Network hiccup or hour outside the dataset — the map falls back
            // to the atlas and the periodic refresh retries later.
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
        if let cached = vectorCache[hourKey] { return cached }

        if sliceIndex[hourKey] != nil,
           let points = try? await store.loadSlicePoints(hourKey: hourKey) {
            let vectors = Self.vectors(from: points, grid: grid)
            vectorCache[hourKey] = vectors
            vectorCacheOrder.append(hourKey)
            if vectorCacheOrder.count > Self.vectorCacheLimit {
                vectorCache[vectorCacheOrder.removeFirst()] = nil
            }
            return vectors
        }

        let offset = TimeInterval(hourKey) - Date().timeIntervalSince1970
        if fetchingAllowed, offset > Self.onDemandPast, offset < Self.onDemandFuture {
            Task { await fetchSlice(hourKey: hourKey) }
        }
        return nil
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
    /// (0 = N, the convention `VelocityField`/arrows expect).
    private static func vectors(from points: [SalishSeaCastAPI.WetPoint],
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
    /// constant per gauge, calibrate empirically: over the trailing lunar day,
    /// the mean difference between the model's ssh and the station's own
    /// predicted heights is the datum offset (plus mean surge, which averages
    /// out over a tidal cycle). The corrected series is then ssh − K.
    private func calibration(gauge: SalishSeaCastAPI.Gauge, station: TideStation,
                             samples: [(t: Int, ssh: Double)]) async -> Double? {
        let cacheKey = "\(gauge.dataset)|\(station.id)|\(sshGeneration)"
        if let k = calibrationCache[cacheKey] { return k }

        let now = Date()
        let windowStart = now.addingTimeInterval(-25 * 3600)
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
