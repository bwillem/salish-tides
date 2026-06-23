import SwiftUI

struct ContentView: View {
    @Environment(MapViewModel.self) private var vm

    var body: some View {
        Group {
            if vm.isMigrating {
                MigrationView(progress: vm.migrationProgress)
            } else {
                mapView
            }
        }
        .task { await vm.initialize() }
    }

    private var mapView: some View {
        ZStack(alignment: .bottom) {
            MapLibreView()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    PhaseIndicatorView()
                        .padding(.trailing)
                        .padding(.top, 8)
                }
                Spacer()
                TimelineControlView()
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                    .padding(.top, 10)
                    .background(.ultraThinMaterial)
            }
        }
        .alert("Setup Error", isPresented: .constant(vm.migrationError != nil)) {
            Button("OK") {}
        } message: {
            Text(vm.migrationError ?? "")
        }
    }
}

private struct MigrationView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.22, blue: 0.36)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "water.waves")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Salish Tides")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 280)
                    Text("Loading charts… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}
