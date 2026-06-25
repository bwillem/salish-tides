import SwiftUI

@main
struct SalishTidesApp: App {
    @State private var viewModel = MapViewModel()
    @State private var settings = AppSettings()
    @State private var network = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(settings)
                .environment(network)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
