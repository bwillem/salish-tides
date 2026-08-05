import SwiftUI

/// The current-station detail shown *inside the phase card* when a pass marker
/// is selected (Dodd, Seymour, Active Pass, ...): the pass's current right now
/// (from the on-device harmonic fit) plus its next slack and next max flood/ebb
/// (from the bundled CHS events — CHS-exact times).
///
/// Content only — no card chrome. `PhaseIndicatorView` wraps this in the same
/// glass card it uses for the tide chart, so tapping a tide station or a current
/// station is one unified card, just different contents.
struct CurrentStationDetail: View {
    let station: CurrentStation
    let now: Date

    var body: some View {
        let signed = station.signedSpeedKn(at: now)
        let flooding = signed >= 0
        let upcoming = station.events.drop { $0.date <= now }
        let nextSlack = upcoming.first { $0.kind == .slack }
        let nextMax = upcoming.first { $0.kind != .slack }

        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(station.name)
                .font(.stCaption).bold()
                .foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Unit + flood/ebb baseline-align with the big number so they sit at
            // its bottom (matches the crosshair speed pill). No direction arrow —
            // the "flooding"/"ebbing" word already says it.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(String(format: "%.1f", abs(signed))).font(.stReadout)
                Text("kn").font(.stReadoutUnit).foregroundStyle(.secondary)
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).opacity(0.7)
            Text(value).font(.stCaption).foregroundStyle(.primary)
        }
        .foregroundStyle(Color.inkSecondary)
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
