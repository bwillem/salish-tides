import MapLibre
import Metal
import MetalKit
import simd
import QuartzCore
import CoreLocation

// Custom Metal style layer that renders tidal current as animated, flowing
// particles (see the particle plan / DESIGN.md).
//
// Pipeline per frame (driven by a 30 fps CADisplayLink → setNeedsDisplay):
//   1. A compute pass advects N particles by sampling the velocity texture,
//      reseeding any that age out, stall (land / slack), or leave the field.
//   2. Each particle is drawn as a short "comet streak" — a line from a tail to a
//      head offset along the local flow, length proportional to speed, fading
//      tail→head — straight into MapLibre's render encoder, projected with the
//      live map matrix so the streaks stay glued to the basemap.
//
// Streaks (rather than an accumulating offscreen trail buffer) keep everything in
// the map's own render pass: no offscreen textures, no cross-queue events, and no
// screen-space "swim" during pan/zoom. Longer comet tails could later be added via
// a ground-locked accumulation texture if desired.
//
// Race-free: particle buffers ping-pong. The compute pass (on our own command
// queue) reads `current` and writes `next`; the render pass reads `current` — the
// buffer produced by *last* frame's compute, long since complete. A 2-deep
// semaphore bounds frames in flight. Positions are thus one frame stale (invisible
// at 30 fps) but drawn with the current camera, so there's no pan/zoom swim.
//
// MLNCustomStyleLayer's callbacks run on the main thread, so the Metal state is
// single-threaded in practice; @unchecked Sendable lets that hold under Swift 6
// strict concurrency. The framework module is built with MLN_RENDER_BACKEND_METAL,
// so backendResource()/device/renderEncoder are visible without a #if guard.
final class CurrentParticleLayer: MLNCustomStyleLayer, @unchecked Sendable {

    // GPU layout mirrors the Metal `Particle` struct (16 bytes).
    private struct GPUParticle {
        var pos: SIMD2<Float>   // normalized field coords: x→lon, y→lat (north=0)
        var age: Float          // seconds lived
        var pad: Float = 0
    }

    private struct AdvectUniforms {
        var speedK: Float        // screen points moved per (m/s) per frame
        var worldSize: Float     // 512·2^zoom (points across the whole world)
        var lonMin: Float
        var latMax: Float
        var lonSpan: Float
        var latSpan: Float
        var lifetime: Float
        var minMag: Float        // reseed cutoff (near-zero = land)
        var frame: UInt32
        var count: UInt32
    }

    // Render uniforms (10 floats; matrix passed separately). Order must match the
    // Metal `RenderUniforms` struct exactly.
    private struct RenderUniforms {
        var lonMin: Float
        var latMax: Float
        var lonSpan: Float
        var latSpan: Float
        var worldSize: Float
        var streakLenScale: Float // streak length: points per (m/s)
        var maxStreakPx: Float    // cap on streak length (points)
        var maxSpeed: Float       // m/s mapped to the top of the colour ramp
        var minMag: Float         // below this sampled speed, the streak isn't drawn
        var lifetime: Float       // seconds, for the birth/death alpha fade
        var dark: Float           // 1 = night palette, 0 = day
        var viewportW: Float      // drawable size in points
        var viewportH: Float
        var lineWidth: Float      // streak thickness in points
        var pad: Float = 0
    }

    // Tunables.
    private let particleCount = 6000
    private let lifetime: Float = 4.0          // seconds before a forced reseed
    // Motion + streaks are sized in SCREEN points (not geographic span) so they're
    // independent of zoom — zooming in no longer speeds particles up.
    private let speedPx: Float = 0.35          // screen points moved per (m/s) per frame
    private let streakLenScale: Float = 13.0   // streak length: points per (m/s)
    private let maxStreakPx: Float = 30.0      // cap on streak length (points)
    // Cutoff (m/s) for both drawing and reseeding: below this a streak isn't drawn
    // AND the particle recycles to a fresh spot. The atlas has no slack vectors
    // (real water is ≥ ~0.59 m/s), so the only sub-threshold values are the linear-
    // filter bleed between water and zero (land) cells — cutting there keeps streaks
    // off the coastline and recycles particles before they creep onto land. Because
    // water is always well above this, a time change never reseeds water particles
    // (they redirect into the new flow), so a scrub commit doesn't repaint.
    private let minMag: Float = 0.30
    // Streak thickness (points). Day is thicker so it reads on the pale basemap.
    private let lineWidthDay: Float = 2.0
    private let lineWidthNight: Float = 1.4
    private let maxSpeed: Float = 2.5          // m/s mapped to the top of the ramp

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

    private var velocityTexture: MTLTexture?
    private var fieldBounds: ChartBounds?
    private var pendingField: VelocityField?

    // Night vs day palette, driven by the map's colour scheme.
    private var isDark = true

    // Animation runs only while the particle style is selected (`styleActive`)
    // and the app is foregrounded (`foreground`). Either being false stops the
    // display link to save power and skips drawing.
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

            if let field = pendingField {
                applyField(field)
                pendingField = nil
            }

            syncDisplayLink()
        }
    }

    override func willMove(from mapView: MLNMapView) {
        stopDisplayLink()
        advectPipeline = nil
        renderPipeline = nil
        depthState = nil
        samplerState = nil
        velocityTexture = nil
        fieldBounds = nil
        particleBuffers = []
        queue = nil
        device = nil
    }

    fileprivate func step() {
        setNeedsDisplay()
    }

    private func syncDisplayLink() {
        animating ? startDisplayLink() : stopDisplayLink()
    }

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

    /// Whether the particle style is the selected current display. When false the
    /// layer stops animating and draws nothing (the arrow layers take over).
    func setActive(_ active: Bool) {
        guard active != styleActive else { return }
        styleActive = active
        syncDisplayLink()
    }

    /// Pauses the animation when the app leaves the foreground.
    func setForeground(_ foreground: Bool) {
        guard foreground != self.foreground else { return }
        self.foreground = foreground
        syncDisplayLink()
    }

    /// Pushes a new velocity field, recreating the texture when the grid size
    /// changes. Stashes the field if the device isn't ready yet.
    func update(field: VelocityField?) {
        guard let field else {
            velocityTexture = nil
            fieldBounds = nil
            return
        }
        guard device != nil else {
            pendingField = field
            return
        }
        applyField(field)
    }

    private func applyField(_ field: VelocityField) {
        guard let device else { return }
        // Always allocate a fresh texture rather than overwriting in place: an
        // in-place CPU write would race the GPU compute pass still reading the
        // texture (a one-frame garbage read = the whole field "repainting" on a
        // scrub commit). The old texture stays retained by any in-flight frame and
        // is released once that frame completes.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: field.cols, height: field.rows, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.replace(
            region: MTLRegionMake2D(0, 0, field.cols, field.rows),
            mipmapLevel: 0,
            withBytes: field.uv,
            bytesPerRow: field.cols * 2 * MemoryLayout<Float>.size)
        velocityTexture = tex
        fieldBounds = field.bounds
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
              let texture = velocityTexture,
              let bounds = fieldBounds,
              particleBuffers.count == 2 else { return }

        frame &+= 1
        let next = 1 - current

        let lonSpan = Float(bounds.lon_max - bounds.lon_min)
        let latSpan = Float(bounds.lat_max - bounds.lat_min)
        let vpW = Float(context.size.width)
        let vpH = Float(context.size.height)
        let worldSize = Float(512.0 * pow(2.0, context.zoomLevel))

        // 1. Advection on our own command buffer: current → next.
        inFlight.wait()
        var advect = AdvectUniforms(
            speedK: speedPx, worldSize: worldSize,
            lonMin: Float(bounds.lon_min), latMax: Float(bounds.lat_max),
            lonSpan: lonSpan, latSpan: latSpan,
            lifetime: lifetime, minMag: minMag,
            frame: frame, count: UInt32(particleCount))
        if let cb = queue.makeCommandBuffer(), let ce = cb.makeComputeCommandEncoder() {
            ce.setComputePipelineState(advectPipeline)
            ce.setBuffer(particleBuffers[current], offset: 0, index: 0)
            ce.setBuffer(particleBuffers[next], offset: 0, index: 1)
            ce.setBytes(&advect, length: MemoryLayout<AdvectUniforms>.stride, index: 2)
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

        // 2. Render last frame's positions (buffer `current`, fully computed) as
        //    comet streaks into the map's pass with the live matrix → glued.
        var matrix = Self.matrix(from: context.projectionMatrix)
        var render = RenderUniforms(
            lonMin: Float(bounds.lon_min), latMax: Float(bounds.lat_max),
            lonSpan: lonSpan, latSpan: latSpan,
            worldSize: worldSize,
            streakLenScale: streakLenScale, maxStreakPx: maxStreakPx,
            maxSpeed: maxSpeed, minMag: minMag, lifetime: lifetime,
            dark: isDark ? 1 : 0,
            viewportW: vpW, viewportH: vpH,
            lineWidth: isDark ? lineWidthNight : lineWidthDay)

        renderEncoder.setRenderPipelineState(renderPipeline)
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setVertexBuffer(particleBuffers[current], offset: 0, index: 0)
        renderEncoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        renderEncoder.setVertexBytes(&render, length: MemoryLayout<RenderUniforms>.stride, index: 2)
        renderEncoder.setVertexTexture(texture, index: 0)
        renderEncoder.setVertexSamplerState(samplerState, index: 0)
        // Six vertices per particle → one screen-space-expanded quad (thick streak).
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: particleCount * 6)

        current = next
    }

    // MARK: - Setup

    private func buildParticleBuffers(device: MTLDevice) {
        // Seed across the Salish Sea in world coords with staggered ages. Anything
        // off the actual field reseeds into it on the first frame; the staggered
        // ages keep births desynchronised so they don't all fade together.
        var seed = [GPUParticle]()
        seed.reserveCapacity(particleCount)
        for _ in 0..<particleCount {
            let lon = Double.random(in: -125.5 ... -122.0)
            let lat = Double.random(in: 47.0 ... 50.0)
            let w = Self.lonLatToWorld(lon: lon, lat: lat)
            seed.append(GPUParticle(
                pos: SIMD2(Float(w.x), Float(w.y)),
                age: Float.random(in: 0...lifetime)))
        }
        let len = particleCount * MemoryLayout<GPUParticle>.stride
        guard let a = device.makeBuffer(bytes: seed, length: len, options: .storageModeShared),
              let b = device.makeBuffer(length: len, options: .storageModeShared) else { return }
        particleBuffers = [a, b]
        current = 0
    }

    private func buildPipelines(device: MTLDevice, colorPixelFormat: MTLPixelFormat) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            print("CurrentParticleLayer shader compile error:\n\(error)")
            assertionFailure("CurrentParticleLayer: failed to compile shaders")
            return
        }

        if let advect = library.makeFunction(name: "advect") {
            advectPipeline = try? device.makeComputePipelineState(function: advect)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "CurrentParticle.streaks"
        desc.vertexFunction = library.makeFunction(name: "streakVertex")
        desc.fragmentFunction = library.makeFunction(name: "streakFragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one              // premultiplied
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

        let samp = MTLSamplerDescriptor()
        samp.minFilter = .linear
        samp.magFilter = .linear
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samp)
    }

    // lon/lat → global Web-Mercator world coords [0,1] (mirrors the shader's
    // lonLatToWorld). Used to seed particle positions in stable world space.
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

    struct Particle { float2 pos; float age; float pad; };

    struct AdvectUniforms {
        float speedK; float worldSize; float lonMin; float latMax;
        float lonSpan; float latSpan; float lifetime; float minMag;
        uint frame; uint count;
    };

    struct RenderUniforms {
        float lonMin; float latMax; float lonSpan; float latSpan;
        float worldSize; float streakLenScale; float maxStreakPx; float maxSpeed;
        float minMag; float lifetime; float dark; float viewportW;
        float viewportH; float lineWidth; float pad;
    };

    static inline float hash(uint x) {
        x = (x ^ 61u) ^ (x >> 16);
        x *= 9u; x = x ^ (x >> 4); x *= 0x27d4eb2du; x = x ^ (x >> 15);
        return float(x & 0x00FFFFFFu) / float(0x01000000);
    }

    // lon/lat → global Web-Mercator world coords in [0,1] (stable, viewport-
    // independent — this is what particle positions are stored in, so they stay
    // glued to the ground through pan/zoom).
    static inline float2 lonLatToWorld(float lon, float lat) {
        float mx = (lon + 180.0) / 360.0;
        float yi = log(tan((45.0 + lat / 2.0) * M_PI_F / 180.0));
        float my = (180.0 - yi * (180.0 / M_PI_F)) / 360.0;
        return float2(mx, my);
    }

    // World coords → field-normalized [0,1] for the current field bbox, so the
    // velocity texture can be sampled at a particle's world position.
    static inline float2 worldToField(float2 w, float lonMin, float latMax,
                                      float lonSpan, float latSpan) {
        float lon = w.x * 360.0 - 180.0;
        float yi = M_PI_F * (1.0 - 2.0 * w.y);
        float lat = atan(exp(yi)) * (360.0 / M_PI_F) - 90.0;
        return float2((lon - lonMin) / lonSpan, (latMax - lat) / latSpan);
    }

    kernel void advect(device const Particle *inP   [[buffer(0)]],
                       device Particle       *outP  [[buffer(1)]],
                       constant AdvectUniforms &u    [[buffer(2)]],
                       texture2d<float> field        [[texture(0)]],
                       sampler s                     [[sampler(0)]],
                       uint id [[thread_position_in_grid]]) {
        if (id >= u.count) return;
        Particle p = inP[id];

        float2 f = worldToField(p.pos, u.lonMin, u.latMax, u.lonSpan, u.latSpan);
        bool inField = f.x >= 0.0 && f.x < 1.0 && f.y >= 0.0 && f.y < 1.0;
        float2 vel = inField ? field.sample(s, f).xy : float2(0.0);
        float mag = length(vel);

        // Reseed on age-out, leaving the field area, or landing on true zero
        // (land / no-coverage — u.minMag is the low reseed cutoff, ~0.05). Real
        // water is always ≥0.59 m/s, so a time change never drops a water particle
        // below this; they redirect into the new flow instead of teleporting.
        bool reseed = (p.age >= u.lifetime) || (mag < u.minMag) || !inField;

        if (reseed) {
            // Random point within the current field bbox → world coords.
            uint h = id * 747796405u + u.frame * 2891336453u;
            float lon = u.lonMin + hash(h) * u.lonSpan;
            float lat = u.latMax - hash(h ^ 0x9e3779b9u) * u.latSpan;
            p.pos = lonLatToWorld(lon, lat);
            // Reborn at age 0 so it fades in from zero opacity — no pop, no jump.
            p.age = 0.0;
        } else {
            // Screen-space velocity (zoom-independent): worldSize cancels the zoom
            // because 1 world unit ≈ worldSize screen points. East → +x, north → −y.
            p.pos += float2(vel.x, -vel.y) * (u.speedK / u.worldSize);
            p.age += (1.0 / 30.0);
        }
        outP[id] = p;
    }

    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };

    // Projects a world-Mercator position [0,1] to clip space via tile coords.
    static inline float4 projectWorld(float2 w, float worldSize,
                                      constant float4x4 &matrix) {
        return matrix * float4(w * worldSize, 1.0, 1.0);
    }

    vertex VertexOut streakVertex(uint vid [[vertex_id]],
                                  device const Particle *particles [[buffer(0)]],
                                  constant float4x4 &matrix        [[buffer(1)]],
                                  constant RenderUniforms &u        [[buffer(2)]],
                                  texture2d<float> field            [[texture(0)]],
                                  sampler s                         [[sampler(0)]]) {
        // Six vertices per particle form a quad (two triangles): tail/head ends,
        // each offset ± a perpendicular in screen space to give the streak width.
        uint pi = vid / 6u;
        uint corner = vid % 6u;
        bool isHead = (corner == 2u || corner == 4u || corner == 5u);
        float side  = (corner == 1u || corner == 2u || corner == 4u) ? 1.0 : -1.0;
        Particle p = particles[pi];

        float2 f = worldToField(p.pos, u.lonMin, u.latMax, u.lonSpan, u.latSpan);
        bool inField = f.x >= 0.0 && f.x < 1.0 && f.y >= 0.0 && f.y < 1.0;
        float2 vel = inField ? field.sample(s, f).xy : float2(0.0);
        float mag = length(vel);

        // Tail trails behind the head along the flow. Length is in screen points
        // (zoom-independent) and capped so strong currents don't draw long beams.
        float2 vp = float2(u.viewportW, u.viewportH);
        float2 dpx = float2(vel.x, -vel.y) * u.streakLenScale;   // points
        float dlen = length(dpx);
        if (dlen > u.maxStreakPx) { dpx *= (u.maxStreakPx / dlen); }
        float2 dWorld = dpx / u.worldSize;                       // points → world

        float4 clipHead = projectWorld(p.pos, u.worldSize, matrix);
        float4 clipTail = projectWorld(p.pos - dWorld, u.worldSize, matrix);
        float4 clip = isHead ? clipHead : clipTail;

        // Perpendicular to the streak in screen (point) space, expanded by half
        // the line width. Uniform scale cancels, so points are fine here.
        float2 pHead = (clipHead.xy / clipHead.w * 0.5 + 0.5) * vp;
        float2 pTail = (clipTail.xy / clipTail.w * 0.5 + 0.5) * vp;
        float2 dir = pHead - pTail;
        float dirLen = length(dir);
        float2 ndir = dirLen > 1e-4 ? dir / dirLen : float2(1.0, 0.0);
        float2 perp = float2(-ndir.y, ndir.x);
        float2 offPts = perp * side * (u.lineWidth * 0.5);
        clip.xy += (offPts / vp * 2.0) * clip.w;

        VertexOut out;
        out.position = clip;

        // Colour by speed; night = cool white-blue, day = deep saturated blue so
        // it reads on the light basemap. Fade tail→head and in/out over life.
        float t = clamp(mag / u.maxSpeed, 0.0, 1.0);
        float3 slow, fast;
        if (u.dark > 0.5) { slow = float3(0.30, 0.62, 0.95); fast = float3(0.85, 0.97, 1.00); }
        else              { slow = float3(0.02, 0.20, 0.52); fast = float3(0.00, 0.42, 0.78); }
        float3 c = mix(slow, fast, t);

        float lifeFade = smoothstep(0.0, 0.4, p.age / u.lifetime) *
                         (1.0 - smoothstep(0.7, 1.0, p.age / u.lifetime));
        float endFade = isHead ? 1.0 : 0.20;     // comet: bright head, faint tail
        float a = (u.dark > 0.5 ? 0.85 : 0.95) * lifeFade * endFade;
        // Don't draw where the sampled speed is below the water threshold (coastal
        // linear-filter bleed / land) or the particle is outside the field area.
        if (mag < u.minMag || !inField) { a = 0.0; }
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
