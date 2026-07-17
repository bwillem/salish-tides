import MapLibre
import Metal
import MetalKit
import simd
import QuartzCore
import CoreLocation

// Custom Metal style layer that animates tidal current as flowing particles.
//
// The data points (live or offline-model cells) are resampled onto a
// **viewport-anchored raster** on every update: bin-average into grid cells,
// flood-fill outward across chart water (bounded by the data spacing, so flow
// reaches the drawn coastline but never invents current far from real data),
// then box-blur — a smooth, averaged field that is a general representation of
// the current, not a reproduction of the sample layout. Land comes from the
// basemap's own rendered polygons (exact chart-water membership; the model's
// dry-cell mask fills in for styles with no land polygons), so particles live
// and die at the coastline the user sees.
//
// Pipeline (30 fps CADisplayLink → setNeedsDisplay):
//   1. Compute pass: one bilinear texture sample per particle → velocity,
//      water, data-coverage; advect; recycle dead/aged particles directly into
//      a random *water* cell (uniform density over water, regardless of how
//      much of the screen is land — no clustering, no burnt reseeds).
//   2. Render: each particle drawn as a short streak from its stored velocity,
//      projected with the live map matrix (glued through pan/zoom).
//
// Per-frame cost is O(particles) — a single texture fetch each — so zoomed-out
// views cost the same as zoomed-in ones. The raster rebuild is O(cells) on a
// background task, at the update cadence (hour change / viewport settle).
//
// Race-free: particle buffers ping-pong; the render reads last frame's compute
// output; a 2-deep semaphore bounds frames in flight. MLNCustomStyleLayer's
// callbacks are main-thread, so the Metal state is single-threaded; @unchecked
// Sendable holds that under Swift 6.
final class CurrentParticleLayer: MLNCustomStyleLayer, @unchecked Sendable {

    // Matches the Metal `Particle` struct (32 bytes).
    private struct GPUParticle {
        var pos: SIMD2<Float>    // world Mercator [0,1]
        var vel: SIMD2<Float>    // sampled east/north m/s (for the renderer)
        var age: Float
        var fade: Float          // water × coverage fade (for the alpha edge)
        var pad0: Float = 0
        var pad1: Float = 0
    }

    private struct AdvectUniforms {
        var speedK: Float        // screen points moved per (m/s) per frame
        var worldSize: Float     // 512·2^zoom
        var originX: Float       // field origin/span in world coords
        var originY: Float
        var spanX: Float
        var spanY: Float
        var lifetime: Float
        var frame: UInt32
        var count: UInt32        // particle count
        var fieldCols: UInt32
        var fieldRows: UInt32
        var waterCellCount: UInt32
    }

    private struct RenderUniforms {
        var worldSize: Float
        var streakLenScale: Float
        var maxStreakPx: Float
        var maxSpeed: Float
        var lifetime: Float
        var dark: Float
        var viewportW: Float
        var viewportH: Float
        var lineWidth: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    // Tunables.
    private let particleCount = 2250
    private let lifetime: Float = 4.0
    private let speedPx: Float = 0.35          // screen points per (m/s) per frame
    private let streakLenScale: Float = 7.0    // streak length: points per (m/s)
    private let maxStreakPx: Float = 14.0
    private let maxSpeed: Float = 2.5
    private let lineWidthDay: Float = 2.0
    private let lineWidthNight: Float = 1.4
    // Raster resolution across the longer viewport axis. 160 cells ≈ 2–5 px
    // per cell on screen — smooth to the eye, cheap to rebuild (~25k cells).
    private let fieldCellsAcross = 160

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var advectPipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var samplerState: MTLSamplerState?

    private var particleBuffers: [MTLBuffer] = []
    private var current = 0
    private var frame: UInt32 = 0
    private let inFlight = DispatchSemaphore(value: 2)

    // The resampled field + the water-cell list particles reseed into.
    private var fieldTexture: MTLTexture?
    private var waterCellBuffer: MTLBuffer?
    private var appliedField: Field?
    // Inputs stashed for rebuilds (style reloads, late device arrival) and the
    // async build coalescing (at most one build in flight, at most one queued).
    private var lastInputs: Inputs?
    private var appliedInputs: Inputs?
    private var building = false
    private var pendingBuild: Inputs?

    private var isDark = true
    private var styleActive = true
    private var foreground = true
    private var animating: Bool { styleActive && foreground }
    private var displayLink: CADisplayLink?

    // MARK: - Field raster

    /// One basemap land feature: exterior ring + holes, in world Mercator.
    /// Kept grouped (not flattened) so overlapping tile-clipped copies of the
    /// same landmass union correctly — a flat even-odd test across independent
    /// rings classifies double-covered overlap strips as water.
    struct LandPolygon: Sendable, Equatable {
        let exterior: [SIMD2<Float>]
        let holes: [[SIMD2<Float>]]
    }

    /// Everything an update pushes in, kept so the field can be rebuilt.
    /// Equatable so identical pushes (scene-phase flips, content-identical
    /// reloads) skip the rebuild entirely.
    private struct Inputs: Sendable, Equatable {
        let vectors: [CurrentVector]
        let mask: [CurrentVector]
        let landPolygons: [LandPolygon]
        let boundsWorld: Bounds

        struct Bounds: Sendable, Equatable {
            let minX: Float, minY: Float, maxX: Float, maxY: Float
        }
    }

    /// The CPU-built raster: interleaved RGBA per cell (east, north, water,
    /// coverage), plus the indices of live water cells for uniform reseeding.
    private struct Field: Sendable {
        let cols: Int
        let rows: Int
        let originX: Float, originY: Float
        let spanX: Float, spanY: Float
        let rgba: [Float]
        let waterCells: [UInt32]
    }

    // MARK: - Lifecycle

    override func didMove(to mapView: MLNMapView) {
        MainActor.assumeIsolated {
            let resource = mapView.backendResource()
            guard let device = resource.device else { return }
            self.device = device
            self.queue = device.makeCommandQueue()
            buildPipelines(device: device, colorPixelFormat: resource.mtkView.colorPixelFormat)
            buildParticleBuffers(device: device)
            if let inputs = lastInputs { rebuildField(from: inputs) }
            syncDisplayLink()
        }
    }

    override func willMove(from mapView: MLNMapView) {
        stopDisplayLink()
        advectPipeline = nil
        renderPipeline = nil
        depthState = nil
        samplerState = nil
        particleBuffers = []
        fieldTexture = nil
        waterCellBuffer = nil
        appliedField = nil
        // The GPU field is gone, so the inputs are no longer "applied" — leave
        // this set and didMove's rebuild-from-lastInputs would dedupe against
        // a field that no longer exists.
        appliedInputs = nil
        queue = nil
        device = nil
    }

    // MapLibre normally pairs willMove(from:) with teardown, but nothing
    // contractually guarantees it runs before the layer is released. The weak
    // proxy already prevents a retain cycle, but an un-invalidated link would
    // keep a 30 fps timer ticking a dead proxy on the main run loop. deinit is
    // nonisolated; CADisplayLink.invalidate() is documented thread-safe, so
    // this backstop is fine under strict concurrency.
    deinit {
        displayLink?.invalidate()
    }

    fileprivate func step() {
        // With no field applied (viewport off all coverage — e.g. offline
        // outside the model domains), invalidating would still force MapLibre
        // into a full-map re-render 30×/s with nothing to draw: pure battery
        // burn in exactly the offline-at-sea case. Skip the invalidation
        // rather than pausing the link — an empty tick is ~free next to a map
        // render, and the next applyField revives this path with no resume
        // bookkeeping to get wrong.
        guard fieldTexture != nil else { return }
        setNeedsDisplay()
    }

    private func syncDisplayLink() { animating ? startDisplayLink() : stopDisplayLink() }

    private func startDisplayLink() {
        guard displayLink == nil, device != nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(layer: self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Inputs (main thread)

    func setDark(_ dark: Bool) { isDark = dark }

    func setActive(_ active: Bool) {
        guard active != styleActive else { return }
        styleActive = active
        syncDisplayLink()
    }

    func setForeground(_ foreground: Bool) {
        guard foreground != self.foreground else { return }
        self.foreground = foreground
        syncDisplayLink()
    }

    /// Pushes the data vectors plus land knowledge (basemap polygons; model
    /// dry cells as fallback for styles without land polygons) and the
    /// viewport in world coords. Rebuilds the field raster off-main and swaps
    /// it in when done — cheap and infrequent (hourly / viewport settle /
    /// scrub). Identical pushes are ignored; while a build runs, only the
    /// newest superseding input is kept (never a queue of stale builds).
    func update(vectors: [CurrentVector], mask: [CurrentVector],
                landPolygons: [LandPolygon],
                boundsWorld: (minX: Float, minY: Float, maxX: Float, maxY: Float)) {
        let inputs = Inputs(vectors: vectors, mask: mask, landPolygons: landPolygons,
                            boundsWorld: .init(minX: boundsWorld.minX, minY: boundsWorld.minY,
                                               maxX: boundsWorld.maxX, maxY: boundsWorld.maxY))
        lastInputs = inputs
        guard device != nil else { return }
        rebuildField(from: inputs)
    }

    private func rebuildField(from inputs: Inputs) {
        guard inputs != appliedInputs else { return }
        if building {
            pendingBuild = inputs
            return
        }
        building = true
        startBuild(inputs)
    }

    private func startBuild(_ inputs: Inputs) {
        let cellsAcross = fieldCellsAcross
        Task.detached(priority: .userInitiated) { [weak self] in
            let field = Self.buildField(inputs: inputs, cellsAcross: cellsAcross)
            // Re-capture weakly so the strong ref never crosses the actor hop
            // (Swift 6 region isolation); the layer is main-thread-only anyway.
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Mark applied only when the GPU resources actually swapped
                // in: after a failed apply the old texture keeps rendering,
                // and recording these inputs as applied would dedupe every
                // identical future push against a field that never landed —
                // leaving the stale run on screen with no repair path.
                if self.applyField(field) {
                    self.appliedInputs = inputs
                }
                if let next = self.pendingBuild {
                    self.pendingBuild = nil
                    if next != inputs {
                        self.startBuild(next)
                        return
                    }
                }
                self.building = false
            }
        }
    }

    /// Swaps the built field's GPU resources in. Returns false when a Metal
    /// allocation failed (or the device is gone) and the previous field is
    /// still what renders — the caller must then leave `appliedInputs` alone
    /// so a repeat push retries rather than deduplicating.
    private func applyField(_ field: Field?) -> Bool {
        guard let field, field.cols > 0, field.rows > 0 else {
            // A nil/degenerate field is a deliberate clear, not a failure.
            fieldTexture = nil
            waterCellBuffer = nil
            appliedField = nil
            return true
        }
        // No device: the build outlived willMove's teardown. didMove rebuilds
        // from lastInputs, which must not be marked applied here.
        guard let device else { return false }
        // Always a fresh texture/buffer: in-place writes would race in-flight
        // GPU frames; the old ones are retained by those frames until done.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: field.cols, height: field.rows, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return false }
        tex.replace(region: MTLRegionMake2D(0, 0, field.cols, field.rows),
                    mipmapLevel: 0, withBytes: field.rgba,
                    bytesPerRow: field.cols * 4 * MemoryLayout<Float>.size)
        // Reseed target list; a 1-entry zero buffer when there's no live water
        // so the kernel always has something bound.
        let cells: [UInt32] = field.waterCells.isEmpty ? [0] : field.waterCells
        guard let cellBuf = device.makeBuffer(bytes: cells,
                                              length: cells.count * MemoryLayout<UInt32>.stride,
                                              options: .storageModeShared) else { return false }
        fieldTexture = tex
        waterCellBuffer = cellBuf
        appliedField = field
        return true
    }

    // MARK: - Field construction (pure, off-main)

    private static func buildField(inputs: Inputs, cellsAcross: Int) -> Field? {
        let b = inputs.boundsWorld
        var minX = b.minX, minY = b.minY, maxX = b.maxX, maxY = b.maxY
        // Margin so pans don't immediately run off the field edge.
        let mx = (maxX - minX) * 0.15, my = (maxY - minY) * 0.15
        minX -= mx; maxX += mx; minY -= my; maxY += my
        let spanX = maxX - minX, spanY = maxY - minY
        guard spanX > 0, spanY > 0 else { return nil }

        var cols: Int, rows: Int
        if spanX >= spanY {
            cols = cellsAcross
            rows = max(16, Int((Float(cellsAcross) * spanY / spanX).rounded()))
        } else {
            rows = cellsAcross
            cols = max(16, Int((Float(cellsAcross) * spanX / spanY).rounded()))
        }
        let cells = cols * rows
        let cellW = spanX / Float(cols), cellH = spanY / Float(rows)

        func cellIndex(_ x: Float, _ y: Float) -> Int? {
            let cx = Int((x - minX) / cellW), cy = Int((y - minY) / cellH)
            guard cx >= 0, cx < cols, cy >= 0, cy < rows else { return nil }
            return cy * cols + cx
        }

        // ── Land mask ────────────────────────────────────────────────────
        // Basemap polygons when available (exact drawn coastline, scanline-
        // rasterized per feature and unioned so overlapping tile-clipped
        // copies can't cancel out); otherwise the model's dry cells, splatted
        // and dilated to their own grid spacing so the band stays contiguous
        // at any raster resolution.
        var land = [Bool](repeating: false, count: cells)
        var landCount = 0
        if !inputs.landPolygons.isEmpty {
            for polygon in inputs.landPolygons {
                rasterize(polygon, into: &land,
                          minX: minX, minY: minY, cellW: cellW, cellH: cellH,
                          cols: cols, rows: rows)
            }
            landCount = land.reduce(0) { $0 + ($1 ? 1 : 0) }
        } else if !inputs.mask.isEmpty {
            // Estimate the mask's own spacing (in raster cells) from its
            // bounding-box density, and dilate each point by half of it: the
            // band stays closed whether a raster cell is 15 m or 900 m.
            var lo = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var hi = -lo
            var maskCells: [Int] = []
            maskCells.reserveCapacity(inputs.mask.count)
            for m in inputs.mask {
                let w = lonLatToWorld(lon: m.lon, lat: m.lat)
                let p = SIMD2(Float(w.x), Float(w.y))
                lo = simd_min(lo, p); hi = simd_max(hi, p)
                if let i = cellIndex(p.x, p.y) { maskCells.append(i) }
            }
            let area = max(0, (hi.x - lo.x)) * max(0, (hi.y - lo.y))
            let spacingWorld = (area / Float(max(1, inputs.mask.count))).squareRoot()
            let radius = min(24, max(1, Int((spacingWorld / min(cellW, cellH) / 2).rounded(.up))))
            for i in maskCells {
                let cy = i / cols, cx = i % cols
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let ny = cy + dy, nx = cx + dx
                        guard ny >= 0, ny < rows, nx >= 0, nx < cols else { continue }
                        let n = ny * cols + nx
                        if !land[n] { land[n] = true; landCount += 1 }
                    }
                }
            }
        }

        // ── Splat data ───────────────────────────────────────────────────
        // No land guard here: whether a data sample on a "land" cell should
        // win is decided below, once the data spacing is known.
        var sumU = [Float](repeating: 0, count: cells)
        var sumV = [Float](repeating: 0, count: cells)
        var count = [Float](repeating: 0, count: cells)
        var dataCells = 0
        for v in inputs.vectors {
            let w = lonLatToWorld(lon: v.lon, lat: v.lat)
            guard let i = cellIndex(Float(w.x), Float(w.y)) else { continue }
            let theta = Float(v.direction_deg) * .pi / 180
            let speed = Float(v.speed_ms)
            if count[i] == 0 { dataCells += 1 }
            sumU[i] += speed * sin(theta)
            sumV[i] += speed * cos(theta)
            count[i] += 1
        }
        guard dataCells > 0 else { return Field(cols: cols, rows: rows,
                                                originX: minX, originY: minY,
                                                spanX: spanX, spanY: spanY,
                                                rgba: [Float](repeating: 0, count: cells * 4),
                                                waterCells: []) }

        let waterCellCountEstimate = max(1, cells - landCount)
        let spacingCells = (Float(waterCellCountEstimate) / Float(dataCells)).squareRoot()

        // ── Reconcile data with the land mask ────────────────────────────
        // Coarse-raster regime (cells comparable to the data spacing): a land
        // cell that contains a current sample is almost certainly a channel
        // narrower than one cell (Dodd Narrows at planning zooms) — force it
        // water so the strongest passes keep their flow; the under-land
        // render clip still bounds it to the drawn channel pixels.
        // Fine-raster regime (cells ≪ data spacing): a sample on land is the
        // model's displaced coastline (widened passes) — land wins, drop it.
        if spacingCells <= 3 {
            for i in 0..<cells where count[i] > 0 && land[i] {
                land[i] = false
            }
        } else {
            for i in 0..<cells where count[i] > 0 && land[i] {
                count[i] = 0
                sumU[i] = 0
                sumV[i] = 0
                dataCells -= 1
            }
            guard dataCells > 0 else { return Field(cols: cols, rows: rows,
                                                    originX: minX, originY: minY,
                                                    spanX: spanX, spanY: spanY,
                                                    rgba: [Float](repeating: 0, count: cells * 4),
                                                    waterCells: []) }
        }

        var velU = [Float](repeating: 0, count: cells)
        var velV = [Float](repeating: 0, count: cells)
        var dist = [Int](repeating: .max, count: cells)
        var queue: [Int] = []
        queue.reserveCapacity(dataCells)
        for i in 0..<cells where count[i] > 0 {
            velU[i] = sumU[i] / count[i]
            velV[i] = sumV[i] / count[i]
            dist[i] = 0
            queue.append(i)
        }

        // ── Flood-fill across water, bounded by the data spacing ─────────
        // Reach ≈ 1.1× the estimated point spacing: enough to close the
        // diagonal gaps between samples AND bridge one-sample holes in the
        // model's coast-eroded velocity mask (fills meet from both sides),
        // without inventing current much beyond real coverage — off the model
        // domain and in unsampled bays the fill stops and no particles render.
        // The cap must scale with spacing (at navigation zooms one sample is
        // 20+ cells), or the narrowest throats go dark exactly where currents
        // are strongest.
        let reach = min(64, max(2, Int((spacingCells * 1.1).rounded(.up)) + 2))

        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let d = dist[i]
            guard d < reach else { continue }
            let cy = i / cols, cx = i % cols
            for dy in -1...1 {
                for dx in -1...1 where (dy, dx) != (0, 0) {
                    let ny = cy + dy, nx = cx + dx
                    guard ny >= 0, ny < rows, nx >= 0, nx < cols else { continue }
                    let n = ny * cols + nx
                    guard !land[n], dist[n] == .max else { continue }
                    // Average of already-assigned neighbours (≥1: cell `i`).
                    var u: Float = 0, v: Float = 0, k: Float = 0
                    for ey in -1...1 {
                        for ex in -1...1 {
                            let my = ny + ey, mx2 = nx + ex
                            guard my >= 0, my < rows, mx2 >= 0, mx2 < cols else { continue }
                            let m = my * cols + mx2
                            if dist[m] <= d { u += velU[m]; v += velV[m]; k += 1 }
                        }
                    }
                    velU[n] = u / max(1, k)
                    velV[n] = v / max(1, k)
                    dist[n] = d + 1
                    queue.append(n)
                }
            }
        }

        // ── Smooth (two 3×3 passes over covered water) ───────────────────
        for _ in 0..<2 {
            var outU = velU, outV = velV
            for cy in 0..<rows {
                for cx in 0..<cols {
                    let i = cy * cols + cx
                    guard !land[i], dist[i] != .max else { continue }
                    var u: Float = 0, v: Float = 0, k: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let ny = cy + dy, nx = cx + dx
                            guard ny >= 0, ny < rows, nx >= 0, nx < cols else { continue }
                            let n = ny * cols + nx
                            guard !land[n], dist[n] != .max else { continue }
                            u += velU[n]; v += velV[n]; k += 1
                        }
                    }
                    outU[i] = u / max(1, k)
                    outV[i] = v / max(1, k)
                }
            }
            velU = outU; velV = outV
        }

        // ── Pack ─────────────────────────────────────────────────────────
        // Coverage is a PLATEAU with a short frontier fade, not a gradient:
        // distance-to-nearest-sample must not modulate brightness inside the
        // interpolated interior, or every model sample renders as a bright
        // bullseye with dim/dead lanes along the lattice between samples —
        // exactly the clumped, banded look at navigation zooms where one
        // sample spans ~20 raster cells. Full coverage wherever the fill
        // connects to data; fade only over the last few cells at the edge of
        // real coverage.
        let edge = max(1, min(4, reach / 3))
        var rgba = [Float](repeating: 0, count: cells * 4)
        var waterCells: [UInt32] = []
        waterCells.reserveCapacity(cells / 4)
        for i in 0..<cells {
            let covered = dist[i] != .max
            let cov: Float = covered ? min(1, Float(reach - dist[i]) / Float(edge)) : 0
            rgba[i * 4]     = covered ? velU[i] : 0
            rgba[i * 4 + 1] = covered ? velV[i] : 0
            rgba[i * 4 + 2] = land[i] ? 0 : 1
            rgba[i * 4 + 3] = cov
            if !land[i], cov >= 0.15 { waterCells.append(UInt32(i)) }
        }
        return Field(cols: cols, rows: rows, originX: minX, originY: minY,
                     spanX: spanX, spanY: spanY, rgba: rgba, waterCells: waterCells)
    }

    /// Scanline-rasterizes one land polygon (exterior minus its holes) into
    /// the mask, OR-ing with whatever is already set — so tile-duplicated
    /// copies of the same landmass union instead of cancelling (the failure
    /// mode of a flat even-odd test across independent rings). O(vertices ×
    /// rows-per-edge + covered cells), vs O(cells × vertices) for per-cell
    /// point-in-polygon.
    private static func rasterize(_ polygon: LandPolygon, into land: inout [Bool],
                                  minX: Float, minY: Float, cellW: Float, cellH: Float,
                                  cols: Int, rows: Int) {
        // Row-bucketed edge crossings at each row's cell-center y. Even-odd
        // within one simple ring is exact; the union of disjoint holes is
        // likewise exact with their crossings merged.
        func crossings(_ rings: [[SIMD2<Float>]]) -> [[Float]] {
            var rowXs = [[Float]](repeating: [], count: rows)
            for ring in rings {
                let n = ring.count
                guard n >= 3 else { continue }
                var j = n - 1
                for i in 0..<n {
                    let a = ring[j], b = ring[i]
                    j = i
                    let yLo = min(a.y, b.y), yHi = max(a.y, b.y)
                    guard yHi > yLo else { continue }   // horizontal edge: no crossings
                    // Rows whose center y lies in the half-open [yLo, yHi) —
                    // half-open so a shared vertex isn't counted twice.
                    var cy = Int(((yLo - minY) / cellH - 0.5).rounded(.up))
                    let cyEnd = Int(((yHi - minY) / cellH - 0.5).rounded(.up))
                    cy = max(0, cy)
                    while cy < min(rows, cyEnd) {
                        let y = minY + (Float(cy) + 0.5) * cellH
                        if y >= yLo, y < yHi {
                            rowXs[cy].append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
                        }
                        cy += 1
                    }
                }
            }
            for cy in 0..<rows where !rowXs[cy].isEmpty { rowXs[cy].sort() }
            return rowXs
        }

        let ext = crossings([polygon.exterior])
        let holes = polygon.holes.isEmpty ? nil : crossings(polygon.holes)

        for cy in 0..<rows {
            let xs = ext[cy]
            guard !xs.isEmpty else { continue }
            // A well-formed closed ring crosses any scanline an even number of
            // times; an odd count means degenerate third-party geometry and
            // would shift the span pairing for the whole row — skip the row
            // (adjacent rows and overlapping tile copies cover the gap).
            guard xs.count % 2 == 0 else { continue }
            let holeXs = holes?[cy] ?? []
            var k = 0
            while k + 1 < xs.count {
                let x0 = xs[k], x1 = xs[k + 1]
                k += 2
                var cx = max(0, Int(((x0 - minX) / cellW - 0.5).rounded(.up)))
                let cxEnd = min(cols - 1, Int(((x1 - minX) / cellW - 0.5).rounded(.down)))
                while cx <= cxEnd {
                    let x = minX + (Float(cx) + 0.5) * cellW
                    // Inside a hole? (crossings to the left of x, even-odd)
                    var inHole = false
                    if !holeXs.isEmpty {
                        var crossingsLeft = 0
                        for hx in holeXs where hx <= x { crossingsLeft += 1 }
                        inHole = crossingsLeft % 2 == 1
                    }
                    if !inHole { land[cy * cols + cx] = true }
                    cx += 1
                }
            }
        }
    }

    // MARK: - Draw

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard styleActive,
              let renderEncoder,
              let queue,
              let advectPipeline,
              let renderPipeline,
              let depthState,
              let samplerState,
              let texture = fieldTexture,
              let waterCellBuffer,
              let field = appliedField,
              particleBuffers.count == 2 else { return }

        frame &+= 1
        let next = 1 - current
        let vpW = Float(context.size.width)
        let vpH = Float(context.size.height)
        let worldSize = Float(512.0 * pow(2.0, context.zoomLevel))

        let didAdvect = inFlight.wait(timeout: .now()) == .success
        if didAdvect {
            var advect = AdvectUniforms(
                speedK: speedPx, worldSize: worldSize,
                originX: field.originX, originY: field.originY,
                spanX: field.spanX, spanY: field.spanY,
                lifetime: lifetime, frame: frame,
                count: UInt32(particleCount),
                fieldCols: UInt32(field.cols), fieldRows: UInt32(field.rows),
                waterCellCount: UInt32(field.waterCells.count))
            if let cb = queue.makeCommandBuffer(), let ce = cb.makeComputeCommandEncoder() {
                ce.setComputePipelineState(advectPipeline)
                ce.setBuffer(particleBuffers[current], offset: 0, index: 0)
                ce.setBuffer(particleBuffers[next], offset: 0, index: 1)
                ce.setBytes(&advect, length: MemoryLayout<AdvectUniforms>.stride, index: 2)
                ce.setBuffer(waterCellBuffer, offset: 0, index: 3)
                ce.setTexture(texture, index: 0)
                ce.setSamplerState(samplerState, index: 0)
                let tg = min(advectPipeline.maxTotalThreadsPerThreadgroup, 64)
                ce.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
                ce.endEncoding()
                cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }
                cb.commit()
            } else {
                inFlight.signal()
            }
        }

        var matrix = Self.matrix(from: context.projectionMatrix)
        var render = RenderUniforms(
            worldSize: worldSize, streakLenScale: streakLenScale, maxStreakPx: maxStreakPx,
            maxSpeed: maxSpeed, lifetime: lifetime,
            dark: isDark ? 1 : 0, viewportW: vpW, viewportH: vpH,
            lineWidth: isDark ? lineWidthNight : lineWidthDay)

        renderEncoder.setRenderPipelineState(renderPipeline)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setVertexBuffer(particleBuffers[current], offset: 0, index: 0)
        renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        renderEncoder.setVertexBytes(&render, length: MemoryLayout<RenderUniforms>.stride, index: 2)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: particleCount * 6)

        if didAdvect { current = next }
    }

    // MARK: - Setup

    private func buildParticleBuffers(device: MTLDevice) {
        var seed = [GPUParticle]()
        seed.reserveCapacity(particleCount)
        for _ in 0..<particleCount {
            let lon = Double.random(in: -125.5 ... -122.0)
            let lat = Double.random(in: 47.0 ... 50.0)
            let w = Self.lonLatToWorld(lon: lon, lat: lat)
            seed.append(GPUParticle(pos: SIMD2(Float(w.x), Float(w.y)), vel: .zero,
                                    age: Float.random(in: 0...lifetime), fade: 0))
        }
        let len = particleCount * MemoryLayout<GPUParticle>.stride
        guard let a = device.makeBuffer(bytes: seed, length: len, options: .storageModeShared),
              let b = device.makeBuffer(length: len, options: .storageModeShared) else { return }
        particleBuffers = [a, b]
        current = 0
    }

    private func buildPipelines(device: MTLDevice, colorPixelFormat: MTLPixelFormat) {
        // Failures here degrade gracefully (draw() bails, arrows still work) —
        // but that also means a release build where particles never appear has
        // no symptom besides their absence, so each is logged.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            Log.map.error("particle shader compile failed: \(error, privacy: .public)")
            assertionFailure("CurrentParticleLayer: failed to compile shaders")
            return
        }
        if let advect = library.makeFunction(name: "advect") {
            do {
                advectPipeline = try device.makeComputePipelineState(function: advect)
            } catch {
                Log.map.error("particle advect pipeline failed: \(error, privacy: .public)")
            }
        } else {
            Log.map.error("particle advect function missing from compiled library")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "CurrentParticle.field"
        desc.vertexFunction = library.makeFunction(name: "streakVertex")
        desc.fragmentFunction = library.makeFunction(name: "streakFragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        desc.depthAttachmentPixelFormat = .depth32Float_stencil8
        desc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Log.map.error("particle render pipeline failed: \(error, privacy: .public)")
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .always
        depthDesc.isDepthWriteEnabled = false
        depthState = device.makeDepthStencilState(descriptor: depthDesc)

        let samp = MTLSamplerDescriptor()
        samp.minFilter = .linear
        samp.magFilter = .linear
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samp)
    }

    /// lon/lat → global Web-Mercator world coords [0,1]. Internal so the map
    /// coordinator can convert basemap land polygons into the layer's space.
    static func lonLatToWorld(lon: Double, lat: Double) -> (x: Double, y: Double) {
        let mx = (lon + 180.0) / 360.0
        let yi = log(tan((45.0 + lat / 2.0) * .pi / 180.0))
        let my = (180.0 - yi * (180.0 / .pi)) / 360.0
        return (mx, my)
    }

    private static func matrix(from m: MLNMatrix4) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(Float(m.m00), Float(m.m01), Float(m.m02), Float(m.m03)),
            SIMD4(Float(m.m10), Float(m.m11), Float(m.m12), Float(m.m13)),
            SIMD4(Float(m.m20), Float(m.m21), Float(m.m22), Float(m.m23)),
            SIMD4(Float(m.m30), Float(m.m31), Float(m.m32), Float(m.m33))
        ))
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Particle { float2 pos; float2 vel; float age; float fade; float2 pad; };

    struct AdvectUniforms {
        float speedK; float worldSize; float originX; float originY;
        float spanX; float spanY; float lifetime;
        uint frame; uint count; uint fieldCols; uint fieldRows; uint waterCellCount;
    };

    struct RenderUniforms {
        float worldSize; float streakLenScale; float maxStreakPx; float maxSpeed;
        float lifetime; float dark; float viewportW; float viewportH;
        float lineWidth; float pad0; float pad1; float pad2;
    };

    static inline float hash(uint x) {
        x = (x ^ 61u) ^ (x >> 16);
        x *= 9u; x = x ^ (x >> 4); x *= 0x27d4eb2du; x = x ^ (x >> 15);
        return float(x & 0x00FFFFFFu) / float(0x01000000);
    }

    kernel void advect(device const Particle *inP [[buffer(0)]],
                       device Particle       *outP [[buffer(1)]],
                       constant AdvectUniforms &u   [[buffer(2)]],
                       device const uint *waterCells [[buffer(3)]],
                       texture2d<float> field        [[texture(0)]],
                       sampler s                     [[sampler(0)]],
                       uint id [[thread_position_in_grid]]) {
        if (id >= u.count) return;
        Particle p = inP[id];

        float2 uv = float2((p.pos.x - u.originX) / u.spanX,
                           (p.pos.y - u.originY) / u.spanY);
        bool inField = uv.x >= 0.0 && uv.x < 1.0 && uv.y >= 0.0 && uv.y < 1.0;
        float4 smp = inField ? field.sample(s, uv) : float4(0.0);
        float water = smp.z;
        float cov   = smp.w;
        bool alive = inField && water > 0.5 && cov > 0.1;

        bool reseed = (p.age >= u.lifetime) || !alive;
        if (reseed) {
            if (u.waterCellCount == 0u) {
                p.fade = 0.0; p.vel = float2(0.0);
                outP[id] = p;
                return;
            }
            // Uniform over the *water* cells — density never depends on how
            // much of the viewport is land, and never clusters.
            uint h = id * 747796405u + u.frame * 2891336453u;
            uint cell = waterCells[uint(hash(h) * float(u.waterCellCount)) % u.waterCellCount];
            float cy = float(cell / u.fieldCols);
            float cx = float(cell % u.fieldCols);
            float jx = hash(h ^ 0x9e3779b9u);
            float jy = hash(h ^ 0x68bc21ebu);
            p.pos = float2(u.originX + (cx + jx) / float(u.fieldCols) * u.spanX,
                           u.originY + (cy + jy) / float(u.fieldRows) * u.spanY);
            // Random birth phase so lifetimes never march in lockstep.
            p.age = hash(h ^ 0x1b873593u) * u.lifetime;
            p.vel = float2(0.0); p.fade = 0.0;
        } else {
            float2 vel = smp.xy;
            // Screen-space velocity (zoom-independent). East → +x, north → −y.
            p.pos += float2(vel.x, -vel.y) * (u.speedK / u.worldSize);
            p.age += (1.0 / 30.0);
            p.vel = vel;
            p.fade = smoothstep(0.5, 0.8, water) * smoothstep(0.1, 0.35, cov);
        }
        outP[id] = p;
    }

    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };

    vertex VertexOut streakVertex(uint vid [[vertex_id]],
                                  device const Particle *particles [[buffer(0)]],
                                  constant float4x4 &matrix        [[buffer(1)]],
                                  constant RenderUniforms &u        [[buffer(2)]]) {
        uint pi = vid / 6u;
        uint corner = vid % 6u;
        bool isHead = (corner == 2u || corner == 4u || corner == 5u);
        float side  = (corner == 1u || corner == 2u || corner == 4u) ? 1.0 : -1.0;
        Particle p = particles[pi];

        float2 vel = p.vel;
        float mag = length(vel);

        float2 vp = float2(u.viewportW, u.viewportH);
        float2 dpx = float2(vel.x, -vel.y) * u.streakLenScale;
        float dlen = length(dpx);
        if (dlen > u.maxStreakPx) { dpx *= (u.maxStreakPx / dlen); }
        float2 dWorld = dpx / u.worldSize;

        float4 clipHead = matrix * float4(p.pos * u.worldSize, 1.0, 1.0);
        float4 clipTail = matrix * float4((p.pos - dWorld) * u.worldSize, 1.0, 1.0);
        float4 clip = isHead ? clipHead : clipTail;

        float2 pHead = (clipHead.xy / clipHead.w * 0.5 + 0.5) * vp;
        float2 pTail = (clipTail.xy / clipTail.w * 0.5 + 0.5) * vp;
        float2 dir = pHead - pTail;
        float dirLen = length(dir);
        float2 ndir = dirLen > 1e-4 ? dir / dirLen : float2(1.0, 0.0);
        float2 perp = float2(-ndir.y, ndir.x);
        clip.xy += (perp * side * (u.lineWidth * 0.5) / vp * 2.0) * clip.w;

        VertexOut out;
        out.position = clip;

        float t = clamp(mag / u.maxSpeed, 0.0, 1.0);
        float3 slow, fast;
        if (u.dark > 0.5) { slow = float3(0.30, 0.62, 0.95); fast = float3(0.85, 0.97, 1.00); }
        else              { slow = float3(0.02, 0.20, 0.52); fast = float3(0.00, 0.42, 0.78); }
        float3 c = mix(slow, fast, t);

        float lifeFade = smoothstep(0.0, 0.4, p.age / u.lifetime) *
                         (1.0 - smoothstep(0.7, 1.0, p.age / u.lifetime));
        float endFade  = isHead ? 1.0 : 0.20;
        float a = (u.dark > 0.5 ? 0.85 : 0.95) * lifeFade * endFade * p.fade;

        out.color = float4(c, a);
        return out;
    }

    fragment float4 streakFragment(VertexOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);   // premultiplied
    }
    """
}

// CADisplayLink retains its target; routing through a weak proxy keeps the
// display link from retaining the layer (and thus the map) for its lifetime.
private final class DisplayLinkProxy {
    weak var layer: CurrentParticleLayer?
    init(layer: CurrentParticleLayer) { self.layer = layer }
    @objc func tick() { layer?.step() }
}
