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

// MARK: - Offline downloads

/// Downloads and tracks `MLNOfflinePack`s so a network style selected while
/// online becomes genuinely available offline — not just whatever the ambient
/// cache happened to capture. Vector styles only (see
/// `Basemap.supportsOfflineDownload`); raster imagery is too large to pack.
///
/// Each pack covers the Salish envelope (the same bounds `build-pmtiles.sh` uses
/// for the bundled basemap) across the app's zoom range. On completion the style
/// is reported back so it can be marked offline-selectable.
@MainActor
@Observable
final class OfflineMapManager {
    enum DownloadState: Equatable {
        case none
        case downloading(Double)   // fraction 0…1
        case ready
        case failed
    }

    private static let bounds = MLNCoordinateBoundsMake(
        CLLocationCoordinate2D(latitude: 46.92, longitude: -128.23),
        CLLocationCoordinate2D(latitude: 51.20, longitude: -122.05))
    private static let minZoom: Double = 7
    private static let maxZoom: Double = 14

    /// Per-style download state, keyed by `Basemap.rawValue`. Observed by the UI,
    /// which records a `.ready` style as offline-selectable.
    private(set) var states: [String: DownloadState] = [:]

    // The shared storage loads its pack list asynchronously, so we don't create
    // packs until it has — otherwise we can't tell an existing pack from a new
    // one and end up duplicating it. Requests that arrive first are stashed with
    // their style URL and flushed once the list is known.
    @ObservationIgnored private var packsLoaded = false
    @ObservationIgnored private var pending: [String: URL] = [:]
    @ObservationIgnored private var packsObserver: NSKeyValueObservation?

    /// A Sendable snapshot of a pack, taken synchronously (on the main queue) so
    /// only Sendable data crosses to the main actor — never the non-Sendable
    /// `MLNOfflinePack` / `Notification`.
    private struct PackSnapshot: Sendable {
        let basemapRaw: String
        let stateRaw: Int
        let completed: UInt64
        let expected: UInt64
        init?(_ pack: MLNOfflinePack) {
            guard let raw = String(data: pack.context, encoding: .utf8) else { return nil }
            basemapRaw = raw
            stateRaw = pack.state.rawValue
            completed = pack.progress.countOfResourcesCompleted
            expected = pack.progress.countOfResourcesExpected
        }
        init?(_ note: Notification) {
            guard let pack = note.object as? MLNOfflinePack else { return nil }
            self.init(pack)
        }
    }

    init() {
        // Per-pack progress. MapLibre posts on the main queue, so snapshot the
        // Sendable fields here and hop to the main actor with just that.
        NotificationCenter.default.addObserver(
            forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let snap = PackSnapshot(note) else { return }
            MainActor.assumeIsolated { self?.apply(snap) }
        }
        // We deliberately don't observe MLNOfflinePackError: it fires for
        // *recoverable* errors while the download keeps going, so it isn't a
        // terminal-failure signal. A pack that truly fails becomes `.invalid`,
        // which `apply` maps to `.failed`.

        // The pack list loads asynchronously; reconcile whenever it changes (and
        // once, on load, flush any deferred downloads).
        packsObserver = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) { [weak self] storage, _ in
            let loaded = storage.packs != nil
            Task { @MainActor in self?.reconcile(loaded: loaded) }
        }
    }

    func state(for basemap: Basemap) -> DownloadState { states[basemap.rawValue] ?? .none }

    /// Start (or resume) an offline pack for a downloadable style. No-op if it's
    /// already ready or in flight. Deferred until the pack list has loaded so the
    /// dedup below is reliable across launches.
    func download(_ basemap: Basemap, styleURL: URL) {
        guard basemap.supportsOfflineDownload else { return }
        switch state(for: basemap) {
        case .ready, .downloading: return
        case .none, .failed:       break
        }
        guard packsLoaded else {
            pending[basemap.rawValue] = styleURL
            states[basemap.rawValue] = .downloading(0)   // optimistic; reconciled on load
            return
        }
        startOrAdoptPack(basemap, styleURL: styleURL)
    }

    /// Adopt an existing on-disk pack for this style rather than creating a
    /// duplicate; otherwise add a fresh one. Only called once the pack list is
    /// loaded (so `packs` is non-nil).
    private func startOrAdoptPack(_ basemap: Basemap, styleURL: URL) {
        if let existing = MLNOfflineStorage.shared.packs?
            .first(where: { Self.basemap($0.context) == basemap }) {
            existing.requestProgress()   // drives the UI state via the progress notification
            existing.resume()            // continue a partial download; a complete pack is unaffected
            return
        }
        states[basemap.rawValue] = .downloading(0)
        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL, bounds: Self.bounds,
            fromZoomLevel: Self.minZoom, toZoomLevel: Self.maxZoom)
        let raw = basemap.rawValue
        MLNOfflineStorage.shared.addPack(for: region, withContext: Self.context(basemap)) { [weak self] pack, error in
            if let pack, error == nil {
                pack.resume()   // synchronous, on the main queue per the API contract
            } else {
                MainActor.assumeIsolated { self?.states[raw] = .failed }
            }
        }
    }

    /// React to the shared pack list loading/changing: refresh each known pack's
    /// UI state, and once the list is available flush any downloads that were
    /// deferred while it loaded.
    private func reconcile(loaded: Bool) {
        for pack in MLNOfflineStorage.shared.packs ?? [] where Self.basemap(pack.context) != nil {
            pack.requestProgress()   // packs restored from disk start `.unknown`
        }
        guard loaded, !packsLoaded else { return }
        packsLoaded = true
        let deferred = pending
        pending.removeAll()
        for (raw, url) in deferred {
            guard let basemap = Basemap(rawValue: raw), state(for: basemap) != .ready else { continue }
            startOrAdoptPack(basemap, styleURL: url)
        }
    }

    private func apply(_ snap: PackSnapshot) {
        guard Basemap(rawValue: snap.basemapRaw) != nil,
              let state = MLNOfflinePackState(rawValue: snap.stateRaw) else { return }
        switch state {
        case .complete:
            states[snap.basemapRaw] = .ready
        case .active:
            let frac = snap.expected > 0 ? Double(snap.completed) / Double(snap.expected) : 0
            states[snap.basemapRaw] = .downloading(min(frac, 0.999))
        case .invalid:
            states[snap.basemapRaw] = .failed
        case .inactive, .unknown:
            break
        @unknown default:
            break
        }
    }

    private static func context(_ basemap: Basemap) -> Data { Data(basemap.rawValue.utf8) }
    private static func basemap(_ context: Data) -> Basemap? {
        String(data: context, encoding: .utf8).flatMap(Basemap.init)
    }
}
