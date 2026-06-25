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
            CrosshairView()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    PhaseIndicatorView()
                        .padding(.trailing)
                        .padding(.top, 8)
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
