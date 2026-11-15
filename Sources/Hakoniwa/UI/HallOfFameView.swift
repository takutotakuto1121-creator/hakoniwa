import HakoniwaCore
import Observation
import SwiftUI

/// Top 10 creatures of all time per category, refreshed while the "英雄" tab is visible.
@Observable
final class HallOfFameStore {
    static let shared = HallOfFameStore()

    private(set) var lists: [FameKind: [FameEntry]] = [:]
    private(set) var loaded = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = false

    private init() {}

    /// Starts refreshing (called when the tab appears).
    func activate() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        AppEnvironment.shared.controller.perform { [weak self] w in
            var out: [FameKind: [FameEntry]] = [:]
            for k in FameKind.allCases { out[k] = w.hallOfFame(k) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.lists = out
                self.loaded = true
            }
        }
    }

    /// Selects and follows a living hero, if it is still alive.
    func follow(_ e: FameEntry) {
        let env = AppEnvironment.shared
        env.controller.perform { w in
            let alive = w.slot(of: e.uid) != nil
            DispatchQueue.main.async {
                let model = env.model
                guard alive else {
                    model.showToast("「\(e.speciesName)」の英雄はもうこの世にいない")
                    HallOfFameStore.shared.refresh()
                    return
                }
                model.select(e.uid)
                model.following = true
                if let r = model.renderer, r.camera.targetZoom < 3 * r.camera.pixelRatio {
                    r.camera.targetZoom = 4 * r.camera.pixelRatio
                }
            }
        }
    }
}

struct HallOfFameView: View {
    @Bindable var model: AppModel
    var store = HallOfFameStore.shared

    var body: some View {
        Group {
            if !store.loaded {
                placeholder("英雄たちの記録を集めています…")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(FameKind.allCases, id: \.rawValue) { kind in
                        FameColumn(kind: kind, entries: store.lists[kind] ?? [], selected: model.selectedUid,
                                   tps: model.ticksPerSecond, now: model.tick)
                    }
                }
            }
        }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
    }
}

private struct FameColumn: View {
    let kind: FameKind
    let entries: [FameEntry]
    let selected: UInt64
    let tps: Float
    let now: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text(subtitle).font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
            if entries.isEmpty {
                Text("まだ記録がない").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.uid) { rank, e in
                            FameRow(rank: rank + 1, entry: e, kind: kind, accent: accent, top: entries.first?.value ?? 1,
                                    selected: e.uid == selected, tps: tps, now: now)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private var title: String {
        switch kind {
        case .kills: return "最強の狩人"
        case .offspring: return "子だくさん"
        case .longevity: return "長寿の賢者"
        }
    }

    private var subtitle: String {
        switch kind {
        case .kills: return "仕留めた数"
        case .offspring: return "産んだ子の数"
        case .longevity: return "生きた時間"
        }
    }

    private var symbol: String {
        switch kind {
        case .kills: return "flame.fill"
        case .offspring: return "circle.hexagongrid.fill"
        case .longevity: return "hourglass"
        }
    }

    private var accent: Color {
        switch kind {
        case .kills: return Palette.carnivore
        case .offspring: return Palette.omnivore
        case .longevity: return Palette.accent
        }
    }
}

private struct FameRow: View {
    let rank: Int
    let entry: FameEntry
    let kind: FameKind
    let accent: Color
    let top: Float
    let selected: Bool
    let tps: Float
    let now: Int64
    @State private var hovering = false

    private var alive: Bool { entry.deathTick == nil }

    var body: some View {
        let body = hueColor(entry.hue, 0.8)
        HStack(spacing: 7) {
            rankBadge
            ZStack {
                Circle().fill(body.opacity(alive ? 0.25 : 0.1)).frame(width: 16, height: 16)
                Circle().fill(alive ? body : body.opacity(0.4)).frame(width: 8, height: 8)
                    .shadow(color: alive ? body : .clear, radius: 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(entry.speciesName)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(alive ? .white : Palette.textDim)
                        .lineLimit(1)
                    Circle().fill(Palette.diet(entry.diet)).frame(width: 4, height: 4)
                }
                Text(statusLine)
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(alive ? Palette.herbivore.opacity(0.85) : Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(valueText)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(alive ? accent : accent.opacity(0.55))
                Capsule().fill(accent.opacity(alive ? 0.7 : 0.3))
                    .frame(width: max(3, 46 * CGFloat(entry.value / max(top, 1e-3))), height: 2.5)
            }
            if alive {
                Image(systemName: selected ? "scope" : "location.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(selected ? Palette.accent : (hovering ? .white : Palette.textFaint))
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Palette.accent.opacity(0.14) : (hovering && alive ? Color.white.opacity(0.07) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if alive { HallOfFameStore.shared.follow(entry) } }
        .help(alive ? "クリックで追尾" : "すでに亡くなった個体")
    }

    @ViewBuilder private var rankBadge: some View {
        if rank <= 3 {
            let medal = [Color(red: 1.0, green: 0.82, blue: 0.3), Color(red: 0.8, green: 0.85, blue: 0.92),
                         Color(red: 0.85, green: 0.55, blue: 0.35)][rank - 1]
            ZStack {
                Circle().fill(medal.opacity(0.2)).frame(width: 17, height: 17)
                if rank == 1 {
                    Image(systemName: "crown.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(medal)
                } else {
                    Text("\(rank)").font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundStyle(medal)
                }
            }
        } else {
            Text("\(rank)").font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.textFaint).frame(width: 17)
        }
    }

    private var statusLine: String {
        let gen = "第\(entry.generation)世代"
        if let d = entry.deathTick {
            let ago = Double(max(now - d, 0)) / Double(tps)
            let when = ago < 60 ? "ついさっき" : (ago < 3600 ? "\(Int(ago) / 60)分前に" : "\(Int(ago) / 3600)時間\((Int(ago) % 3600) / 60)分前に")
            return "\(gen) ・ \(when)死亡"
        }
        return "\(gen) ・ 存命"
    }

    private var valueText: String {
        switch kind {
        case .kills: return "\(Int(entry.value))匹"
        case .offspring: return "\(Int(entry.value))匹"
        case .longevity: return formatSpan(Double(entry.value))
        }
    }
}

private func formatSpan(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)秒" }
    if s < 3600 { return "\(s / 60)分\(String(format: "%02d", s % 60))秒" }
    return "\(s / 3600)時間\(String(format: "%02d", (s % 3600) / 60))分"
}
