import Foundation

/// Thin networking wrapper over `SalishSeaCastAPI`. Nonisolated async funcs, so
/// fetching and JSON decoding run off the main actor.
struct SalishSeaCastClient: Sendable {

    enum FetchError: Error {
        case badStatus(Int)
        case responseTooLarge
    }

    // Expected responses top out around 400 KB (a full native window); server
    // data is untrusted, so cap what we'll buffer — the JSONSerialization
    // object graph inflates several× over the byte size, and an unbounded
    // body is a memory-pressure kill.
    private static let maxResponseBytes = 8 * 1024 * 1024

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        // Live data is an enhancement, never a need: don't queue requests
        // waiting for connectivity, and respect Low Data Mode.
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = false
        session = URLSession(configuration: config)
    }

    /// One hourly velocity field. Returns nil for an empty response; the
    /// returned `center` may differ from the requested one when the model
    /// hasn't published that hour (closest-match semantics) — callers check.
    func fetchCurrentsSlice(center: Date) async throws
        -> (center: Date, points: [SalishSeaCastAPI.WetPoint])? {
        let data = try await get(SalishSeaCastAPI.currentsSliceURL(center: center))
        return try SalishSeaCastAPI.parseCurrentsSlice(data)
    }

    /// One hourly native-resolution velocity subwindow (see NativeWindow).
    /// Same closest-match caveat as `fetchCurrentsSlice`.
    func fetchNativeCurrents(center: Date, window: SalishSeaCastAPI.NativeWindow) async throws
        -> (center: Date, points: [SalishSeaCastAPI.NativePoint])? {
        let data = try await get(SalishSeaCastAPI.nativeCurrentsSliceURL(center: center, window: window))
        return try SalishSeaCastAPI.parseNativeCurrentsSlice(data)
    }

    /// Lon/lat of every strided grid cell — static geometry, fetched once.
    func fetchGrid() async throws -> SalishSeaCastAPI.LiveGrid {
        try SalishSeaCastAPI.parseGrid(try await get(SalishSeaCastAPI.gridURL()))
    }

    /// A gauge's 10-minute SSH series from `from` through the forecast end.
    func fetchSSH(gauge: SalishSeaCastAPI.Gauge, from: Date) async throws -> [(t: Int, ssh: Double)] {
        try SalishSeaCastAPI.parseSSH(try await get(SalishSeaCastAPI.sshURL(gauge: gauge, from: from)))
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // ERDDAP reports out-of-range/unpublished requests as errors —
            // treated upstream as "no live data for that hour", not a failure.
            throw FetchError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // Checking after the download is deliberate: the cap's job is to
        // bound what reaches JSONSerialization (whose object graph inflates
        // several× over the byte size), and timeoutIntervalForResource
        // already bounds a stalling server. Per-byte streaming enforcement
        // costs far more than it buys (~millions of iterator steps on the
        // multi-MB grid fetch).
        guard data.count <= Self.maxResponseBytes else {
            throw FetchError.responseTooLarge
        }
        return data
    }
}
