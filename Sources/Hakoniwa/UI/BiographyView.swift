import HakoniwaCore
import Observation
import SwiftUI

/// Follows the life story (`World.biography`) of the selected creature. The story stays on
/// screen after the creature dies, until another creature is selected.
@Observable
final class BiographyStore {
    static let shared = BiographyStore()

    struct Entry: Identifiable, Equatable {
        var id: Int
        var tick: Int64
        var text: String
    }

    /// What the story is about; kept after death.
    struct Subject: Equatable {
        var uid: UInt64
        var speciesName: String
        var generation: Int32
        var hue: Float
        var saturation: Float
        var diet: Float
        var isEgg: Bool
        /// Estimated birth tick (nil while still an egg).
        var birthTick: Int64?
    }

    private(set) var uid: UInt64 = 0
    private(set) var subject: Subject?
    private(set) var entries: [Entry] = []
    private(set) var alive = true

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var worldID = 0
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var signature: (count: Int, tick: Int64, text: String) = (0, 0, "")

    private init() {
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func reset() {
        uid = 0
        subject = nil
        entries = []
        alive = true
        signature = (0, 0, "")
    }

    private func poll() {
        let env = AppEnvironment.shared
        let model = env.model
        if model.worldID != worldID {
            worldID = model.worldID
            reset()
        }
        let sel = model.selectedUid
        if sel != 0 && sel != uid {
            reset()
            uid = sel
            env.controller.perform { w in w.watch(uid: sel) }
        }
        guard uid != 0 else { return }
        if let d = model.detail, d.uid == uid {
            let birth: Int64? = d.isEgg ? nil : model.tick - Int64(Double(d.age) * Double(model.ticksPerSecond))
            let s = Subject(uid: d.uid, speciesName: d.speciesName, generation: d.generation, hue: d.genes.hue,
                            saturation: d.genes.saturation, diet: d.genes.diet, isEgg: d.isEgg,
                            birthTick: subject?.birthTick ?? birth)
            if s != subject { subject = s }
        }
        guard !inFlight else { return }
        inFlight = true
        let want = uid, known = signature
        env.controller.perform { [weak self] w in
            let bio = w.biography
            let watching = w.watchUid == want
            let isAlive = w.slot(of: want) != nil
            let last = bio.last
            let sig = (bio.count, last?.tick ?? 0, last?.text ?? "")
            let changed = watching && (sig.0 != known.count || sig.1 != known.tick || sig.2 != known.text)
            let copy = changed ? bio.enumerated().map { Entry(id: $0.offset, tick: $0.element.tick, text: $0.element.text) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.uid == want, watching else { return }
                if let c = copy {
                    self.entries = c
                    self.signature = sig
                }
                if self.alive != isAlive { self.alive = isAlive }
            }
        }
    }
}

// MARK: - Presentation helpers

enum BioStyle {
    static func icon(_ text: String) -> (String, Color) {
        if text.hasPrefix("観察開始") { return ("eye.fill", Palette.accent) }
        if text.contains("仕留められた") || text.contains("命を落とした") || text.contains("食べられた") {
            return ("xmark.octagon.fill", Palette.carnivore)
        }
        if text.contains("力尽きた") { return ("moon.zzz.fill", Color(red: 0.6, green: 0.65, blue: 0.8)) }
        if text.contains("寿命を全う") { return ("sunset.fill", Color(red: 1.0, green: 0.72, blue: 0.45)) }
        if text.contains("疫病") { return ("allergens.fill", Color(red: 0.75, green: 0.55, blue: 1.0)) }
        if text.contains("神の手") { return ("hand.raised.fill", Palette.omnivore) }
        if text.contains("仕留めた") { return ("crown.fill", Color(red: 1.0, green: 0.8, blue: 0.3)) }
        if text.contains("襲いかかった") { return ("bolt.fill", Color(red: 1.0, green: 0.5, blue: 0.3)) }
        if text.contains("噛みつかれた") { return ("exclamationmark.triangle.fill", Palette.carnivore) }
        if text.contains("肉") { return ("fork.knife", Color(red: 1.0, green: 0.55, blue: 0.4)) }
        if text.contains("植物") { return ("leaf.fill", Palette.herbivore) }
        if text.contains("卵を産") { return ("circle.circle.fill", Color(red: 0.95, green: 0.85, blue: 0.55)) }
        if text.contains("孵った") { return ("sparkles", Color(red: 0.85, green: 0.95, blue: 1.0)) }
        return ("circle.fill", Palette.textDim)
    }

    static func isEnding(_ text: String) -> Bool { text.contains("生涯 ") }

    /// "生後12分" style label for an entry, when the birth time is known.
    static func ageLabel(_ tick: Int64, birth: Int64?, tps: Float) -> String? {
        guard let b = birth, tick >= b else { return nil }
        let s = Int(Double(tick - b) / Double(tps))
        if s < 60 { return "生後\(s)秒" }
        if s < 3600 { return "生後\(s / 60)分" }
        return "生後\(s / 3600)時間\((s % 3600) / 60)分"
    }
}

/// One line of the story: a glowing node on a thread, the time and the sentence.
private struct BioRow: View {
    let entry: BiographyStore.Entry
    let birth: Int64?
    let tps: Float
    let thread: Color
    let first: Bool
    let last: Bool
    let latest: Bool
    var compact = false

    var body: some View {
        let (sym, c) = BioStyle.icon(entry.text)
        let ending = BioStyle.isEnding(entry.text)
        let node: CGFloat = compact ? 18 : 22
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                ZStack {
                    Circle().fill(c.opacity(0.18)).frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                    Circle().strokeBorder(c.opacity(latest ? 0.9 : 0.4), lineWidth: 1).frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                    Image(systemName: sym).font(.system(size: compact ? 8.5 : 10, weight: .bold)).foregroundStyle(c)
                }
                .shadow(color: latest ? c.opacity(0.8) : .clear, radius: 6)
                .padding(.top, 1)
            }
            .frame(width: node)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(formatWorldTime(Double(entry.tick) / Double(tps)))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Palette.textFaint)
                    if let a = BioStyle.ageLabel(entry.tick, birth: birth, tps: tps) {
                        Text(a).font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(thread.opacity(0.8))
                    }
                }
                Text(entry.text)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: ending ? .bold : .medium, design: .rounded))
                    .foregroundStyle(ending ? c : .white.opacity(latest ? 1 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, compact ? 6 : 9)
            Spacer(minLength: 0)
        }
        .background(alignment: .topLeading) {
            // The thread of life joining the nodes; the background spans the full row height.
            VStack(spacing: 0) {
                Rectangle().fill(first ? Color.clear : thread.opacity(0.5)).frame(height: node / 2 + 1)
                Rectangle().fill(last ? Color.clear : thread.opacity(0.5))
            }
            .frame(width: 1.5)
            .padding(.leading, node / 2 - 0.75)
        }
    }
}

private func subjectColor(_ s: BiographyStore.Subject?) -> Color {
    guard let s else { return Palette.accent }
    return hueColor(s.hue, s.saturation)
}

// MARK: - Inspector section

/// The latest chapters of the selected creature's life, inside the inspector.
struct BiographySection: View {
    @Bindable var model: AppModel
    var store = BiographyStore.shared

    var body: some View {
        let mine = store.uid == model.selectedUid
        let entries = mine ? Array(store.entries.suffix(4)) : []
        let thread = subjectColor(store.subject)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "生涯の物語")
                Spacer()
                Button {
                    model.bottomTab = .story
                    model.showBottom = true
                } label: {
                    HStack(spacing: 3) {
                        Text(store.entries.count > 4 ? "全\(store.entries.count)章を読む" : "伝記を開く")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }
            if entries.isEmpty {
                Text("観察を始めています…").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { k, e in
                        BioRow(entry: e, birth: store.subject?.birthTick, tps: model.ticksPerSecond, thread: thread,
                               first: k == 0 && e.id == 0, last: k == entries.count - 1, latest: k == entries.count - 1, compact: true)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: entries.map(\.id))
            }
        }
    }
}

// MARK: - Bottom panel tab

/// The full life story of the watched creature, as a timeline next to a portrait card.
struct BiographyPanel: View {
    @Bindable var model: AppModel
    var store = BiographyStore.shared

    var body: some View {
        if store.uid == 0 {
            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill").font(.system(size: 22)).foregroundStyle(Palette.textFaint)
                Text("生き物をクリックすると、その一生の物語がここに綴られていきます")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 14) {
                portrait
                    .frame(width: 210)
                timeline
            }
        }
    }

    private var portrait: some View {
        let s = store.subject
        let c = subjectColor(s)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(c.opacity(store.alive ? 0.22 : 0.08)).frame(width: 40, height: 40)
                    Circle().fill(store.alive ? c : c.opacity(0.35)).frame(width: 16, height: 16)
                        .shadow(color: store.alive ? c : .clear, radius: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("「\(s?.speciesName ?? "—")」の一代記")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("第\(s?.generation ?? 0)世代 ・ 個体 #\(store.uid)")
                        .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textDim)
                }
            }
            HStack(spacing: 6) {
                if let s {
                    tag(s.diet < 0.35 ? "草食" : (s.diet < 0.65 ? "雑食" : "肉食"), Palette.diet(s.diet))
                }
                tag(store.alive ? "存命" : "故人", store.alive ? Palette.herbivore : Palette.textDim)
                Text("\(store.entries.count)章").font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 0)
            if store.alive && model.selectedUid != store.uid {
                Button {
                    model.select(store.uid)
                    model.following = true
                } label: {
                    Label("この個体に戻る", systemImage: "scope")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.opacity(0.18), lineWidth: 1))
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.18)))
            .foregroundStyle(c)
    }

    private var timeline: some View {
        let entries = store.entries
        let thread = subjectColor(store.subject)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { k, e in
                        BioRow(entry: e, birth: store.subject?.birthTick, tps: model.ticksPerSecond, thread: thread,
                               first: k == 0, last: k == entries.count - 1, latest: k == entries.count - 1)
                            .id(e.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.top, 2)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: entries.count)
            }
            .onAppear { if let l = entries.last { proxy.scrollTo(l.id, anchor: .bottom) } }
            .onChange(of: entries.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }
}
