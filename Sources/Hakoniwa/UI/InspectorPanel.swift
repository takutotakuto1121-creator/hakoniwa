import HakoniwaCore
import simd
import SwiftUI

struct InspectorPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        if let d = model.detail {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header(d)
                    vitals(d)
                    if !d.isEgg { VisionToggleRow(model: model, detail: d) }
                    brain(d)
                    genes(d)
                    lineage
                }
                .padding(14)
            }
            .frame(width: 340)
            .glass(18)
        }
    }

    private func header(_ d: CreatureDetail) -> some View {
        let color = hueColor(d.genes.hue, d.genes.saturation)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(color.opacity(0.25)).frame(width: 34, height: 34)
                    Circle().fill(color).frame(width: 14, height: 14).shadow(color: color, radius: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.speciesName).font(.system(size: 17, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        badge(dietLabel(d.genes.diet), Palette.diet(d.genes.diet))
                        Text("第\(d.generation)世代").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textDim)
                        if d.isEgg { badge("卵", Palette.accent) }
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    Button { model.following.toggle() } label: {
                        Image(systemName: model.following ? "scope" : "location")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.following ? Color.black : .white)
                            .frame(width: 28, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7).fill(model.following ? Palette.accent : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("追尾 (F)")
                    Button { model.select(nil) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 22)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("選択を解除 (Esc)")
                }
            }
            Text("個体 #\(d.uid)" + (d.parentUid != 0 ? "  ・ 親 #\(d.parentUid)" : "  ・ 原初の個体"))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textFaint)
        }
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.2)))
            .foregroundStyle(c)
    }

    private func dietLabel(_ d: Float) -> String { d < 0.35 ? "草食" : (d < 0.65 ? "雑食" : "肉食") }

    private func vitals(_ d: CreatureDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            vital("エネルギー", Double(d.energy / max(d.capacity, 1)), Palette.omnivore, String(format: "%.0f / %.0f", d.energy, d.capacity))
            vital("体力", Double(d.health / max(d.maxHealth, 1)), Palette.herbivore, String(format: "%.0f / %.0f", d.health, d.maxHealth))
            vital("年齢", Double(d.age / max(d.lifespan, 1)), Palette.accent, String(format: "%.0f秒 / 寿命%.0f秒", d.age, d.lifespan))
            HStack(spacing: 0) {
                Stat(label: "子", value: "\(d.offspring)匹")
                Spacer()
                Stat(label: "捕食", value: "\(d.kills)回", color: d.kills > 0 ? Palette.carnivore : .white)
                Spacer()
                Stat(label: "食べた量", value: String(format: "%.0f", d.eaten))
                Spacer()
                Stat(label: "速さ", value: String(format: "%.0f", simd_length(d.velocity)))
                Spacer()
                Stat(label: "結合", value: "\(d.brain.connections.count)本")
            }
            .padding(.top, 2)
        }
    }

    private func vital(_ label: String, _ v: Double, _ c: Color, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textDim)
                Spacer()
                Text(text).font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
            }
            MeterBar(value: v, color: c)
        }
    }

    private func brain(_ d: CreatureDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: "脳 — いま考えていること")
                Spacer()
                HStack(spacing: 6) {
                    legendDot(Color(red: 1, green: 0.62, blue: 0.25), "興奮")
                    legendDot(Color(red: 0.35, green: 0.7, blue: 1), "抑制")
                }
            }
            BrainView(detail: d)
                .frame(height: 370)
        }
    }

    private func legendDot(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(c).frame(width: 10, height: 3)
            Text(s).font(.system(size: 9.5)).foregroundStyle(Palette.textFaint)
        }
    }

    private func genes(_ d: CreatureDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "遺伝子")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 6) {
                ForEach(0..<Genes.count, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Genes.names[i]).font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textDim)
                            Spacer()
                            Text(String(format: "%.2f", d.genes.v[i])).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.textFaint)
                        }
                        MeterBar(value: Double(d.genes.v[i]), color: geneColor(i, d), height: 3.5)
                    }
                }
            }
        }
    }

    private func geneColor(_ i: Int, _ d: CreatureDetail) -> Color {
        switch i {
        case 1: return Palette.diet(d.genes.diet)
        case 2, 3: return hueColor(d.genes.hue, d.genes.saturation)
        default: return Palette.accent.opacity(0.85)
        }
    }

    private var lineage: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "祖先の種")
            if model.lineage.isEmpty {
                Text("—").foregroundStyle(Palette.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.lineage.enumerated()), id: \.element.id) { idx, sp in
                        HStack(spacing: 8) {
                            VStack(spacing: 0) {
                                Rectangle().fill(idx == 0 ? Color.clear : Palette.hairline).frame(width: 1, height: 6)
                                Circle().fill(sp.color).frame(width: 8, height: 8).shadow(color: sp.color, radius: sp.isAlive ? 3 : 0)
                                Rectangle().fill(idx == model.lineage.count - 1 ? Color.clear : Palette.hairline).frame(width: 1, height: 6)
                            }
                            Text(sp.name).font(.system(size: 11.5, weight: idx == 0 ? .bold : .regular, design: .rounded))
                                .foregroundStyle(sp.isAlive ? .white : Palette.textDim)
                            Text(sp.dietLabel).font(.system(size: 9.5)).foregroundStyle(Palette.diet(sp.meanDiet))
                            Spacer()
                            Text(sp.isAlive ? "\(sp.population)匹" : "絶滅")
                                .font(.system(size: 10, design: .rounded)).monospacedDigit()
                                .foregroundStyle(sp.isAlive ? Palette.textDim : Palette.textFaint)
                            Text(formatWorldTime(Double(sp.birthTick) / Double(model.ticksPerSecond)) + "〜")
                                .font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedSpecies = sp.id
                            model.bottomTab = .tree
                            model.showBottom = true
                        }
                    }
                }
            }
        }
    }
}
