import AppKit
import HakoniwaCore
import MetalKit
import QuartzCore
import ScreenSaver

/// The 箱庭 screen saver: the bundled evolved world keeps evolving in real time (1×) while the
/// camera drifts slowly over it. No panels; only a small caption in a corner.
///
/// The Metal view is created in `startAnimation` and torn down in `stopAnimation`, so a saver that
/// is merely instantiated (System Settings thumbnails) costs nothing. Frames are drawn from
/// `animateOneFrame` (the MTKView's own display link is paused).
@objc(HakoniwaSaverView)
final class HakoniwaSaverView: ScreenSaverView {
    private var world: SharedWorld?
    private var mtkView: MTKView?
    private var renderer: Renderer?
    private var director = CameraDirector()
    private let caption = NSTextField(labelWithString: "")
    private var lastFrame: CFTimeInterval = 0
    private var lastCaption: CFTimeInterval = 0
    private var captionCorner = 0
    private var cornerSince: CFTimeInterval = 0
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = isPreview ? 1.0 / 30.0 : 1.0 / 60.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
    override var isOpaque: Bool { true }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    // MARK: - Lifecycle

    override func startAnimation() {
        super.startAnimation()
        setUp()
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDown()
    }

    deinit {
        if let o = stopObserver { DistributedNotificationCenter.default().removeObserver(o) }
    }

    /// True between `startAnimation` and `stopAnimation`.
    private var active = false

    private func setUp() {
        guard !active else { return }
        active = true
        SharedWorld.acquire { [weak self] w in
            guard let self, self.active, self.renderer == nil else { w.release(); return }
            self.attach(w)
        }
        // On recent macOS the legacy screen-saver host does not always call `stopAnimation`
        // when the user returns; this notification is the reliable signal.
        if stopObserver == nil {
            stopObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.tearDown() }
            }
        }
    }

    private func attach(_ w: SharedWorld) {
        let v = MTKView(frame: bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        // Draw only when the screen saver asks for a frame.
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        guard let r = Renderer(view: v, controller: w.controller) else {
            w.release()
            return
        }
        v.delegate = r
        v.alphaValue = 0
        director = CameraDirector()  // frame a new opening shot for the fresh camera
        addSubview(v)
        world = w
        mtkView = v
        renderer = r
        setUpCaption()
        lastFrame = CACurrentMediaTime()
        cornerSince = lastFrame
        // Fade in from black once the first frames are drawn.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 2.5
            v.animator().alphaValue = 1
        }
    }

    private func tearDown() {
        active = false
        guard let r = renderer else { return }
        mtkView?.delegate = nil
        mtkView?.removeFromSuperview()
        mtkView?.releaseDrawables()
        mtkView = nil
        renderer = nil
        HakoniwaSaverView.retire(r)
        caption.removeFromSuperview()
        world?.release()
        world = nil
    }

    /// Frees the renderer once the GPU has finished its frames. Its in-flight semaphore must not be
    /// destroyed while frames still hold it (libdispatch traps), and their completion handlers
    /// only hold the renderer weakly. Command buffers on one queue complete in order, so an empty
    /// buffer committed last completes after all of them.
    private static func retire(_ r: Renderer) {
        guard let cmd = r.queue.makeCommandBuffer() else { return }
        cmd.addCompletedHandler { _ in
            DispatchQueue.main.async { withExtendedLifetime(r) {} }
        }
        cmd.commit()
    }

    // MARK: - Frame

    override func animateOneFrame() {
        guard let v = mtkView, let r = renderer, let w = world else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 0.1)
        lastFrame = now
        // The camera needs the drawable size before the first shot is framed.
        if r.camera.viewSize.x != Float(v.drawableSize.width) || r.camera.viewSize.y != Float(v.drawableSize.height) {
            r.camera.viewSize = V2(Float(v.drawableSize.width), Float(v.drawableSize.height))
            r.camera.pixelRatio = Float(window?.backingScaleFactor ?? 2)
        }
        w.controller.withFront { snap in
            r.camera.worldSize = snap.worldSize
            director.update(dt: dt, camera: r.camera, snap: snap)
        }
        v.draw()
        if now - lastCaption > 1 {
            lastCaption = now
            updateCaption(now: now)
        }
    }

    /// Captures the next rendered frame (preview tool).
    func captureNextFrame(_ completion: @escaping (CGImage?) -> Void) {
        guard let r = renderer else { completion(nil); return }
        r.captureNextFrame(completion)
    }

    /// Switches to following a creature at once (preview tool).
    func followNow() {
        guard let r = renderer, let w = world else { return }
        w.controller.withFront { director.followNow(camera: r.camera, snap: $0) }
    }

    var captionView: NSTextField? { caption.superview == nil ? nil : caption }

    // MARK: - Caption

    private func setUpCaption() {
        guard !isPreview else { return }
        caption.font = NSFont.systemFont(ofSize: 12, weight: .light)
        caption.textColor = NSColor(white: 1, alpha: 0.42)
        caption.drawsBackground = false
        caption.isBordered = false
        caption.isEditable = false
        caption.isSelectable = false
        caption.wantsLayer = true
        caption.stringValue = "箱庭"
        caption.sizeToFit()
        addSubview(caption)
        placeCaption()
    }

    private func updateCaption(now: CFTimeInterval) {
        guard caption.superview != nil, let u = world?.latest else { return }
        let hours = Double(u.tick) / Double(max(u.ticksPerSecond, 1)) / 3600
        caption.stringValue = String(format: "箱庭 — 第%d世代・%.1f時間", Int(u.maxGeneration), hours)
        caption.sizeToFit()
        // Move to another corner every few minutes so the text never burns in.
        if now - cornerSince > 300 {
            cornerSince = now
            captionCorner = (captionCorner + 1) % 4
        }
        placeCaption()
    }

    private func placeCaption() {
        let m: CGFloat = 28
        let s = caption.frame.size
        let x = captionCorner == 0 || captionCorner == 3 ? bounds.maxX - s.width - m : m
        let y = captionCorner < 2 ? m : bounds.maxY - s.height - m
        caption.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
