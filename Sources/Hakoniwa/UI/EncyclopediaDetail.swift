import HakoniwaCore
import SwiftUI

/// One species, in depth: portrait, records, genes, ancestry and descendants.
struct SpeciesDetailPage: View {
    @Bindable var store: EncyclopediaStore
    let id: Int32
    /// `World.lineage(of:)`: this species first, the primordial ancestor last.
    @State private var lineage: [SpeciesInfo] = []

    private var entry: SpeciesEntry? { store.entries[id] }
    private var tps: Double { Double(store.ticksPerSecond) }

    var body: some View {
        VStack(spacing: 0) {
            navigation
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 14)
            if let e = entry {
                ScrollViewReader { scroller in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        hero(e)
                        HStack(alignment: .top, spacing: 16) {
                            populationPanel(e).frame(maxWidth: .infinity)
                            genesPanel(e).frame(width: 360)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            lineagePanel(e).frame(maxWidth: .infinity)
                            descendantsPanel(e).frame(maxWidth: .infinity)
                            looksPanel(e).frame(maxWidth: .infinity)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .onAppear {
                    // For automated screenshots of the lower panels.
                    guard EncyclopediaLaunch.flags.scrollToBottom else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scroller.scrollTo("bottom", anchor: .bottom) }
                }
                }
            } else {
                Spacer()
                Text("この種の記録が見つからない").foregroundStyle(Palette.textDim)
                Spacer()
            }
        }
        .onAppear { store.lineage(of: id) { lineage = $0 } }
    }

    // MARK: Navigation

    private var navigation: some View {
        HStack(spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.22)) { store.detailId = nil } } label: {
                Label("図鑑に戻る", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("一覧に戻る (Esc)")
            HStack(spacing: 6) {
                Image(systemName: "book.pages.fill").foregroundStyle(EncyclopediaPalette.gold)
                Text("種の図鑑").foregroundStyle(Palette.textDim)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textFaint)
                Text(entry?.info.name ?? "—")
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            Spacer()
            Button { store.close() } label: {
                Label("世界に戻る", systemImage: "xmark")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("図鑑を閉じる")
        }
    }

    // MARK: Hero

    private func hero(_ e: SpeciesEntry) -> some View {
        let info = e.info
        let tint = info.color
        return HStack(alignment: .top, spacing: 16) {
            SpeciesPortrait(store: store, id: id, large: true, extinct: !info.isAlive, tint: tint)
                .frame(maxWidth: .infinity)
                .aspectRatio(EncyclopediaStore.largeAspect, contentMode: .fit)
                .overlay {
                    LinearGradient(colors: [.clear, EncyclopediaPalette.background.opacity(0.9)],
                                   startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            EncyPill(text: info.dietLabel, color: Palette.diet(info.meanDiet))
                            if info.isAlive {
                                EncyPill(text: "生存中 \(formatCount(info.population))匹", color: Palette.herbivore)
                            } else {
                                EncyPill(text: "絶滅", color: Color.white.opacity(0.6))
                            }
                            if info.parentId < 0 { EncyPill(text: "原初の種", color: EncyclopediaPalette.gold) }
                        }
                        Text(info.name)
                            .font(.system(size: 46, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: info.isAlive ? tint.opacity(0.85) : .clear, radius: 18)
                        Text(subtitle(e))
                            .font(.system(size: 12.5, design: .rounded)).foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(22)
                }
                .overlay(alignment: .topTrailing) {
                    Text("創始者の姿")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                        .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [(info.isAlive ? tint : .white).opacity(0.45), .white.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile("食性", info.dietLabel, String(format: "平均 %.2f(0=草食, 1=肉食)", info.meanDiet), Palette.diet(info.meanDiet))
                    tile("平均サイズ", String(format: "%.2f", info.meanSize), String(format: "体の半径 約%.1f", 3.5 + 9.5 * info.meanSize), .white)
                    tile("誕生", formatWorldTime(Double(info.birthTick) / tps), "世界の時間", Palette.accent)
                    if let x = info.extinctTick {
                        tile("絶滅", formatWorldTime(Double(x) / tps), "\(formatSpan(Double(x - info.birthTick) / tps))続いた", Color.white.opacity(0.65))
                    } else {
                        tile("存続", formatSpan(store.seconds - Double(info.birthTick) / tps), "いまも続いている", Palette.herbivore)
                    }
                    tile("最大個体数", "\(formatCount(info.peakPopulation))匹", info.isAlive ? "いま \(formatCount(info.population))匹" : "最盛期", EncyclopediaPalette.gold)
                    tile("累計誕生", "\(formatCount(info.totalBorn))匹", "卵を含む", .white)
                    tile("最大世代", "第\(info.maxGeneration)世代", e.members.map { String(format: "現存の平均 第%.0f世代", $0.meanGeneration) } ?? "—", Palette.accent)
                    tile("子孫の種", "\(store.descendantCount(of: id))種", "直接の分岐 \(e.children.count)種", Color(red: 0.8, green: 0.7, blue: 1))
                }
                actions(e)
            }
            .frame(width: 400)
        }
    }

    private func subtitle(_ e: SpeciesEntry) -> String {
        let info = e.info
        let parent = info.parentId >= 0 ? (store.entries[info.parentId]?.info.name ?? lineage.dropFirst().first?.name) : nil
        let from = parent.map { "「\($0)」から分かれて" } ?? "世界のはじまりから"
        let when = formatWorldTime(Double(info.birthTick) / tps)
        if let x = info.extinctTick {
            return "\(when)に\(from)生まれ、\(formatWorldTime(Double(x) / tps))に姿を消した"
        }
        return "\(when)に\(from)生まれ、いまも\(formatCount(info.population))匹が生きている"
    }

    private func tile(_ label: String, _ value: String, _ sub: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textFaint)
            Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textDim).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.8))
    }

    private func actions(_ e: SpeciesEntry) -> some View {
        let alive = (e.members?.count ?? 0) > 0
        return VStack(spacing: 8) {
            Button { store.jumpToMember(of: id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "scope").font(.system(size: 14, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("現存の個体へジャンプ").font(.system(size: 13, weight: .bold, design: .rounded))
                        Text(alive ? "\(formatCount(e.members?.count ?? 0))匹のうち1匹を追尾する(押すたびに別の個体)" : "生きている個体がいない")
                            .font(.system(size: 10, design: .rounded)).opacity(0.7)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 46)
                .foregroundStyle(alive ? Color.black : .white.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(alive ? Palette.accent : Color.white.opacity(0.05)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!alive)
            Button { store.revive(id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: e.info.isAlive ? "arrow.uturn.backward.circle.fill" : "sparkles").font(.system(size: 14, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.info.isAlive ? "祖先型を放つ" : "この種を蘇らせる").font(.system(size: 13, weight: .bold, design: .rounded))
                        Text("創始者の遺伝子から\(GodActions.reviveCount)匹を画面の中央に").font(.system(size: 10, design: .rounded)).opacity(0.7)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 46)
                .foregroundStyle(EncyclopediaPalette.gold)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EncyclopediaPalette.gold.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EncyclopediaPalette.gold.opacity(0.4), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Panels

    private func panel<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: title)
                Spacer()
                if let t = trailing {
                    Text(t).font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textFaint)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(EncyclopediaPalette.card.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func populationPanel(_ e: SpeciesEntry) -> some View {
        panel("個体数の推移", trailing: "アプリが1秒ごとに記録(保存はされない)") {
            SpeciesPopulationChart(store: store, info: e.info)
                .frame(height: 252)
            LifespanBar(info: e.info, now: store.tick, tps: tps)
                .frame(height: 34)
        }
    }

    private func genesPanel(_ e: SpeciesEntry) -> some View {
        let tint = e.info.color
        return panel("創始者の遺伝子", trailing: e.members != nil ? "◆ = 現存個体の平均" : nil) {
            VStack(alignment: .leading, spacing: 5.5) {
                ForEach(0..<Genes.count, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text(Genes.names[i]).font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textDim)
                            .frame(width: 66, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                MeterBar(value: Double(e.founder.v[i]), color: geneColor(i, e, tint), height: 5)
                                if let m = e.members?.meanGenes.v[i] {
                                    Image(systemName: "diamond.fill").font(.system(size: 7))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black, radius: 1)
                                        .position(x: g.size.width * CGFloat(min(max(m, 0), 1)), y: g.size.height / 2)
                                }
                            }
                        }
                        .frame(height: 9)
                        Text(String(format: "%.2f", e.founder.v[i])).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Palette.textFaint).frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func geneColor(_ i: Int, _ e: SpeciesEntry, _ tint: Color) -> Color {
        switch i {
        case 1: return Palette.diet(e.founder.diet)
        case 2, 3: return hueColor(e.founder.hue, e.founder.saturation)
        default: return Palette.accent.opacity(0.85)
        }
    }

    private func lineagePanel(_ e: SpeciesEntry) -> some View {
        let chain = Array(lineage.reversed())   // primordial first
        return panel("祖先の系譜", trailing: chain.count > 1 ? "\(chain.count - 1)代さかのぼる" : nil) {
            if chain.isEmpty {
                Text("—").foregroundStyle(Palette.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { k, sp in
                        HStack(spacing: 10) {
                            VStack(spacing: 0) {
                                Rectangle().fill(k == 0 ? Color.clear : Palette.hairline.opacity(2)).frame(width: 1.5, height: 10)
                                Circle().fill(sp.isAlive ? sp.color : Color.white.opacity(0.3)).frame(width: 9, height: 9)
                                    .shadow(color: sp.isAlive ? sp.color : .clear, radius: 3)
                                Rectangle().fill(k == chain.count - 1 ? Color.clear : Palette.hairline.opacity(2)).frame(width: 1.5, height: 10)
                            }
                            SpeciesChip(store: store, info: sp, current: sp.id == id)
                        }
                    }
                }
            }
        }
    }

    private func descendantsPanel(_ e: SpeciesEntry) -> some View {
        let kids = e.children.compactMap { store.entries[$0]?.info }.sorted { $0.birthTick < $1.birthTick }
        return panel("子孫の種", trailing: kids.isEmpty ? nil : "直接 \(kids.count)種 ・ 全部で \(store.descendantCount(of: id))種") {
            if kids.isEmpty {
                Text(e.info.isAlive ? "まだ分かれた種はない" : "子孫の種は残さなかった")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(kids.prefix(8)) { sp in
                        SpeciesChip(store: store, info: sp, current: false,
                                    note: "\(formatWorldTime(Double(sp.birthTick) / tps))に分岐")
                    }
                    if kids.count > 8 {
                        Text("ほか \(kids.count - 8)種").font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.textFaint)
                    }
                }
            }
        }
    }

    private func looksPanel(_ e: SpeciesEntry) -> some View {
        panel("姿の移り変わり") {
            HStack(spacing: 8) {
                lookImage(.founder, "創始者", e)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.textFaint)
                if e.members != nil {
                    lookImage(.living, "現在の平均", e)
                } else {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03))
                            .overlay(Text("もういない").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textFaint))
                            .aspectRatio(EncyclopediaStore.smallAspect, contentMode: .fit)
                        Text("現在").font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.textFaint)
                    }
                }
            }
            if let m = e.members {
                Text(changeSummary(e.founder, m.meanGenes))
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func lookImage(_ kind: EncyclopediaStore.PortraitKind, _ label: String, _ e: SpeciesEntry) -> some View {
        VStack(spacing: 6) {
            SpeciesPortrait(store: store, id: id, kind: kind, extinct: kind == .founder && !e.info.isAlive, tint: e.info.color)
                .aspectRatio(EncyclopediaStore.smallAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            Text(label).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textDim)
        }
    }

    /// The two or three genes that changed most since the founder, in words.
    private func changeSummary(_ f: Genes, _ m: Genes) -> String {
        var diffs: [(Int, Float)] = []
        for i in 0..<Genes.count where i != 2 && i != 3 && i != 10 {
            diffs.append((i, m.v[i] - f.v[i]))
        }
        let top = diffs.filter { abs($0.1) >= 0.06 }.sorted { abs($0.1) > abs($1.1) }.prefix(3)
        if top.isEmpty { return "創始者からほとんど姿を変えていない。" }
        let words = top.map { i, d -> String in
            let name = Genes.names[i]
            switch i {
            case 1: return d > 0 ? "肉食寄りに" : "草食寄りに"
            default: return "\(name)が\(d > 0 ? "増した" : "減った")"
            }
        }
        return "創始者に比べて、" + words.joined(separator: "、") + "。"
    }
}

// MARK: - Pieces

/// A small clickable species row with a mini portrait.
struct SpeciesChip: View {
    var store: EncyclopediaStore
    /// Used for species that never became established (absent from the store's entries).
    let fallback: SpeciesInfo
    let current: Bool
    var note: String?
    @State private var hover = false

    init(store: EncyclopediaStore, info: SpeciesInfo, current: Bool, note: String? = nil) {
        self.store = store
        fallback = info
        self.current = current
        self.note = note
    }

    var body: some View {
        let known = store.entries[fallback.id] != nil
        // Prefer the live record so counts match the rest of the page.
        let info = store.entries[fallback.id]?.info ?? fallback
        HStack(spacing: 10) {
            SpeciesPortrait(store: store, id: info.id, extinct: !info.isAlive, tint: info.color)
                .frame(width: 70, height: 42.5)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.name).font(.system(size: 12.5, weight: current ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(info.isAlive ? .white : .white.opacity(0.6))
                    Text(info.dietLabel).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(Palette.diet(info.meanDiet))
                    if current { Text("この種").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Palette.accent) }
                }
                Text(note ?? (info.isAlive ? "生存中 \(formatCount(info.population))匹" : (known ? "絶滅" : "絶滅(定着しなかった種)")))
                    .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 0)
            if known && !current {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textFaint)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover && known && !current ? 0.07 : (current ? 0.05 : 0))))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            guard known, !current else { return }
            withAnimation(.easeOut(duration: 0.22)) { store.detailId = info.id }
        }
    }
}

/// Population of one species across its whole life. The part before the app started recording is marked.
struct SpeciesPopulationChart: View {
    var store: EncyclopediaStore
    let info: SpeciesInfo

    var body: some View {
        let _ = store.historyVersion
        let pts = store.history[info.id] ?? []
        let tps = Double(store.ticksPerSecond)
        let tint = info.isAlive ? info.color : Color.white.opacity(0.55)
        let start = info.birthTick
        let end = max(info.extinctTick ?? store.tick, start + 1)
        let peak = max(CGFloat(info.peakPopulation), CGFloat(pts.map(\.population).max() ?? 0), 1)
        let observedFrom = max(store.observedSince, start)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height - 16
            let xOf = { (t: Int64) -> CGFloat in CGFloat(t - start) / CGFloat(end - start) * w }
            let yOf = { (p: CGFloat) -> CGFloat in h - p / peak * (h - 14) }
            ZStack(alignment: .topLeading) {
                // Grid
                Path { p in
                    for k in 0...3 {
                        let y = h - CGFloat(k) / 3 * (h - 14)
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                // Before recording began
                if observedFrom > start {
                    let x1 = min(xOf(observedFrom), w)
                    Rectangle()
                        .fill(Color.white.opacity(0.025))
                        .frame(width: x1, height: h)
                        .overlay(
                            Text(x1 > 120 ? "記録を始める前" : "")
                                .font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textFaint)
                        )
                    Path { p in p.move(to: CGPoint(x: x1, y: 0)); p.addLine(to: CGPoint(x: x1, y: h)) }
                        .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                // Peak (exact, from the world's records)
                let py = yOf(CGFloat(info.peakPopulation))
                Path { p in p.move(to: CGPoint(x: 0, y: py)); p.addLine(to: CGPoint(x: w, y: py)) }
                    .stroke(EncyclopediaPalette.gold.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Text("最大 \(formatCount(info.peakPopulation))匹")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(EncyclopediaPalette.gold.opacity(0.8))
                    .offset(x: 4, y: max(py - 14, 0))
                if pts.count >= 2 {
                    let line = Path { p in
                        for (k, pt) in pts.enumerated() {
                            let q = CGPoint(x: xOf(pt.tick), y: yOf(CGFloat(pt.population)))
                            if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
                        }
                    }
                    let area = Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: xOf(pts.last!.tick), y: h))
                        p.addLine(to: CGPoint(x: xOf(pts.first!.tick), y: h))
                        p.closeSubpath()
                    }
                    area.fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .shadow(color: tint.opacity(0.8), radius: 4)
                    if let last = pts.last, info.isAlive {
                        Circle().fill(tint).frame(width: 7, height: 7).shadow(color: tint, radius: 4)
                            .position(x: xOf(last.tick), y: yOf(CGFloat(last.population)))
                    }
                } else if observedFrom >= end {
                    Text("記録を始める前に絶滅したため、推移のデータはない")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textDim)
                        .frame(width: w, height: h)
                } else {
                    Text("記録を集めています…").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textDim)
                        .frame(width: w, height: h)
                }
                // Axis labels
                HStack {
                    Text(formatWorldTime(Double(start) / tps) + "(誕生)")
                    Spacer()
                    Text(info.extinctTick != nil ? formatWorldTime(Double(end) / tps) + "(絶滅)" : "いま")
                }
                .font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
                .frame(width: w)
                .offset(y: h + 3)
            }
        }
    }
}

/// Where the species' life falls within the whole history of the world (exact).
struct LifespanBar: View {
    let info: SpeciesInfo
    let now: Int64
    let tps: Double

    var body: some View {
        let total = max(Double(now), 1)
        let a = Double(info.birthTick) / total
        let b = Double(info.extinctTick ?? now) / total
        let tint = info.isAlive ? info.color : Color.white.opacity(0.5)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(g.size.width * (b - a), 4))
                        .offset(x: g.size.width * a)
                        .shadow(color: tint.opacity(0.6), radius: 3)
                }
            }
            .frame(height: 6)
            HStack {
                Text("世界のはじまり")
                Spacer()
                Text("この種がいた期間 \(formatSpan(Double((info.extinctTick ?? now) - info.birthTick) / tps))")
                    .foregroundStyle(Palette.textDim)
                Spacer()
                Text("いま(\(formatWorldTime(Double(now) / tps)))")
            }
            .font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
        }
    }
}
