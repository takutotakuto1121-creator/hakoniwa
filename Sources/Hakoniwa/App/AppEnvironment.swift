import AppKit
import HakoniwaCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Command-line options, mainly for automated visual checks.
struct LaunchOptions {
    var load: String?
    var seed: UInt64?
    var ticks: Int = 0
    var screenshot: String?
    var selectFirst = false
    var zoom: Float?
    var frames = 90
    var tab: BottomTab?
    var speed: SimSpeed?
    var paused = false
    var hidePanels = false
    var center: V2?
    var tool: Tool?
    var windowSize: CGSize?
    var meteor = false
    /// Records a movie of `recordSeconds` to this path, then quits (for automated checks).
    var record: String?
    var recordSeconds: Double = 5
    /// Writes the creature card of the selection (use with `--select-first`) to this path, then quits.
    var card: String?

    /// AppKit pairs up `-key value` arguments as user defaults and treats any argument left over as a
    /// file to open. A value-less flag followed by another option (`--select-first --zoom 2`) leaves `2`
    /// unpaired, AppKit then "opens" it instead of creating the main window, and the app shows nothing.
    /// Our options are parsed by `parse`, so tell AppKit to ignore stray arguments.
    /// Must run before `NSApplication` finishes launching.
    static func shieldFromAppKit() {
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--load": o.load = next()
            case "--seed": o.seed = next().flatMap { UInt64($0) }
            case "--ticks": o.ticks = next().flatMap { Int($0) } ?? 0
            case "--screenshot": o.screenshot = next()
            case "--select-first": o.selectFirst = true
            case "--zoom": o.zoom = next().flatMap { Float($0) }
            case "--frames": o.frames = next().flatMap { Int($0) } ?? 90
            case "--tab": o.tab = next().flatMap { BottomTab(rawValue: $0) }
            case "--speed": o.speed = next().flatMap { Int($0) }.flatMap { SimSpeed(rawValue: $0) }
            case "--paused": o.paused = true
            case "--hide-panels": o.hidePanels = true
            case "--meteor": o.meteor = true
            case "--record": o.record = next()
            case "--card": o.card = next()
            case "--record-seconds": o.recordSeconds = next().flatMap { Double($0) } ?? 5
            case "--tool": o.tool = next().flatMap { Tool(rawValue: $0) }
            case "--center":
                if let s = next() {
                    let p = s.split(separator: ",").compactMap { Float($0) }
                    if p.count == 2 { o.center = V2(p[0], p[1]) }
                }
            case "--window":
                if let s = next() {
                    let p = s.split(separator: "x").compactMap { Double($0) }
                    if p.count == 2 { o.windowSize = CGSize(width: p[0], height: p[1]) }
                }
            default: break
            }
            i += 1
        }
        return o
    }
}

enum WorldSizePreset: String, CaseIterable, Identifiable {
    case small, standard, large
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "小さい(軽い)"
        case .standard: return "標準"
        case .large: return "大きい"
        }
    }
    var side: Float {
        switch self {
        case .small: return 2800
        case .standard: return 4000
        case .large: return 5000
        }
    }

    func config(initialCreatures: Int) -> SimConfig {
        var c = SimConfig()
        let ratio = (side * side) / (c.worldWidth * c.worldHeight)
        c.worldWidth = side
        c.worldHeight = side
        c.totalEnergy *= ratio
        c.maxPlants = Int(Float(c.maxPlants) * ratio)
        c.maxMeat = Int(Float(c.maxMeat) * ratio)
        c.minPopulation = max(40, Int(Float(c.minPopulation) * ratio))
        c.initialCreatures = initialCreatures
        return c
    }
}

/// Process-wide wiring between the simulation, the renderer and the UI.
final class AppEnvironment {
    static let shared = AppEnvironment()
    let options: LaunchOptions
    let controller: SimulationController
    let model: AppModel
    private var configuredRenderer = false

    private init() {
        options = LaunchOptions.parse(CommandLine.arguments)
        LaunchOptions.shieldFromAppKit()
        var world: World?
        if let path = options.load {
            do { world = try World.load(from: URL(fileURLWithPath: path)) } catch {
                NSLog("could not load \(path): \(error)")
            }
        } else if options.seed == nil, let url = Bundle.main.url(forResource: "showcase", withExtension: "hkw") {
            world = try? World.load(from: url)
        }
        let w = world ?? World(config: SimConfig(), seed: options.seed ?? UInt64(Date().timeIntervalSince1970) % 100_000)
        if options.ticks > 0 { w.step(options.ticks) }
        controller = SimulationController(world: w)
        model = AppModel(controller: controller)
        if let s = options.speed { model.speed = s }
        if options.paused { model.paused = true }
        if let t = options.tab { model.bottomTab = t }
        if options.hidePanels { model.showPanels = false }
        if let t = options.tool { model.tool = t }
        controller.start()
    }

    func rendererDidLoad(_ r: Renderer) {
        guard !configuredRenderer else { return }
        configuredRenderer = true
        if let z = options.zoom {
            r.camera.targetZoom = z * r.camera.pixelRatio
            r.camera.zoom = r.camera.targetZoom
        } else {
            r.camera.targetZoom = 0.55 * r.camera.pixelRatio
            r.camera.zoom = 0.3 * r.camera.pixelRatio
        }
        if let c = options.center {
            r.camera.targetCenter = c
            r.camera.center = c
        }
        if options.selectFirst {
            let center = options.center ?? r.camera.center
            controller.perform { [model] w in
                let uid = w.creature(near: center, maxDistance: 3000)
                DispatchQueue.main.async {
                    model.select(uid)
                    model.following = uid != nil
                }
            }
        }
    }

    // MARK: Actions

    func newWorld(seed: UInt64, initialCreatures: Int, size: WorldSizePreset) {
        let cfg = size.config(initialCreatures: initialCreatures)
        model.showToast("新しい世界を作っています…")
        DispatchQueue.global(qos: .userInitiated).async { [controller, model] in
            let w = World(config: cfg, seed: seed)
            controller.replaceWorld(w)
            DispatchQueue.main.async { model.showToast("新しい世界(シード \(seed))") }
        }
    }

    static let worldType = UTType(filenameExtension: "hkw") ?? .data

    func saveWorld() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AppEnvironment.worldType]
        panel.nameFieldStringValue = "箱庭 \(Self.stamp()).hkw"
        panel.title = "世界を保存"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.perform { [model] w in
            do {
                try w.save(to: url)
                DispatchQueue.main.async { model.showToast("保存しました: \(url.lastPathComponent)") }
            } catch {
                DispatchQueue.main.async { model.showToast("保存できませんでした: \(error)") }
            }
        }
    }

    func openWorld() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppEnvironment.worldType]
        panel.title = "世界を開く"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadWorld(url)
    }

    func loadWorld(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [controller, model] in
            do {
                let w = try World.load(from: url)
                controller.replaceWorld(w)
                DispatchQueue.main.async { model.showToast("読み込みました: \(url.lastPathComponent)") }
            } catch {
                DispatchQueue.main.async { model.showToast("読み込めませんでした: \(error)") }
            }
        }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    static func outputFolder(_ base: FileManager.SearchPathDirectory) -> URL {
        let dir = FileManager.default.urls(for: base, in: .userDomainMask).first!.appendingPathComponent("箱庭", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func takeScreenshot() {
        guard let r = model.renderer else { return }
        r.captureNextFrame { [model] img in
            guard let img else { model.showToast("スクリーンショットに失敗しました"); return }
            let url = AppEnvironment.outputFolder(.picturesDirectory).appendingPathComponent("箱庭 \(AppEnvironment.stamp()).png")
            if writePNG(img, to: url) {
                model.showToast("スクリーンショットを保存しました(ピクチャ/箱庭)")
            }
        }
    }

    func toggleRecording() {
        guard let r = model.renderer else { return }
        if r.recorder != nil {
            stopRecording(reveal: true)
        } else {
            let url = AppEnvironment.outputFolder(.moviesDirectory).appendingPathComponent("箱庭 \(AppEnvironment.stamp()).mp4")
            startRecording(to: url)
        }
    }

    @discardableResult
    func startRecording(to url: URL) -> Bool {
        guard let r = model.renderer, r.recorder == nil else { return false }
        // Hardware H.264 is fussy about large frames, so the movie is at most 1920×1200 (even sizes).
        let size = VideoRecorder.movieSize(for: r.camera.viewSize)
        do {
            let rec = try VideoRecorder(url: url, width: size.width, height: size.height, device: r.device)
            rec.onFailure = { [weak self] message in
                guard let self, self.model.renderer?.recorder === rec else { return }
                self.model.showToast("録画が中断されました: \(message)")
                self.stopRecording(reveal: false)
            }
            r.recorder = rec
            model.recording = true
            model.showToast("録画を開始しました")
            return true
        } catch {
            model.showToast("録画を開始できませんでした: \(error.localizedDescription)")
            return false
        }
    }

    func stopRecording(reveal: Bool, completion: ((URL?) -> Void)? = nil) {
        guard let r = model.renderer, let rec = r.recorder else { completion?(nil); return }
        r.recorder = nil
        model.recording = false
        rec.finish { [model] url in
            if let url {
                model.showToast("録画を保存しました(ムービー/箱庭)")
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                model.showToast("録画の保存に失敗しました")
            }
            completion?(url)
        }
    }

    /// Renders the Metal frame plus the SwiftUI overlay of `window` into one image.
    func captureWindow(_ window: NSWindow, completion: @escaping (CGImage?) -> Void) {
        guard let r = model.renderer, let content = window.contentView else { completion(nil); return }
        r.captureNextFrame { metal in
            guard let metal else { completion(nil); return }
            let scale = window.backingScaleFactor
            let w = metal.width, h = metal.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { completion(nil); return }
            ctx.draw(metal, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Render the SwiftUI layer tree on top (the Metal layer itself renders empty here).
            func findMetal(_ v: NSView) -> NSView? {
                if v is WorldMTKView { return v }
                for s in v.subviews { if let f = findMetal(s) { return f } }
                return nil
            }
            let metalView = findMetal(content)
            let metalLayerWasHidden = metalView?.layer?.isHidden ?? false
            metalView?.layer?.isHidden = true
            defer { metalView?.layer?.isHidden = metalLayerWasHidden }
            if let layer = content.layer {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                if content.isFlipped == false {
                    ctx.translateBy(x: 0, y: content.bounds.height)
                    ctx.scaleBy(x: 1, y: -1)
                }
                layer.render(in: ctx)
                ctx.restoreGState()
            }
            completion(ctx.makeImage())
        }
    }
}

@discardableResult
func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}
