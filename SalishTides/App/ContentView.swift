import SwiftUI

struct ContentView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var network
    @Environment(MapController.self) private var mapController
    @Environment(OfflineMapManager.self) private var offline
    @Environment(LiveDataService.self) private var liveData
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    // When a downloadable network style is selected while *confirmed* online,
    // pre-download its offline pack so it works offline everywhere. Gating on
    // didConfirmOnline avoids acting on the optimistic launch default.
    private func cacheCurrentStyleIfOnline() {
        guard network.isOnline, network.didConfirmOnline else { return }
        let basemap = settings.basemap
        // Use the strict resolver, not `styleURL`: the latter falls back to the
        // Standard (local-pmtiles) style when e.g. the MapTiler key is missing,
        // and packing that under Ocean's identity yields a download that hangs
        // forever (its tiles aren't network-fetchable). No real style → no pack.
        guard basemap.supportsOfflineDownload,
              let url = MapStyleLoader.resolvedStyleURL(for: basemap, dark: colorScheme == .dark) else { return }
        offline.download(basemap, styleURL: url)
    }

    // Record any style whose pack has finished as offline-selectable. Runs off
    // the manager's published state, so a download that completes after the user
    // has switched away is still captured.
    private func syncOfflineReady() {
        for (raw, state) in offline.states where state == .ready {
            if let basemap = Basemap(rawValue: raw) { settings.markOfflineReady(basemap) }
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
        // Live SalishSeaCast fetching runs for the life of the view; its own
        // kicks below cover the moments worth re-checking between its periodic
        // staleness passes.
        .task { await liveData.start() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { liveData.kick() }
        }
        .onChange(of: settings.offlineOnly) {
            // Flipping the switch swaps the rendered source immediately, both
            // directions — not just on the next fetch.
            liveData.kick()
            Task { await vm.refresh() }
        }
        .onChange(of: liveData.dataGeneration) {
            Task { await vm.refresh() }
        }
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
                    // Top-left control cluster: settings, compass (only when
                    // rotated), locate.
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SettingsButton { showingSettings = true }
                        if !mapController.isNorthUp {
                            CompassButton(bearing: mapController.bearing) {
                                mapController.resetNorth()
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                        LocateButton { mapController.recenterOnUser() }
                    }
                    .animation(.snappy, value: mapController.isNorthUp)
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
        // The binding must clear the error on dismiss — a `.constant` binding
        // here re-presents the alert forever. Retry re-runs the idempotent
        // setup/migration path, so a transient failure (e.g. low disk) is
        // recoverable without relaunching.
        .alert("Setup Error", isPresented: Binding(
            get: { vm.migrationError != nil },
            set: { if !$0 { vm.migrationError = nil } }
        )) {
            Button("Retry") {
                Task {
                    // Let the dismissal transition finish before retrying: a
                    // fast failure (setup throws in ms) would re-set the error
                    // mid-dismissal, and SwiftUI drops an alert re-presented
                    // during one — the failure would become invisible.
                    try? await Task.sleep(for: .milliseconds(600))
                    await vm.initialize()
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.migrationError ?? "")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear { cacheCurrentStyleIfOnline(); syncOfflineReady() }
        .onChange(of: settings.basemap) { cacheCurrentStyleIfOnline() }
        .onChange(of: network.isOnline) {
            cacheCurrentStyleIfOnline()
            if network.isOnline { liveData.kick() }
        }
        .onChange(of: network.didConfirmOnline) { cacheCurrentStyleIfOnline() }
        .onChange(of: offline.states) { syncOfflineReady() }
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

/// Compass control — a needle (red north / muted south) rotated so north always
/// points up-screen as the map turns. Tap to animate back to north-up.
private struct CompassButton: View {
    let bearing: Double
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "arrowtriangle.up.fill")
                    .foregroundStyle(.red)
                    .offset(y: -4.5)
                Image(systemName: "arrowtriangle.down.fill")
                    .foregroundStyle(.secondary)
                    .offset(y: 4.5)
            }
            .font(.system(size: 9))
            .rotationEffect(.degrees(-bearing))
            .frame(width: 44, height: 44)
        }
        .floatingCard(cornerRadius: Radius.lg)
        .accessibilityLabel("Compass")
        .accessibilityValue("\(Int(bearing.rounded()))°")
        .accessibilityHint("Rotates the map back to north")
    }
}

/// Locate control — centers and follows the user's location (Maps-style).
private struct LocateButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .floatingCard(cornerRadius: Radius.lg)
        .accessibilityLabel("Locate me")
        .accessibilityHint("Centers the map on your location")
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
