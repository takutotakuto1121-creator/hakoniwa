import HakoniwaCore
import SwiftUI

/// Inspector row: switch for the field-of-view overlay, with a colour key and what each sector sees.
struct VisionToggleRow: View {
    @Bindable var model: AppModel
    let detail: CreatureDetail

    static let plant = Color(red: 0.36, green: 0.95, blue: 0.52)
    static let meat = Color(red: 1.0, green: 0.42, blue: 0.36)
    static let life = Color(red: 0.93, green: 0.96, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SectionTitle(text: "視界")
                Text(String(format: "%.0f° · 距離 %.0f", detail.phenotype.halfFov * 2 * 180 / .pi, detail.phenotype.viewDistance))
                    .font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
                Spacer()
                Toggle("", isOn: $model.showVision)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("選択中の個体の視野を世界の上に描く")
            }
            if model.showVision {
                HStack(spacing: 10) {
                    key(Self.plant, "植物")
                    key(Self.meat, "肉")
                    key(Self.life, "生き物")
                    Spacer()
                    sectorStrip
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.showVision)
    }

    private func key(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(c).frame(width: 9, height: 3).shadow(color: c.opacity(0.8), radius: 2)
            Text(s).font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textDim)
        }
    }

    /// Five small cells (left to right as the creature sees it) tinted by what each sector sees.
    private var sectorStrip: some View {
        HStack(spacing: 2) {
            ForEach(0..<Brain.sectors, id: \.self) { s in
                let b = s * Brain.perSector
                let p = Double(detail.inputs[b]), m = Double(detail.inputs[b + 1]), c = Double(detail.inputs[b + 2])
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        ZStack {
                            RoundedRectangle(cornerRadius: 2).fill(Self.plant.opacity(p * 0.9))
                            RoundedRectangle(cornerRadius: 2).fill(Self.meat.opacity(m * 0.9))
                            RoundedRectangle(cornerRadius: 2).fill(Self.life.opacity(c * 0.7))
                        }
                        .blendMode(.plusLighter)
                    )
                    .frame(width: 11, height: 8)
                    .help(Brain.sectorNames[s])
            }
        }
    }
}
