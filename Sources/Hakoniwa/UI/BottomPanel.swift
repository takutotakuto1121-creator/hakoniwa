import Charts
import HakoniwaCore
import SwiftUI

struct BottomPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(BottomTab.allCases) { t in
                    Button { model.bottomTab = t } label: {
                        Text(t.label)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .foregroundStyle(model.bottomTab == t ? Color.black : .white.opacity(0.75))
                            .background(Capsule().fill(model.bottomTab == t ? Palette.accent : Color.white.opacity(0.06)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(summary).font(.system(size: 10.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
                Button { model.showBottom = false } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .help("閉じる (B)")
            }
            Group {
                switch model.bottomTab {
                case .population: PopulationChart(model: model)
                case .traits: TraitsView(model: model)
                case .tree: PhylogenyView(model: model)
                case .events: EventsList(model: model)
                case .story: BiographyPanel(model: model)
                case .heroes: HallOfFameView(model: model)
                }
            }
            .frame(height: 200)
        }
        .padding(12)
        .glass(18)
    }

    private var summary: String {
        "植物 \(formatCount(model.plants)) ・ 肉片 \(formatCount(model.meat)) ・ 記録 \(model.samples.count)点"
    }
}

/// Reduces a long series to at most `n` evenly spaced points.
func downsample<T>(_ a: [T], to n: Int) -> [T] {
    guard a.count > n, n > 1 else { return a }
    let step = Double(a.count - 1) / Double(n - 1)
    return (0..<n).map { a[Int((Double($0) * step).rounded())] }
}

private func axisTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 { return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60))" }
    if s >= 600 { return "\(s / 60)分" }
    return "\(s / 60):\(String(format: "%02d", s % 60))"
}

struct PopulationChart: View {
    var model: AppModel

    private struct Point: Identifiable {
        let id: Int
        let t: Double
        let group: String
        let value: Int
    }

    var body: some View {
        let tps = Double(model.ticksPerSecond)
        let pts = downsample(model.samples, to: 360)
        let data: [Point] = pts.enumerated().flatMap { i, s -> [Point] in
            let t = Double(s.tick) / tps
            return [Point(id: i * 3, t: t, group: "草食", value: Int(s.herbivores)),
                    Point(id: i * 3 + 1, t: t, group: "雑食", value: Int(s.omnivores)),
                    Point(id: i * 3 + 2, t: t, group: "肉食", value: Int(s.carnivores))]
        }
        if data.isEmpty {
            placeholder("最初の記録を待っています…")
        } else {
            Chart(data) { p in
                AreaMark(x: .value("時間", p.t), y: .value("個体数", p.value), stacking: .standard)
                    .foregroundStyle(by: .value("食性", p.group))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["草食": Palette.herbivore.opacity(0.75), "雑食": Palette.omnivore.opacity(0.8), "肉食": Palette.carnivore.opacity(0.85)])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { v in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel { if let t = v.as(Double.self) { Text(axisTime(t)) } }
                        .foregroundStyle(Palette.textFaint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel().foregroundStyle(Palette.textFaint)
                }
            }
            .chartLegend(position: .top, alignment: .trailing, spacing: 4)
        }
    }
}

struct TraitsView: View {
    var model: AppModel

    private struct Trait: Identifiable {
        let id: String
        let title: String
        let unit: String
        let color: Color
        let value: (StatSample) -> Double
        let format: String
    }

    private var traits: [Trait] {
        [
            Trait(id: "meal", title: "餌を得る速さ", unit: "/秒", color: Palette.herbivore,
                  value: { Double($0.intakeRate) }, format: "%.1f"),
            Trait(id: "size", title: "体の大きさ", unit: "", color: Palette.accent, value: { Double($0.meanSize) }, format: "%.2f"),
            Trait(id: "speed", title: "速さ", unit: "", color: Color(red: 0.75, green: 0.6, blue: 1), value: { Double($0.meanSpeed) }, format: "%.2f"),
            Trait(id: "view", title: "視距離", unit: "", color: Color(red: 1, green: 0.75, blue: 0.5), value: { Double($0.meanViewDistance) }, format: "%.2f"),
            Trait(id: "brain", title: "脳の結合数", unit: "本", color: Color(red: 1, green: 0.55, blue: 0.75), value: { Double($0.meanConnections) }, format: "%.1f"),
            Trait(id: "gen", title: "平均世代", unit: "世代", color: Palette.omnivore, value: { Double($0.meanGeneration) }, format: "%.0f"),
        ]
    }

    var body: some View {
        let pts = downsample(model.samples, to: 200)
        if pts.count < 2 {
            placeholder("進化の記録を集めています…")
        } else {
            HStack(spacing: 10) {
                ForEach(traits) { tr in
                    TraitCard(title: tr.title, unit: tr.unit, color: tr.color, format: tr.format,
                              values: pts.map(tr.value), times: pts.map { Double($0.tick) / Double(model.ticksPerSecond) })
                }
            }
        }
    }
}

private struct TraitCard: View {
    let title: String
    let unit: String
    let color: Color
    let format: String
    let values: [Double]
    let times: [Double]

    var body: some View {
        let first = values.first ?? 0, last = values.last ?? 0
        let change = first != 0 ? (last - first) / abs(first) * 100 : 0
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textDim)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: format, last)).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(Palette.textFaint)
            }
            Text(unit == "世代" ? String(format: "+%.0f世代(はじめから)", last - first)
                 : String(format: "%@%.0f%%(はじめから)", change >= 0 ? "+" : "", change))
                .font(.system(size: 9.5, design: .rounded)).monospacedDigit()
                .foregroundStyle(change >= 0 ? color : Palette.textDim)
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", times[i]), y: .value("v", v))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", times[i]), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}

struct EventsList: View {
    var model: AppModel

    var body: some View {
        if model.events.isEmpty {
            placeholder("まだ何も起きていません")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.events.reversed()) { e in
                        HStack(spacing: 8) {
                            Image(systemName: icon(e.kind)).font(.system(size: 10)).foregroundStyle(color(e.kind)).frame(width: 14)
                            Text(formatWorldTime(Double(e.tick) / Double(model.ticksPerSecond)))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textFaint)
                                .frame(width: 84, alignment: .leading)
                            Text(e.message).font(.system(size: 11.5, design: .rounded))
                                .foregroundStyle(e.kind == .extinction ? Palette.textDim : .white)
                            Spacer()
                        }
                        .padding(.vertical, 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let s = e.speciesId { model.selectedSpecies = s; model.bottomTab = .tree }
                        }
                    }
                }
            }
        }
    }

    private func icon(_ k: EventKind) -> String {
        switch k {
        case .speciation: return "arrow.triangle.branch"
        case .extinction: return "xmark.circle"
        case .milestone: return "flag.fill"
        case .firstCarnivore: return "exclamationmark.triangle.fill"
        case .intervention: return "hand.point.up.left.fill"
        case .collapse: return "bolt.fill"
        }
    }

    private func color(_ k: EventKind) -> Color {
        switch k {
        case .speciation: return Palette.herbivore
        case .extinction: return Palette.textFaint
        case .milestone: return Palette.accent
        case .firstCarnivore: return Palette.carnivore
        case .intervention: return Palette.omnivore
        case .collapse: return Palette.carnivore
        }
    }
}

func placeholder(_ s: String) -> some View {
    Text(s).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.textFaint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
