import SwiftUI
import MapLibre
import CoreLocation

struct MapLibreView: UIViewRepresentable {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    // Day / Night basemap styles (see DESIGN.md §2.3).
    static func styleURL(for scheme: ColorScheme) -> URL? {
        let name = scheme == .dark ? "stub-style-dark" : "stub-style-light"
        return Bundle.main.url(forResource: name, withExtension: "json")
    }

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

        context.coordinator.lastScheme = colorScheme
        mapView.styleURL = Self.styleURL(for: colorScheme)

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Swap the basemap when the system appearance flips, re-applying the
        // current vectors once the new style finishes loading.
        if context.coordinator.lastScheme != colorScheme {
            context.coordinator.lastScheme = colorScheme
            context.coordinator.prepareForStyleReload(vm.currentVectors)
            mapView.styleURL = Self.styleURL(for: colorScheme)
        }
        context.coordinator.updateVectors(vm.currentVectors, on: mapView)
        // Push the latest velocity field to the particle layer. Read here so
        // Observation re-invokes updateUIView whenever the field changes.
        context.coordinator.updateField(vm.velocityField)
        context.coordinator.setParticleDark(colorScheme == .dark)
        // Particles vs arrows, honouring the Reduce-Motion / Low-Power fallback,
        // plus pause-on-background. Read here so Observation re-runs updateUIView
        // when the setting, accessibility/power state, or scene phase changes.
        context.coordinator.applyCurrentStyle(settings.effectiveCurrentStyle, on: mapView)
        context.coordinator.setForeground(scenePhase == .active)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewportChange: { [vm] bounds in
            Task { await vm.updateViewport(bounds) }
        })
    }

    // MLNMapViewDelegate is an ObjC protocol with no @MainActor annotation; Swift 6 rejects
    // class-level @MainActor on the conforming type. All MLN callbacks are main-thread in
    // practice, so nonisolated(unsafe) on mutable state is correct and safe here.
    final class Coordinator: NSObject, MLNMapViewDelegate, @unchecked Sendable {
        private let sourceID = "salish-vectors"
        private let shaftLayerID = "salish-shafts"
        private let barbLayerID = "salish-barbs"
        private let particleLayerID = "salish-particles"
        nonisolated(unsafe) private var pendingVectors: [CurrentVector]?
        // The custom particle layer, re-created on each style (re)load. Held so
        // updateUIView can push the latest velocity field to it.
        nonisolated(unsafe) private var particleLayer: CurrentParticleLayer?
        // Tracks the basemap appearance currently applied, so we only reload the
        // style on an actual Day/Night flip.
        nonisolated(unsafe) var lastScheme: ColorScheme?
        private let onViewportChange: (ChartBounds) -> Void

        init(onViewportChange: @escaping (ChartBounds) -> Void) {
            self.onViewportChange = onViewportChange
        }

        // Setting styleURL tears down the added source/layers; stash the vectors
        // so didFinishLoading re-applies them onto the new style.
        func prepareForStyleReload(_ vectors: [CurrentVector]) {
            pendingVectors = vectors
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

        // Latest velocity field, retained so it can be re-pushed to a freshly
        // created particle layer after a Day/Night style reload.
        nonisolated(unsafe) private var lastField: VelocityField?

        func updateField(_ field: VelocityField?) {
            // Skip when unchanged: updateUIView fires ~11×/s during a scrub (the
            // arrows' vectors change), and re-uploading the same velocity texture
            // would race the GPU compute pass reading it, jolting the particles.
            guard field?.id != lastField?.id else { return }
            lastField = field
            particleLayer?.update(field: field)
        }

        // Retained so a freshly created layer (after a style reload) can be
        // restored to the correct scheme and current-display mode.
        nonisolated(unsafe) private var lastDark = true
        nonisolated(unsafe) private var lastStyleMode: CurrentStyle = .particles

        func setParticleDark(_ dark: Bool) {
            lastDark = dark
            particleLayer?.setDark(dark)
        }

        func applyCurrentStyle(_ style: CurrentStyle, on mapView: MLNMapView) {
            lastStyleMode = style
            let showArrows = style == .arrows
            if let s = mapView.style {
                s.layer(withIdentifier: shaftLayerID)?.isVisible = showArrows
                s.layer(withIdentifier: barbLayerID)?.isVisible = showArrows
            }
            particleLayer?.setActive(!showArrows)
        }

        func setForeground(_ foreground: Bool) {
            particleLayer?.setForeground(foreground)
        }

        private func addLayers(to style: MLNStyle) {
            let source = MLNShapeSource(identifier: sourceID, shapes: [], options: nil)
            style.addSource(source)

            // Re-runs on every style (re)load, so a Day/Night flip picks up the
            // matching ramp automatically.
            let dark = (lastScheme ?? .dark) == .dark

            let shaftLayer = MLNLineStyleLayer(identifier: shaftLayerID, source: source)
            shaftLayer.lineColor = speedColorExpression(dark: dark)
            shaftLayer.lineWidth = NSExpression(format: "TERNARY(speed_knots < 1.5, 1.0, TERNARY(speed_knots < 3.0, 1.8, 3.0))")
            shaftLayer.lineCap = NSExpression(forConstantValue: "round")
            shaftLayer.predicate = NSPredicate(format: "arrow_type == 'shaft'")

            let barbLayer = MLNLineStyleLayer(identifier: barbLayerID, source: source)
            barbLayer.lineColor = speedColorExpression(dark: dark)
            barbLayer.lineWidth = NSExpression(format: "TERNARY(speed_knots < 1.5, 0.8, TERNARY(speed_knots < 3.0, 1.4, 2.5))")
            barbLayer.predicate = NSPredicate(format: "arrow_type == 'barb'")

            // Visibility is driven by the selected current style (re-applied
            // below), so a Day/Night style reload restores the right mode.
            let showArrows = lastStyleMode == .arrows
            shaftLayer.isVisible = showArrows
            barbLayer.isVisible = showArrows

            style.addLayer(shaftLayer)
            style.addLayer(barbLayer)

            // Animated particle current overlay, drawn above the arrows.
            let particleLayer = CurrentParticleLayer(identifier: particleLayerID)
            style.addLayer(particleLayer)
            self.particleLayer = particleLayer
            // Re-seed the freshly created layer with the field + style/scheme from
            // before the reload, so particles don't blank out on a Day/Night flip.
            particleLayer.update(field: lastField)
            particleLayer.setDark(lastDark)
            particleLayer.setActive(lastStyleMode != .arrows)
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

        private func speedColorExpression(dark: Bool) -> NSExpression {
            let c = UIColor.currentSpeedRamp(dark: dark)
            return NSExpression(format: """
                TERNARY(speed_knots < 0.5, %@,
                TERNARY(speed_knots < 1.5, %@,
                TERNARY(speed_knots < 3.0, %@,
                TERNARY(speed_knots < 4.5, %@, %@))))
            """,
            c[0], c[1], c[2], c[3], c[4])
        }
    }
}
