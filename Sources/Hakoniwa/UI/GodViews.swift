import HakoniwaCore
import SwiftUI

enum GodColors {
    static let ice = Color(red: 0.62, green: 0.86, blue: 1.0)
    static let warm = Color(red: 1.0, green: 0.74, blue: 0.36)
    static let plague = Color(red: 0.62, green: 0.92, blue: 0.22)
    static let stone = Color(red: 0.86, green: 0.76, blue: 0.62)
}

extension ClimateKind {
    var color: Color {
        switch self {
        case .iceAge: return GodColors.ice
        case .bloom: return GodColors.warm
        case .normal: return .white
        }
    }
    var symbol: String {
        switch self {
        case .iceAge: return "snowflake"
        case .bloom: return "sun.max.fill"
        case .normal: return "cloud.sun"
        }
    }
}

/// Column of world-scale interventions under the tool palette.
struct GodPalette: View {
    @Bindable var model: AppModel
    private var god: GodModel { GodModel.shared }

    var body: some View {
        VStack(spacing: 4) {
            Text("神の手")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textFaint)
                .padding(.top, 2)
            button("square.split.2x1.fill", tint: GodColors.stone, help: "大陸を分断:世界を壁で二つに分ける") {
                GodActions.splitContinents(model)
            }
            button("square.dashed", tint: GodColors.stone, help: "壁を取り払う", enabled: god.wallCount > 0) {
                GodActions.clearWalls(model)
            }
            Divider().frame(width: 24).overlay(Palette.hairline)
            climateButton(.iceAge, help: "氷河期:\(Int(GodActions.climateMinutes))分間、植物が激減する")
            climateButton(.bloom, help: "温暖期:\(Int(GodActions.climateMinutes))分間、植物が豊かに茂る")
            button("microbe.fill", tint: GodColors.plague, help: "疫病:最も栄えている種を病が襲う", active: god.sickCount > 0) {
                GodActions.plague(model)
            }
        }
        .padding(5)
        .glass(14)
    }

    private func button(_ symbol: String, tint: Color, help: String, enabled: Bool = true, active: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 32)
                .foregroundStyle(enabled ? tint.opacity(active ? 1 : 0.9) : Color.white.opacity(0.25))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? tint.opacity(0.22) : Color.clear)
                )
                .symbolEffect(.pulse, isActive: active)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func climateButton(_ kind: ClimateKind, help: String) -> some View {
        let active = god.climate == kind
        return Button { GodActions.toggleClimate(kind, model) } label: {
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(kind.color.opacity(0.22))
                    Circle()
                        .trim(from: 0, to: god.climateProgress)
                        .stroke(kind.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 27, height: 27)
                        .shadow(color: kind.color.opacity(0.8), radius: 3)
                }
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kind.color.opacity(active ? 1 : 0.9))
            }
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "\(kind.label)を終わらせる" : help)
    }
}

/// Climate and plague status for the top bar.
struct ClimateStat: View {
    private var god: GodModel { GodModel.shared }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("気候").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
                if god.climate == .normal {
                    Text("平常").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: god.climate.symbol).font(.system(size: 11, weight: .bold))
                        Text(god.climate.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("残り \(formatCountdown(god.climateRemaining))")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(god.climate.color.opacity(0.75))
                    }
                    .foregroundStyle(god.climate.color)
                    .shadow(color: god.climate.color.opacity(0.6), radius: 4)
                }
            }
            if god.sickCount > 0 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("疫病").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
                    HStack(spacing: 4) {
                        Image(systemName: "microbe.fill").font(.system(size: 10.5, weight: .bold))
                        Text("感染 \(formatCount(god.sickCount))匹").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .foregroundStyle(GodColors.plague)
                    .shadow(color: GodColors.plague.opacity(0.5), radius: 4)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: god.sickCount > 0)
        .animation(.easeOut(duration: 0.25), value: god.climate)
    }
}

/// Extinction story and the revive button, shown under the species card in the tree.
struct ReviveSection: View {
    @Bindable var model: AppModel
    let species: SpeciesInfo

    var body: some View {
        let s = species
        let tps = Double(model.ticksPerSecond)
        let now = model.tick
        let ancestorAgo = Double(now - s.birthTick) / tps
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let ext = s.extinctTick {
                    Text("\(formatSpan(Double(now - ext) / tps))前に絶滅")
                        .foregroundStyle(Palette.carnivore.opacity(0.85))
                    Text("\(formatSpan(ancestorAgo))前の祖先")
                } else if let ext = GodModel.shared.revivedFrom[s.id] {
                    Text("\(formatSpan(Double(now - ext) / tps))前に絶滅し、蘇った")
                        .foregroundStyle(Palette.accent)
                    Text("\(formatSpan(ancestorAgo))前の祖先")
                }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textDim)
            .monospacedDigit()
            Button { GodActions.revive(s, model) } label: {
                HStack(spacing: 5) {
                    Image(systemName: s.isAlive ? "arrow.uturn.backward.circle.fill" : "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text(s.isAlive ? "祖先型を放つ" : "この種を蘇らせる")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(s.isAlive ? Color.white : Color.black)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(s.isAlive ? AnyShapeStyle(Color.white.opacity(0.1))
                                        : AnyShapeStyle(LinearGradient(colors: [s.color, Palette.accent],
                                                                       startPoint: .leading, endPoint: .trailing)))
                )
                .shadow(color: s.isAlive ? .clear : s.color.opacity(0.6), radius: 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(s.isAlive ? "この種の創始者を画面中央に放つ" : "絶滅したこの種の創始者を画面中央に蘇らせる")
        }
    }
}
