import AppKit
import CoreImage
import HakoniwaCore
import Metal
import Observation
import SwiftUI

/// One established species as the encyclopedia shows it.
struct SpeciesEntry: Identifiable {
    var info: SpeciesInfo
    var founder: Genes
    /// Mean look of the living (hatched) members, nil when none are alive.
    var members: SpeciesMembers?
    var children: [Int32]
    var id: Int32 { info.id }
}

/// Population of one species at one moment, sampled by the app (Core keeps no per-species history).
struct PopulationPoint {
    var tick: Int64
    var population: Int32
}

enum EncyclopediaSort: String, CaseIterable, Identifiable {
    case population, birth, diet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .population: return "個体数"
        case .birth: return "誕生順"
        case .diet: return "食性"
        }
    }
}

enum EncyclopediaFilter: String, CaseIterable, Identifiable {
    case all, alive, extinct
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "すべて"
        case .alive: return "生存中"
        case .extinct: return "絶滅"
        }
    }
}

/// State of the species encyclopedia. Lives on the main thread; World access goes through the controller.
@Observable
final class EncyclopediaStore {
    static let shared = EncyclopediaStore()

    var isPresented = false
    /// The species whose detail page is shown, nil for the list.
    var detailId: Int32?
    var sort: EncyclopediaSort = .population
    var filter: EncyclopediaFilter = .all

    // Refreshed every second while the page is open.
    var entries: [Int32: SpeciesEntry] = [:]
    var tick: Int64 = 0
    var ticksPerSecond: Float = 20
    /// Tick at which this app started sampling the current world.
    var observedSince: Int64 = 0
    /// Bumped whenever the sampled history changes, so charts redraw.
    var historyVersion = 0
    var portraits: [String: CGImage] = [:]

    @ObservationIgnored private(set) var history: [Int32: [PopulationPoint]] = [:]
    @ObservationIgnored private var lastSampleTick: Int64 = -1
    @ObservationIgnored private var worldKey: ObjectIdentifier?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var jumpCursor: [Int32: Int] = [:]
    @ObservationIgnored private var wasRenderingPaused = false
    @ObservationIgnored let portraitFactory = PortraitFactory()
    /// Species ids are reused by every world, so portraits drawn for a previous world are dropped.
    @ObservationIgnored private var portraitEpoch = 0

    /// At most this many samples per species; older ones are thinned when it fills up.
    static let maxSamples = 360

    var seconds: Double { Double(tick) / Double(ticksPerSecond) }

    // MARK: Sampling

    /// Starts sampling once per second (from app launch, so the charts have data when first opened).
    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        let env = AppEnvironment.shared
        let full = isPresented
        env.controller.perform { [weak self] w in
            let key = ObjectIdentifier(w)
            let tick = w.tick, tps = w.config.ticksPerSecond
            var pops: [(Int32, Int32)] = []
            for s in w.species where s.established { pops.append((s.id, Int32(s.population))) }
            var entries: [Int32: SpeciesEntry]?
            if full {
                let members = w.speciesMembers()
                var children: [Int32: [Int32]] = [:]
                for s in w.species where s.established && s.parentId >= 0 { children[s.parentId, default: []].append(s.id) }
                var map: [Int32: SpeciesEntry] = [:]
                for s in w.species where s.established {
                    map[s.id] = SpeciesEntry(info: SpeciesInfo(s), founder: s.founderGenes, members: members[s.id],
                                             children: children[s.id] ?? [])
                }
                entries = map
            }
            DispatchQueue.main.async {
                self?.apply(key: key, tick: tick, tps: tps, pops: pops, entries: entries)
            }
        }
    }

    private func apply(key: ObjectIdentifier, tick: Int64, tps: Float, pops: [(Int32, Int32)], entries: [Int32: SpeciesEntry]?) {
        if key != worldKey {
            // A different world was loaded: start over.
            worldKey = key
            history = [:]
            lastSampleTick = -1
            observedSince = tick
            jumpCursor = [:]
            portraits = [:]
            portraitFactory.clear()
            portraitEpoch += 1
            if detailId != nil { detailId = nil }
            self.entries = [:]
        }
        self.tick = tick
        ticksPerSecond = tps
        if tick != lastSampleTick {
            lastSampleTick = tick
            for (id, p) in pops {
                var h = history[id] ?? []
                // Extinct species: keep a single closing zero.
                if p == 0 && (h.isEmpty || h.last!.population == 0) { continue }
                h.append(PopulationPoint(tick: tick, population: p))
                if h.count > Self.maxSamples {
                    // Thin the older half; keep recent samples at full resolution.
                    let keepRecent = Self.maxSamples / 3
                    var thinned: [PopulationPoint] = []
                    thinned.reserveCapacity(h.count)
                    let cut = h.count - keepRecent
                    for (n, pt) in h.enumerated() where n >= cut || n % 2 == 0 { thinned.append(pt) }
                    h = thinned
                }
                history[id] = h
            }
            historyVersion += 1
        }
        if let e = entries { self.entries = e }
    }

    // MARK: Opening

    func open(species id: Int32? = nil) {
        let env = AppEnvironment.shared
        detailId = id
        guard !isPresented else { return }
        isPresented = true
        if let v = env.model.renderer?.view {
            wasRenderingPaused = v.isPaused
            // The page is opaque, so the world need not be drawn behind it.
            v.isPaused = true
        }
        refresh()
    }

    func close() {
        guard isPresented else { return }
        isPresented = false
        detailId = nil
        AppEnvironment.shared.model.renderer?.view?.isPaused = wasRenderingPaused
    }

    func toggle() { isPresented ? close() : open() }

    func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.keyCode == 53 {   // escape: detail → list → world
            if detailId != nil {
                withAnimation(.easeOut(duration: 0.2)) { detailId = nil }
            } else {
                close()
            }
            return true
        }
        return false
    }

    // MARK: Lists

    func sortedEntries() -> [SpeciesEntry] {
        var list = Array(entries.values)
        switch filter {
        case .all: break
        case .alive: list = list.filter { $0.info.isAlive }
        case .extinct: list = list.filter { !$0.info.isAlive }
        }
        switch sort {
        case .population:
            list.sort {
                if $0.info.population != $1.info.population { return $0.info.population > $1.info.population }
                if $0.info.peakPopulation != $1.info.peakPopulation { return $0.info.peakPopulation > $1.info.peakPopulation }
                return $0.id < $1.id
            }
        case .birth:
            list.sort { $0.info.birthTick != $1.info.birthTick ? $0.info.birthTick < $1.info.birthTick : $0.id < $1.id }
        case .diet:
            // Carnivores first: they are the rarer and more striking ones.
            list.sort { $0.info.meanDiet != $1.info.meanDiet ? $0.info.meanDiet > $1.info.meanDiet : $0.id < $1.id }
        }
        return list
    }

    /// Ancestors from the primordial species down to (excluding) `id`, via `World.lineage(of:)`.
    func lineage(of id: Int32, completion: @escaping ([SpeciesInfo]) -> Void) {
        AppEnvironment.shared.controller.perform { w in
            let chain = w.lineage(of: id).map(SpeciesInfo.init)
            let founders = Dictionary(uniqueKeysWithValues: w.lineage(of: id).map { ($0.id, $0.founderGenes) })
            DispatchQueue.main.async {
                for (sid, g) in founders where self.lineageFounders[sid] == nil { self.lineageFounders[sid] = g }
                completion(chain)
            }
        }
    }

    /// Founder genes of ancestors that never became established (not in `entries`).
    @ObservationIgnored var lineageFounders: [Int32: Genes] = [:]

    func founder(of id: Int32) -> Genes? { entries[id]?.founder ?? lineageFounders[id] }

    /// Number of established species descended from `id` (children, grandchildren, ...).
    func descendantCount(of id: Int32) -> Int {
        var n = 0
        var stack = entries[id]?.children ?? []
        while let s = stack.popLast() {
            n += 1
            stack += entries[s]?.children ?? []
        }
        return n
    }

    // MARK: Actions

    /// Closes the page and follows a living member of the species (a different one on each call).
    func jumpToMember(of id: Int32) {
        let env = AppEnvironment.shared
        let model = env.model
        env.controller.perform { [weak self] w in
            let uids = w.members(ofSpecies: id)
            DispatchQueue.main.async {
                guard let self else { return }
                guard !uids.isEmpty else { model.showToast("この種の個体はもういない"); return }
                let k = (self.jumpCursor[id] ?? 0) % uids.count
                self.jumpCursor[id] = k + 1
                self.close()
                model.select(uids[k])
                model.following = true
                if let r = model.renderer, r.camera.targetZoom < 2.5 * r.camera.pixelRatio {
                    r.camera.targetZoom = 3 * r.camera.pixelRatio
                }
                let name = self.entries[id]?.info.name ?? "この種"
                model.showToast("「\(name)」の個体を追尾中(\(k + 1) / \(uids.count)匹目)")
            }
        }
    }

    func revive(_ id: Int32) {
        guard let info = entries[id]?.info else { return }
        close()
        GodActions.revive(info, AppEnvironment.shared.model)
    }

    // MARK: Portraits

    enum PortraitKind: String { case founder = "f", living = "m" }

    /// Portrait sizes in pixels. Views show them at exactly this aspect ratio (no cropping).
    static let smallSize = (560, 340)
    static let largeSize = (1936, 744)
    static var smallAspect: CGFloat { CGFloat(smallSize.0) / CGFloat(smallSize.1) }
    static var largeAspect: CGFloat { CGFloat(largeSize.0) / CGFloat(largeSize.1) }

    /// The cached portrait, or nil while it is being drawn (it then appears by itself).
    func portrait(_ id: Int32, _ kind: PortraitKind, large: Bool, extinct: Bool = false) -> CGImage? {
        let key = "\(kind.rawValue)\(large ? "L" : "S")\(extinct ? "x" : "")\(id)"
        if let img = portraits[key] { return img }
        let genes: Genes?
        switch kind {
        case .founder: genes = founder(of: id)
        case .living: genes = entries[id]?.members?.meanGenes
        }
        guard let g = genes else { return nil }
        let size = large ? Self.largeSize : Self.smallSize
        // Living portraits follow the population as it evolves; founders never change.
        let cacheable = kind == .founder
        let epoch = portraitEpoch
        portraitFactory.request(key: key, genes: g, seed: UInt64(id) &* 0x9E37_79B9 &+ 17, width: size.0, height: size.1,
                                desaturate: extinct) { [weak self] img in
            guard let self, let img, epoch == self.portraitEpoch else { return }
            self.portraits[key] = img
            if !cacheable {
                // Redraw the living look again later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, epoch == self.portraitEpoch else { return }
                    self.portraits[key] = nil
                    self.portraitFactory.forget(key)
                }
            }
        }
        return nil
    }
}

/// Draws species portraits off the main thread with the same shaders as the creature card.
final class PortraitFactory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hakoniwa.portraits", qos: .userInitiated)
    private var renderer: CreaturePortraitRenderer?
    private var failed = false
    /// Main thread only.
    private var pending = Set<String>()
    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    func clear() { pending.removeAll() }
    func forget(_ key: String) { pending.remove(key) }

    func request(key: String, genes: Genes, seed: UInt64, width: Int, height: Int, desaturate: Bool,
                 completion: @escaping (CGImage?) -> Void) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        queue.async { [self] in
            if renderer == nil && !failed {
                if let d = MTLCreateSystemDefaultDevice(), let r = CreaturePortraitRenderer(device: d) { renderer = r } else { failed = true }
            }
            let d = CreatureDetail.portraitStandIn(genes: genes, seed: seed)
            var img = renderer?.render(d, width: width, height: height)
            if desaturate, let src = img {
                let f = CIFilter(name: "CIColorControls")
                f?.setValue(CIImage(cgImage: src), forKey: kCIInputImageKey)
                f?.setValue(0.12, forKey: kCIInputSaturationKey)
                // Faded, like an old specimen.
                let dim = CIFilter(name: "CIExposureAdjust")
                dim?.setValue(f?.outputImage, forKey: kCIInputImageKey)
                dim?.setValue(-0.7, forKey: kCIInputEVKey)
                if let out = dim?.outputImage, let cg = ci.createCGImage(out, from: out.extent) { img = cg }
            }
            DispatchQueue.main.async { completion(img) }
        }
    }
}
