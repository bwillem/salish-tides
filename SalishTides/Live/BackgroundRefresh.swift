import BackgroundTasks
import Foundation

/// Scheduling side of the background refresh. The *handler* is registered
/// declaratively by the `.backgroundTask(.appRefresh:)` scene modifier in
/// `SalishTidesApp`, so this type only submits the requests that ask iOS to
/// launch us — reschedule-first inside the handler, and on every background
/// transition — keeping exactly one request pending at a time.
///
/// Delivery is opportunistic and best-effort: iOS weighs app-usage patterns,
/// battery, Low Power Mode, and connectivity, and skips it entirely when the
/// user disables Background App Refresh. `earliestBeginDate` is a floor, never a
/// guarantee — the cache is designed to tolerate long gaps between runs.
enum BackgroundRefresh {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in project.yml /
    /// Info.plist and the identifier passed to `.backgroundTask(.appRefresh:)`.
    static let taskIdentifier = "com.bguenther.salishtides.refresh"

    /// Earliest the system should consider relaunching us. A floor, not a
    /// schedule — sized against the live-data staleness thresholds (SSH 6 h,
    /// slices 12 h) so a granted run has something worth fetching.
    private static let earliestInterval: TimeInterval = 2 * 3600

    /// Submit (or replace) the pending app-refresh request. Cheap and safe to
    /// call repeatedly; a new submission supersedes any prior pending one.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected when the user has Background App Refresh off
            // (.notPermitted) or the feature is unavailable — live data still
            // refreshes in the foreground, so this is diagnostic only.
            Log.live.error("background refresh submit failed: \(error, privacy: .public)")
        }
    }
}
