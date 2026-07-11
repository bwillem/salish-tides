import MapLibre
import Metal
import MetalKit
import simd
import QuartzCore
import CoreLocation

// Custom Metal style layer that animates tidal current as flowing particles.
//
// Velocity comes from **inverse-distance weighting of the actual data points**
// (no rasterized grid). Each particle interpolates the current from the nearby
// vectors directly, so the flow is smooth everywhere (no grid blockiness) and
// "coverage" is defined by proximity to real data (smooth falloff, so particles
// stay on the water the data describes instead of bleeding across a coarse cell
// onto land). This is what makes it hold up at extreme zoom — e.g. Active Pass,
// where the ~0.7 km data grid is coarser than the channel and any texture-based
// field fails.
//
// Pipeline (30 fps CADisplayLink → setNeedsDisplay):
//   1. Compute pass: per particle, IDW the data points → velocity + coverage;
//      advect; reseed (uniformly within the data bbox) when aged out or off
//      coverage. The computed velocity + coverage are stored back in the particle.
//   2. Render: each particle drawn as a short streak from its stored velocity,
//      projected with the live map matrix (glued through pan/zoom). Alpha fades
//      with coverage (smooth edge) and the particle's life.
//
// Race-free: particle buffers ping-pong; the render reads last frame's compute
// output; a 2-deep semaphore bounds frames in flight. MLNCustomStyleLayer's
// callbacks are main-thread, so the Metal state is single-threaded; @unchecked
// Sendable holds that under Swift 6.
final class CurrentParticleLayer: MLNCustomStyleLayer, @unchecked Sendable {

    // Matches the Metal `Particle` struct (24 bytes).
    private struct GPUParticle {
        var pos: SIMD2<Float>    // world Mercator [0,1]
        var vel: SIMD2<Float>    // interpolated east/north m/s (for the renderer)
        var age: Float
        var cov: Float           // interpolated coverage weight (for the alpha edge)
    }

    // Matches the Metal `Point` struct (16 bytes) — one per data vector.
    private struct GPUPoint {
        var pos: SIMD2<Float>    // world Mercator [0,1]
        var vel: SIMD2<Float>    // east/north m/s
    }

    private struct AdvectUniforms {
        var speedK: Float        // screen points moved per (m/s) per frame
        var worldSize: Float     // 512·2^zoom
        var vMinX: Float         // current viewport world bounds (reseed domain)
        var vMinY: Float
        var vMaxX: Float
        var vMaxY: Float
        var lifetime: Float
        var radius: Float        // IDW falloff radius (world units)
        var covThreshold: Float  // below this weight a particle is off-coverage
        var frame: UInt32
        var count: UInt32        // particle count
        var pointCount: UInt32
    }

    private struct RenderUniforms {
        var worldSize: Float
        var streakLenScale: Float
        var maxStreakPx: Float
        var maxSpeed: Float
        var covThreshold: Float
        var lifetime: Float
        var dark: Float
        var viewportW: Float
        var viewportH: Float
        var lineWidth: Float
        var pad0: Float = 0
        var pad1: Float = 0
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
    private let radiusFactor: Float = 1.4      // IDW radius as a multiple of point spacing
    private let covThreshold: Float = 0.45     // total IDW weight needed to be "on water"

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var advectPipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

    private var particleBuffers: [MTLBuffer] = []
    private var current = 0
    private var frame: UInt32 = 0
    private let inFlight = DispatchSemaphore(value: 2)

    // Data points (interpolation source) + the IDW radius (≈ point spacing).
    private var pointBuffer: MTLBuffer?
    private var pointCount = 0
    private var idwRadius: Float = 0.001
    private var pendingVectors: [CurrentVector]?

    private var isDark = true
    private var styleActive = true
    private var foreground = true
    private var animating: Bool { styleActive && foreground }
    private var displayLink: CADisplayLink?

    // MARK: - Lifecycle

    override func didMove(to mapView: MLNMapView) {
        MainActor.assumeIsolated {
            let resource = mapView.backendResource()
            guard let device = resource.device else { return }
            self.device = device
            self.queue = device.makeCommandQueue()
            buildPipelines(device: device, colorPixelFormat: resource.mtkView.colorPixelFormat)
            buildParticleBuffers(device: device)
            if let v = pendingVectors { applyVectors(v); pendingVectors = nil }
            syncDisplayLink()
        }
    }

    override func willMove(from mapView: MLNMapView) {
        stopDisplayLink()
        advectPipeline = nil
        renderPipeline = nil
        depthState = nil
        particleBuffers = []
        pointBuffer = nil
        queue = nil
        device = nil
    }

    fileprivate func step() { setNeedsDisplay() }
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

    /// Pushes the data vectors used as the IDW interpolation source. Cheap and
    /// infrequent (hourly / viewport / scrub). A fresh buffer per update avoids a
    /// CPU-write/GPU-read race; the old buffer lives until in-flight frames finish.
    func update(vectors: [CurrentVector]) {
        guard device != nil else { pendingVectors = vectors; return }
        applyVectors(vectors)
    }

    private func applyVectors(_ vectors: [CurrentVector]) {
        guard let device else { return }
        var pts = [GPUPoint]()
        pts.reserveCapacity(vectors.count)
        for v in vectors where v.isSignificant {
            let w = Self.lonLatToWorld(lon: v.lon, lat: v.lat)
            let theta = Float(v.direction_deg) * .pi / 180
            let speed = Float(v.speed_ms)
            pts.append(GPUPoint(pos: SIMD2(Float(w.x), Float(w.y)),
                                vel: SIMD2(speed * sin(theta), speed * cos(theta))))
        }
        pointCount = pts.count
        guard pointCount > 0 else {
            pointBuffer = device.makeBuffer(length: MemoryLayout<GPUPoint>.stride, options: .storageModeShared)
            return
        }
        idwRadius = max(Self.medianNearestNeighbor(pts) * radiusFactor, 1e-6)
        pointBuffer = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<GPUPoint>.stride,
                                        options: .storageModeShared)
    }

    /// Median nearest-neighbour distance (world units) over a sample of the points
    /// — a robust estimate of the data spacing regardless of how the points are
    /// laid out (grid, channel line, sparse), used to size the IDW radius.
    private static func medianNearestNeighbor(_ pts: [GPUPoint]) -> Float {
        let n = pts.count
        guard n > 1 else { return 0.001 }
        let stride = max(1, n / 128)
        var nn = [Float]()
        var i = 0
        while i < n {
            let a = pts[i].pos
            var best = Float.greatestFiniteMagnitude
            for j in 0..<n where j != i {
                let d = pts[j].pos - a
                let dd = d.x * d.x + d.y * d.y
                if dd < best { best = dd }
            }
            if best < .greatestFiniteMagnitude { nn.append(best.squareRoot()) }
            i += stride
        }
        guard !nn.isEmpty else { return 0.001 }
        nn.sort()
        return nn[nn.count / 2]
    }

    // MARK: - Draw

    override func draw(in mapView: MLNMapView, with context: MLNStyleLayerDrawingContext) {
        guard styleActive,
              let renderEncoder,
              let queue,
              let advectPipeline,
              let renderPipeline,
              let depthState,
              let pointBuffer,
              pointCount > 0,
              particleBuffers.count == 2 else { return }

        frame &+= 1
        let next = 1 - current
        let vpW = Float(context.size.width)
        let vpH = Float(context.size.height)
        let worldSize = Float(512.0 * pow(2.0, context.zoomLevel))

        // 1. Advection (own command buffer); non-blocking acquire so we never stall
        //    the main thread inside MapLibre's render callback.
        // Reseed within the current viewport (with a small margin) so all the
        // particles concentrate on the visible water at any zoom — the data set
        // spans the whole atlas region, far larger than the view at high zoom.
        let b = mapView.visibleCoordinateBounds
        let sw = Self.lonLatToWorld(lon: b.sw.longitude, lat: b.sw.latitude)
        let ne = Self.lonLatToWorld(lon: b.ne.longitude, lat: b.ne.latitude)
        let mX = (Float(ne.x) - Float(sw.x)) * 0.08
        let mY = (Float(sw.y) - Float(ne.y)) * 0.08   // note: world Y grows southward
        let vMinX = Float(sw.x) - mX, vMaxX = Float(ne.x) + mX
        let vMinY = Float(ne.y) - mY, vMaxY = Float(sw.y) + mY

        let didAdvect = inFlight.wait(timeout: .now()) == .success
        if didAdvect {
            var advect = AdvectUniforms(
                speedK: speedPx, worldSize: worldSize,
                vMinX: vMinX, vMinY: vMinY, vMaxX: vMaxX, vMaxY: vMaxY,
                lifetime: lifetime, radius: idwRadius, covThreshold: covThreshold,
                frame: frame, count: UInt32(particleCount), pointCount: UInt32(pointCount))
            if let cb = queue.makeCommandBuffer(), let ce = cb.makeComputeCommandEncoder() {
                ce.setComputePipelineState(advectPipeline)
                ce.setBuffer(particleBuffers[current], offset: 0, index: 0)
                ce.setBuffer(particleBuffers[next], offset: 0, index: 1)
                ce.setBytes(&advect, length: MemoryLayout<AdvectUniforms>.stride, index: 2)
                ce.setBuffer(pointBuffer, offset: 0, index: 3)
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

        // 2. Render last frame's particles as streaks with the live matrix.
        var matrix = Self.matrix(from: context.projectionMatrix)
        var render = RenderUniforms(
            worldSize: worldSize, streakLenScale: streakLenScale, maxStreakPx: maxStreakPx,
            maxSpeed: maxSpeed, covThreshold: covThreshold, lifetime: lifetime,
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
                                    age: Float.random(in: 0...lifetime), cov: 0))
        }
        let len = particleCount * MemoryLayout<GPUParticle>.stride
        guard let a = device.makeBuffer(bytes: seed, length: len, options: .storageModeShared),
              let b = device.makeBuffer(length: len, options: .storageModeShared) else { return }
        particleBuffers = [a, b]
        current = 0
    }

    private func buildPipelines(device: MTLDevice, colorPixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else {
            assertionFailure("CurrentParticleLayer: failed to compile shaders")
            return
        }
        if let advect = library.makeFunction(name: "advect") {
            advectPipeline = try? device.makeComputePipelineState(function: advect)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "CurrentParticle.idw"
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
        renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .always
        depthDesc.isDepthWriteEnabled = false
        depthState = device.makeDepthStencilState(descriptor: depthDesc)
    }

    private static func lonLatToWorld(lon: Double, lat: Double) -> (x: Double, y: Double) {
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

    struct Particle { float2 pos; float2 vel; float age; float cov; };
    struct Point    { float2 pos; float2 vel; };

    struct AdvectUniforms {
        float speedK; float worldSize; float vMinX; float vMinY;
        float vMaxX; float vMaxY; float lifetime; float radius;
        float covThreshold; uint frame; uint count; uint pointCount;
    };

    struct RenderUniforms {
        float worldSize; float streakLenScale; float maxStreakPx; float maxSpeed;
        float covThreshold; float lifetime; float dark; float viewportW;
        float viewportH; float lineWidth; float pad0; float pad1;
    };

    static inline float hash(uint x) {
        x = (x ^ 61u) ^ (x >> 16);
        x *= 9u; x = x ^ (x >> 4); x *= 0x27d4eb2du; x = x ^ (x >> 15);
        return float(x & 0x00FFFFFFu) / float(0x01000000);
    }

    // Inverse-distance interpolation of the data points at world position `pos`.
    // Compact-support weight (zero beyond `radius`) → smooth field, and the total
    // weight is the "coverage" (high near data, zero where there's none).
    static inline float3 sampleIDW(float2 pos, device const Point *pts, uint n, float radius) {
        float r2 = radius * radius;
        float2 vsum = float2(0.0);
        float wsum = 0.0;
        for (uint i = 0u; i < n; i++) {
            float2 d = pos - pts[i].pos;
            float t = 1.0 - dot(d, d) / r2;
            if (t > 0.0) { float w = t * t; vsum += pts[i].vel * w; wsum += w; }
        }
        float2 vel = wsum > 1e-6 ? vsum / wsum : float2(0.0);
        return float3(vel, wsum);   // xy = velocity, z = coverage
    }

    kernel void advect(device const Particle *inP [[buffer(0)]],
                       device Particle       *outP [[buffer(1)]],
                       constant AdvectUniforms &u   [[buffer(2)]],
                       device const Point *pts      [[buffer(3)]],
                       uint id [[thread_position_in_grid]]) {
        if (id >= u.count) return;
        Particle p = inP[id];

        float3 s = sampleIDW(p.pos, pts, u.pointCount, u.radius);
        float2 vel = s.xy;
        float cov = s.z;

        bool reseed = (p.age >= u.lifetime) || (cov < u.covThreshold);
        if (reseed) {
            // Uniform within the current viewport → all particles concentrate on
            // the visible water at any zoom. Spawns that miss the data coverage
            // (land / no-data) recycle again next frame, so the steady state is an
            // even fill of exactly the covered water in view.
            uint h = id * 747796405u + u.frame * 2891336453u;
            p.pos = float2(u.vMinX + hash(h) * (u.vMaxX - u.vMinX),
                           u.vMinY + hash(h ^ 0x9e3779b9u) * (u.vMaxY - u.vMinY));
            // Random birth phase so lifetimes never march in lockstep — otherwise
            // a mass reseed (first frame at high zoom, or a big pan/zoom jump) sets
            // every particle to age 0 at once and the whole field pulses together.
            p.age = hash(h ^ 0x68bc21ebu) * u.lifetime;
            p.vel = float2(0.0); p.cov = 0.0;
        } else {
            // Screen-space velocity (zoom-independent). East → +x, north → −y.
            p.pos += float2(vel.x, -vel.y) * (u.speedK / u.worldSize);
            p.age += (1.0 / 30.0);
            p.vel = vel; p.cov = cov;
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

        // Streak: head at the particle, tail trailing along the flow (screen pts).
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
        // Smooth coverage edge (fade out as the particle approaches the data boundary).
        float covFade  = smoothstep(u.covThreshold, u.covThreshold * 2.0, p.cov);
        float a = (u.dark > 0.5 ? 0.85 : 0.95) * lifeFade * endFade * covFade;

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
