import SwiftUI

struct ContentView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(NetworkMonitor.self) private var network
    @Environment(MapController.self) private var mapController
    @Environment(CrosshairPresenter.self) private var crosshair
    @Environment(StationMarkerPresenter.self) private var stationMarker
    @Environment(LiveDataService.self) private var liveData
    @Environment(\.scenePhase) private var scenePhase
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
        // Live SalishSeaCast fetching runs for the life of the view; its own
        // kicks below cover the moments worth re-checking between its periodic
        // staleness passes.
        .task { await liveData.start() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                liveData.kick()
            } else if scenePhase == .background, !settings.offlineOnly {
                // Keep one app-refresh request pending whenever we leave the
                // foreground, so iOS can wake us to refresh the live cache.
                // Skipped in offline mode, matching how offlineOnly gates all
                // fetching; the handler reschedules the chain thereafter.
                BackgroundRefresh.schedule()
            }
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

    /// True while the user's basemap streams its tiles (Satellite) but there's
    /// no connection — the cue for the "Offline" pill. Standard is bundled
    /// offline, so it never flags. The map itself keeps rendering the selected
    /// basemap from cache; this only drives the hint, never a style swap.
    private var streamingImageryOffline: Bool {
        settings.basemap.requiresNetwork && !network.isOnline
    }

    private var mapView: some View {
        ZStack(alignment: .bottom) {
            MapLibreView()
                .ignoresSafeArea()
            // Navionics-style: always on-screen but faint at rest, ramping to
            // full contrast while panning/zooming or scrubbing, then easing back
            // a couple seconds after release. Quick up, gentle down.
            CrosshairView()
                .opacity(crosshair.isEmphasized ? 1 : 0.5)
                .animation(crosshair.isEmphasized ? .easeOut(duration: 0.18)
                                                  : .easeOut(duration: 0.5),
                           value: crosshair.isEmphasized)
            // Speed above / bearing below the reticle. Unlike the reticle,
            // which rests at half opacity, the tags vanish completely at rest
            // and ride the SAME emphasis timing back in on pan/zoom/scrub —
            // data appears when the hand moves, chrome stays when it doesn't.
            CrosshairTagsView()
                .opacity(crosshair.isEmphasized ? 1 : 0)
                .animation(crosshair.isEmphasized ? .easeOut(duration: 0.18)
                                                  : .easeOut(duration: 0.5),
                           value: crosshair.isEmphasized)
            // Tide-station marker: a SwiftUI glass overlay pinned over the map at
            // the station's projected screen point (the coordinator writes it
            // every camera frame). It lives here — above the map, below the
            // controls/timeline — precisely so its glass samples the map, unlike
            // a MapLibre annotation. Position tracks per-frame (no implicit
            // animation); only a station change (`name`) or on/off-screen edge
            // cross-fades. `.id(name)` re-seeds the pulse on a station swap.
            Group {
                if let point = stationMarker.screenPoint {
                    StationMarkerView(tendency: stationMarker.tendency,
                                      name: stationMarker.name,
                                      nearCrosshair: stationMarker.nearCrosshair)
                        .id(stationMarker.name)
                        .position(point)
                        .transition(.opacity)
                }
            }
            // Match the map's full-bleed coordinate space: the coordinator
            // projects to `mapView.convert(_:toPointTo:)`, whose points are
            // measured from the full-screen map (it ignores the safe area). This
            // overlay must ignore it too, or every `.position` is shifted by the
            // top inset — a constant screen offset that reads as a zoom-dependent
            // drift on the map (a few km when zoomed out, metres when zoomed in).
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.22), value: stationMarker.name)
            .animation(.easeOut(duration: 0.22), value: stationMarker.screenPoint == nil)
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
                // Status pills above the timeline, on one baseline: connectivity
                // on the left — an "Offline" pill shown only while a streaming
                // basemap (Satellite) is selected and the network is unreachable,
                // noting that *new* imagery can't load (cached tiles keep showing;
                // it clears itself once back online) — and the currents-source
                // tier on the right ("Online mode" / "Offline model"; none until
                // a load completes). Full attribution: Settings → Data Sources.
                //
                // The animation lives on the always-present Group, not on the
                // conditional row: when the Offline pill is the *only* pill,
                // reconnecting collapses the `if`, and an animation modifier
                // inside it would be torn down before the fade could run — the
                // pill would pop. On the stable Group it fades out cleanly.
                Group {
                    let badge = SourceBadge.Content(vm.currentSource)
                    if streamingImageryOffline || badge != nil {
                        HStack(alignment: .bottom) {
                            if streamingImageryOffline {
                                OfflineBadge()
                                    .transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            if let badge {
                                SourceBadge(content: badge)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.sm)
                    }
                }
                .animation(.snappy, value: streamingImageryOffline)
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
        .onChange(of: network.isOnline) {
            if network.isOnline { liveData.kick() }
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
                .font(.stControlIcon)
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
            .font(.stCompassNeedle)
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
                .font(.stControlIconSmall)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .floatingCard(cornerRadius: Radius.lg)
        .accessibilityLabel("Locate me")
        .accessibilityHint("Centers the map on your location")
    }
}

/// Currents-source status pill — a coloured dot + label in its own small glass
/// container, shown bottom-right to say which tier the rendered current field is
/// drawn from. "Online mode" (live SalishSeaCast) uses the brand accent; the
/// "Offline model" harmonic tier uses a muted dot.
private struct SourceBadge: View {
    let content: Content

    /// The presentable states of `MapViewModel.CurrentSource`. nil source
    /// (nothing rendered yet / off coverage) maps to nil, so the call site can
    /// `if let` it away entirely.
    enum Content {
        case online, model

        init?(_ source: MapViewModel.CurrentSource?) {
            switch source {
            case .live:  self = .online
            case .model: self = .model
            case nil:    return nil
            }
        }

        var label: String { self == .online ? "Online mode" : "Offline model" }
        var dot: Color { self == .online ? Color.brandAccent : Color.inkSecondary.opacity(0.6) }
        var a11y: String {
            self == .online
                ? "Online mode: showing live SalishSeaCast current forecast."
                : "Offline model: showing tide-predicted currents without weather effects."
        }
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(content.dot)
                .frame(width: 5, height: 5)
            Text(content.label)
                .font(.stCaption)
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .floatingCard(cornerRadius: Radius.pill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.a11y)
    }
}

/// Connectivity pill — a red dot + "Offline", bottom-left above the timeline.
/// Shown only while a streaming basemap (Satellite) is selected and the network
/// is down: cached tiles keep rendering, so this just tells the user why new
/// imagery isn't filling in. It fades away on its own once back online.
private struct OfflineBadge: View {
    var body: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
            Text("Offline")
                .font(.stCaption)
                .foregroundStyle(Color.inkSecondary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .floatingCard(cornerRadius: Radius.pill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Offline. Showing cached satellite imagery; new areas will fill in once you reconnect.")
    }
}

/// The crosshair's own glanceable readout: current speed above the reticle,
/// flow bearing below, each on a half-transparent tag (see `crosshairTag()`).
/// A tag renders only when its datum exists, so land / off coverage shows a
/// bare reticle and slack shows "0.0 kn" with no bearing (a near-zero
/// vector's direction is suppressed as noise upstream). VoiceOver users get
/// the same data from the labeled speed card, so the tags stay hidden to it.
private struct CrosshairTagsView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    // Clear of the reticle's reach (gap 8 + arm 22, see ReticleShape) with
    // breathing room, measured centre-to-tag-centre.
    private static let tagOffset: CGFloat = 50

    var body: some View {
        ZStack {
            if let speed = vm.crosshairSpeed {
                Text(settings.formatSpeed(knots: speed))
                    .font(.stClock)
                    .crosshairTag()
                    .offset(y: -Self.tagOffset)
            }
            if let direction = vm.crosshairDirection {
                Text(bearingText(direction))
                    .font(.stCaption)
                    .crosshairTag()
                    .offset(y: Self.tagOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Mariner-style three-digit bearing plus an eight-point abbreviation:
    /// "048° NE". 360 normalizes to 000.
    private func bearingText(_ degrees: Double) -> String {
        let d = (degrees.rounded().truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((d + 22.5).truncatingRemainder(dividingBy: 360) / 45) % 8
        return String(format: "%03.0f° %@", d, points[index])
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

// Navionics-style reticle: a small "+" marking the exact centre point, plus
// four longer lines extending outward past a gap — a fine crosshair that pins
// the readout location without hiding the water under it. As a Shape it fills
// the proposed space and centres on the screen, so both strokes stay aligned.
private struct ReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let center: CGFloat = 3    // half-length of the small centre "+"
        let gap: CGFloat = 8       // clear space before the extending arms start
        let arm: CGFloat = 22      // length of each extending line
        var p = Path()

        // Small centre "+".
        p.move(to: CGPoint(x: cx, y: cy - center)); p.addLine(to: CGPoint(x: cx, y: cy + center))
        p.move(to: CGPoint(x: cx - center, y: cy)); p.addLine(to: CGPoint(x: cx + center, y: cy))

        // Four longer arms extending outward, starting past the gap.
        p.move(to: CGPoint(x: cx, y: cy - gap)); p.addLine(to: CGPoint(x: cx, y: cy - gap - arm))
        p.move(to: CGPoint(x: cx, y: cy + gap)); p.addLine(to: CGPoint(x: cx, y: cy + gap + arm))
        p.move(to: CGPoint(x: cx - gap, y: cy)); p.addLine(to: CGPoint(x: cx - gap - arm, y: cy))
        p.move(to: CGPoint(x: cx + gap, y: cy)); p.addLine(to: CGPoint(x: cx + gap + arm, y: cy))
        return p
    }
}

private struct MigrationView: View {
    let progress: Double

    var body: some View {
        ZStack {
            // Match the launch screen exactly (Info.plist UILaunchScreen →
            // LaunchLogo on the system background) so the static launch image
            // hands off to this live view with no visible jump: same full
            // wordmark, same centred position, same white/black surface.
            Color(.systemBackground)
                .ignoresSafeArea()
            // Centred at the launch screen's native size (~280 pt) — pinned dead
            // centre, independent of the progress row below, so the logo sits
            // right where the launch image left it.
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 280)
            // Progress lives at the bottom so it doesn't push the logo off centre.
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.primary)
                        .frame(width: 280)
                    Text("Loading charts… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 64)
            }
        }
    }
}
