import Foundation
import HakoniwaCore

/// Launch flags that trigger god-hand features, for automated screenshots:
/// `--split`, `--walls`, `--ice-age`, `--warm`, `--plague`, `--pick-extinct`, `--revive`.
/// (Value-less flags; put them at the end of the command line.)
enum GodLaunch {
    struct Flags {
        var split = false
        var walls = false
        var iceAge = false
        var warm = false
        var plague = false
        var pickExtinct = false
        var revive = false
    }

    static let flags: Flags = {
        var f = Flags()
        for a in CommandLine.arguments {
            switch a {
            case "--split": f.split = true
            case "--walls": f.walls = true
            case "--ice-age": f.iceAge = true
            case "--warm": f.warm = true
            case "--plague": f.plague = true
            case "--pick-extinct": f.pickExtinct = true
            case "--revive": f.revive = true
            default: break
            }
        }
        return f
    }()

    static func apply(model: AppModel, renderer r: Renderer) {
        let f = flags
        if AppEnvironment.shared.options.screenshot != nil {
            // The capture waits for one more frame after the frame-driving timer stops; when the
            // display is asleep or the window is hidden the display link never delivers it.
            let target = AppEnvironment.shared.options.frames
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak r] _ in
                guard let r, r.frameCount >= target + 2 else { return }
                r.view?.draw()
            }
        }
        let c = r.camera.targetCenter
        if f.split { GodActions.splitContinents(model) }
        if f.walls {
            // A meandering reef across the view plus a small atoll.
            var prev: V2?
            for k in 0...24 {
                let x = Float(k) / 24
                let p = c + V2((x - 0.5) * 1500, sin(x * 7) * 160 + 80)
                if let a = prev { GodActions.paintWall(model, from: a, to: p, erase: false) }
                prev = p
            }
            for k in 0...16 {
                let a = Float(k) / 16 * 2 * .pi
                let p = c + V2(-300, -330) + V2(cos(a), sin(a)) * 120
                GodActions.paintWall(model, from: p, to: p, erase: false)
            }
        }
        if f.iceAge { GodActions.toggleClimate(.iceAge, model) }
        if f.warm { GodActions.toggleClimate(.bloom, model) }
        if f.plague { GodActions.plague(model) }
        if f.pickExtinct || f.revive {
            // Prefer an extinct ancestor of a living species (visible in the default tree view).
            model.controller.perform { w in
                let living = w.species.filter { $0.population > 0 }
                var ancestors = Set<Int32>()
                for s in living {
                    var p = s.parentId
                    while p >= 0 && Int(p) < w.species.count { ancestors.insert(p); p = w.species[Int(p)].parentId }
                }
                let extinct = w.species.filter { $0.established && $0.population == 0 }
                let pick = extinct.filter { ancestors.contains($0.id) }.max { $0.peakPopulation < $1.peakPopulation }
                    ?? extinct.max { $0.peakPopulation < $1.peakPopulation }
                guard let sp = pick else {
                    DispatchQueue.main.async { model.showToast("絶滅した種がまだいない") }
                    return
                }
                let info = SpeciesInfo(sp)
                DispatchQueue.main.async {
                    model.bottomTab = .tree
                    model.showBottom = true
                    model.selectedSpecies = info.id
                    if f.revive { GodActions.revive(info, model) }
                }
            }
        }
    }
}
