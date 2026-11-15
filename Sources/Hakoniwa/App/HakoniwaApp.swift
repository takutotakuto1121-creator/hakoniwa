import AppKit
import HakoniwaCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.shared
        if env.options.screenshot == nil {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Automated capture: stay in the background and ignore stray clicks from the user.
            DispatchQueue.main.async {
                for w in NSApp.windows {
                    w.ignoresMouseEvents = true
                    w.orderBack(nil)
                }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyHandler.handle(event, env: env) ? nil : event
        }
        if let size = env.options.windowSize {
            DispatchQueue.main.async {
                if let w = NSApp.windows.first {
                    w.setContentSize(size)
                    w.center()
                }
            }
        }
        if let path = env.options.screenshot, !DuelLaunch.requested {
            scheduleScreenshot(path: path, env: env)
        }
        DuelLaunch.start(env: env)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Double-clicked .hkw files.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.pathExtension == "hkw" }) {
            AppEnvironment.shared.loadWorld(url)
        }
    }

    /// Finish an in-progress recording before quitting so the movie file is complete.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let r = AppEnvironment.shared.model.renderer, let rec = r.recorder else { return .terminateNow }
        r.recorder = nil
        AppEnvironment.shared.model.recording = false
        rec.finish { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.controller.stop()
    }

    private func scheduleScreenshot(path: String, env: AppEnvironment) {
        let target = env.options.frames
        var meteorFired = false
        // Drive frames manually: when the window is occluded the display link stops.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            guard let r = env.model.renderer else { return }
            if r.frameCount >= target + 2 { timer.invalidate(); return }
            if env.options.meteor && !meteorFired && r.frameCount >= max(target - 40, 1) {
                meteorFired = true
                let c = r.camera.center
                env.controller.perform { w in w.meteor(at: c, radius: Tool.meteor.radius) }
            }
            r.view?.draw()
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            guard let r = env.model.renderer, r.frameCount >= target, let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            timer.invalidate()
            env.captureWindow(window) { img in
                if let img {
                    writePNG(img, to: URL(fileURLWithPath: path))
                    print("screenshot \(path) \(img.width)x\(img.height) fps \(String(format: "%.1f", r.fps))")
                } else {
                    print("screenshot failed")
                }
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }
}

enum KeyHandler {
    /// Returns true when the event was consumed.
    static func handle(_ event: NSEvent, env: AppEnvironment) -> Bool {
        // Leave typing in text fields alone.
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return false }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return false }
        if DuelCoordinator.shared.handleKey(event) { return true }
        let m = env.model
        switch event.keyCode {
        case 49: m.togglePause(); return true                 // space
        case 53:                                              // escape
            if m.selectedUid != 0 { m.select(nil) } else { m.tool = .select }
            return true
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "1": m.speed = .x1; m.paused = false
        case "2": m.speed = .x4; m.paused = false
        case "3": m.speed = .x16; m.paused = false
        case "4": m.speed = .x64; m.paused = false
        case "5": m.speed = .max; m.paused = false
        case ".": m.step()
        case "f": if m.selectedUid != 0 { m.following.toggle() }
        case "h": m.showPanels.toggle()
        case "i": m.showInspector.toggle()
        case "b": m.showBottom.toggle()
        case "v": m.tool = .select
        case "g": m.tool = .food
        case "c": m.tool = .spawn
        case "x": m.tool = .remove
        case "m": m.tool = .meteor
        case "t": m.bottomTab = .tree; m.showBottom = true
        default: return false
        }
        return true
    }
}

@main
struct HakoniwaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let env: AppEnvironment

    init() {
        // Always start with a fresh main window instead of restoring (possibly closed) windows.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        env = AppEnvironment.shared
    }

    var body: some Scene {
        WindowGroup("箱庭") {
            ContentView(model: env.model)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新しい世界…") { env.model.showNewWorldSheet = true }.keyboardShortcut("n")
                Button("世界を開く…") { env.openWorld() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("世界を保存…") { env.saveWorld() }.keyboardShortcut("s")
                Divider()
                Button("スクリーンショットを保存") { env.takeScreenshot() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button(env.model.recording ? "録画を停止" : "録画を開始") { env.toggleRecording() }.keyboardShortcut("r")
            }
            CommandMenu("シミュレーション") {
                Button(env.model.paused ? "再開" : "一時停止") { env.model.togglePause() }
                Button("1ステップ進める") { env.model.step() }
                Divider()
                ForEach(SimSpeed.allCases) { s in
                    Button("速度 \(s.label)") { env.model.speed = s; env.model.paused = false }
                }
                Divider()
                Button("世代対決…") { DuelCoordinator.shared.toggle() }.keyboardShortcut("d")
                Divider()
                Button("追尾の切り替え") { env.model.following.toggle() }
                Button("選択を解除") { env.model.select(nil) }
            }
            CommandGroup(after: .sidebar) {
                Button(env.model.showPanels ? "パネルを隠す" : "パネルを表示") { env.model.showPanels.toggle() }
                    .keyboardShortcut("\\")
            }
        }
    }
}
