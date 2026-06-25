import SwiftUI

@main
struct SalishTidesApp: App {
    @State private var viewModel = MapViewModel()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
