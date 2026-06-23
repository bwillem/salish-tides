import SwiftUI
import MapLibre
import CoreLocation

struct MapLibreView: UIViewRepresentable {
    @Environment(MapViewModel.self) private var vm

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.compassView.compassVisibility = .adaptive
        mapView.minimumZoomLevel = 7
        mapView.maximumZoomLevel = 14

        // Default center: Salish Sea
        let center = CLLocationCoordinate2D(latitude: 48.8, longitude: -123.2)
        mapView.setCenter(center, zoomLevel: 9.5, animated: false)

        if let styleURL = Bundle.main.url(forResource: "stub-style", withExtension: "json") {
            mapView.styleURL = styleURL
        }

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.updateVectors(vm.currentVectors, on: mapView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewportChange: { [vm] bounds in
            Task { await vm.updateViewport(bounds) }
        })
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate, @unchecked Sendable {
        private let sourceID = "salish-vectors"
        private let shaftLayerID = "salish-shafts"
        private let barbLayerID = "salish-barbs"
        private var pendingVectors: [CurrentVector]?
        private let onViewportChange: (ChartBounds) -> Void

        init(onViewportChange: @escaping (ChartBounds) -> Void) {
            self.onViewportChange = onViewportChange
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            addLayers(to: style)
            if let v = pendingVectors {
                applyVectors(v, style: style)
                pendingVectors = nil
            }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let b = mapView.visibleCoordinateBounds
            let viewport = ChartBounds(
                lat_min: b.sw.latitude,
                lat_max: b.ne.latitude,
                lon_min: b.sw.longitude,
                lon_max: b.ne.longitude
            )
            onViewportChange(viewport)
        }

        func updateVectors(_ vectors: [CurrentVector], on mapView: MLNMapView) {
            guard let style = mapView.style else {
                pendingVectors = vectors
                return
            }
            applyVectors(vectors, style: style)
        }

        private func addLayers(to style: MLNStyle) {
            let source = MLNShapeSource(identifier: sourceID, shapes: [], options: nil)
            style.addSource(source)

            let shaftLayer = MLNLineStyleLayer(identifier: shaftLayerID, source: source)
            shaftLayer.lineColor = speedColorExpression()
            shaftLayer.lineWidth = NSExpression(format: "max(1.0, min(3.0, speed_knots * 0.8))")
            shaftLayer.lineCap = NSExpression(forConstantValue: "round")
            shaftLayer.predicate = NSPredicate(format: "arrow_type == 'shaft'")

            let barbLayer = MLNLineStyleLayer(identifier: barbLayerID, source: source)
            barbLayer.lineColor = speedColorExpression()
            barbLayer.lineWidth = NSExpression(format: "max(0.8, min(2.5, speed_knots * 0.7))")
            barbLayer.predicate = NSPredicate(format: "arrow_type == 'barb'")

            style.addLayer(shaftLayer)
            style.addLayer(barbLayer)
        }

        private func applyVectors(_ vectors: [CurrentVector], style: MLNStyle) {
            guard let source = style.source(withIdentifier: sourceID) as? MLNShapeSource else { return }
            source.shape = MLNShapeCollectionFeature(shapes: buildFeatures(from: vectors))
        }

        private func buildFeatures(from vectors: [CurrentVector]) -> [MLNPolylineFeature] {
            var features: [MLNPolylineFeature] = []
            features.reserveCapacity(vectors.count * 3)

            let halfDeg = 0.005       // ~500 m at Salish Sea latitudes
            // barb = 35% of full shaft (2×halfDeg) → 0.70 × halfDeg
            let barbFraction = 0.70

            for v in vectors where v.isSignificant {
                let θ = v.direction_deg * .pi / 180
                let dLat = cos(θ) * halfDeg
                let dLon = sin(θ) * halfDeg

                let tail = CLLocationCoordinate2D(latitude: v.lat - dLat, longitude: v.lon - dLon)
                let tip  = CLLocationCoordinate2D(latitude: v.lat + dLat, longitude: v.lon + dLon)

                var shaft = [tail, tip]
                let shaftFeature = MLNPolylineFeature(coordinates: &shaft, count: 2)
                shaftFeature.attributes = ["speed_knots": v.speedKnots, "arrow_type": "shaft"]
                features.append(shaftFeature)

                // Two barbs at ±25° from the reversed direction
                let backθ = θ + .pi
                let barbLen = halfDeg * barbFraction
                for spread in [-0.4363, 0.4363] {
                    let βθ = backθ + spread
                    var barb = [
                        tip,
                        CLLocationCoordinate2D(
                            latitude:  tip.latitude  + cos(βθ) * barbLen,
                            longitude: tip.longitude + sin(βθ) * barbLen
                        )
                    ]
                    let barbFeature = MLNPolylineFeature(coordinates: &barb, count: 2)
                    barbFeature.attributes = ["speed_knots": v.speedKnots, "arrow_type": "barb"]
                    features.append(barbFeature)
                }
            }
            return features
        }

        private func speedColorExpression() -> NSExpression {
            NSExpression(format: """
                TERNARY(speed_knots < 0.5, %@,
                TERNARY(speed_knots < 1.5, %@,
                TERNARY(speed_knots < 3.0, %@,
                TERNARY(speed_knots < 4.5, %@, %@))))
            """,
            UIColor(red: 0.13, green: 0.40, blue: 0.67, alpha: 1),
            UIColor(red: 0.45, green: 0.68, blue: 0.82, alpha: 1),
            UIColor(red: 1.00, green: 1.00, blue: 0.75, alpha: 1),
            UIColor(red: 0.96, green: 0.43, blue: 0.26, alpha: 1),
            UIColor(red: 0.84, green: 0.19, blue: 0.15, alpha: 1))
        }
    }
}
