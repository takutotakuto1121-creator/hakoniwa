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
        if let path = env.options.soundTest {
            do {
                print(try SoundEngine.shared.renderOffline(to: URL(fileURLWithPath: path), seconds: 10))
            } catch {
                print("sound test failed: \(error)")
            }
            fflush(stdout)
            exit(0)
        }
        if env.options.screenshot == nil && env.options.record == nil && env.options.card == nil {
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
        } else if let path = env.options.record {
            scheduleRecording(path: path, env: env)
        } else if let path = env.options.card {
            scheduleCard(path: path, env: env)
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
        guard AppEnvironment.shared.model.renderer?.recorder != nil else { return .terminateNow }
        AppEnvironment.shared.stopRecording(reveal: false) { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.controller.stop()
    }

    /// `--card PATH`: once the selection's details have arrived, write its creature card and quit.
    private func scheduleCard(path: String, env: AppEnvironment) {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { timer in
            guard let r = env.model.renderer else { return }
            r.view?.draw()
            guard r.frameCount >= env.options.frames, env.model.detail != nil else { return }
            timer.invalidate()
            let t0 = CACurrentMediaTime()
            if let img = CreatureCard.makeImage(model: env.model), writePNG(img, to: URL(fileURLWithPath: path)) {
                print("card \(path) \(img.width)x\(img.height) in \(String(format: "%.2f", CACurrentMediaTime() - t0))s")
            } else {
                print("card failed")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// `--record PATH`: warm up for `--frames` frames, record `--record-seconds`, write the movie and quit.
    private func scheduleRecording(path: String, env: AppEnvironment) {
        var started: CFTimeInterval?
        var stopping = false
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            guard let r = env.model.renderer else { return }
            if started == nil && r.frameCount >= env.options.frames {
                guard env.startRecording(to: URL(fileURLWithPath: path)) else {
                    print("record failed to start"); fflush(stdout); NSApp.terminate(nil); return
                }
                started = CACurrentMediaTime()
            }
            if let s = started, !stopping, CACurrentMediaTime() - s >= env.options.recordSeconds {
                stopping = true
                let rec = r.recorder
                env.stopRecording(reveal: false) { url in
                    print("record \(url?.path ?? "FAILED") frames \(rec?.frames ?? 0) dropped \(rec?.dropped ?? 0) skipped \(rec?.skipped ?? 0)")
                    fflush(stdout)
                    timer.invalidate()
                    NSApp.terminate(nil)
                }
            }
            r.view?.draw()
        }
    }

    private func scheduleScreenshot(path: String, env: AppEnvironment) {
        let target = env.options.frames
        var meteorFired = false
        // Drive frames manually: when the window is occluded the display link stops.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            guard let r = env.model.renderer else { return }
            // Keep drawing until the app quits: the capture is taken from a frame drawn after the request,
            // and an occluded window gets no display-link frames.
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
        if TimelapsePlayer.shared.active { return TimelapsePlayer.shared.handleKey(event) }
        if EncyclopediaStore.shared.handleKey(event) { return true }
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
        case "w": m.tool = .wall
        case "e": m.tool = .eraseWall
        case "t": m.bottomTab = .tree; m.showBottom = true
        case "l": TimelapsePlayer.shared.start()
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
                Button("進化のタイムラプス") { TimelapsePlayer.shared.toggle() }.keyboardShortcut("l")
                Button("種の図鑑") { EncyclopediaStore.shared.toggle() }.keyboardShortcut("e")
                Button("お気に入りの個体") { PetStore.shared.showFavorites.toggle() }.keyboardShortcut("k")
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
