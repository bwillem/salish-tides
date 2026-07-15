import SwiftUI

// Read-only tide height chart. The cursor is pinned to the centre; the curve
// slides as `currentDate` changes (driven by the timeline slider).
// Heights are interpolated from the nearest station's hi/lo predictions, in
// that station's own datum (MLLW for NOAA, Chart Datum for CHS).
struct TideChartView: View {
    @Environment(AppSettings.self) private var settings

    let currentDate: Date
    let events: [TideEvent]
    /// Live model water levels (already on the station's datum). Where the
    /// series covers a sample time it overrides the interpolated prediction,
    /// cross-fading into the prediction near its coverage edges so the curve
    /// never steps where the sources hand off.
    let live: LiveTideSeries?

    private func height(at t: Date) -> Double? {
        let predicted = TideCurve.height(at: t, events: events)
        return live?.blendedHeight(at: t, fallback: predicted) ?? predicted
    }

    // Visible window: ±windowHalfHours on each side of cursor
    private let windowHalfHours: Double = 6.0
    private let stepMinutes: Int = 12

    // Layout constants
    // Shared so the phase card can inset its labels to the plot's left edge —
    // see PhaseIndicatorView.
    static let plotLeftInset: CGFloat = 26   // y-axis label width
    private var leftPad: CGFloat { Self.plotLeftInset }
    private let bottomPad: CGFloat = 18   // x-axis label height
    private let topPad:    CGFloat = 8

    var body: some View {
        // Heights are stored in metres; convert to the user's unit up front so
        // the domain, curve, axis ticks, and labels are all in display units.
        let unit = settings.heightUnit
        let conv: (Double) -> Double = unit.value(fromMetres:)

        return Canvas { ctx, size in
            guard events.count >= 2 else {
                drawPlaceholder(ctx: ctx, size: size)
                return
            }

            var samples: [(date: Date, height: Double)] = []
            var t = currentDate.addingTimeInterval(-windowHalfHours * 3600)
            let windowEnd = currentDate.addingTimeInterval(windowHalfHours * 3600)
            while t <= windowEnd {
                if let h = height(at: t) { samples.append((t, h)) }
                t = t.addingTimeInterval(TimeInterval(stepMinutes * 60))
            }
            guard samples.count >= 2 else { return }

            // Dynamic y-domain from the visible samples (real tides go negative
            // below MLLW and ~5 m at Chart Datum — a fixed 0–5 domain won't do).
            let heights = samples.map { conv($0.height) }
            let lo = heights.min()!, hi = heights.max()!
            let pad = max(conv(0.3), (hi - lo) * 0.15)
            let yMin = lo - pad, yMax = hi + pad

            let chartLeft  = leftPad
            let chartRight = size.width
            let chartTop   = topPad
            let chartBot   = size.height - bottomPad
            let chartW     = chartRight - chartLeft
            let chartH     = chartBot - chartTop
            let windowSecs = windowHalfHours * 2 * 3600

            func xOf(_ date: Date) -> CGFloat {
                let frac = date.timeIntervalSince(currentDate) / windowSecs + 0.5
                return chartLeft + CGFloat(frac) * chartW
            }
            func yOf(_ h: Double) -> CGFloat {
                let frac = (h - yMin) / (yMax - yMin)
                return chartBot - CGFloat(frac) * chartH
            }

            // ── Horizontal grid lines (adaptive step) ───────────────────────
            let range = yMax - yMin
            let gridStep = Self.niceStep(range)
            var grid = Path()
            var gridLevels: [Double] = []
            var m = (yMin / gridStep).rounded(.up) * gridStep
            while m <= yMax {
                gridLevels.append(m)
                let y = yOf(m)
                grid.move(to:    CGPoint(x: chartLeft, y: y))
                grid.addLine(to: CGPoint(x: chartRight, y: y))
                m += gridStep
            }
            ctx.stroke(grid, with: .color(.primary.opacity(0.10)), lineWidth: 0.5)

            // ── Tide curve ──────────────────────────────────────────────────
            let pts = samples.map { CGPoint(x: xOf($0.date), y: yOf(conv($0.height))) }

            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: chartBot))
            pts.forEach { fill.addLine(to: $0) }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: chartBot))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.brandAccent.opacity(0.55), location: 0),
                    .init(color: Color.brandAccent.opacity(0.06), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: chartTop),
                endPoint:   CGPoint(x: 0, y: chartBot)
            ))

            var stroke = Path()
            stroke.move(to: pts[0])
            pts.dropFirst().forEach { stroke.addLine(to: $0) }
            ctx.stroke(stroke, with: .color(.primary.opacity(0.80)), lineWidth: 1.5)

            // ── Cursor (current time = centre) ──────────────────────────────
            let cx = xOf(currentDate)
            var cursor = Path()
            cursor.move(to:    CGPoint(x: cx, y: chartTop))
            cursor.addLine(to: CGPoint(x: cx, y: chartBot))
            ctx.stroke(cursor, with: .color(.primary.opacity(0.90)), lineWidth: 1.5)

            let currentH = conv(height(at: currentDate) ?? 0)
            let cy = yOf(currentH)
            let dotR: CGFloat = 4
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2)),
                with: .color(.primary)
            )

            let labelY = cy < chartTop + 20 ? cy + 14 : cy - 10
            ctx.draw(
                Text(String(format: "%.1f%@", currentH, unit.abbreviation))
                    .font(.system(size: 10, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary),
                at: CGPoint(x: cx + 6, y: labelY),
                anchor: .leading
            )
            // Station provenance (name + datum) is rendered as a caption below
            // the chart in PhaseIndicatorView, so it never overlaps the curve.

            // ── X-axis: a steady half-hour tick ruler, labelled every 3h ────
            // Ticks live on the absolute clock grid (…:00, :30) so they glide
            // with the curve as you scrub rather than blinking. Labels sit on
            // the 3-hour marks and fade in/out only at the plot edges — never
            // mid-plot — so a time value stays readable right under the cursor.
            let cal = Calendar.salish
            let startDate = currentDate.addingTimeInterval(-windowHalfHours * 3600)
            let endDate   = currentDate.addingTimeInterval(windowHalfHours * 3600)

            // First :00/:30 slot at or after the window's left edge.
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: startDate)
            comps.minute = 0
            comps.second = 0
            var tick = cal.date(from: comps) ?? startDate
            while tick < startDate { tick = tick.addingTimeInterval(30 * 60) }

            var ruler = Path()
            while tick <= endDate {
                let tx = xOf(tick)
                if tx >= chartLeft && tx <= chartRight {
                    let c = cal.dateComponents([.hour, .minute], from: tick)
                    let onHour   = (c.minute ?? 0) == 0
                    let labelled = onHour && (c.hour ?? 0) % 3 == 0

                    let tickLen: CGFloat = labelled ? 4 : (onHour ? 3 : 2)
                    ruler.move(to:    CGPoint(x: tx, y: chartBot))
                    ruler.addLine(to: CGPoint(x: tx, y: chartBot + tickLen))

                    if labelled {
                        // Ramp 0→full over the last 16px so labels slide in and
                        // out at the edges instead of popping.
                        let edgeFade = max(0, min(1, min(tx - chartLeft, chartRight - tx) / 16))
                        if edgeFade > 0 {
                            ctx.draw(
                                Text(settings.hourTickLabel(hour: c.hour ?? 0))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.45 * edgeFade)),
                                at: CGPoint(x: tx, y: size.height - 3),
                                anchor: .bottom
                            )
                        }
                    }
                }
                tick = tick.addingTimeInterval(30 * 60)
            }
            ctx.stroke(ruler, with: .color(.primary.opacity(0.22)), lineWidth: 0.5)

            // ── Y-axis: height labels ───────────────────────────────────────
            let axisDecimals = gridStep < 1 ? 1 : 0
            for level in gridLevels {
                let y = yOf(level)
                guard y >= chartTop && y <= chartBot else { continue }
                ctx.draw(
                    Text(String(format: "%.\(axisDecimals)f%@", level, unit.abbreviation))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.35)),
                    at: CGPoint(x: chartLeft - 3, y: y),
                    anchor: .trailing
                )
            }
        }
    }

    /// A "nice" axis interval (…0.5, 1, 2, 5, 10…) giving ~4 grid divisions
    /// across `range`. Unit-agnostic, so it produces sensible ticks whether the
    /// domain is in metres (~2–5) or feet (~7–16).
    private static func niceStep(_ range: Double) -> Double {
        guard range > 0 else { return 1 }
        let rough = range / 4
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let normalized = rough / magnitude
        let step: Double = normalized < 1.5 ? 1 : normalized < 3 ? 2 : normalized < 7 ? 5 : 10
        return step * magnitude
    }

    private func drawPlaceholder(ctx: GraphicsContext, size: CGSize) {
        ctx.draw(
            Text("Tide data unavailable")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.35)),
            at: CGPoint(x: size.width / 2, y: size.height / 2),
            anchor: .center
        )
    }
}
