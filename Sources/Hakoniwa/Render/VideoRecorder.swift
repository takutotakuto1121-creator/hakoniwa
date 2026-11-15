import AVFoundation
import CoreVideo
import Metal

/// Writes rendered frames to an H.264 .mp4 file.
final class VideoRecorder: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "hakoniwa.recorder")
    private var startTime: CFTimeInterval?
    private var lastTime: CFTimeInterval = -1
    let width: Int
    let height: Int
    private(set) var frames = 0
    private var finished = false

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        // H.264 needs even dimensions.
        self.width = width & ~1
        self.height = height & ~1
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.width,
            AVVideoHeightKey: self.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(self.width * self.height * 6, 8_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "hakoniwa", code: 1) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Called from a Metal completion handler with a shared-storage BGRA texture.
    func append(texture: MTLTexture, time: CFTimeInterval) {
        queue.async { [self] in
            guard !finished, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
            if startTime == nil { startTime = time }
            let t = time - startTime!
            if t <= lastTime { return }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bpr = CVPixelBufferGetBytesPerRow(buffer)
                texture.getBytes(base, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, min(width, texture.width), min(height, texture.height)), mipmapLevel: 0)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) {
                lastTime = t
                frames += 1
            }
        }
    }

    func finish(_ completion: @escaping (URL?) -> Void) {
        queue.async { [self] in
            finished = true
            input.markAsFinished()
            writer.finishWriting {
                let ok = self.writer.status == .completed && self.frames > 0
                if !ok { NSLog("recording failed: status \(self.writer.status.rawValue) frames \(self.frames) error \(String(describing: self.writer.error))") }
                DispatchQueue.main.async { completion(ok ? self.url : nil) }
            }
        }
    }
}
