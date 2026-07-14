import SwiftUI
import MapLibre
import CoreLocation

struct MapLibreView: UIViewRepresentable {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(MapController.self) private var mapController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    // Resolved style for the selected basemap + current appearance. Placeholders
    // (MapTiler key, local-tiles URL) are injected by MapStyleLoader, which falls
    // back to the bundled-offline Standard style on any failure.
    private func desiredStyleURL(for scheme: ColorScheme) -> URL? {
        MapStyleLoader.styleURL(for: settings.basemap, dark: scheme == .dark)
    }

    func makeUIView(context: Context) -> MLNMapView {
        // Grow the ambient cache so a day's viewing survives offline (default is
        // ~50 MB). This is what makes online styles render offline afterward.
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(256 * 1024 * 1024, withCompletionHandler: { _ in })

        let mapView = MLNMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        // We render our own compass control (top-left stack), so hide the
        // built-in one.
        mapView.compassView.compassVisibility = .hidden
        mapView.minimumZoomLevel = 7
        mapView.maximumZoomLevel = 14

        // Default center: Salish Sea
        let center = CLLocationCoordinate2D(latitude: 48.8, longitude: -123.2)
        mapView.setCenter(center, zoomLevel: 9.5, animated: false)

        mapController.mapView = mapView
        context.coordinator.lastScheme = colorScheme
        context.coordinator.appliedBasemap = settings.basemap
        mapView.styleURL = desiredStyleURL(for: colorScheme)

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Reload the basemap on a Day/Night flip or a Map Style change,
        // re-applying the current vectors once the new style finishes loading.
        if context.coordinator.lastScheme != colorScheme
            || context.coordinator.appliedBasemap != settings.basemap {
            context.coordinator.lastScheme = colorScheme
            context.coordinator.appliedBasemap = settings.basemap
            context.coordinator.prepareForStyleReload(vm.currentVectors)
            // The outgoing style's land polygons are stale the moment the URL
            // changes; drop them so the particle field falls back to the model
            // mask until the new style renders and the idle re-query lands.
            context.coordinator.invalidateLandPolygons()
            mapView.styleURL = desiredStyleURL(for: colorScheme)
        }
        // Pushes the vectors to both the arrow source and the particle layer.
        // Read vm.currentVectors / vm.currentFieldVectors / vm.currentLandMask
        // here so Observation re-runs updateUIView on change (the coordinator
        // change-detects, so identical passes are cheap).
        context.coordinator.updateVectors(vm.currentVectors,
                                          fieldVectors: vm.currentFieldVectors,
                                          mask: vm.currentLandMask, on: mapView)
        context.coordinator.setParticleDark(colorScheme == .dark)
        // Particles vs arrows, honouring the Reduce-Motion / Low-Power fallback,
        // plus pause-on-background. Read here so Observation re-runs updateUIView
        // when the setting, accessibility/power state, or scene phase changes.
        context.coordinator.applyCurrentStyle(settings.effectiveCurrentStyle, on: mapView)
        context.coordinator.setForeground(scenePhase == .active)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onViewportChange: { [vm] bounds in
                Task { await vm.updateViewport(bounds) }
            },
            onBearingChange: { [mapController] bearing in
                // Only write on an actual change: mapViewRegionIsChanging fires
                // every frame during pan/zoom too, and ContentView observes
                // `bearing`, so a redundant write would re-render the overlay
                // ~60×/sec while panning.
                Task { @MainActor in
                    if mapController.bearing != bearing { mapController.bearing = bearing }
                }
            }
        )
    }

    // MLNMapViewDelegate is an ObjC protocol with no @MainActor annotation; Swift 6 rejects
    // class-level @MainActor on the conforming type. All MLN callbacks are main-thread in
    // practice, so nonisolated(unsafe) on mutable state is correct and safe here.
    final class Coordinator: NSObject, MLNMapViewDelegate, @unchecked Sendable {
        private let sourceID = "salish-vectors"
        private let shaftLayerID = "salish-shafts"
        private let barbLayerID = "salish-barbs"
        private let particleLayerID = "salish-particles"
        private let slackLayerID = "salish-slack"
        nonisolated(unsafe) private var pendingVectors: [CurrentVector]?
        // The custom particle layer, re-created on each style (re)load. Held so
        // updateUIView can push the latest velocity field to it.
        nonisolated(unsafe) private var particleLayer: CurrentParticleLayer?
        // Tracks the basemap appearance currently applied, so we only reload the
        // style on an actual Day/Night flip.
        nonisolated(unsafe) var lastScheme: ColorScheme?
        // Developer basemap selection currently applied; reload only on change.
        nonisolated(unsafe) var appliedBasemap: Basemap?
        private let onViewportChange: (ChartBounds) -> Void
        private let onBearingChange: (Double) -> Void

        init(onViewportChange: @escaping (ChartBounds) -> Void,
             onBearingChange: @escaping (Double) -> Void) {
            self.onViewportChange = onViewportChange
            self.onBearingChange = onBearingChange
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
            onBearingChange(mapView.direction)
            // Recentre the particle field on the new viewport immediately with
            // the data already in hand — a camera move alone never re-runs the
            // SwiftUI update, and waiting for the debounced data reload would
            // leave freshly panned-to water empty (particles reseed only into
            // the field's water cells). Full data follows after the reload.
            let bounds = worldBounds(of: mapView)
            if bounds != lastBoundsWorld {
                lastBoundsWorld = bounds
                lastLandPolygons = landPolygons(from: mapView)
                particleLayer?.update(vectors: lastFieldVectors, mask: lastMask,
                                      landPolygons: lastLandPolygons, boundsWorld: bounds)
            }
        }

        // Live updates while the user rotates, so the compass tracks smoothly.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            onBearingChange(mapView.direction)
        }

        // Latest arrows vectors + particle-field inputs (full-res vectors,
        // land mask, drawn-land polygons, viewport), retained both for change
        // detection and so they can be re-pushed to a freshly created layer
        // after a style reload.
        nonisolated(unsafe) private var lastVectors: [CurrentVector] = []
        nonisolated(unsafe) private var lastFieldVectors: [CurrentVector] = []
        nonisolated(unsafe) private var lastMask: [CurrentVector] = []
        nonisolated(unsafe) private var lastLandPolygons: [CurrentParticleLayer.LandPolygon] = []
        nonisolated(unsafe) private var lastBoundsWorld: (minX: Float, minY: Float, maxX: Float, maxY: Float) = (0, 0, 0, 0)
        // False while the current polygon snapshot is untrustworthy (style
        // mid-reload, tiles still rendering) — re-queried on viewport change
        // and on mapViewDidBecomeIdle.
        nonisolated(unsafe) private var landPolygonsValid = false

        func updateVectors(_ vectors: [CurrentVector], fieldVectors: [CurrentVector],
                           mask: [CurrentVector], on mapView: MLNMapView) {
            // Change detection: updateUIView re-runs on every observed change
            // (scene phase, colour scheme, style mode...), and everything below
            // — the feature query, the arrow shape rebuild, the field raster
            // rebuild — is far too expensive to run for identical inputs.
            let bounds = worldBounds(of: mapView)
            let dataChanged = vectors != lastVectors || fieldVectors != lastFieldVectors
                || mask != lastMask
            let boundsChanged = bounds != lastBoundsWorld
            guard dataChanged || boundsChanged || !landPolygonsValid else { return }

            lastVectors = vectors
            lastFieldVectors = fieldVectors
            lastMask = mask
            lastBoundsWorld = bounds
            if boundsChanged || !landPolygonsValid {
                lastLandPolygons = landPolygons(from: mapView)
                // Best-effort snapshot: tiles may still be rendering; the
                // mapViewDidBecomeIdle re-query below corrects it once the
                // map settles.
                landPolygonsValid = mapView.style != nil
            }
            particleLayer?.update(vectors: fieldVectors, mask: mask,
                                  landPolygons: lastLandPolygons, boundsWorld: bounds)
            guard let style = mapView.style else {
                pendingVectors = vectors
                return
            }
            if dataChanged { applyVectors(vectors, style: style) }
        }

        /// Rendering settled (tiles loaded, camera at rest): re-capture the
        /// land polygons and rebuild the field if they changed. This is what
        /// keeps the land mask honest after pans into previously unrendered
        /// areas and after style reloads — a snapshot taken mid-load misses
        /// land whose tiles hadn't arrived yet.
        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            let fresh = landPolygons(from: mapView)
            landPolygonsValid = true
            guard fresh != lastLandPolygons else { return }
            lastLandPolygons = fresh
            lastBoundsWorld = worldBounds(of: mapView)
            particleLayer?.update(vectors: lastFieldVectors, mask: lastMask,
                                  landPolygons: fresh, boundsWorld: lastBoundsWorld)
        }

        /// Called when a style reload starts: the outgoing style's polygons
        /// no longer describe what will be drawn. Empty polygons make the
        /// particle layer fall back to the model mask until the new style
        /// renders and the idle re-query lands.
        func invalidateLandPolygons() {
            lastLandPolygons = []
            landPolygonsValid = false
        }

        /// The visible viewport as world-Mercator min/max (the particle field's
        /// raster extent).
        private func worldBounds(of mapView: MLNMapView) -> (minX: Float, minY: Float, maxX: Float, maxY: Float) {
            let b = MainActor.assumeIsolated { mapView.visibleCoordinateBounds }
            let sw = CurrentParticleLayer.lonLatToWorld(lon: b.sw.longitude, lat: b.sw.latitude)
            let ne = CurrentParticleLayer.lonLatToWorld(lon: b.ne.longitude, lat: b.ne.latitude)
            // World y grows southward: the north-east corner has the smaller y.
            return (Float(sw.x), Float(ne.y), Float(ne.x), Float(sw.y))
        }

        /// The basemap's rendered land polygons in the current viewport, as
        /// world-Mercator rings (holes included — the particle layer's even-odd
        /// test handles them). This is what reconciles the flow with the *drawn*
        /// coastline: the model's own land mask is displaced at narrow passes
        /// (NEMO widens them), so only the basemap knows where the user sees a
        /// beach. Styles without an "earth" layer (Ocean/Satellite, the flat
        /// fallback) return no rings and keep the model-mask behavior.
        private func landPolygons(from mapView: MLNMapView) -> [CurrentParticleLayer.LandPolygon] {
            // MLN delegate callbacks are main-thread (see the class comment);
            // visibleFeatures is @MainActor-annotated, so assert rather than
            // hop, and convert to Sendable polygons before leaving the closure.
            MainActor.assumeIsolated {
                let features = mapView.visibleFeatures(in: mapView.bounds,
                                                       styleLayerIdentifiers: ["earth"])
                var polygons: [CurrentParticleLayer.LandPolygon] = []
                func add(_ polygon: MLNPolygon) {
                    func ring(_ shape: MLNMultiPoint) -> [SIMD2<Float>] {
                        let coords = UnsafeBufferPointer(start: shape.coordinates,
                                                         count: Int(shape.pointCount))
                        return coords.map {
                            let w = CurrentParticleLayer.lonLatToWorld(lon: $0.longitude, lat: $0.latitude)
                            return SIMD2(Float(w.x), Float(w.y))
                        }
                    }
                    // Exterior + holes stay grouped: the rasterizer unions
                    // polygons, so tile-duplicated copies can't cancel out.
                    polygons.append(CurrentParticleLayer.LandPolygon(
                        exterior: ring(polygon),
                        holes: (polygon.interiorPolygons ?? []).map(ring)))
                }
                for feature in features {
                    if let polygon = feature as? MLNPolygon {
                        add(polygon)
                    } else if let multi = feature as? MLNMultiPolygon {
                        multi.polygons.forEach(add)
                    }
                }
                return polygons
            }
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
                s.layer(withIdentifier: slackLayerID)?.isVisible = showArrows
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
            shaftLayer.lineWidth = NSExpression(format: "TERNARY(speed_knots < 1.5, 1.4, TERNARY(speed_knots < 3.0, 1.8, 3.0))")
            shaftLayer.lineCap = NSExpression(forConstantValue: "round")
            shaftLayer.predicate = NSPredicate(format: "arrow_type == 'shaft'")

            let barbLayer = MLNLineStyleLayer(identifier: barbLayerID, source: source)
            barbLayer.lineColor = speedColorExpression(dark: dark)
            barbLayer.lineWidth = NSExpression(format: "TERNARY(speed_knots < 1.5, 1.1, TERNARY(speed_knots < 3.0, 1.4, 2.5))")
            barbLayer.predicate = NSPredicate(format: "arrow_type == 'barb'")

            // Slack/weak grid points (speed 0, no direction) render as small
            // faint dots — exactly how the atlas draws them — so weak-current
            // areas read as "charted, slack" rather than missing data.
            let slackLayer = MLNCircleStyleLayer(identifier: slackLayerID, source: source)
            slackLayer.circleColor = NSExpression(forConstantValue: UIColor.currentSpeedRamp(dark: dark)[0])
            slackLayer.circleRadius = NSExpression(forConstantValue: 1.4)
            slackLayer.circleOpacity = NSExpression(forConstantValue: 0.5)
            slackLayer.predicate = NSPredicate(format: "arrow_type == 'slack'")

            // Arrow + slack visibility is driven by the selected current style
            // (re-applied below), so a Day/Night style reload restores the right
            // mode. Particles are the default, so the static arrows start hidden.
            let showArrows = lastStyleMode == .arrows
            shaftLayer.isVisible = showArrows
            barbLayer.isVisible = showArrows
            slackLayer.isVisible = showArrows

            style.addLayer(slackLayer)
            style.addLayer(shaftLayer)
            style.addLayer(barbLayer)

            // Animated particle current overlay. Inserted BELOW the basemap's
            // land fill when the style has one (Standard orders ocean below
            // the land fills — see standard-{light,dark}.json), so land paints
            // over the particles: pixel-perfect clipping at the drawn
            // coastline, which the source data can't provide (NEMO widens
            // narrow passes ~1–3 cells; the atlas has no land mask at all).
            // Styles without an "earth" layer (Ocean/Satellite, the flat
            // fallback) keep the old draw-on-top behavior.
            let particleLayer = CurrentParticleLayer(identifier: particleLayerID)
            if let earth = style.layer(withIdentifier: "earth") {
                // Inserting below "earth" only clips correctly if the style
                // keeps its ocean fill BELOW the land fills (see the reordered
                // standard-{light,dark}.json); nothing else enforces that
                // hand-maintained invariant, so trap regressions in debug.
                let ids = style.layers.map(\.identifier)
                if let w = ids.firstIndex(of: "water"), let e = ids.firstIndex(of: "earth"), w > e {
                    assertionFailure("style orders 'water' above 'earth' — the ocean fill will paint over the particle layer; restore the standard-*.json layer order")
                }
                style.insertLayer(particleLayer, below: earth)
            } else {
                style.addLayer(particleLayer)
            }
            self.particleLayer = particleLayer
            // Re-seed the freshly created layer with the field + style/scheme from
            // before the reload, so particles don't blank out on a Day/Night flip.
            // Land polygons were invalidated when the reload started (a
            // stale style's coastline is worse than the model-mask fallback);
            // the idle re-query upgrades them once the new style renders.
            particleLayer.update(vectors: lastFieldVectors, mask: lastMask,
                                 landPolygons: lastLandPolygons, boundsWorld: lastBoundsWorld)
            particleLayer.setDark(lastDark)
            particleLayer.setActive(lastStyleMode != .arrows)
        }

        private func applyVectors(_ vectors: [CurrentVector], style: MLNStyle) {
            guard let source = style.source(withIdentifier: sourceID) as? MLNShapeSource else { return }
            source.shape = MLNShapeCollectionFeature(shapes: buildFeatures(from: vectors))
        }

        private func buildFeatures(from vectors: [CurrentVector]) -> [MLNShape] {
            var features: [MLNShape] = []
            features.reserveCapacity(vectors.count * 3)

            // Slack grid points: zero speed, no direction → a plain dot.
            for v in vectors where v.speed_ms == 0 {
                let pt = MLNPointFeature()
                pt.coordinate = CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon)
                pt.attributes = ["arrow_type": "slack"]
                features.append(pt)
            }

            let baseHalfDeg = 0.005   // ~500 m; the half-length of a ~1 kn arrow

            for v in vectors where v.isSignificant {
                let θ = v.direction_deg * .pi / 180

                // Tail length encodes speed: faster current → longer arrow, slower
                // → shorter stub. Capped at 1.6× so the fastest don't overrun their
                // neighbours (reached ~3.7 kn); the 0.5 base keeps the slowest
                // visible. speedKnots ≥ 0, so the scale never drops below 0.5.
                let lengthScale = min(0.5 + v.speedKnots * 0.30, 1.6)
                let halfDeg = baseHalfDeg * lengthScale
                let dLat = cos(θ) * halfDeg
                let dLon = sin(θ) * halfDeg

                // Arrowhead is the constant 0.70× of the reference half-length so
                // it stays a fixed size as the tail grows — but never longer than
                // this arrow's own half-shaft, so short slow arrows don't become an
                // oversized head on a stub.
                let barbLen = min(halfDeg, baseHalfDeg) * 0.70

                let tail = CLLocationCoordinate2D(latitude: v.lat - dLat, longitude: v.lon - dLon)
                let tip  = CLLocationCoordinate2D(latitude: v.lat + dLat, longitude: v.lon + dLon)

                var shaft = [tail, tip]
                let shaftFeature = MLNPolylineFeature(coordinates: &shaft, count: 2)
                shaftFeature.attributes = ["speed_knots": v.speedKnots, "arrow_type": "shaft"]
                features.append(shaftFeature)

                // Two barbs at ±25° from the reversed direction
                let backθ = θ + .pi
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
