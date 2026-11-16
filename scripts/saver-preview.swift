// Runs the screen-saver view in an ordinary window and saves screenshots, so the saver can be
// checked without installing it. Built by `scripts/build-saver.sh --preview`.
//
//   build/saver-preview [--out DIR] [--world FILE] [--size 1280x800] [--shots 3,20,40]
//                       [--follow-at SECONDS] [--thumbnail]
//
// --thumbnail runs the view with isPreview = true (the System Settings thumbnail) at 300x188.
// Prints the average CPU use and peak memory at the end.
import AppKit
import Foundation

@main
struct SaverPreview {
    static func main() {
        _ = startUptime
        var out = "build/saver-shots"
        var worldPath = "Resources/showcase.hkw"
        var size = NSSize(width: 1280, height: 800)
        var shots: [Double] = [3, 20, 40]
        var followAt: Double?
        var thumbnail = false
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--out": out = args.next() ?? out
            case "--world": worldPath = args.next() ?? worldPath
            case "--size":
                let p = (args.next() ?? "").split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
            case "--shots": shots = (args.next() ?? "").split(separator: ",").compactMap { Double($0) }.sorted()
            case "--follow-at": followAt = Double(args.next() ?? "")
            case "--thumbnail": thumbnail = true
            default:
                FileHandle.standardError.write("unknown option \(a)\n".data(using: .utf8)!)
                exit(2)
            }
        }
        if thumbnail && size == NSSize(width: 1280, height: 800) { size = NSSize(width: 300, height: 188) }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        SharedWorld.worldURLOverride = URL(fileURLWithPath: worldPath)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "箱庭 screen saver preview"
        guard let view = HakoniwaSaverView(frame: NSRect(origin: .zero, size: size), isPreview: thumbnail) else {
            print("could not create the saver view"); exit(1)
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let t0 = Date()
        view.startAnimation()
        print("started in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")

        if let f = followAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + f) { view.followNow() }
        }
        var remaining = shots.count
        for (i, s) in shots.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                view.captureNextFrame { img in
                    let path = "\(out)/\(thumbnail ? "thumb" : "shot")-\(i + 1)-\(Int(s))s.png"
                    if let img { save(composite(img, view: view, scale: window.backingScaleFactor), to: path) }
                    print(img == nil ? "capture failed at \(s) s" : "saved \(path)")
                    remaining -= 1
                    if remaining == 0 { finish(view) }
                }
            }
        }
        if shots.isEmpty { finish(view) }
        app.run()
    }

    /// Draws the caption label on top of the Metal frame (the capture contains the world only).
    static func composite(_ img: CGImage, view: HakoniwaSaverView, scale: CGFloat) -> CGImage {
        guard let label = view.captionView,
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        if let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: rep)
            if let li = rep.cgImage {
                let f = label.frame
                ctx.draw(li, in: CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale))
            }
        }
        return ctx.makeImage() ?? img
    }

    static func save(_ img: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func finish(_ view: HakoniwaSaverView) {
        view.stopAnimation()
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let cpu = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        let wall = ProcessInfo.processInfo.systemUptime - startUptime
        print(String(format: "cpu %.1f s over %.1f s wall (%.0f%% of one core), peak memory %.0f MB",
                     cpu, wall, cpu / wall * 100, Double(u.ru_maxrss) / 1_048_576))
        // Give the simulation thread a moment to notice the stop, then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    static let startUptime = ProcessInfo.processInfo.systemUptime
}
