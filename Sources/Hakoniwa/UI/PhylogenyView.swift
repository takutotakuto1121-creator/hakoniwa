import HakoniwaCore
import SwiftUI

/// Phylogenetic tree: each species is a horizontal line from its birth to its extinction
/// (or now); children branch off their parent at their birth time.
struct PhylogenyView: View {
    @Bindable var model: AppModel
    @State private var livingOnly = true

    private struct Row {
        let species: SpeciesInfo
        let depth: Int
    }

    var body: some View {
        let rows = buildRows()
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $livingOnly) {
                    Text("生きている系統だけ").font(.system(size: 11, design: .rounded))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text("\(rows.count)種を表示").font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textFaint)
                if let id = model.selectedSpecies, let sp = model.speciesById[id] {
                    SpeciesCard(species: sp, tps: model.ticksPerSecond, now: model.tick)
                } else {
                    Text("線をクリックすると種の詳細を表示").font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 170)
            if rows.isEmpty {
                placeholder("まだ種が分岐していません")
            } else {
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        let rowH: CGFloat = rows.count > 60 ? 6 : (rows.count > 30 ? 9 : 13)
                        let height = max(geo.size.height, CGFloat(rows.count) * rowH + 20)
                        tree(rows: rows, size: CGSize(width: geo.size.width, height: height), rowH: rowH)
                            .frame(width: geo.size.width, height: height)
                    }
                }
            }
        }
    }

    private func buildRows() -> [Row] {
        var all = model.species
        var include = Set<Int32>()
        if livingOnly {
            for s in all where s.isAlive {
                var cur: Int32 = s.id
                while cur >= 0, let sp = model.speciesById[cur], !include.contains(cur) {
                    include.insert(cur)
                    cur = sp.parentId
                }
            }
            all = all.filter { include.contains($0.id) }
        } else {
            all = all.filter { $0.established || $0.isAlive }
        }
        var children: [Int32: [SpeciesInfo]] = [:]
        let ids = Set(all.map(\.id))
        var roots: [SpeciesInfo] = []
        for s in all {
            if s.parentId >= 0 && ids.contains(s.parentId) { children[s.parentId, default: []].append(s) } else { roots.append(s) }
        }
        var rows: [Row] = []
        func visit(_ s: SpeciesInfo, _ depth: Int) {
            rows.append(Row(species: s, depth: depth))
            for c in (children[s.id] ?? []).sorted(by: { $0.birthTick < $1.birthTick }) { visit(c, depth + 1) }
        }
        for r in roots.sorted(by: { $0.birthTick < $1.birthTick }) { visit(r, 0) }
        if rows.count > 600 { rows = Array(rows.prefix(600)) }
        return rows
    }

    private func tree(rows: [Row], size: CGSize, rowH: CGFloat) -> some View {
        let now = max(model.tick, 1)
        let left: CGFloat = 6, right: CGFloat = 120
        let w = size.width - left - right
        func x(_ tick: Int64) -> CGFloat { left + w * CGFloat(Double(tick) / Double(now)) }
        var rowOf: [Int32: Int] = [:]
        for (i, r) in rows.enumerated() { rowOf[r.species.id] = i }
        let highlight = Set(model.lineage.map(\.id))
        let selected = model.selectedSpecies
        return Canvas { ctx, _ in
            // Time grid.
            let tps = Double(model.ticksPerSecond)
            let totalSec = Double(now) / tps
            let stepSec: Double = totalSec > 4 * 3600 ? 3600 : (totalSec > 3600 ? 1800 : (totalSec > 600 ? 300 : 60))
            var t = stepSec
            while t < totalSec {
                let gx = x(Int64(t * tps))
                var p = Path(); p.move(to: CGPoint(x: gx, y: 0)); p.addLine(to: CGPoint(x: gx, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 1)
                ctx.draw(Text(axisLabel(t)).font(.system(size: 8, design: .rounded)).foregroundColor(.white.opacity(0.25)),
                         at: CGPoint(x: gx + 2, y: 2), anchor: .topLeading)
                t += stepSec
            }
            for (i, r) in rows.enumerated() {
                let s = r.species
                let y = 14 + CGFloat(i) * rowH
                let x0 = x(s.birthTick), x1 = x(s.extinctTick ?? now)
                let color = s.color
                let isHi = highlight.contains(s.id) || selected == s.id
                // Branch from the parent.
                if let pr = rowOf[s.parentId] {
                    let py = 14 + CGFloat(pr) * rowH
                    var b = Path()
                    b.move(to: CGPoint(x: x0, y: py))
                    b.addLine(to: CGPoint(x: x0, y: y))
                    ctx.stroke(b, with: .color(color.opacity(isHi ? 0.8 : 0.3)), lineWidth: isHi ? 1.4 : 0.8)
                }
                var line = Path()
                line.move(to: CGPoint(x: x0, y: y))
                line.addLine(to: CGPoint(x: max(x1, x0 + 1.5), y: y))
                if s.isAlive {
                    let lw = min(rowH * 0.7, 1.5 + CGFloat(log2(Double(max(s.population, 1)))) * 0.5)
                    var glow = ctx
                    glow.addFilter(.shadow(color: color.opacity(0.9), radius: isHi ? 5 : 2.5))
                    glow.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    if rowH >= 6 {
                        let label = Text("\(s.name) \(s.population)").font(.system(size: rowH >= 9 ? 9 : 7.5, weight: .medium, design: .rounded))
                            .foregroundColor(isHi ? .white : .white.opacity(0.7))
                        ctx.draw(label, at: CGPoint(x: x1 + 5, y: y), anchor: .leading)
                    }
                } else {
                    ctx.stroke(line, with: .color(color.opacity(isHi ? 0.8 : 0.35)), style: StrokeStyle(lineWidth: isHi ? 1.6 : 1, lineCap: .round))
                    var end = Path()
                    end.move(to: CGPoint(x: x1, y: y - 2)); end.addLine(to: CGPoint(x: x1, y: y + 2))
                    ctx.stroke(end, with: .color(.white.opacity(0.2)), lineWidth: 0.8)
                }
                if selected == s.id {
                    let r = CGRect(x: x0 - 3, y: y - rowH / 2, width: max(x1 - x0, 2) + 6, height: rowH)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white.opacity(0.5)), lineWidth: 0.8)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in
            let i = Int(((v.location.y - 14) / rowH).rounded())
            if i >= 0 && i < rows.count { model.selectedSpecies = rows[i].species.id }
        })
    }

    private func axisLabel(_ t: Double) -> String {
        let s = Int(t)
        if s >= 3600 { return "\(s / 3600)時間" + (s % 3600 != 0 ? "\((s % 3600) / 60)分" : "") }
        return "\(s / 60)分"
    }
}

private struct SpeciesCard: View {
    let species: SpeciesInfo
    let tps: Float
    let now: Int64

    var body: some View {
        let s = species
        let lived = Double((s.extinctTick ?? now) - s.birthTick) / Double(tps)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(s.color).frame(width: 9, height: 9).shadow(color: s.color, radius: 3)
                Text(s.name).font(.system(size: 13, weight: .bold, design: .rounded))
            }
            Text("\(s.dietLabel)・\(s.isAlive ? "生存中 \(s.population)匹" : "絶滅")")
                .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.diet(s.meanDiet))
            Group {
                Text("最大 \(s.peakPopulation)匹 ・ 累計 \(formatCount(s.totalBorn))匹")
                Text("誕生 \(formatWorldTime(Double(s.birthTick) / Double(tps)))")
                Text("存続 \(formatWorldTime(lived))")
                Text("最大世代 第\(s.maxGeneration)世代")
            }
            .font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textDim).monospacedDigit()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}
