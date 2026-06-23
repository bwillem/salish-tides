import SwiftUI

struct TimelineControlView: View {
    @Environment(MapViewModel.self) private var vm
    @State private var offsetHours: Double = 0
    // Fixed anchor captured at view appearance; updated only when "Now" is tapped.
    // Ensures slider position and displayed time stay in sync across a scrubbing session.
    @State private var sessionAnchor: Date = .now

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                stepButton(label: "← Hr", delta: -1)
                Spacer()
                dateTimeLabel
                Spacer()
                stepButton(label: "Hr →", delta: 1)
            }
            HStack(spacing: 14) {
                Button("Now") { jumpToNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Slider(value: $offsetHours, in: -12...12, step: 1)
                    .onChange(of: offsetHours) { _, v in applyOffset(v) }
                Text(offsetLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .onAppear { sessionAnchor = .now }
    }

    private func stepButton(label: String, delta: Int) -> some View {
        Button(label) { jump(to: offsetHours + Double(delta)) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var dateTimeLabel: some View {
        VStack(spacing: 2) {
            Text(vm.currentDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.headline.monospacedDigit())
            if let sel = vm.currentSelection {
                Text("Chart \(sel.chart) · \(sel.phase.replacingOccurrences(of: "_", with: " "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var offsetLabel: String {
        let h = Int(offsetHours)
        guard h != 0 else { return "" }
        return h > 0 ? "+\(h)h" : "\(h)h"
    }

    private func jumpToNow() {
        sessionAnchor = .now
        offsetHours = 0
        Task { await vm.setTime(sessionAnchor) }
    }

    private func jump(to hours: Double) {
        offsetHours = max(-12, min(12, hours))
        applyOffset(offsetHours)
    }

    private func applyOffset(_ hours: Double) {
        let date = sessionAnchor.addingTimeInterval(hours * 3_600)
        Task { await vm.setTime(date) }
    }
}
