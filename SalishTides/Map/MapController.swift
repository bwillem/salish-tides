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

    /// A Sendable snapshot of a pack, extracted synchronously inside the observer
    /// block (we're on the main queue) so only Sendable data crosses to the main
    /// actor — never the non-Sendable `MLNOfflinePack` / `Notification`.
    private struct PackSnapshot: Sendable {
        let basemapRaw: String
        let stateRaw: Int
        let completed: UInt64
        let expected: UInt64
        init?(_ note: Notification) {
            guard let pack = note.object as? MLNOfflinePack,
                  let raw = String(data: pack.context, encoding: .utf8) else { return nil }
            basemapRaw = raw
            stateRaw = pack.state.rawValue
            completed = pack.progress.countOfResourcesCompleted
            expected = pack.progress.countOfResourcesExpected
        }
    }

    init() {
        let nc = NotificationCenter.default
        // MapLibre posts these on the main queue; we snapshot Sendable fields in
        // the block and hop to the main actor with just that.
        nc.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] note in
            guard let snap = PackSnapshot(note) else { return }
            MainActor.assumeIsolated { self?.apply(snap) }
        }
        nc.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] note in
            guard let snap = PackSnapshot(note) else { return }
            MainActor.assumeIsolated { self?.markFailed(snap.basemapRaw) }
        }
        restoreExistingPacks()
    }

    func state(for basemap: Basemap) -> DownloadState { states[basemap.rawValue] ?? .none }

    /// Start (or resume) an offline pack for a downloadable style. No-op if it's
    /// already ready or in flight.
    func download(_ basemap: Basemap, styleURL: URL) {
        guard basemap.supportsOfflineDownload else { return }
        switch state(for: basemap) {
        case .ready, .downloading: return
        case .none, .failed:       break
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

    /// Packs created in a previous session start in `.unknown`; ask each for its
    /// progress so we can restore the UI state (and re-report any completed one).
    private func restoreExistingPacks() {
        for pack in MLNOfflineStorage.shared.packs ?? [] {
            guard Self.basemap(pack.context) != nil else { continue }
            pack.requestProgress()
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
        default:
            break
        }
    }

    private func markFailed(_ basemapRaw: String) {
        guard Basemap(rawValue: basemapRaw) != nil else { return }
        states[basemapRaw] = .failed
    }

    private static func context(_ basemap: Basemap) -> Data { Data(basemap.rawValue.utf8) }
    private static func basemap(_ context: Data) -> Basemap? {
        String(data: context, encoding: .utf8).flatMap(Basemap.init)
    }
}
