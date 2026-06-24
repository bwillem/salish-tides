import SwiftUI

// Horizontally scrollable time tape.
// The cursor is pinned at screen-centre; tick marks slide past it as the user drags.
// Snaps to the nearest integer hour on release with a short spring animation.
// Does not call onCommit during drag — only after the snap settles.
struct TapeSliderView: View {
    @Binding var offsetHours: Int
    let sessionAnchor: Date
    let onCommit: () -> Void

    @State private var dragTranslation: CGFloat = 0

    private let pixelsPerHour: CGFloat = 27
    private let maxHours: Int = 12

    // Continuous display offset — drives all Canvas drawing
    private var displayedOffset: Double {
        let raw = Double(offsetHours) + Double(-dragTranslation) / pixelsPerHour
        return max(-Double(maxHours), min(Double(maxHours), raw))
    }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
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
    }

    // MARK: - Canvas drawing

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let cx       = size.width / 2
        let totalH   = size.height
        let offset   = displayedOffset
        let atNow    = abs(offset) < 0.4

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Vancouver")!

        // ── Tick marks ───────────────────────────────────────────────────────
        for tick in -maxHours ... maxHours {
            let x = cx + CGFloat(Double(tick) - offset) * pixelsPerHour
            guard x >= -4 && x <= size.width + 4 else { continue }

            let isNow = tick == 0
            let is3h  = tick % 3 == 0

            if isNow {
                // "Now" marker: full-height line in oceanLight so it's visible
                // whether the cursor is sitting on it or has moved away
                var p = Path()
                p.move(to:    CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: totalH * 0.70))
                ctx.stroke(p, with: .color(Color.oceanLight.opacity(0.75)), lineWidth: 1.0)
            }

            // Hour / 3-hour tick
            let tickH: CGFloat   = is3h ? 11 : 6
            let tickAlpha: Double = isNow ? 0 : (is3h ? 0.55 : 0.28)
            if tickAlpha > 0 {
                var p = Path()
                p.move(to:    CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: tickH))
                ctx.stroke(p, with: .color(.white.opacity(tickAlpha)), lineWidth: 1.0)
            }

            // Clock-hour label on 3-hour marks (skip the "now" tick — cursor implies it)
            if is3h && !isNow {
                let tickDate = sessionAnchor.addingTimeInterval(Double(tick) * 3600)
                let hour = cal.component(.hour, from: tickDate)
                // Suppress labels too close to the right edge
                guard x <= size.width - 22 else { continue }
                ctx.draw(
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.40)),
                    at: CGPoint(x: x, y: totalH - 2),
                    anchor: .bottom
                )
            }
        }

        // ── Centre cursor ────────────────────────────────────────────────────
        let cursorColor: Color = atNow ? .white : Color.tideEbb

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
