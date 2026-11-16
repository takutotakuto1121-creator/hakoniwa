import Foundation
import HakoniwaCore

/// One running world shared by every screen-saver view in the process (one view per display,
/// plus the preview in System Settings), so several displays do not each run a simulation.
///
/// The first view to start loads the bundled `showcase.hkw` and starts the simulation thread at
/// real-time speed (1×); the last view to stop ends the thread. Main thread only.
final class SharedWorld {
    /// Overrides the bundled world file (used by the preview tool, which has no bundle).
    static var worldURLOverride: URL?

    private static var current: SharedWorld?

    let controller: SimulationController
    /// Latest statistics from the simulation thread (for the caption).
    private(set) var latest: UIUpdate?
    private var users = 0

    private init(world: World) {
        controller = SimulationController(world: world)
        controller.speed = .x1
        controller.onUpdate = { [weak self] u in
            // The caption only needs the tick and generation; drop the heavy parts.
            var u = u
            u.samples = nil; u.events = nil; u.species = nil; u.lineage = nil
            self?.latest = u
        }
        controller.start()
    }

    private static var waiters: [(SharedWorld) -> Void] = []

    /// Hands the running world to `done` (main thread), loading it in the background first if
    /// needed, so the screen does not freeze while the 13 MB file is read. Balance with `release()`.
    static func acquire(_ done: @escaping (SharedWorld) -> Void) {
        if let c = current {
            c.users += 1
            done(c)
            return
        }
        waiters.append(done)
        guard waiters.count == 1 else { return }  // a load is already under way
        let box = WorldBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.world = loadWorld()
            DispatchQueue.main.async {
                let s = SharedWorld(world: box.world!)
                current = s
                let ws = waiters
                waiters.removeAll()
                s.users = ws.count
                for w in ws { w(s) }
            }
        }
    }

    func release() {
        users -= 1
        guard users <= 0 else { return }
        controller.onUpdate = nil
        controller.stop()
        if SharedWorld.current === self { SharedWorld.current = nil }
    }

    /// Carries the freshly loaded world from the loading queue to the main thread.
    private final class WorldBox: @unchecked Sendable { var world: World? }

    private static func loadWorld() -> World {
        let url = worldURLOverride
            ?? Bundle(for: SharedWorld.self).url(forResource: "showcase", withExtension: "hkw")
        if let url {
            do { return try World.load(from: url) } catch {
                NSLog("Hakoniwa saver: could not load \(url.path): \(error)")
            }
        }
        // No bundled world (or an unreadable one): start a fresh world rather than a black screen.
        return World(config: SimConfig(), seed: UInt64(Date().timeIntervalSince1970) % 100_000)
    }
}
