import HakoniwaCore
import SwiftUI

// MARK: - Host

/// Placed in the main window's ZStack; shows the species encyclopedia when requested.
struct EncyclopediaHost: View {
    var store = EncyclopediaStore.shared
    var body: some View {
        ZStack {
            if store.isPresented {
                EncyclopediaPage(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.isPresented)
    }
}

enum EncyclopediaPalette {
    static let background = Color(red: 0.012, green: 0.022, blue: 0.035)
    static let card = Color(red: 0.035, green: 0.06, blue: 0.085)
    static let gold = Color(red: 1.0, green: 0.84, blue: 0.45)
}

struct EncyclopediaPage: View {
    @Bindable var store: EncyclopediaStore

    var body: some View {
        ZStack {
            background
            if let id = store.detailId {
                SpeciesDetailPage(store: store, id: id)
                    .id(id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            } else {
                SpeciesListPage(store: store)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: store.detailId)
    }

    private var background: some View {
        ZStack {
            EncyclopediaPalette.background
            RadialGradient(colors: [Color(red: 0.05, green: 0.14, blue: 0.17).opacity(0.85), .clear],
                           center: UnitPoint(x: 0.2, y: 0.0), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(red: 0.12, green: 0.06, blue: 0.16).opacity(0.5), .clear],
                           center: UnitPoint(x: 0.95, y: 1.0), startRadius: 0, endRadius: 800)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

// MARK: - Shared pieces

func dietName(_ d: Float) -> String { d < 0.35 ? "草食" : (d < 0.65 ? "雑食" : "肉食") }

struct EncyPill: View {
    let text: String
    let color: Color
    var filled = false
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(filled ? color.opacity(0.9) : Color.black.opacity(0.45)))
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.55), lineWidth: 0.8))
            .foregroundStyle(filled ? Color.black : color)
    }
}

/// A row of selectable capsules (used for sorting and filtering).
struct EncyChoice<T: Hashable & Identifiable>: View {
    let title: String
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textFaint)
            HStack(spacing: 2) {
                ForEach(options) { o in
                    let on = o == selection
                    Button { withAnimation(.easeOut(duration: 0.2)) { selection = o } } label: {
                        Text(label(o))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12).frame(height: 26)
                            .foregroundStyle(on ? Color.black : .white.opacity(0.8))
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Palette.accent : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }
}

/// A species portrait (founder or living look) that appears once drawn.
struct SpeciesPortrait: View {
    var store: EncyclopediaStore
    let id: Int32
    var kind: EncyclopediaStore.PortraitKind = .founder
    var large = false
    var extinct = false
    var tint: Color

    var body: some View {
        // Always exactly the offered size; the image fills it and is cropped.
        Color.clear.overlay {
            if let img = store.portrait(id, kind, large: large, extinct: extinct) {
                Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.09), Color(red: 0.015, green: 0.03, blue: 0.045)],
                                   startPoint: .top, endPoint: .bottom)
                    Circle().fill(tint.opacity(0.18)).frame(width: 46, height: 46).blur(radius: 10)
                    ProgressView().controlSize(.small).opacity(0.5)
                }
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.3), value: store.portraits.count)
    }
}

/// Population over time from the app's samples, drawn as a glowing area.
struct SpeciesSparkline: View {
    var store: EncyclopediaStore
    let info: SpeciesInfo
    var tint: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        let _ = store.historyVersion
        let pts = store.history[info.id] ?? []
        GeometryReader { g in
            if pts.count >= 2 {
                let t0 = pts.first!.tick, t1 = max(pts.last!.tick, t0 + 1)
                let peak = max(CGFloat(info.peakPopulation), CGFloat(pts.map(\.population).max() ?? 1), 1)
                let path = Path { p in
                    for (k, pt) in pts.enumerated() {
                        let x = CGFloat(pt.tick - t0) / CGFloat(t1 - t0) * g.size.width
                        let y = g.size.height - CGFloat(pt.population) / peak * (g.size.height - 2) - 1
                        if k == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                let area = Path { p in
                    p.addPath(path)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height))
                    p.closeSubpath()
                }
                ZStack {
                    area.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    path.stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .shadow(color: tint.opacity(0.7), radius: 3)
                }
            } else {
                HStack {
                    Spacer()
                    Text(info.isAlive ? "記録を集めています…" : "観測を始める前に絶滅")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textFaint)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                .background(
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: g.size.height - 0.5))
                        p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 0.5))
                    }
                    .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
            }
        }
    }
}

// MARK: - List

struct SpeciesListPage: View {
    @Bindable var store: EncyclopediaStore

    var body: some View {
        let all = store.entries.values
        let alive = all.filter { $0.info.isAlive }.count
        let list = store.sortedEntries()
        VStack(alignment: .leading, spacing: 16) {
            header(total: all.count, alive: alive)
            controls(shown: list.count)
            if store.entries.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("記録を読み込んでいます…").font(.system(size: 12)).foregroundStyle(Palette.textDim)
                    }
                    Spacer()
                }
                Spacer()
            } else if list.isEmpty {
                Spacer()
                Text(store.filter == .extinct ? "まだ絶滅した種はいない" : "該当する種がいない")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 330), spacing: 14)], spacing: 14) {
                        ForEach(list) { e in
                            SpeciesCardView(store: store, entry: e)
                                .onTapGesture { withAnimation(.easeOut(duration: 0.22)) { store.detailId = e.id } }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func header(total: Int, alive: Int) -> some View {
        HStack(alignment: .center, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [EncyclopediaPalette.gold.opacity(0.35), EncyclopediaPalette.gold.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 42, height: 42)
                    Image(systemName: "book.pages.fill").font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(EncyclopediaPalette.gold)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("種の図鑑").font(.system(size: 26, weight: .heavy, design: .rounded))
                    Text("この世界に生まれ、8匹以上に増えて定着したすべての種の記録")
                        .font(.system(size: 12)).foregroundStyle(Palette.textDim)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            summary("記録された種", "\(total)", .white)
            summary("生存中", "\(alive)", Palette.herbivore)
            summary("絶滅", "\(total - alive)", Color.white.opacity(0.5))
            summary("世界の時間", formatWorldTime(store.seconds), Palette.accent)
            closeButton
        }
    }

    private func summary(_ label: String, _ value: String, _ c: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
            Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(c)
        }
    }

    private var closeButton: some View {
        Button { store.close() } label: {
            Label("世界に戻る", systemImage: "xmark")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("図鑑を閉じる (Esc)")
    }

    private func controls(shown: Int) -> some View {
        HStack(spacing: 22) {
            EncyChoice(title: "並べ替え", options: EncyclopediaSort.allCases, selection: $store.sort) { $0.label }
            EncyChoice(title: "絞り込み", options: EncyclopediaFilter.allCases, selection: $store.filter) { $0.label }
            Spacer()
            HStack(spacing: 10) {
                legend("草食", Palette.herbivore)
                legend("雑食", Palette.omnivore)
                legend("肉食", Palette.carnivore)
            }
            Text("\(shown)種を表示").font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
        }
    }

    private func legend(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7).shadow(color: c, radius: 2)
            Text(s).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.textDim)
        }
    }
}

struct SpeciesCardView: View {
    var store: EncyclopediaStore
    let entry: SpeciesEntry
    @State private var hover = false

    private var info: SpeciesInfo { entry.info }
    private var tint: Color { info.color }
    private var tps: Double { Double(store.ticksPerSecond) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                SpeciesPortrait(store: store, id: info.id, extinct: !info.isAlive, tint: tint)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(EncyclopediaStore.smallAspect, contentMode: .fit)
                    .clipped()
                LinearGradient(colors: [.clear, EncyclopediaPalette.card.opacity(0.95)],
                               startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(info.isAlive ? .white : .white.opacity(0.7))
                        .shadow(color: info.isAlive ? tint.opacity(0.8) : .clear, radius: 8)
                        .lineLimit(1)
                    Text(info.parentId >= 0 ? "第\(info.maxGeneration)世代まで" : "原初の種 ・ 第\(info.maxGeneration)世代まで")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .overlay(alignment: .topLeading) {
                EncyPill(text: info.dietLabel, color: Palette.diet(info.meanDiet)).padding(8)
            }
            .overlay(alignment: .topTrailing) {
                statusPill.padding(8)
            }
            VStack(alignment: .leading, spacing: 8) {
                SpeciesSparkline(store: store, info: info, tint: info.isAlive ? tint : Color.white.opacity(0.45))
                    .frame(height: 30)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        cell("誕生", formatWorldTime(Double(info.birthTick) / tps))
                        if let e = info.extinctTick {
                            cell("絶滅", formatWorldTime(Double(e) / tps))
                        } else {
                            cell("存続", formatSpan(store.seconds - Double(info.birthTick) / tps))
                        }
                        cell("サイズ", String(format: "%.2f", info.meanSize))
                    }
                    GridRow {
                        cell("最大", "\(formatCount(info.peakPopulation))匹")
                        cell("累計誕生", "\(formatCount(info.totalBorn))匹")
                        cell("最大世代", "\(info.maxGeneration)")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 11)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(EncyclopediaPalette.card))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [(info.isAlive ? tint : Color.white).opacity(hover ? 0.75 : (info.isAlive ? 0.35 : 0.12)),
                                                      Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: hover ? 1.5 : 1)
        )
        .shadow(color: info.isAlive ? tint.opacity(hover ? 0.3 : 0.0) : .clear, radius: 14)
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help("「\(info.name)」の詳細")
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle().fill(info.isAlive ? Palette.herbivore : Color.white.opacity(0.4)).frame(width: 6, height: 6)
            Text(info.isAlive ? "\(formatCount(info.population))匹" : "絶滅")
                .font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .foregroundStyle(info.isAlive ? .white : .white.opacity(0.6))
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(info.isAlive ? 0.9 : 0.6)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
