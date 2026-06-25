import SwiftUI

@main
struct SalishTidesApp: App {
    @State private var viewModel = MapViewModel()
    @State private var settings = AppSettings()
    @State private var network = NetworkMonitor()
    @State private var mapController = MapController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(settings)
                .environment(network)
                .environment(mapController)
                .tint(.brandAccent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
