import AppKit
import HakoniwaCore
import SwiftUI

/// The "god hand" interventions. Every World change goes through the controller's command queue.
enum GodActions {
    /// World minutes a climate event lasts.
    static let climateMinutes: Float = 10
    /// Brush radius (world units) of the wall tools.
    static let wallRadius: Float = 55
    static let eraseRadius: Float = 90
    /// Number of founders brought back by a revival.
    static let reviveCount = 6

    static func splitContinents(_ model: AppModel) {
        model.controller.perform { w in w.splitIntoContinents() }
        model.showToast("大陸が二つに分断された")
    }

    static func clearWalls(_ model: AppModel) {
        model.controller.perform { w in w.clearWalls() }
        model.showToast("壁が取り払われ、大地がつながった")
    }

    static func paintWall(_ model: AppModel, from a: V2, to b: V2, erase: Bool) {
        let r = erase ? eraseRadius : wallRadius
        model.controller.perform { w in
            w.paintWall(from: a, to: b, radius: r, erase: erase)
            if !erase { w.evictFromWalls() }
        }
    }

    /// Starts `kind`, or ends it early when it is already running.
    static func toggleClimate(_ kind: ClimateKind, _ model: AppModel) {
        if GodModel.shared.climate == kind {
            model.controller.perform { w in w.startClimate(.normal, minutes: 0) }
            GodModel.shared.climate = .normal
            model.showToast("\(kind.label)を終わらせた")
            return
        }
        model.controller.perform { w in w.startClimate(kind, minutes: climateMinutes) }
        GodModel.shared.climate = kind
        GodModel.shared.climateRemaining = Double(climateMinutes * 60)
        GodModel.shared.climateTotal = Double(climateMinutes * 60)
        switch kind {
        case .iceAge: model.showToast("氷河期が来た。植物が激減する")
        case .bloom: model.showToast("温暖期が来た。植物が豊かに茂る")
        case .normal: break
        }
    }

    static func plague(_ model: AppModel) {
        model.controller.perform { w in
            let name = w.plague()
            DispatchQueue.main.async {
                model.showToast(name.map { "疫病が「\($0)」を襲った" } ?? "疫病が襲う種が見つからない")
            }
        }
    }

    /// Brings back the founders of a species at the centre of the screen, then selects and follows one.
    static func revive(_ species: SpeciesInfo, _ model: AppModel) {
        guard let r = model.renderer else { return }
        let at = r.camera.center
        let id = species.id, name = species.name
        if let ext = species.extinctTick { GodModel.shared.revivedFrom[id] = ext }
        model.controller.perform { w in
            let uids = w.revive(speciesId: id, at: at, count: reviveCount)
            DispatchQueue.main.async {
                guard let first = uids.first else {
                    model.showToast("土のエネルギーが足りず、蘇らせられなかった")
                    return
                }
                model.select(first)
                model.following = true
                if r.camera.targetZoom < 2.5 * r.camera.pixelRatio { r.camera.targetZoom = 3 * r.camera.pixelRatio }
                model.showToast(species.isAlive ? "「\(name)」の祖先型を\(uids.count)匹放った" : "絶滅した「\(name)」が蘇った")
            }
        }
    }
}

/// "3時間12分", "8分", "40秒" — a coarse span of world time.
func formatSpan(_ seconds: Double) -> String {
    let s = Int(max(seconds, 0))
    if s >= 3600 {
        let m = (s % 3600) / 60
        return "\(s / 3600)時間" + (m > 0 ? "\(m)分" : "")
    }
    if s >= 60 { return "\(s / 60)分" }
    return "\(s)秒"
}

/// "7:42" style countdown of world time.
func formatCountdown(_ seconds: Double) -> String {
    let s = Int(max(seconds, 0).rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}
