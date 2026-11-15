import HakoniwaCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - Model

/// A creature the user has named or starred. Kept per world seed in UserDefaults (not in the world file).
struct Pet: Codable, Identifiable, Equatable {
    var uid: UInt64
    var name: String
    var favorite: Bool
    // Identity check: a uid only refers to this creature if the generation and species also match.
    var speciesId: Int32
    var generation: Int32
    var speciesName: String
    var hue: Float
    var saturation: Float
    var diet: Float
    var lastAge: Float = 0
    var offspring: Int32 = 0
    var kills: Int32 = 0
    var diedAtTick: Int64?
    var id: UInt64 { uid }

    var displayName: String { name.isEmpty ? "\(speciesName) #\(uid)" : name }
    var isNamed: Bool { !name.isEmpty }
    var color: Color { hueColor(hue, saturation) }
}

enum PetPresence { case unknown, alive, dead, absent }

/// The name tag of one creature on screen, in points from the top-left of the window.
struct NameTag: Identifiable, Equatable {
    var uid: UInt64
    var name: String
    var x: CGFloat
    var y: CGFloat
    var hue: Float
    var saturation: Float
    var selected: Bool
    var id: UInt64 { uid }
}

/// "ポチは第12世代で生涯を終えた" shown when a pet dies.
struct Memorial: Equatable {
    var id: Int
    var title: String
    var detail: String
    var hue: Float
    var saturation: Float
}

/// Names, favourites, name tags and the farewell notice. Main thread only.
@Observable
final class PetStore {
    static let shared = PetStore()

    private(set) var pets: [UInt64: Pet] = [:]
    private(set) var presence: [UInt64: PetPresence] = [:]
    private(set) var tags: [NameTag] = []
    var showFavorites = false
    private(set) var memorial: Memorial?

    @ObservationIgnored private var seed: UInt64?
    @ObservationIgnored private var worldKey: ObjectIdentifier?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var tagTimer: Timer?
    @ObservationIgnored private var memorialCount = 0
    @ObservationIgnored private var queryInFlight = false

    static let defaultsKey = "hakoniwa.pets.v1"

    var favorites: [Pet] {
        pets.values.filter { $0.favorite || $0.isNamed }.sorted {
            let a = presence[$0.uid] == .alive, b = presence[$1.uid] == .alive
            if a != b { return a }
            return $0.uid < $1.uid
        }
    }

    func pet(_ uid: UInt64) -> Pet? { pets[uid] }

    // MARK: Lifecycle

    func start() {
        guard statusTimer == nil else { return }
        let s = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(s, forMode: .common)
        statusTimer = s
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.updateTags() }
        RunLoop.main.add(t, forMode: .common)
        tagTimer = t
        poll()
    }

    /// Asks the simulation thread where the pets are and whether they still live.
    private func poll() {
        guard !queryInFlight else { return }
        queryInFlight = true
        let uids = Set(pets.keys)
        AppEnvironment.shared.controller.perform { [weak self] w in
            let key = ObjectIdentifier(w), seed = w.seed, tick = w.tick
            let st = w.status(of: uids)
            DispatchQueue.main.async { self?.apply(key: key, seed: seed, tick: tick, asked: uids, status: st) }
        }
    }

    private func apply(key: ObjectIdentifier, seed: UInt64, tick: Int64, asked: Set<UInt64>, status: [UInt64: CreatureStatus]) {
        queryInFlight = false
        if key != worldKey {
            // Another world: load its pets; everything is re-checked without farewell notices.
            worldKey = key
            if seed != self.seed {
                self.seed = seed
                pets = Self.load(seed: seed)
            }
            presence = [:]
            poll()
            return
        }
        for uid in asked {
            guard var p = pets[uid] else { continue }
            let was = presence[uid] ?? .unknown
            if let s = status[uid], s.generation == p.generation, s.speciesId == p.speciesId {
                p.lastAge = s.age
                p.offspring = s.offspring
                p.kills = s.kills
                if p.diedAtTick != nil { p.diedAtTick = nil }
                pets[uid] = p
                if was != .alive { presence[uid] = .alive }
            } else if was == .alive {
                p.diedAtTick = tick
                pets[uid] = p
                presence[uid] = .dead
                save()
                farewell(p)
            } else if was == .unknown {
                presence[uid] = p.diedAtTick != nil ? .dead : .absent
            }
        }
    }

    private func farewell(_ p: Pet) {
        memorialCount += 1
        let id = memorialCount
        let life = formatSpan(Double(p.lastAge))
        var parts = ["生涯 \(life)"]
        if p.offspring > 0 { parts.append("子 \(p.offspring)匹") }
        if p.kills > 0 { parts.append("捕食 \(p.kills)回") }
        if AppEnvironment.shared.options.screenshot != nil { print("farewell \(p.displayName) gen \(p.generation)"); fflush(stdout) }
        memorial = Memorial(id: id, title: "\(p.displayName)は第\(p.generation)世代で生涯を終えた",
                            detail: "「\(p.speciesName)」・ " + parts.joined(separator: " ・ "),
                            hue: p.hue, saturation: p.saturation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.memorial?.id == id { self?.memorial = nil }
        }
    }

    // MARK: Editing

    /// Names (or renames) the creature shown in `d`. An empty name keeps it only if starred.
    func setName(_ raw: String, for d: CreatureDetail) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
        var p = pets[d.uid] ?? Pet(uid: d.uid, name: "", favorite: false, speciesId: d.speciesId, generation: d.generation,
                                   speciesName: d.speciesName, hue: d.genes.hue, saturation: d.genes.saturation, diet: d.genes.diet)
        if pets[d.uid] == nil && name.isEmpty { return }
        guard p.name != name || pets[d.uid] == nil else { return }
        let wasNamed = p.isNamed
        p.name = name
        if !name.isEmpty { p.favorite = true }
        if name.isEmpty && !p.favorite {
            pets[d.uid] = nil
            presence[d.uid] = nil
        } else {
            p.lastAge = d.age
            pets[d.uid] = p
            presence[d.uid] = .alive
        }
        save()
        updateTags()
        if !name.isEmpty {
            AppEnvironment.shared.model.showToast(wasNamed ? "名前を「\(name)」に変えた" : "「\(name)」と名付けた。お気に入りに入れた")
        }
    }

    func toggleFavorite(_ d: CreatureDetail) {
        if var p = pets[d.uid] {
            p.favorite.toggle()
            if !p.favorite && !p.isNamed { pets[d.uid] = nil; presence[d.uid] = nil } else { pets[d.uid] = p }
        } else {
            pets[d.uid] = Pet(uid: d.uid, name: "", favorite: true, speciesId: d.speciesId, generation: d.generation,
                              speciesName: d.speciesName, hue: d.genes.hue, saturation: d.genes.saturation, diet: d.genes.diet,
                              lastAge: d.age)
            presence[d.uid] = .alive
        }
        save()
    }

    func isFavorite(_ uid: UInt64) -> Bool { pets[uid].map { $0.favorite || $0.isNamed } ?? false }

    func remove(_ uid: UInt64) {
        pets[uid] = nil
        presence[uid] = nil
        save()
        updateTags()
    }

    func follow(_ uid: UInt64) {
        let model = AppEnvironment.shared.model
        guard presence[uid] == .alive else { return }
        model.select(uid)
        model.following = true
        model.showInspector = true
        if let r = model.renderer, r.camera.targetZoom < 2 * r.camera.pixelRatio { r.camera.targetZoom = 2.6 * r.camera.pixelRatio }
    }

    // MARK: Persistence (per world seed)

    private static func loadAll() -> [String: [Pet]] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let all = try? JSONDecoder().decode([String: [Pet]].self, from: data) else { return [:] }
        return all
    }

    private static func load(seed: UInt64) -> [UInt64: Pet] {
        var out: [UInt64: Pet] = [:]
        for p in loadAll()["\(seed)"] ?? [] { out[p.uid] = p }
        return out
    }

    private func save() {
        guard let seed else { return }
        var all = Self.loadAll()
        all["\(seed)"] = pets.isEmpty ? nil : Array(pets.values).sorted { $0.uid < $1.uid }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Name tags

    /// Places the tags over the named creatures that are on screen (60 Hz, from the latest snapshot).
    private func updateTags() {
        let env = AppEnvironment.shared
        let named = pets.values.filter { $0.isNamed && presence[$0.uid] == .alive }
        guard !named.isEmpty, let r = env.model.renderer else {
            if !tags.isEmpty { tags = [] }
            return
        }
        let cam = r.camera
        let ratio = CGFloat(max(cam.pixelRatio, 1))
        let byUid = Dictionary(uniqueKeysWithValues: named.map { ($0.uid, $0) })
        let controller = env.controller
        let speed = controller.speed, paused = controller.paused
        let now = CACurrentMediaTime()
        let selected = env.model.selectedUid
        var out: [NameTag] = []
        controller.withFront { snap in
            var extrap: Float = 0
            if !paused && (speed == .x1 || speed == .x4) {
                extrap = Float(min((now - controller.publishTime) * speed.multiplier, 1.2 / Double(snap.ticksPerSecond)))
            }
            for (k, u) in snap.uids.enumerated() {
                guard let p = byUid[u] else { continue }
                let c = snap.creatures[k]
                // Centre of the body (the position is the head), as the selection ring does.
                let isEgg = c.flags.truncatingRemainder(dividingBy: 2) >= 1
                let segs = 2 + min(Float(Int(c.segments * 5)), 4)
                let bodyLen = (segs - 1) * (0.82 + 0.13 * c.diet)
                let back = isEgg ? 0 : (bodyLen * 0.5 + 0.2) * c.radius
                let reach = isEgg ? c.radius * 1.3 : c.radius * (1 + bodyLen * 0.5)
                let world = c.position + c.velocity * extrap - V2(cos(c.heading), sin(c.heading)) * back
                let px = cam.pixel(world: world)
                let x = CGFloat(px.x) / ratio
                let y = CGFloat(px.y - reach * cam.zoom) / ratio - 17
                let vw = CGFloat(cam.viewSize.x) / ratio, vh = CGFloat(cam.viewSize.y) / ratio
                guard x > -80, x < vw + 80, y > -30, y < vh + 30 else { continue }
                out.append(NameTag(uid: u, name: p.name, x: x, y: y, hue: p.hue, saturation: p.saturation, selected: u == selected))
            }
        }
        out.sort { $0.uid < $1.uid }
        if out != tags { tags = out }
    }
}

// MARK: - Views

/// Name labels over named creatures. Sits between the world and the panels.
struct NameTagLayer: View {
    var store = PetStore.shared
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.tags) { t in
                NameTagView(tag: t)
                    .position(x: t.x, y: t.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct NameTagView: View {
    let tag: NameTag
    var body: some View {
        let c = hueColor(tag.hue, tag.saturation)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.system(size: 7.5, weight: .bold)).foregroundStyle(c)
                Text(tag.name)
                    .font(.system(size: tag.selected ? 12 : 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(Color.black.opacity(tag.selected ? 0.7 : 0.55)))
            .overlay(Capsule().strokeBorder(c.opacity(tag.selected ? 0.95 : 0.6), lineWidth: tag.selected ? 1.3 : 1))
            .shadow(color: c.opacity(0.5), radius: 5)
            Triangle().fill(c.opacity(tag.selected ? 0.95 : 0.6)).frame(width: 7, height: 4)
        }
        .fixedSize()
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// Favourites panel and the farewell notice. Sits above the panels.
struct PetOverlay: View {
    var model: AppModel
    var store = PetStore.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if store.showFavorites && model.showPanels {
                FavoritesPanel(model: model, store: store)
                    .padding(.leading, 72)
                    .padding(.top, 92)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack {
                if let m = store.memorial {
                    MemorialView(memorial: m)
                        .id(m.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 136)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.showFavorites)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.memorial)
    }
}

struct MemorialView: View {
    let memorial: Memorial
    var body: some View {
        let c = hueColor(memorial.hue, memorial.saturation)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(c.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "leaf.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(c.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(memorial.title).font(.system(size: 14, weight: .bold, design: .rounded))
                Text(memorial.detail).font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textDim)
            }
        }
        .padding(.leading, 12).padding(.trailing, 20).padding(.vertical, 10)
        .glass(22)
        .shadow(color: c.opacity(0.25), radius: 16)
    }
}

struct FavoritesPanel: View {
    var model: AppModel
    var store: PetStore

    var body: some View {
        let list = store.favorites
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "star.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(EncyclopediaPalette.gold)
                Text("お気に入り").font(.system(size: 14, weight: .bold, design: .rounded))
                Text("\(list.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.textFaint)
                Spacer()
                Button { store.showFavorites = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("閉じる")
            }
            if list.isEmpty {
                Text("個体を選び、右のパネルで名前を付けるか ☆ を押すと、ここに並びます。")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(list) { p in row(p) }
                    }
                }
                .frame(height: min(CGFloat(list.count) * 48, 360))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(12)
        .frame(width: 270)
        .glass(16)
    }

    private func row(_ p: Pet) -> some View {
        let state = store.presence[p.uid] ?? .unknown
        let alive = state == .alive
        let selected = model.selectedUid == p.uid
        return HStack(spacing: 9) {
            ZStack {
                Circle().fill(p.color.opacity(alive ? 0.22 : 0.08)).frame(width: 26, height: 26)
                Circle().fill(alive ? p.color : Color.white.opacity(0.25)).frame(width: 10, height: 10)
                    .shadow(color: alive ? p.color : .clear, radius: 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(p.displayName).font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(alive ? .white : .white.opacity(0.5)).lineLimit(1)
                    if p.isNamed { Image(systemName: "tag.fill").font(.system(size: 8)).foregroundStyle(p.color.opacity(alive ? 0.9 : 0.4)) }
                }
                Text(subtitle(p, state)).font(.system(size: 10, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            if alive {
                Image(systemName: selected && model.following ? "scope" : "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected && model.following ? Palette.accent : .white.opacity(0.7))
            } else {
                Button { store.remove(p.uid) } label: {
                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help("一覧から外す")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Palette.accent.opacity(0.12) : Color.white.opacity(0.03)))
        .contentShape(Rectangle())
        .onTapGesture { store.follow(p.uid) }
        .help(alive ? "選んで追尾する" : "")
    }

    private func subtitle(_ p: Pet, _ s: PetPresence) -> String {
        switch s {
        case .alive: return "\(p.speciesName) ・ 第\(p.generation)世代 ・ \(formatSpan(Double(p.lastAge)))"
        case .dead: return "第\(p.generation)世代で生涯を終えた(\(formatSpan(Double(p.lastAge))))"
        case .absent: return "この世界にはいない"
        case .unknown: return "\(p.speciesName) ・ 第\(p.generation)世代"
        }
    }
}

/// Name field and star in the inspector.
struct PetNameRow: View {
    var model: AppModel
    let detail: CreatureDetail
    var store = PetStore.shared
    @State private var text = ""
    @State private var editingUid: UInt64 = 0
    @FocusState private var focused: Bool

    var body: some View {
        let fav = store.isFavorite(detail.uid)
        HStack(spacing: 8) {
            Image(systemName: "tag.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.pet(detail.uid)?.isNamed == true ? hueColor(detail.genes.hue, detail.genes.saturation) : Palette.textFaint)
            TextField("名前を付ける(例: ポチ)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if !f { commit() } }
            Button { store.toggleFavorite(detail) } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fav ? EncyclopediaPalette.gold : .white.opacity(0.6))
                    .frame(width: 26, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(fav ? "お気に入りから外す" : "お気に入りに入れる")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(focused ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? Palette.accent.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1))
        .onAppear { sync() }
        .onChange(of: detail.uid) { _, _ in sync() }
    }

    private func sync() {
        editingUid = detail.uid
        text = store.pet(detail.uid)?.name ?? ""
    }

    private func commit() {
        guard editingUid == detail.uid else { sync(); return }
        store.setName(text, for: detail)
        text = store.pet(detail.uid)?.name ?? ""
    }
}
