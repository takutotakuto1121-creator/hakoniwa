import HakoniwaCore
import Metal
import QuartzCore
import simd

/// Layout must match `GodUniforms` in `godShaderSource` (64 bytes).
struct GodUniforms {
    var viewSize = SIMD2<Float>(1, 1)
    var camCenter = SIMD2<Float>(0, 0)
    var worldSize = SIMD2<Float>(1, 1)
    var offset = SIMD2<Float>(0, 0)
    var zoom: Float = 1
    var time: Float = 0
    var pixelRatio: Float = 2
    var extrap: Float = 0
    var ice: Float = 0
    var warm: Float = 0
    var wallRes = Float(WallMask.resolution)
    var fieldRange = Float(GodBridge.fieldRange)
}

/// Draws the god-hand layers inside the renderer's scene pass:
/// reef walls (after the background), miasma around sick creatures (before creatures)
/// and the climate colour grade (last, using programmable blending).
final class GodLayer {
    private let reefPipeline: MTLRenderPipelineState
    private let miasmaPipeline: MTLRenderPipelineState
    /// nil on GPUs without framebuffer fetch (the grade is then skipped).
    private let gradePipeline: MTLRenderPipelineState?
    private let wallTexture: MTLTexture
    private var wallSerial = 0
    private var wallCount = 0
    private var sickCount = 0
    private var ice: Float = 0
    private var warm: Float = 0
    private var u = GodUniforms()

    init?(device: MTLDevice) {
        do {
            let lib = try device.makeLibrary(source: godShaderSource, options: nil)
            func make(_ v: String, _ f: String, blend: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: v)
                d.fragmentFunction = lib.makeFunction(name: f)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = .rgba16Float
                if blend {  // premultiplied alpha
                    ca.isBlendingEnabled = true
                    ca.sourceRGBBlendFactor = .one
                    ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    ca.sourceAlphaBlendFactor = .one
                    ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            reefPipeline = try make("godFullscreenVertex", "reefFragment", blend: true)
            miasmaPipeline = try make("miasmaVertex", "miasmaFragment", blend: true)
            gradePipeline = device.supportsFamily(.apple4) ? try make("godFullscreenVertex", "gradeFragment", blend: false) : nil
        } catch {
            NSLog("God layer shaders failed to compile: \(error)")
            return nil
        }
        let n = WallMask.resolution
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        wallTexture = tex
        assert(MemoryLayout<GodUniforms>.stride == 64)
    }

    /// Pulls the latest wall field and climate, and eases the climate grade in and out.
    func update(camera: Camera, bridge: GodBridge, dt: Float, time: Float, extrap: Float) {
        if let w = bridge.wallField(newerThan: wallSerial) {
            wallSerial = w.serial
            wallCount = w.count
            let n = WallMask.resolution
            if w.field.count == n * n {
                w.field.withUnsafeBytes { src in
                    wallTexture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                                        withBytes: src.baseAddress!, bytesPerRow: n * 4)
                }
            }
        }
        let climate = bridge.climate
        sickCount = bridge.sickCount
        let k = 1 - exp(-dt * 1.6)
        ice += ((climate == .iceAge ? 1 : 0) - ice) * k
        warm += ((climate == .bloom ? 1 : 0) - warm) * k
        if ice < 0.002 { ice = 0 }
        if warm < 0.002 { warm = 0 }
        u.viewSize = camera.viewSize
        u.camCenter = camera.center
        u.worldSize = camera.worldSize
        u.zoom = camera.zoom
        u.time = time
        u.pixelRatio = camera.pixelRatio
        u.extrap = extrap
        u.ice = ice
        u.warm = warm
    }

    func drawWalls(_ enc: MTLRenderCommandEncoder) {
        guard wallCount > 0 else { return }
        enc.setRenderPipelineState(reefPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<GodUniforms>.stride, index: 0)
        enc.setFragmentTexture(wallTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func drawMiasma(_ enc: MTLRenderCommandEncoder, creatures: MTLBuffer, count: Int, offset: V2) {
        guard sickCount > 0, count > 0 else { return }
        u.offset = offset
        enc.setRenderPipelineState(miasmaPipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<GodUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<GodUniforms>.stride, index: 0)
        enc.setVertexBuffer(creatures, offset: 0, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    func drawGrade(_ enc: MTLRenderCommandEncoder) {
        guard let p = gradePipeline, ice > 0 || warm > 0 else { return }
        enc.setRenderPipelineState(p)
        enc.setFragmentBytes(&u, length: MemoryLayout<GodUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
