import SwiftUI

struct ContentView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var network
    @State private var showingSettings = false

    // When a network style is shown while *confirmed* online, its tiles enter
    // the ambient cache — record it so it stays selectable offline. Gating on
    // didConfirmOnline avoids marking from the optimistic launch default.
    private func recordIfOnline() {
        if network.isOnline, network.didConfirmOnline {
            settings.markOfflineReady(settings.basemap)
        }
    }

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
                    VStack(alignment: .trailing, spacing: Spacing.sm) {
                        PhaseIndicatorView()
                        CurrentSpeedView()
                    }
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
        .onAppear { recordIfOnline() }
        .onChange(of: settings.basemap) { recordIfOnline() }
        .onChange(of: network.isOnline) { recordIfOnline() }
        .onChange(of: network.didConfirmOnline) { recordIfOnline() }
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
            // Inverse halo keeps the reticle legible on any tile in either theme:
            // systemBackground is the opposite of .primary, so the reticle is
            // dark-on-light in Day and light-on-dark in Night, each with a
            // contrasting outline.
            ReticleShape().stroke(Color(.systemBackground).opacity(0.6), lineWidth: 3.5)
            ReticleShape().stroke(.primary.opacity(0.9), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Ring + four ticks centred on the view's rect. As a Shape it fills the
// proposed space and centres on the screen, so both strokes stay aligned and
// the reticle sits at the viewport centre (the point the readouts refer to).
private struct ReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        var p = Path()
        p.addEllipse(in: CGRect(x: cx - 11, y: cy - 11, width: 22, height: 22))
        p.move(to: CGPoint(x: cx, y: cy - 18)); p.addLine(to: CGPoint(x: cx, y: cy - 12))
        p.move(to: CGPoint(x: cx, y: cy + 12)); p.addLine(to: CGPoint(x: cx, y: cy + 18))
        p.move(to: CGPoint(x: cx - 18, y: cy)); p.addLine(to: CGPoint(x: cx - 12, y: cy))
        p.move(to: CGPoint(x: cx + 12, y: cy)); p.addLine(to: CGPoint(x: cx + 18, y: cy))
        return p
    }
}

private struct MigrationView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "water.waves")
                    .font(.system(size: 48))
                    .foregroundStyle(.primary.opacity(0.8))
                Text("Salish Tides")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.primary)
                        .frame(width: 280)
                    Text("Loading charts… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
