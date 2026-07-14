import Foundation
import Testing
@testable import SalishTides

struct GridIndexTests {

    @Test func stridedDimensions() {
        // 898×398 native at stride 2 → 449×199 strided.
        #expect(SalishSeaCastAPI.stridedRows == 449)
        #expect(SalishSeaCastAPI.stridedCols == 199)
    }

    @Test func stridedIndexRoundsDownToCell() {
        let cols = SalishSeaCastAPI.stridedCols
        #expect(SalishSeaCastAPI.stridedIndex(gridY: 0, gridX: 0) == 0)
        #expect(SalishSeaCastAPI.stridedIndex(gridY: 1, gridX: 1) == 0)
        #expect(SalishSeaCastAPI.stridedIndex(gridY: 2, gridX: 0) == cols)
        #expect(SalishSeaCastAPI.stridedIndex(gridY: 897, gridX: 397) == 448 * cols + 198)
    }

    /// Synthetic strided grid: lat/lon are linear in the strided indices, so
    /// interpolated values are exactly predictable.
    private func syntheticGrid() -> SalishSeaCastAPI.LiveGrid {
        let rows = SalishSeaCastAPI.stridedRows, cols = SalishSeaCastAPI.stridedCols
        var lat = [Float](repeating: .nan, count: rows * cols)
        var lon = [Float](repeating: .nan, count: rows * cols)
        for sy in 0..<rows {
            for sx in 0..<cols {
                lat[sy * cols + sx] = 48.0 + Float(sy) * 0.01
                lon[sy * cols + sx] = -125.0 + Float(sx) * 0.01
            }
        }
        return SalishSeaCastAPI.LiveGrid(lat: lat, lon: lon)
    }

    @Test func nativeLatLonExactOnStridedCells() throws {
        let grid = syntheticGrid()
        let p = try #require(SalishSeaCastAPI.nativeLatLon(y: 20, x: 40, grid: grid))
        #expect(abs(p.lat - (48.0 + 10 * 0.01)) < 1e-4)
        #expect(abs(p.lon - (-125.0 + 20 * 0.01)) < 1e-4)
    }

    @Test func nativeLatLonMidpointBetweenStridedCells() throws {
        let grid = syntheticGrid()
        // Odd native y → average of strided rows 10 and 11.
        let p = try #require(SalishSeaCastAPI.nativeLatLon(y: 21, x: 40, grid: grid))
        #expect(abs(p.lat - (48.0 + 10.5 * 0.01)) < 1e-4)
    }

    @Test func nativeWindowIsQuantizedAndCovering() throws {
        let grid = syntheticGrid()
        // Bounds covering strided cells sy 10...20, sx 30...40.
        let w = try #require(SalishSeaCastAPI.nativeWindow(
            latMin: 48.10, latMax: 48.20, lonMin: -124.70, lonMax: -124.60, grid: grid))
        let q = SalishSeaCastAPI.windowQuantum
        #expect(w.y0 % q == 0)
        #expect(w.x0 % q == 0)
        // Covers the native extent of the matched strided cells (sy*2).
        #expect(w.y0 <= 10 * 2 && w.y1 >= 20 * 2)
        #expect(w.x0 <= 30 * 2 && w.x1 >= 40 * 2)
        // Stays on the grid.
        #expect(w.y0 >= 0 && w.y1 < SalishSeaCastAPI.nativeRows)
        #expect(w.x0 >= 0 && w.x1 < SalishSeaCastAPI.nativeCols)
    }

    @Test func nativeWindowNilOffDomain() {
        let grid = syntheticGrid()
        #expect(SalishSeaCastAPI.nativeWindow(
            latMin: 10, latMax: 11, lonMin: 0, lonMax: 1, grid: grid) == nil)
    }
}

struct PackingTests {

    @Test func wetPointRoundTrip() {
        let points = [
            SalishSeaCastAPI.WetPoint(index: 0, east: 0.5, north: -1.25),
            SalishSeaCastAPI.WetPoint(index: 89_350, east: -3.75, north: 0),
        ]
        #expect(SalishSeaCastAPI.unpackPoints(SalishSeaCastAPI.pack(points)) == points)
    }

    @Test func nativePointRoundTrip() {
        let points = [
            SalishSeaCastAPI.NativePoint(y: 0, x: 0, east: 1.5, north: 2.5),
            SalishSeaCastAPI.NativePoint(y: 897, x: 397, east: -0.125, north: -2),
        ]
        #expect(SalishSeaCastAPI.unpackNativePoints(SalishSeaCastAPI.pack(points)) == points)
    }

    @Test func gridRoundTripPreservesNaN() {
        let grid = SalishSeaCastAPI.LiveGrid(lat: [48.5, .nan], lon: [-123.25, .nan])
        let out = SalishSeaCastAPI.unpackGrid(SalishSeaCastAPI.pack(grid))
        #expect(out.lat[0] == 48.5 && out.lon[0] == -123.25)
        #expect(out.lat[1].isNaN && out.lon[1].isNaN)
    }

    @Test func unpackIgnoresTrailingPartialRecord() {
        let points = [SalishSeaCastAPI.WetPoint(index: 7, east: 1, north: 2)]
        var data = SalishSeaCastAPI.pack(points)
        data.append(contentsOf: [0xDE, 0xAD])   // truncated tail
        #expect(SalishSeaCastAPI.unpackPoints(data) == points)
    }
}

struct ResponseParsingTests {

    private func sliceJSON(time: String, rows: String) -> Data {
        Data("""
        {"table": {"columnNames": ["time","gridY","gridX","VelEast5","VelNorth5"],
                   "rows": [\(rows)]}}
        """.utf8)
    }

    @Test func parsesWetPointsAndDropsNullAndOutOfRange() throws {
        let data = sliceJSON(time: "t", rows: """
            ["2026-07-14T14:30:00Z", 10, 20, 0.5, -0.25],
            ["2026-07-14T14:30:00Z", 11, 21, null, null],
            ["2026-07-14T14:30:00Z", 5000, 20, 0.5, 0.5],
            ["2026-07-14T14:30:00Z", 12, 22, 1.0, 1.0]
        """)
        let result = try #require(try SalishSeaCastAPI.parseCurrentsSlice(data))
        #expect(result.points.count == 2)
        #expect(Int(result.center.timeIntervalSince1970)
                == TideBundleEvent.epochUTC(from: "2026-07-14T14:30:00Z"))
    }

    @Test func hostileTimestampReturnsNilNotCrash() throws {
        let data = sliceJSON(time: "t", rows: """
            ["9223372036854775807-01-01T00:00:00Z", 10, 20, 0.5, -0.25]
        """)
        #expect(try SalishSeaCastAPI.parseCurrentsSlice(data) == nil)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: SalishSeaCastAPI.ResponseError.self) {
            _ = try SalishSeaCastAPI.parseCurrentsSlice(Data("not json".utf8))
        }
        #expect(throws: SalishSeaCastAPI.ResponseError.self) {
            _ = try SalishSeaCastAPI.parseCurrentsSlice(Data(#"{"table": {}}"#.utf8))
        }
    }

    @Test func sshParseSortsAndSkipsNulls() throws {
        let data = Data("""
        {"table": {"columnNames": ["time","longitude","latitude","ssh"],
                   "rows": [
            ["2026-07-14T02:00:00Z", -123.0, 48.4, 1.5],
            ["2026-07-14T01:00:00Z", -123.0, 48.4, 1.0],
            ["2026-07-14T03:00:00Z", -123.0, 48.4, null]
        ]}}
        """.utf8)
        let out = try SalishSeaCastAPI.parseSSH(data)
        #expect(out.count == 2)
        #expect(out[0].ssh == 1.0 && out[1].ssh == 1.5)
        #expect(out[0].t < out[1].t)
    }
}
