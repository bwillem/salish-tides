import SwiftUI

// Horizontally scrollable time tape.
// The cursor is pinned at screen-centre; tick marks slide past it as the user drags.
// Snaps to the nearest integer hour on release with a short spring animation.
// Does not call onCommit during drag — only after the snap settles.
struct TapeSliderView: View {
    @Environment(AppSettings.self) private var settings
    @Binding var offsetHours: Int
    let sessionAnchor: Date
    let onCommit: () -> Void

    @State private var dragTranslation: CGFloat = 0

    private let pixelsPerHour: CGFloat = 27
    private let maxHours: Int = 48

    // Continuous display offset — drives all Canvas drawing
    private var displayedOffset: Double {
        let raw = Double(offsetHours) + Double(-dragTranslation) / pixelsPerHour
        return max(-Double(maxHours), min(Double(maxHours), raw))
    }

    // VoiceOver value: the current offset relative to "now".
    private var accessibilityValueText: String {
        guard offsetHours != 0 else { return "Now" }
        let h = abs(offsetHours)
        let unit = h == 1 ? "hour" : "hours"
        return offsetHours > 0 ? "\(h) \(unit) ahead of now" : "\(h) \(unit) before now"
    }

    // Adjustable-action step (VoiceOver swipe up/down), clamped + committed.
    private func step(by delta: Int) {
        let clamped = max(-maxHours, min(maxHours, offsetHours + delta))
        guard clamped != offsetHours else { return }
        offsetHours = clamped
        dragTranslation = 0
        onCommit()
    }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size, use24Hour: settings.clockFormat.is24Hour)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    dragTranslation = v.translation.width
                }
                .onEnded { v in
                    // Compute final continuous position and snap to nearest hour
                    let raw = Double(offsetHours) + Double(-v.translation.width) / pixelsPerHour
                    let clamped = max(-Double(maxHours), min(Double(maxHours), raw))
                    let snapped = Int(clamped.rounded())

                    // Set dragTranslation to the fractional remainder so the tape
                    // position is continuous across the offsetHours update, then
                    // animate the remainder away.
                    let remainder = clamped - Double(snapped)
                    let compensatingDrag = CGFloat(-remainder * pixelsPerHour)

                    offsetHours = snapped
                    dragTranslation = compensatingDrag

                    withAnimation(.interpolatingSpring(stiffness: 500, damping: 38)) {
                        dragTranslation = 0
                    }
                    onCommit()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Forecast time")
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint("Swipe up or down to change the time by one hour")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
    }

    // MARK: - Canvas drawing

    private func draw(ctx: GraphicsContext, size: CGSize, use24Hour: Bool) {
        let cx       = size.width / 2
        let totalH   = size.height
        let offset   = displayedOffset
        let atNow    = abs(offset) < 0.4

        let cal = Calendar.salish
        var dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dateStyle.timeZone = .salish

        // ── Tick marks ───────────────────────────────────────────────────────
        // sessionAnchor is the top of an hour, so every tick is an exact clock
        // hour: labels are accurate and midnight lands precisely on a tick.
        for tick in -maxHours ... maxHours {
            let x = cx + CGFloat(Double(tick) - offset) * pixelsPerHour
            guard x >= -4 && x <= size.width + 4 else { continue }

            let isNow = tick == 0
            let tickDate = sessionAnchor.addingTimeInterval(Double(tick) * 3600)
            let hour = cal.component(.hour, from: tickDate)
            let isMidnight = hour == 0
            let isLabelled = (tick % 3 == 0) || isMidnight   // taller tick + a label

            if isNow {
                // "Now" marker: full-height line in oceanLight so it's visible
                // whether the cursor is sitting on it or has moved away
                var p = Path()
                p.move(to:    CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: totalH * 0.70))
                ctx.stroke(p, with: .color(Color.oceanLight.opacity(0.75)), lineWidth: 1.0)
            }

            // Hour tick (taller on labelled marks)
            let tickH: CGFloat   = isLabelled ? 11 : 6
            let tickAlpha: Double = isNow ? 0 : (isLabelled ? 0.55 : 0.28)
            if tickAlpha > 0 {
                var p = Path()
                p.move(to:    CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: tickH))
                ctx.stroke(p, with: .color(.primary.opacity(tickAlpha)), lineWidth: 1.0)
            }

            // Labels (skip the "now" tick — the cursor implies it, and stay clear
            // of the edges). Midnight shows the date + a faint day divider so the
            // wide range reads clearly across days; other 3-hour marks show HH:00.
            guard !isNow, x >= 18, x <= size.width - 22 else { continue }
            if isMidnight {
                var div = Path()
                div.move(to:    CGPoint(x: x, y: 0))
                div.addLine(to: CGPoint(x: x, y: totalH * 0.55))
                ctx.stroke(div, with: .color(.primary.opacity(0.22)), lineWidth: 1.0)
                ctx.draw(
                    Text(tickDate, format: dateStyle)
                        .font(.system(size: 9, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.55)),
                    at: CGPoint(x: x, y: totalH - 2),
                    anchor: .bottom
                )
            } else if tick % 3 == 0 && hour != 23 && hour != 1 {
                // (23:00 / 01:00 sit one hour from a midnight date marker — skip
                // them so the date label doesn't collide.)
                let label = use24Hour
                    ? String(format: "%02d:00", hour)
                    : "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
                ctx.draw(
                    Text(label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.40)),
                    at: CGPoint(x: x, y: totalH - 2),
                    anchor: .bottom
                )
            }
        }

        // ── Centre cursor ────────────────────────────────────────────────────
        let cursorColor: Color = atNow ? .primary : Color.tideEbb

        var line = Path()
        line.move(to:    CGPoint(x: cx, y: 0))
        line.addLine(to: CGPoint(x: cx, y: totalH))
        ctx.stroke(line, with: .color(cursorColor.opacity(0.92)), lineWidth: 1.5)

        // Small downward triangle at base of cursor
        let tri: CGFloat = 4
        var arrow = Path()
        arrow.move(to:    CGPoint(x: cx - tri, y: totalH))
        arrow.addLine(to: CGPoint(x: cx + tri, y: totalH))
        arrow.addLine(to: CGPoint(x: cx,       y: totalH - tri * 1.5))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(cursorColor.opacity(0.92)))
    }
}
