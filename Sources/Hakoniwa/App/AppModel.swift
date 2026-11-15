import AppKit
import HakoniwaCore
import Observation
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, food, spawn, remove, meteor, wall, eraseWall
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "選択"
        case .food: return "餌をまく"
        case .spawn: return "生き物を置く"
        case .remove: return "取り除く"
        case .meteor: return "隕石"
        case .wall: return "壁を描く"
        case .eraseWall: return "壁を消す"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .food: return "leaf.fill"
        case .spawn: return "plus.circle.fill"
        case .remove: return "minus.circle.fill"
        case .meteor: return "flame.fill"
        case .wall: return "mountain.2.fill"
        case .eraseWall: return "eraser.fill"
        }
    }
    var radius: Float {
        switch self {
        case .food: return 70
        case .meteor: return 260
        case .remove: return 14
        case .wall: return GodActions.wallRadius
        case .eraseWall: return GodActions.eraseRadius
        default: return 0
        }
    }
    var shortcut: String {
        switch self {
        case .select: return "V"
        case .food: return "G"
        case .spawn: return "C"
        case .remove: return "X"
        case .meteor: return "M"
        case .wall: return "W"
        case .eraseWall: return "E"
        }
    }
}

enum BottomTab: String, CaseIterable, Identifiable {
    case population, traits, tree, events
    var id: String { rawValue }
    var label: String {
        switch self {
        case .population: return "個体数"
        case .traits: return "形質の進化"
        case .tree: return "系統樹"
        case .events: return "出来事"
        }
    }
}

/// UI state on the main thread. Fed by `SimulationController` at ~15 Hz.
@Observable
final class AppModel {
    @ObservationIgnored let controller: SimulationController
    @ObservationIgnored weak var renderer: Renderer?

    // Live statistics
    var tick: Int64 = 0
    var ticksPerSecond: Float = 20
    var population = 0
    var eggs = 0
    var herbivores = 0
    var omnivores = 0
    var carnivores = 0
    var speciesAlive = 0
    var maxGeneration: Int32 = 0
    var season: Float = 1
    var plants = 0
    var meat = 0
    var simRate: Double = 0
    var samples: [StatSample] = []
    var events: [WorldEvent] = []
    var species: [SpeciesInfo] = []
    var speciesById: [Int32: SpeciesInfo] = [:]
    var worldID = 0

    // Selection
    var selectedUid: UInt64 = 0 {
        didSet { controller.selectedUid = selectedUid; if selectedUid == 0 { detail = nil; lineage = [] } }
    }
    var detail: CreatureDetail?
    var lineage: [SpeciesInfo] = []
    var following = false
    var selectedSpecies: Int32?

    // Controls
    var speed: SimSpeed = .x1 { didSet { controller.speed = speed } }
    var paused = false { didSet { controller.paused = paused } }
    var tool: Tool = .select
    var showPanels = true
    var showInspector = true
    var showBottom = true
    var bottomTab: BottomTab = .population
    var showNewWorldSheet = false
    var recording = false
    var toast: String?
    var toastID = 0
    var fps: Double = 60

    init(controller: SimulationController) {
        self.controller = controller
        controller.onUpdate = { [weak self] u in self?.apply(u) }
    }

    var worldSeconds: Double { Double(tick) / Double(ticksPerSecond) }

    func apply(_ u: UIUpdate) {
        if u.worldID != worldID {
            worldID = u.worldID
            selectedUid = 0
            following = false
            selectedSpecies = nil
        }
        tick = u.tick
        ticksPerSecond = u.ticksPerSecond
        population = u.population
        eggs = u.eggs
        herbivores = u.herbivores
        omnivores = u.omnivores
        carnivores = u.carnivores
        speciesAlive = u.speciesAlive
        maxGeneration = u.maxGeneration
        season = u.season
        plants = u.plants
        meat = u.meat
        simRate = u.simRate
        if let s = u.samples { samples = s }
        if let e = u.events { events = e }
        if let sp = u.species {
            species = sp
            var map: [Int32: SpeciesInfo] = [:]
            for s in sp { map[s.id] = s }
            speciesById = map
        }
        if let d = u.detail, d.uid == selectedUid {
            detail = d
            if let l = u.lineage { lineage = l }
        } else if u.detailMissing && selectedUid != 0 {
            showToast("選択していた個体は死んだ")
            selectedUid = 0
            following = false
        }
    }

    func showToast(_ s: String) {
        toast = s
        toastID += 1
        let id = toastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            if self?.toastID == id { self?.toast = nil }
        }
    }

    func select(_ uid: UInt64?) {
        selectedUid = uid ?? 0
        if uid == nil { following = false }
    }

    func togglePause() { paused.toggle() }

    func step() {
        if !paused { paused = true }
        controller.requestStep(1)
    }

    var seasonLabel: String {
        let phase = sin(2 * Double.pi * worldSeconds / 1200)
        let cosPhase = cos(2 * Double.pi * worldSeconds / 1200)
        if phase > 0.5 { return "夏" }
        if phase < -0.5 { return "冬" }
        return cosPhase > 0 ? "春" : "秋"
    }
}

func formatWorldTime(_ seconds: Double) -> String {
    let s = Int(seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%d時間%02d分", h, m) }
    return String(format: "%d分%02d秒", m, sec)
}

extension SpeciesInfo {
    var color: Color {
        Color(hue: Double(meanHue), saturation: Double(min(1, meanSaturation * 0.85 + 0.1)), brightness: 0.95)
    }
}

func hueColor(_ hue: Float, _ sat: Float) -> Color {
    Color(hue: Double(hue), saturation: Double(min(1, sat * 0.85 + 0.1)), brightness: 0.95)
}
