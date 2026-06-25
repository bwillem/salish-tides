import Foundation
import Network
import Observation

/// Observable network reachability. Drives the "online only" map styles — the
/// app is offline-first, so this only *enables* online enhancements when a
/// connection exists (Starlink, dock WiFi). Same plumbing a future SalishSeaCast
/// integration can hang off of.
@MainActor
@Observable
final class NetworkMonitor {
    /// `true` when a usable path exists. Optimistic until the first path update
    /// so the UI isn't briefly disabled at launch.
    private(set) var isOnline = true

    /// `true` once an actually-satisfied path has been observed. Use this with
    /// `isOnline` before treating "online" as a durable fact (e.g. recording a
    /// style as cached) so the optimistic launch default can't trigger it.
    private(set) var didConfirmOnline = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bguenther.salishtides.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // DispatchQueue.main.async preserves FIFO order (independent Tasks
            // don't), so a stale update can't overwrite a newer one. We're on the
            // main thread inside, hence assumeIsolated.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(online: online) }
            }
        }
        monitor.start(queue: queue)
    }

    private func apply(online: Bool) {
        isOnline = online
        if online { didConfirmOnline = true }
    }

    deinit { monitor.cancel() }
}
