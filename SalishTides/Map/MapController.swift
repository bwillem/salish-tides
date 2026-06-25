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
