import SwiftUI

@main
struct SalishTidesApp: App {
    @State private var viewModel = MapViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
        }
    }
}
