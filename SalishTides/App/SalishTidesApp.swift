import SwiftUI

@main
struct SalishTidesApp: App {
    @State private var viewModel: MapViewModel
    @State private var settings: AppSettings
    @State private var network: NetworkMonitor
    @State private var mapController = MapController()
    @State private var crosshair = CrosshairPresenter()
    @State private var stationMarker = StationMarkerPresenter()
    // One-shot cleanup of any offline map packs left by earlier builds; no
    // basemap downloads packs anymore, so it just reclaims that disk once.
    @State private var packCleaner = LegacyOfflinePackCleaner()
    @State private var liveData: LiveDataService

    init() {
        // Built by hand (not property initializers) because the live-data
        // service observes settings + network, and the view model consults the
        // service — a small dependency chain.
        let settings = AppSettings()
        let network = NetworkMonitor()
        let liveData = LiveDataService(settings: settings, network: network)
        _settings = State(initialValue: settings)
        _network = State(initialValue: network)
        _liveData = State(initialValue: liveData)
        _viewModel = State(initialValue: MapViewModel(liveData: liveData))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(settings)
                .environment(network)
                .environment(mapController)
                .environment(crosshair)
                .environment(stationMarker)
                .environment(liveData)
                .tint(.brandAccent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        // Registers the app-refresh handler (before launch finishes, as the
        // system requires) and runs it when iOS grants a background window.
        // `backgroundRefresh()` reschedules first (so the chain survives an
        // early expiration) and then runs one staleness pass; returning
        // completes the task successfully, and a reclaimed window cancels this
        // closure, which `backgroundRefresh()` honors. ContentView submits the
        // initial request on backgrounding.
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await liveData.backgroundRefresh()
        }
    }
}
