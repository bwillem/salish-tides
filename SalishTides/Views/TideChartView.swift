import SwiftUI

// Read-only tide height chart.
// The cursor is always pinned to the center; the curve slides left/right
// as `currentDate` changes (driven by the timeline slider).
struct TideChartView: View {
    let currentDate: Date

    // Visible window: ±windowHalfHours on each side of cursor
    private let windowHalfHours: Double = 6.0
    private let stepMinutes: Int = 12

    // Layout constants
    private let leftPad:   CGFloat = 26   // y-axis label width
    private let bottomPad: CGFloat = 18   // x-axis label height
    private let topPad:    CGFloat = 8

    // Y-axis domain (metres MLLW)
    private let yMin: Double = 0.0
    private let yMax: Double = 5.0

    var body: some View {
        Canvas { ctx, size in
            let samples = TidePredictor.samples(
                centeredOn: currentDate,
                windowHours: windowHalfHours * 2,
                stepMinutes: stepMinutes
            )
            guard samples.count >= 2 else { return }

            let chartLeft  = leftPad
            let chartRight = size.width
            let chartTop   = topPad
            let chartBot   = size.height - bottomPad
            let chartW     = chartRight - chartLeft
            let chartH     = chartBot - chartTop
            let windowSecs = windowHalfHours * 2 * 3600

            // Convert date → canvas x, height → canvas y
            func xOf(_ date: Date) -> CGFloat {
                let frac = date.timeIntervalSince(currentDate) / windowSecs + 0.5
                return chartLeft + CGFloat(frac) * chartW
            }
            func yOf(_ h: Double) -> CGFloat {
                let frac = (h - yMin) / (yMax - yMin)
                return chartBot - CGFloat(frac) * chartH
            }

            // ── Horizontal grid lines ────────────────────────────────────────
            var grid = Path()
            for metre in [1.0, 2.0, 3.0, 4.0] {
                let y = yOf(metre)
                grid.move(to:    CGPoint(x: chartLeft, y: y))
                grid.addLine(to: CGPoint(x: chartRight, y: y))
            }
            ctx.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: 0.5)

            // ── Tide curve ───────────────────────────────────────────────────
            let pts = samples.map { CGPoint(x: xOf($0.date), y: yOf($0.height)) }

            // Filled area (closes at baseline)
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: chartBot))
            pts.forEach { fill.addLine(to: $0) }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: chartBot))
            fill.closeSubpath()

            ctx.fill(fill, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.oceanMid.opacity(0.55), location: 0),
                    .init(color: Color.oceanMid.opacity(0.06), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: chartTop),
                endPoint:   CGPoint(x: 0, y: chartBot)
            ))

            // Curve stroke
            var stroke = Path()
            stroke.move(to: pts[0])
            pts.dropFirst().forEach { stroke.addLine(to: $0) }
            ctx.stroke(stroke, with: .color(.white.opacity(0.80)), lineWidth: 1.5)

            // ── Cursor (current time = centre) ───────────────────────────────
            let cx = xOf(currentDate)
            var cursor = Path()
            cursor.move(to:    CGPoint(x: cx, y: chartTop))
            cursor.addLine(to: CGPoint(x: cx, y: chartBot))
            ctx.stroke(cursor, with: .color(.white.opacity(0.90)), lineWidth: 1.5)

            // Dot at current height
            let cy = yOf(TidePredictor.height(at: currentDate))
            let dotR: CGFloat = 4
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2)),
                with: .color(.white)
            )

            // Current height label (above or below dot to avoid clipping)
            let currentH = TidePredictor.height(at: currentDate)
            let labelY   = cy < chartTop + 20 ? cy + 14 : cy - 10
            ctx.draw(
                Text(String(format: "%.1fm", currentH))
                    .font(.system(size: 10, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white),
                at: CGPoint(x: cx + 6, y: labelY),
                anchor: .leading
            )

            // ── X-axis: time labels every 3h aligned to clock hours ──────────
            let tz = TimeZone(identifier: "America/Vancouver")!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz

            let startDate = currentDate.addingTimeInterval(-windowHalfHours * 3600)
            let endDate   = currentDate.addingTimeInterval(windowHalfHours * 3600)

            // Find first 3-hour boundary after startDate
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: startDate)
            let startHour = comps.hour ?? 0
            comps.hour    = ((startHour / 3) + 1) * 3
            comps.minute  = 0
            comps.second  = 0
            var tick = cal.date(from: comps) ?? startDate

            while tick <= endDate {
                let tx = xOf(tick)
                if tx >= chartLeft + 4 && tx <= chartRight - 22 {
                    // Skip label if too close to cursor
                    let distFromCursor = abs(tx - cx)
                    if distFromCursor > 22 {
                        let hr = cal.component(.hour, from: tick)
                        ctx.draw(
                            Text(String(format: "%02d:00", hr))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45)),
                            at: CGPoint(x: tx, y: size.height - 3),
                            anchor: .bottom
                        )
                    }
                    // Tick mark
                    var tickPath = Path()
                    tickPath.move(to:    CGPoint(x: tx, y: chartBot))
                    tickPath.addLine(to: CGPoint(x: tx, y: chartBot + 3))
                    ctx.stroke(tickPath, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                }
                tick = tick.addingTimeInterval(3 * 3600)
            }

            // ── Y-axis: metre labels ─────────────────────────────────────────
            for metre in [1.0, 2.0, 3.0, 4.0] {
                let y = yOf(metre)
                guard y >= chartTop && y <= chartBot else { continue }
                ctx.draw(
                    Text(String(format: "%.0fm", metre))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35)),
                    at: CGPoint(x: chartLeft - 3, y: y),
                    anchor: .trailing
                )
            }
        }
    }
}
