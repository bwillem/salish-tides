import Foundation
import Testing
@testable import SalishTides

struct ChartSelectorTests {

    /// Minimal table: July 14 maps hour h → chart (h % 20) + 1, with charts
    /// 1–10 flood and 11–20 ebb.
    private func makeSelector(year: Int = 2026) -> ChartSelector {
        let hours: [Int?] = (0..<24).map { ($0 % 20) + 1 }
        let table = AtlasLookupTable(
            year: year,
            timezone: "America/Vancouver",
            mapCount: 20,
            phases: ["flood_1": [1, 10], "ebb_1": [11, 20]],
            grid: ["7": ["14": hours]]
        )
        return ChartSelector(volume: 1, table: table)
    }

    private func pacificDate(year: Int = 2026, month: Int = 7, day: Int = 14, hour: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        c.timeZone = .salish
        return Calendar.salish.date(from: c)!
    }

    @Test func selectsChartForLocalHour() throws {
        let sel = try #require(makeSelector().selection(for: pacificDate(hour: 5)))
        #expect(sel.chart == 6)
        #expect(sel.tendency == .flood)
        #expect(sel.volume == 1)
    }

    @Test func mapsEbbPhaseRange() throws {
        // Hour 14 → chart 15 → ebb range [11, 20].
        let sel = try #require(makeSelector().selection(for: pacificDate(hour: 14)))
        #expect(sel.chart == 15)
        #expect(sel.tendency == .ebb)
    }

    @Test func nilOutsideTableYear() {
        #expect(makeSelector().selection(for: pacificDate(year: 2027, hour: 5)) == nil)
    }

    @Test func nilForMissingDay() {
        #expect(makeSelector().selection(for: pacificDate(month: 8, day: 1, hour: 5)) == nil)
    }

    @Test func keyedToPacificTimeNotUTC() throws {
        // 2026-07-15T02:00:00Z is 19:00 on July 14 in Pacific time — the
        // lookup must resolve to July 14's row, hour 19.
        let utcEvening = Date(timeIntervalSince1970:
            TimeInterval(TideBundleEvent.epochUTC(from: "2026-07-15T02:00:00Z")!))
        let sel = try #require(makeSelector().selection(for: utcEvening))
        #expect(sel.chart == 20)
    }
}
