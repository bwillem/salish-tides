import SwiftUI

struct ContentView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @State private var showingSettings = false

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
            if settings.showCrosshair {
                CrosshairView()
            }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    SettingsButton { showingSettings = true }
                        .padding(.leading)
                        .padding(.top, Spacing.sm)
                    Spacer()
                    PhaseIndicatorView()
                        .padding(.trailing)
                        .padding(.top, Spacing.sm)
                }
                Spacer()
                TimelineControlView()
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .floatingCard()
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.sm)
            }
        }
        .alert("Setup Error", isPresented: .constant(vm.migrationError != nil)) {
            Button("OK") {}
        } message: {
            Text(vm.migrationError ?? "")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

/// Floating gear button, top-left — the entry point to Settings. Mirrors the
/// phase panel's floating-card surface (§4.1b) so the two top corners read as a
/// pair, and meets the 44 pt HIG minimum touch target.
private struct SettingsButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .floatingCard(cornerRadius: Radius.lg)
        .accessibilityLabel("Settings")
    }
}

private struct CrosshairView: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.75), lineWidth: 1.5)
                .frame(width: 22, height: 22)
            Path { p in
                p.move(to: CGPoint(x: 0, y: -18)); p.addLine(to: CGPoint(x: 0, y: -12))
                p.move(to: CGPoint(x: 0, y:  12)); p.addLine(to: CGPoint(x: 0, y:  18))
                p.move(to: CGPoint(x: -18, y: 0)); p.addLine(to: CGPoint(x: -12, y: 0))
                p.move(to: CGPoint(x:  12, y: 0)); p.addLine(to: CGPoint(x:  18, y: 0))
            }
            .stroke(.white.opacity(0.75), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
