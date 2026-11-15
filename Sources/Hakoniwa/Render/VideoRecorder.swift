import AVFoundation
import CoreVideo
import Metal
import QuartzCore

/// Records rendered frames to an H.264 .mp4 file.
///
/// Each frame is drawn by a small full-screen pass straight into a Metal-compatible pixel buffer from the
/// adaptor's pool (no CPU copy). The pass scales the drawable down to the movie size, keeps its aspect ratio
/// (centre crop if the window was resized while recording) and converts the linear colour read from the
/// sRGB drawable back to sRGB bytes, since the movie buffer is plain `bgra8Unorm`.
///
/// Threading: `encodeFrame` is called on the render (main) thread; appends and `finish` run on a private
/// serial queue, fed from Metal completion handlers in submission order.
final class VideoRecorder: @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    /// Called on the main thread if the writer fails mid-recording.
    var onFailure: ((String) -> Void)?

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "hakoniwa.recorder")
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// Movie time base: 1/60000 s, fine enough for any display rate.
    private static let timescale: CMTimeScale = 60000
    private static let frameDuration = CMTime(value: 1000, timescale: timescale)  // 1/60 s
    // Render-thread state.
    private var startTime: CFTimeInterval?
    private var lastScheduled: Int64 = -1
    private var stopped = false
    private var framesSinceFlush = 0
    // Queue state.
    private var lastAppended = CMTime.invalid
    private(set) var frames = 0
    private(set) var dropped = 0
    /// Frames skipped on the render thread because the encoder was busy (render thread only).
    private(set) var skipped = 0
    private var finished = false
    private var failed = false

    /// Largest movie size for a view of `size` pixels: even dimensions, at most 1920 wide and 1200 tall.
    static func movieSize(for size: SIMD2<Float>) -> (width: Int, height: Int) {
        let w = Double(max(size.x, 2)), h = Double(max(size.y, 2))
        let scale = min(1, 1920 / w, 1200 / h)
        func even(_ v: Double) -> Int { max(2, Int(v.rounded()) & ~1) }
        return (even(w * scale), even(h * scale))
    }

    init(url: URL, width: Int, height: Int, device: MTLDevice) throws {
        self.url = url
        self.width = max(2, width & ~1)
        self.height = max(2, height & ~1)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(max(self.width * self.height * 7, 6_000_000), 20_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw Self.error("動画の出力を設定できません") }
        writer.add(input)

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.label = "recording scale"
        d.vertexFunction = library.makeFunction(name: "recordVertex")
        d.fragmentFunction = library.makeFunction(name: "recordFragment")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            throw Self.error("Metal テクスチャキャッシュを作れません")
        }

        guard writer.startWriting() else { throw writer.error ?? Self.error("書き出しを開始できません") }
        writer.startSession(atSourceTime: .zero)
    }

    private static func error(_ s: String) -> NSError {
        NSError(domain: "hakoniwa.recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }

    /// Encodes a scaled copy of `source` (the finished drawable) into `cmd` and appends it to the movie when
    /// the GPU is done. Frames are dropped while the encoder is busy.
    func encodeFrame(commandBuffer cmd: MTLCommandBuffer, source: MTLTexture, time: CFTimeInterval) {
        guard !stopped, writer.status == .writing, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool, let cache = textureCache else { skipped += 1; return }
        if startTime == nil { startTime = time }
        // Strictly increasing presentation times, at most 60 per second.
        let value = Int64(((time - startTime!) * Double(Self.timescale)).rounded())
        if lastScheduled >= 0 && value - lastScheduled < Self.frameDuration.value * 3 / 4 { return }

        // Bounded pool: if the encoder holds on to many buffers, skip the frame rather than allocate more.
        var pb: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pb) == kCVReturnSuccess,
              let buffer = pb else { skipped += 1; return }
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTex)
                == kCVReturnSuccess, let cvTex, let target = CVMetalTextureGetTexture(cvTex) else { skipped += 1; return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { skipped += 1; return }
        enc.label = "recording"
        // Centre crop to the movie aspect ratio, then 4 taps per output pixel.
        let srcAspect = Float(source.width) / Float(max(source.height, 1))
        let dstAspect = Float(width) / Float(height)
        var scale = SIMD2<Float>(1, 1)
        if srcAspect > dstAspect { scale.x = dstAspect / srcAspect } else { scale.y = srcAspect / dstAspect }
        var params: [SIMD4<Float>] = [
            SIMD4(scale.x, scale.y, (1 - scale.x) / 2, (1 - scale.y) / 2),
            SIMD4(scale.x / Float(width), scale.y / Float(height), 0, 0),
        ]
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        lastScheduled = value
        let pts = CMTime(value: value, timescale: Self.timescale)
        cmd.addCompletedHandler { [self] cb in
            let ok = cb.status == .completed
            queue.async { [self] in
                withExtendedLifetime(cvTex) {}
                if ok { append(buffer, at: pts) }
            }
        }
        framesSinceFlush += 1
        if framesSinceFlush >= 120 {
            framesSinceFlush = 0
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    /// On `queue`.
    private func append(_ buffer: CVPixelBuffer, at pts: CMTime) {
        guard !finished, !failed, writer.status == .writing else { return }
        if lastAppended.isValid && pts <= lastAppended { dropped += 1; return }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        if adaptor.append(buffer, withPresentationTime: pts) {
            lastAppended = pts
            frames += 1
        } else {
            failed = true
            let message = writer.error?.localizedDescription ?? "不明なエラー"
            NSLog("recording: append failed at frame \(frames): \(String(describing: writer.error))")
            DispatchQueue.main.async { [self] in onFailure?(message) }
        }
    }

    /// Stops taking frames (call on the render thread), waits for in-flight frames and closes the file.
    /// `completion` runs on the main thread with the file URL, or nil if nothing usable was written.
    func finish(_ completion: @escaping (URL?) -> Void) {
        stopped = true
        // In-flight GPU frames append from completion handlers; give them a moment to land.
        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
            finished = true
            guard writer.status == .writing else {
                NSLog("recording: writer not writing (status \(writer.status.rawValue)): \(String(describing: writer.error))")
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            input.markAsFinished()
            if lastAppended.isValid { writer.endSession(atSourceTime: lastAppended + Self.frameDuration) }
            writer.finishWriting { [self] in
                let ok = writer.status == .completed && frames > 0
                if !ok {
                    NSLog("recording failed: status \(writer.status.rawValue) frames \(frames) error \(String(describing: writer.error))")
                    try? FileManager.default.removeItem(at: url)
                }
                DispatchQueue.main.async { completion(ok ? self.url : nil) }
            }
        }
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct RecordOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex RecordOut recordVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        RecordOut o;
        o.position = float4(p * 2.0 - 1.0, 0, 1);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    inline float3 linearToSRGB(float3 c) {
        c = saturate(c);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
    }

    // params[0]: xy = uv scale, zw = uv offset (centre crop); params[1]: xy = output pixel size in source uv.
    fragment float4 recordFragment(RecordOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   constant float4 *params [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = in.uv * params[0].xy + params[0].zw;
        float2 q = params[1].xy * 0.25;
        // Reading the sRGB drawable gives linear colour; average in linear space, then encode.
        float3 c = src.sample(s, uv + float2(-q.x, -q.y)).rgb + src.sample(s, uv + float2(q.x, -q.y)).rgb
                 + src.sample(s, uv + float2(-q.x, q.y)).rgb + src.sample(s, uv + float2(q.x, q.y)).rgb;
        return float4(linearToSRGB(c * 0.25), 1.0);
    }
    """#
}
