import SwiftUI

@main
struct SalishTidesApp: App {
    @State private var viewModel: MapViewModel
    @State private var settings: AppSettings
    @State private var network: NetworkMonitor
    @State private var mapController = MapController()
    @State private var crosshair = CrosshairPresenter()
    @State private var offline = OfflineMapManager()
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
                .environment(offline)
                .environment(liveData)
                .tint(.brandAccent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
