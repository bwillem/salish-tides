import SwiftUI

/// The card shown when a CHS current-station marker is tapped: the pass's
/// predicted current right now (from the on-device harmonic fit) plus its next
/// slack and next max flood/ebb (from the bundled CHS events — CHS-exact times,
/// which the harmonic curve alone can't nail at the violent rapids).
///
/// A floating glass card above the timeline, mirroring the tide card's surface.
/// Renders only while `selectedStationCode` names a station.
struct CurrentStationCard: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(CurrentStationMarkerPresenter.self) private var presenter

    var body: some View {
        if let code = presenter.selectedStationCode,
           let station = CurrentStationStore.all.first(where: { $0.code == code }) {
            card(for: station)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func card(for station: CurrentStation) -> some View {
        let now = vm.displayDate
        let signed = station.signedSpeedKn(at: now)
        let flooding = signed >= 0
        let upcoming = station.events.drop { $0.date <= now }
        let nextSlack = upcoming.first { $0.kind == .slack }
        let nextMax = upcoming.first { $0.kind != .slack }

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(station.name)
                    .font(.stCaption).bold()
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { presenter.selectedStationCode = nil }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }

            HStack(spacing: Spacing.xs) {
                Image(systemName: flooding ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                Text(String(format: "%.1f kn", abs(signed))).font(.stReadout)
                Text(flooding ? "flooding" : "ebbing").font(.stCaption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)

            if nextSlack != nil || nextMax != nil {
                HStack(spacing: Spacing.md) {
                    if let s = nextSlack { labelled("Slack", time(s.date)) }
                    if let m = nextMax {
                        labelled(m.kind == .maxFlood ? "Max flood" : "Max ebb",
                                 String(format: "%.1f kn %@", m.speedKn, time(m.date)))
                    }
                }
                .font(.stCaption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: 320, alignment: .leading)
        .floatingCard()
        .accessibilityElement(children: .combine)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).opacity(0.7)
            Text(value).foregroundStyle(.primary)
        }
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
