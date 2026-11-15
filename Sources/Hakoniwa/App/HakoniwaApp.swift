import AppKit
import HakoniwaCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let env = AppEnvironment.shared
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
        if let path = env.options.screenshot {
            scheduleScreenshot(path: path, env: env)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.controller.stop()
    }

    private func scheduleScreenshot(path: String, env: AppEnvironment) {
        let target = env.options.frames
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
    private let env = AppEnvironment.shared

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
