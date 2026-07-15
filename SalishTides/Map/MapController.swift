import CoreLocation
import MapLibre
import Observation

/// Bridges SwiftUI map-control buttons to the live `MLNMapView`: publishes the
/// current heading (for the compass) and exposes imperative commands (reset
/// north, recenter on the user). Injected via the environment; `MapLibreView`
/// wires up `mapView` and feeds `bearing`.
@MainActor
@Observable
final class MapController {
    /// The live map view. Plumbing, not observed.
    @ObservationIgnored weak var mapView: MLNMapView?

    /// Map heading in degrees (0 = north-up), updated as the user rotates.
    var bearing: Double = 0

    /// Whether the map is essentially north-up — the compass control hides here,
    /// matching Apple/Google Maps.
    var isNorthUp: Bool {
        let b = bearing.truncatingRemainder(dividingBy: 360)
        return b < 0.5 || b > 359.5
    }

    /// Animate the map back to north-up and level (no tilt).
    func resetNorth() {
        guard let mapView else { return }
        let camera = mapView.camera
        camera.heading = 0
        camera.pitch = 0
        mapView.setCamera(camera, animated: true)
    }

    /// Center on the user's location at the current zoom (the Maps "locate"
    /// button). Uses `setCenter` rather than `.follow` tracking, which would
    /// zoom in to its own default level — too close for a planning chart.
    func recenterOnUser() {
        guard let mapView,
              let coordinate = mapView.userLocation?.coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { return }
        mapView.setCenter(coordinate, animated: true)
    }
}

// MARK: - Crosshair presentation

/// Drives the crosshair's emphasis (Navionics-style). The reticle is always
/// on-screen — faint at rest — and becomes fully prominent while the user is
/// actively repositioning the view (panning/zooming the map or scrubbing the
/// timeline), then eases back to faint a couple of seconds after they let go.
///
/// Interaction sources call `interactionBegan()` continuously while active and
/// `interactionEnded()` once on release; the grace timer keeps the reticle
/// emphasized briefly so a pause between gestures (or the map's momentum
/// settling) doesn't flicker it back down.
@MainActor
@Observable
final class CrosshairPresenter {
    /// Whether the reticle is currently emphasized (full contrast) vs. its faint
    /// resting state. The view animates its own opacity off this — quick ramp up,
    /// slower ease down.
    private(set) var isEmphasized = false

    /// How long the reticle stays emphasized after the last interaction ends.
    private static let lingerSeconds: Double = 2

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// A pan/zoom gesture or scrub is in progress — emphasize immediately and
    /// hold. Cheap to call every frame: no-ops once already emphasized.
    func interactionBegan() {
        hideTask?.cancel()
        hideTask = nil
        if !isEmphasized { isEmphasized = true }
    }

    /// The gesture/scrub ended — start (or restart) the linger timer, after which
    /// the reticle eases back to its faint resting state.
    func interactionEnded() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.lingerSeconds))
            guard !Task.isCancelled else { return }
            self?.isEmphasized = false
        }
    }
}

// MARK: - Legacy offline-pack cleanup

/// One-time cleanup of offline map packs left by earlier builds.
///
/// The app no longer downloads `MLNOfflinePack`s for any basemap — Standard
/// ships bundled and the network styles (Satellite, and Ocean when revived)
/// stream, relying on MapLibre's ambient cache for revisited areas. Any pack
/// still on disk is dead weight from a previous version, so once the shared pack
/// list has loaded we remove every one and stop observing. The ambient cache
/// (`setMaximumAmbientCacheSize`) is separate and left untouched.
@MainActor
final class LegacyOfflinePackCleaner {
    private var packsObserver: NSKeyValueObservation?

    init() {
        // The pack list loads asynchronously; act on the first load, then stop.
        // Only the Sendable `loaded` flag crosses to the main actor — the
        // non-Sendable pack objects are read on the main actor inside `purge`.
        packsObserver = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) { [weak self] storage, _ in
            let loaded = storage.packs != nil
            Task { @MainActor in self?.purge(loaded: loaded) }
        }
    }

    private func purge(loaded: Bool) {
        guard loaded else { return }
        for pack in MLNOfflineStorage.shared.packs ?? [] {
            MLNOfflineStorage.shared.removePack(pack)
        }
        packsObserver = nil   // one-shot
    }
}
