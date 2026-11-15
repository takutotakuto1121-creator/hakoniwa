import AppKit
import CoreGraphics
import HakoniwaCore
import Metal
import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var viewSize = SIMD2<Float>(1, 1)
    var camCenter = SIMD2<Float>(0, 0)
    var worldSize = SIMD2<Float>(1, 1)
    var hoverPos = SIMD2<Float>(0, 0)
    var offset = SIMD2<Float>(0, 0)
    var zoom: Float = 1
    var time: Float = 0
    var extrap: Float = 0
    var pixelRatio: Float = 2
    var season: Float = 1
    var selected: Float = -1
    var hoverRadius: Float = 0
    var toolKind: Float = 0
    var bloomStrength: Float = 0.9
    var exposure: Float = 1.15
}

struct GPUParticle {
    var position: SIMD2<Float>
    var size: Float
    var life: Float
    var color: SIMD4<Float>
}

struct GPURing {
    var position: SIMD2<Float>
    var radius: Float
    var thickness: Float
    var color: SIMD4<Float>
    var dash: Float
    var spin: Float
    var pad = SIMD2<Float>(0, 0)
}

/// CPU-side particle state.
private struct ParticleState {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var size: Float
    var growth: Float
    var life: Float
    var duration: Float
    var color: SIMD4<Float>
    var damping: Float
}

/// Growable shared-memory buffer.
private final class DynamicBuffer {
    let device: MTLDevice
    var buffer: MTLBuffer
    init(device: MTLDevice, bytes: Int) {
        self.device = device
        buffer = device.makeBuffer(length: max(bytes, 256), options: .storageModeShared)!
    }
    func ensure(_ bytes: Int) {
        if buffer.length < bytes {
            buffer = device.makeBuffer(length: bytes * 3 / 2, options: .storageModeShared)!
        }
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    static let logFPS = ProcessInfo.processInfo.environment["HAKONIWA_FPS"] != nil
    let device: MTLDevice
    let queue: MTLCommandQueue
    let camera = Camera()
    let controller: SimulationController
    weak var model: AppModel?
    weak var view: MTKView?

    private var backgroundPipeline: MTLRenderPipelineState!
    private var foodPipeline: MTLRenderPipelineState!
    private var creaturePipeline: MTLRenderPipelineState!
    private var particlePipeline: MTLRenderPipelineState!
    private var ringPipeline: MTLRenderPipelineState!
    private var downPipeline: MTLRenderPipelineState!
    private var upPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!

    private var hdrTexture: MTLTexture?
    private var bloomMips: [MTLTexture] = []
    private var fertilityTexture: MTLTexture
    private var fertilityTick: Int64 = -2

    private let inflight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private var creatureBuffers: [DynamicBuffer] = []
    private var foodBuffers: [DynamicBuffer] = []
    private var particleBuffers: [DynamicBuffer] = []
    private var ringBuffers: [DynamicBuffer] = []

    private var particles: [ParticleState] = []
    private var lastFrameTime = CACurrentMediaTime()
    private let startTime = CACurrentMediaTime()
    private var rng = SystemRandomNumberGenerator()

    // Latest frame data on the CPU (for picking, following and the overlay).
    private(set) var creatureCount = 0
    private(set) var foodCount = 0
    private(set) var selectedIndex: Int = -1
    private(set) var selectedPosition: V2?
    private(set) var selectedRadius: Float = 0
    private(set) var frameCount = 0
    private(set) var fps: Double = 60
    private var fpsAccum: Double = 0
    private var fpsFrames = 0

    /// Pending capture requests, fulfilled after the next frame.
    private var captureRequests: [(CGImage?) -> Void] = []
    var recorder: VideoRecorder?

    /// Tool cursor (world position + radius) drawn as a dashed ring.
    var hover: (position: V2, radius: Float, color: SIMD4<Float>)?

    init?(view: MTKView, controller: SimulationController) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        self.controller = controller
        let fd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: FertilityField.resolution,
                                                          height: FertilityField.resolution, mipmapped: false)
        fd.usage = .shaderRead
        fertilityTexture = device.makeTexture(descriptor: fd)!
        super.init()
        self.view = view
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        for _ in 0..<3 {
            creatureBuffers.append(DynamicBuffer(device: device, bytes: 4096 * MemoryLayout<CreatureInstance>.stride))
            foodBuffers.append(DynamicBuffer(device: device, bytes: 30000 * MemoryLayout<FoodInstance>.stride))
            particleBuffers.append(DynamicBuffer(device: device, bytes: 4096 * MemoryLayout<GPUParticle>.stride))
            ringBuffers.append(DynamicBuffer(device: device, bytes: 16 * MemoryLayout<GPURing>.stride))
        }
        do {
            try buildPipelines(drawableFormat: view.colorPixelFormat)
        } catch {
            NSLog("Shader compilation failed: \(error)")
            return nil
        }
        let ws = controller.withFront { $0.worldSize }
        camera.worldSize = ws
        camera.center = ws * 0.5
        camera.targetCenter = ws * 0.5
        assert(MemoryLayout<CreatureInstance>.stride == 80, "CreatureInstance must be 80 bytes")
        assert(MemoryLayout<Uniforms>.stride == 80)
        assert(MemoryLayout<GPUParticle>.stride == 32)
        assert(MemoryLayout<GPURing>.stride == 48)
    }

    private func buildPipelines(drawableFormat: MTLPixelFormat) throws {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func make(_ v: String, _ f: String, _ format: MTLPixelFormat, blend: Int) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            switch blend {
            case 1:  // premultiplied alpha (alpha 0 => additive)
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case 2:  // pure additive
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .one
            default:
                ca.isBlendingEnabled = false
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let hdr = MTLPixelFormat.rgba16Float
        backgroundPipeline = try make("fullscreenVertex", "backgroundFragment", hdr, blend: 0)
        foodPipeline = try make("foodVertex", "foodFragment", hdr, blend: 1)
        creaturePipeline = try make("creatureVertex", "creatureFragment", hdr, blend: 1)
        particlePipeline = try make("particleVertex", "particleFragment", hdr, blend: 1)
        ringPipeline = try make("ringVertex", "ringFragment", hdr, blend: 1)
        downPipeline = try make("fullscreenVertex", "bloomDownsample", hdr, blend: 0)
        upPipeline = try make("fullscreenVertex", "bloomUpsample", hdr, blend: 2)
        compositePipeline = try make("fullscreenVertex", "compositeFragment", drawableFormat, blend: 0)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.viewSize = V2(Float(size.width), Float(size.height))
        camera.pixelRatio = Float(view.window?.backingScaleFactor ?? 2)
        makeTargets(width: Int(size.width), height: Int(size.height))
    }

    private func makeTargets(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: d)
        bloomMips = []
        var w = max(width / 2, 1), h = max(height / 2, 1)
        for _ in 0..<6 {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            md.usage = [.renderTarget, .shaderRead]
            md.storageMode = .private
            bloomMips.append(device.makeTexture(descriptor: md)!)
            w = max(w / 2, 1); h = max(h / 2, 1)
        }
    }

    /// Captures the next rendered frame (world only, no SwiftUI overlay).
    func captureNextFrame(_ completion: @escaping (CGImage?) -> Void) {
        captureRequests.append(completion)
    }

    // MARK: - Frame

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrameTime, 0.1))
        lastFrameTime = now
        fpsAccum += Double(dt); fpsFrames += 1
        if fpsAccum > 0.5 {
            fps = Double(fpsFrames) / fpsAccum; fpsAccum = 0; fpsFrames = 0
            if Renderer.logFPS {
                print(String(format: "fps %.1f creatures %d food %d particles %d zoom %.2f", fps, creatureCount, foodCount, particles.count, camera.zoom / camera.pixelRatio))
                fflush(stdout)
            }
        }
        let size = view.drawableSize
        if hdrTexture == nil || hdrTexture!.width != Int(size.width) || hdrTexture!.height != Int(size.height) {
            camera.viewSize = V2(Float(size.width), Float(size.height))
            camera.pixelRatio = Float(view.window?.backingScaleFactor ?? 2)
            makeTargets(width: Int(size.width), height: Int(size.height))
        }
        guard let hdr = hdrTexture else { return }

        inflight.wait()
        frameIndex = (frameIndex + 1) % 3
        let cbuf = creatureBuffers[frameIndex], fbuf = foodBuffers[frameIndex]
        let pbuf = particleBuffers[frameIndex], rbuf = ringBuffers[frameIndex]

        // Pull the latest snapshot.
        let selectedUid = model?.selectedUid ?? 0
        let follow = model?.following ?? false
        let speed = controller.speed
        let paused = controller.paused
        var newFX: [FXEvent] = []
        var tps: Float = 20
        var season: Float = 1
        var extrap: Float = 0
        var selIdx = -1
        var selPos: V2?
        var selRad: Float = 0
        controller.withFront { snap in
            camera.worldSize = snap.worldSize
            tps = snap.ticksPerSecond
            season = snap.season
            let nc = snap.creatures.count
            cbuf.ensure(nc * MemoryLayout<CreatureInstance>.stride)
            snap.creatures.withUnsafeBytes { src in
                if let b = src.baseAddress { cbuf.buffer.contents().copyMemory(from: b, byteCount: src.count) }
            }
            creatureCount = nc
            let nf = snap.food.count
            fbuf.ensure(nf * MemoryLayout<FoodInstance>.stride)
            snap.food.withUnsafeBytes { src in
                if let b = src.baseAddress { fbuf.buffer.contents().copyMemory(from: b, byteCount: src.count) }
            }
            foodCount = nf
            if snap.fertilityTick != fertilityTick && snap.fertility.count == FertilityField.resolution * FertilityField.resolution {
                fertilityTick = snap.fertilityTick
                let n = FertilityField.resolution
                snap.fertility.withUnsafeBytes { src in
                    fertilityTexture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                                             withBytes: src.baseAddress!, bytesPerRow: n * 4)
                }
            }
            if !snap.fx.isEmpty {
                newFX = snap.fx
                snap.fx.removeAll(keepingCapacity: true)
            }
            if selectedUid != 0, let k = snap.uids.firstIndex(of: selectedUid) {
                selIdx = k
                selPos = snap.creatures[k].position
                selRad = snap.creatures[k].radius
            }
            if !paused && (speed == .x1 || speed == .x4) {
                extrap = Float(min((now - controller.publishTime) * speed.multiplier, 1.2 / Double(snap.ticksPerSecond)))
            }
        }
        if let p = selPos, selIdx >= 0 {
            let c = cbuf.buffer.contents().bindMemory(to: CreatureInstance.self, capacity: creatureCount)[selIdx]
            selPos = p + c.velocity * extrap
        }
        selectedIndex = selIdx
        selectedPosition = selPos.map { camera.wrap($0) }
        selectedRadius = selRad
        if follow, let p = selectedPosition { camera.targetCenter = p }
        camera.update(dt: dt)

        // Effects.
        let fxBudget = speed == .max ? 4 : (speed.multiplier > 16 ? 8 : (speed.multiplier > 4 ? 40 : 400))
        for e in newFX.prefix(fxBudget) { spawnFX(e) }
        for e in newFX where e.kind == .meteor { spawnFX(e) }
        updateParticles(dt: dt)
        let np = min(particles.count, 20000)
        pbuf.ensure(np * MemoryLayout<GPUParticle>.stride)
        let pp = pbuf.buffer.contents().bindMemory(to: GPUParticle.self, capacity: max(np, 1))
        for k in 0..<np {
            let s = particles[k]
            pp[k] = GPUParticle(position: s.position, size: s.size, life: max(s.life, 0), color: s.color)
        }

        // Rings: selection + tool cursor.
        var rings: [GPURing] = []
        let t = Float(now - startTime)
        if let p = selectedPosition {
            let r = selRad * 2.6 + 10 * camera.pixelRatio / camera.zoom
            rings.append(GPURing(position: p, radius: r, thickness: 1.2 * camera.pixelRatio,
                                 color: SIMD4(0.55, 0.85, 1.0, 0.9) * 0.9, dash: 14, spin: 0.5))
        }
        if let h = hover {
            rings.append(GPURing(position: h.position, radius: h.radius, thickness: 1.5 * camera.pixelRatio,
                                 color: h.color, dash: 24, spin: 0.4))
        }
        rbuf.ensure(max(rings.count, 1) * MemoryLayout<GPURing>.stride)
        rings.withUnsafeBytes { src in
            if let b = src.baseAddress { rbuf.buffer.contents().copyMemory(from: b, byteCount: src.count) }
        }

        var u = Uniforms()
        u.viewSize = camera.viewSize
        u.camCenter = camera.center
        u.worldSize = camera.worldSize
        u.zoom = camera.zoom
        u.time = t
        u.extrap = extrap
        u.pixelRatio = camera.pixelRatio
        u.season = season
        u.selected = Float(selIdx)
        _ = tps

        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        cmd.addCompletedHandler { [weak self] _ in self?.inflight.signal() }

        // Scene pass.
        let scene = MTLRenderPassDescriptor()
        scene.colorAttachments[0].texture = hdr
        scene.colorAttachments[0].loadAction = .dontCare
        scene.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: scene) {
            enc.label = "scene"
            enc.setRenderPipelineState(backgroundPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(fertilityTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            for off in camera.visibleOffsets() {
                u.offset = off
                if foodCount > 0 {
                    enc.setRenderPipelineState(foodPipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setVertexBuffer(fbuf.buffer, offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: foodCount)
                }
                if np > 0 {
                    enc.setRenderPipelineState(particlePipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setVertexBuffer(pbuf.buffer, offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: np)
                }
                if creatureCount > 0 {
                    enc.setRenderPipelineState(creaturePipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setVertexBuffer(cbuf.buffer, offset: 0, index: 1)
                    enc.setFragmentBuffer(cbuf.buffer, offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: creatureCount)
                }
                if !rings.isEmpty {
                    enc.setRenderPipelineState(ringPipeline)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setVertexBuffer(rbuf.buffer, offset: 0, index: 1)
                    enc.setFragmentBuffer(rbuf.buffer, offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rings.count)
                }
            }
            enc.endEncoding()
        }

        // Bloom: downsample chain, then additive upsample.
        for (i, dst) in bloomMips.enumerated() {
            let src = i == 0 ? hdr : bloomMips[i - 1]
            var params = SIMD4<Float>(1 / Float(src.width), 1 / Float(src.height), i == 0 ? 1 : 0, 1.0)
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = dst
            pd.colorAttachments[0].loadAction = .dontCare
            pd.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pd) {
                enc.setRenderPipelineState(downPipeline)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentBytes(&params, length: 16, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        if bloomMips.count > 1 {
            for i in stride(from: bloomMips.count - 1, through: 1, by: -1) {
                let src = bloomMips[i], dst = bloomMips[i - 1]
                var params = SIMD4<Float>(1 / Float(src.width), 1 / Float(src.height), 0.85, 0)
                let pd = MTLRenderPassDescriptor()
                pd.colorAttachments[0].texture = dst
                pd.colorAttachments[0].loadAction = .load
                pd.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: pd) {
                    enc.setRenderPipelineState(upPipeline)
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentBytes(&params, length: 16, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }

        // Composite to the drawable.
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else {
            cmd.commit()
            return
        }
        pass.colorAttachments[0].loadAction = .dontCare
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(hdr, index: 0)
            enc.setFragmentTexture(bloomMips.first ?? hdr, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Readback for screenshots and recording.
        let wantsCapture = !captureRequests.isEmpty
        let rec = recorder
        if wantsCapture || rec != nil {
            let tex = drawable.texture
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: tex.width,
                                                             height: tex.height, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead]
            if let staging = device.makeTexture(descriptor: d), let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: tex, to: staging)
                blit.endEncoding()
                let requests = captureRequests
                captureRequests.removeAll()
                let frameTime = now
                cmd.addCompletedHandler { _ in
                    if let rec { rec.append(texture: staging, time: frameTime) }
                    if !requests.isEmpty {
                        let img = Renderer.makeImage(staging)
                        DispatchQueue.main.async { for r in requests { r(img) } }
                    }
                }
            }
        }
        cmd.present(drawable)
        cmd.commit()
        frameCount += 1
    }

    static func makeImage(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        tex.getBytes(&data, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: cs,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Particles

    private func rand(_ lo: Float, _ hi: Float) -> Float { Float.random(in: lo...hi, using: &rng) }

    private func hueColor(_ h: Float, sat: Float = 0.8, intensity: Float) -> SIMD3<Float> {
        let c = NSColor(hue: CGFloat(h), saturation: CGFloat(sat), brightness: 1, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(pow(r, 2.2)), Float(pow(g, 2.2)), Float(pow(b, 2.2))) * intensity
    }

    private func emit(_ p: V2, vel: V2, size: Float, growth: Float = 0, duration: Float, color: SIMD3<Float>, shape: Float, damping: Float = 2) {
        if particles.count > 20000 { return }
        particles.append(ParticleState(position: p, velocity: vel, size: size, growth: growth, life: 1, duration: duration,
                                       color: SIMD4(color.x, color.y, color.z, shape), damping: damping))
    }

    private func spawnFX(_ e: FXEvent) {
        let p = e.position
        switch e.kind {
        case .birth, .hatch:
            let c = hueColor(e.hue, intensity: 2.2)
            emit(p, vel: .zero, size: e.size * 1.5, growth: e.size * 5, duration: 0.8, color: c, shape: 1)
            for _ in 0..<(e.kind == .birth ? 10 : 6) {
                let a = rand(0, 2 * .pi), s = rand(10, 40)
                emit(p, vel: V2(cos(a), sin(a)) * s, size: rand(0.6, 1.4), duration: rand(0.5, 1.0),
                     color: e.kind == .hatch ? SIMD3(1.2, 1.3, 1.4) : c, shape: 2, damping: 3)
            }
        case .death:
            for _ in 0..<9 {
                let a = rand(0, 2 * .pi), s = rand(2, 10)
                emit(p + V2(cos(a), sin(a)) * rand(0, e.size), vel: V2(cos(a), sin(a)) * s + V2(0, -6),
                     size: rand(0.8, 2.0), duration: rand(1.5, 3.0), color: SIMD3(0.25, 0.35, 0.5), shape: 0, damping: 0.6)
            }
        case .kill:
            emit(p, vel: .zero, size: e.size * 1.2, growth: e.size * 7, duration: 0.6, color: SIMD3(2.5, 0.25, 0.1), shape: 1)
            for _ in 0..<16 {
                let a = rand(0, 2 * .pi), s = rand(20, 80)
                emit(p, vel: V2(cos(a), sin(a)) * s, size: rand(0.8, 1.8), duration: rand(0.4, 0.9),
                     color: SIMD3(2.4, 0.35, 0.12), shape: 2, damping: 4)
            }
        case .meteor:
            emit(p, vel: .zero, size: e.size * 0.6, growth: e.size * 1.2, duration: 1.2, color: SIMD3(6, 3.2, 1.2), shape: 0, damping: 0)
            emit(p, vel: .zero, size: e.size * 0.1, growth: e.size * 2.2, duration: 1.4, color: SIMD3(4, 2, 0.8), shape: 1, damping: 0)
            emit(p, vel: .zero, size: e.size * 0.1, growth: e.size * 1.4, duration: 1.8, color: SIMD3(1.5, 0.7, 0.3), shape: 1, damping: 0)
            for _ in 0..<260 {
                let a = rand(0, 2 * .pi), s = rand(30, e.size * 1.8)
                let hot = rand(0, 1)
                emit(p + V2(cos(a), sin(a)) * rand(0, e.size * 0.2), vel: V2(cos(a), sin(a)) * s,
                     size: rand(1.5, 5), duration: rand(0.8, 2.6),
                     color: SIMD3(3 + hot * 3, 1.0 + hot * 1.6, 0.25 + hot * 0.4), shape: hot > 0.6 ? 2 : 0, damping: 1.6)
            }
        case .feed:
            break
        }
    }

    private func updateParticles(dt: Float) {
        guard !particles.isEmpty else { return }
        var w = 0
        for k in 0..<particles.count {
            var s = particles[k]
            s.life -= dt / s.duration
            if s.life <= 0 { continue }
            s.position += s.velocity * dt
            s.velocity *= exp(-s.damping * dt)
            s.size += s.growth * dt
            s.growth *= exp(-2.5 * dt)
            particles[w] = s
            w += 1
        }
        particles.removeLast(particles.count - w)
    }
}
