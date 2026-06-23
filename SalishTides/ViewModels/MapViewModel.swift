import Foundation
import Observation

@MainActor
@Observable
final class MapViewModel {
    var currentDate: Date = .now
    var currentVectors: [CurrentVector] = []
    var currentSelection: ChartSelection?
    var isMigrating = false
    var migrationProgress: Double = 0
    var migrationError: String?
    var visibleViewport: ChartBounds?
    var crosshairSpeed: Double?

    private let selector: ChartSelector
    private let atlasIndex: AtlasIndex

    init() {
        self.selector = try! ChartSelector.load()
        self.atlasIndex = try! AtlasIndex.load()
    }

    func initialize() async {
        do {
            try await VectorDatabase.shared.setup()

            // Check inside the actor so the flag read and the migration run are serialized
            if await DatabaseMigrator.shared.needsMigration {
                isMigrating = true
            }

            // migrate() is idempotent — safe to call even if already done
            try await DatabaseMigrator.shared.migrate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.migrationProgress = fraction
                }
            }

            // Set to 1.0 before hiding the view so the progress bar completes visually
            migrationProgress = 1.0
            isMigrating = false

            await loadVectors(for: currentDate)
        } catch {
            migrationError = error.localizedDescription
            isMigrating = false
        }
    }

    func setTime(_ date: Date) async {
        currentDate = date
        await loadVectors(for: date)
    }

    func updateViewport(_ bounds: ChartBounds) async {
        visibleViewport = bounds
        await loadVectors(for: currentDate)
    }

    private func loadVectors(for date: Date) async {
        guard let selection = selector.selection(for: date) else { return }
        currentSelection = selection

        // Use viewport filtering when available; falls back to all regions when map hasn't reported bounds yet
        let regions = atlasIndex.regions(forChart: selection.chart, intersecting: visibleViewport)
        do {
            let vectors = try await VectorDatabase.shared.vectors(chart: selection.chart, regions: regions)
            currentVectors = vectors
            crosshairSpeed = nearestSpeed(in: vectors, viewport: visibleViewport)
        } catch {
            currentVectors = []
            crosshairSpeed = nil
        }
    }

    private func nearestSpeed(in vectors: [CurrentVector], viewport: ChartBounds?) -> Double? {
        guard let vp = viewport else { return nil }
        let cLat = (vp.lat_min + vp.lat_max) / 2
        let cLon = (vp.lon_min + vp.lon_max) / 2
        return vectors
            .filter { $0.isSignificant }
            .min(by: {
                let d1 = ($0.lat - cLat) * ($0.lat - cLat) + ($0.lon - cLon) * ($0.lon - cLon)
                let d2 = ($1.lat - cLat) * ($1.lat - cLat) + ($1.lon - cLon) * ($1.lon - cLon)
                return d1 < d2
            })
            .map { $0.speedKnots }
    }
}
