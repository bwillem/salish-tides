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
    /// `true` when a usable path exists. Starts optimistic so the UI isn't
    /// briefly disabled before the first path update arrives.
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bguenther.salishtides.network")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
