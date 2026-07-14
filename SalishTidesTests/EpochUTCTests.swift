import Foundation
import Testing
@testable import SalishTides

// TideBundleEvent.epochUTC is a hand-rolled ISO parser used on both the
// bundled tide file (~200k events) and untrusted server timestamps, so it
// must agree with Foundation on valid input and return nil (never trap) on
// anything else.
struct EpochUTCTests {

    private func foundationEpoch(_ s: String) -> Int? {
        let f = ISO8601DateFormatter()
        return f.date(from: s).map { Int($0.timeIntervalSince1970) }
    }

    @Test func epochOfUnixEpoch() {
        #expect(TideBundleEvent.epochUTC(from: "1970-01-01T00:00:00Z") == 0)
    }

    @Test(arguments: [
        "2026-07-14T12:34:56Z",
        "2026-01-01T00:00:00Z",
        "2026-12-31T23:59:59Z",
        "2000-02-29T06:00:00Z",   // century leap day (divisible by 400)
        "2024-02-29T00:00:00Z",   // ordinary leap day
        "1999-12-31T23:59:59Z",
        "2100-06-15T12:00:00Z",   // 2100 is NOT a leap year — post-Feb date
    ])
    func agreesWithFoundation(_ iso: String) {
        #expect(TideBundleEvent.epochUTC(from: iso) == foundationEpoch(iso))
    }

    @Test func truncatesFractionalSeconds() {
        // ERDDAP could start emitting fractional seconds; the live layer must
        // not silently die on them.
        #expect(TideBundleEvent.epochUTC(from: "2026-07-14T12:34:56.500Z")
                == TideBundleEvent.epochUTC(from: "2026-07-14T12:34:56Z"))
    }

    @Test func allowsLeapSecond() {
        #expect(TideBundleEvent.epochUTC(from: "2026-06-30T23:59:60Z") != nil)
    }

    @Test(arguments: [
        "9223372036854775807-01-01T00:00:00Z",  // Int.max year — would trap in daysFromCivil
        "10000-01-01T00:00:00Z",                // out of accepted year range
        "2026-13-01T00:00:00Z",                 // month 13
        "2026-00-01T00:00:00Z",                 // month 0
        "2026-01-32T00:00:00Z",                 // day 32
        "2026-01-01T24:00:00Z",                 // hour 24
        "2026-01-01T00:61:00Z",                 // minute 61
        "not a date",
        "",
        "2026-01-01",                           // too few fields
    ])
    func rejectsInvalidInput(_ iso: String) {
        #expect(TideBundleEvent.epochUTC(from: iso) == nil)
    }
}
