import HakoniwaCore
import SwiftUI

struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Logo().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("箱庭").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("hakoniwa").font(.system(size: 8.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
                }
            }
            divider
            Stat(label: "世界の時間", value: formatWorldTime(model.worldSeconds))
            Stat(label: "最大世代", value: "第\(model.maxGeneration)世代")
            populationBlock
            Stat(label: "生きている種", value: "\(model.speciesAlive)種")
            Stat(label: "季節", value: model.seasonLabel, color: seasonColor)
            ClimateStat()
            Spacer(minLength: 8)
            rateLabel
            SoundControl()
            speedControl
            controlButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(16)
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(width: 1, height: 28)
    }

    private var seasonColor: Color {
        switch model.seasonLabel {
        case "夏": return Color(red: 1.0, green: 0.82, blue: 0.4)
        case "冬": return Color(red: 0.6, green: 0.8, blue: 1.0)
        case "春": return Color(red: 0.6, green: 1.0, blue: 0.7)
        default: return Color(red: 1.0, green: 0.65, blue: 0.45)
        }
    }

    private var populationBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("個体数").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
                legend("草", Palette.herbivore, model.herbivores)
                legend("雑", Palette.omnivore, model.omnivores)
                legend("肉", Palette.carnivore, model.carnivores)
            }
            HStack(spacing: 8) {
                Text(formatCount(model.population)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                proportionBar.frame(width: 96, height: 5)
                if model.eggs > 0 {
                    Text("卵 \(formatCount(model.eggs))").font(.system(size: 10, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Palette.textDim)
                }
            }
        }
    }

    private func legend(_ s: String, _ c: Color, _ n: Int) -> some View {
        HStack(spacing: 2) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text("\(s)\(n)").font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textDim)
        }
    }

    private var proportionBar: some View {
        GeometryReader { g in
            let total = max(Double(model.herbivores + model.omnivores + model.carnivores), 1)
            HStack(spacing: 1) {
                Capsule().fill(Palette.herbivore).frame(width: g.size.width * Double(model.herbivores) / total)
                Capsule().fill(Palette.omnivore).frame(width: g.size.width * Double(model.omnivores) / total)
                Capsule().fill(Palette.carnivore).frame(width: g.size.width * Double(model.carnivores) / total)
            }
        }
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .clipShape(Capsule())
    }

    private var rateLabel: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("進む速さ").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
            Text(model.paused ? "停止中" : String(format: "実時間の %.0f 倍", max(model.simRate, 0)))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(model.paused ? Palette.omnivore : .white.opacity(0.85))
        }
        .frame(width: 92, alignment: .trailing)
    }

    private var speedControl: some View {
        HStack(spacing: 2) {
            ForEach(SimSpeed.allCases) { s in
                Button {
                    model.speed = s
                    model.paused = false
                } label: {
                    Text(s.label)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .frame(minWidth: 34, minHeight: 24)
                        .foregroundStyle(model.speed == s && !model.paused ? Color.black : .white.opacity(0.8))
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.speed == s && !model.paused ? Palette.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("速度 \(s.label)(キー \(SimSpeed.allCases.firstIndex(of: s)! + 1))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var controlButtons: some View {
        HStack(spacing: 4) {
            iconButton(model.paused ? "play.fill" : "pause.fill", help: model.paused ? "再開 (Space)" : "一時停止 (Space)") {
                model.togglePause()
            }
            iconButton("forward.frame.fill", help: "1ステップ (.)") { model.step() }
            iconButton("book.pages.fill", help: "種の図鑑 (⌘E)") { EncyclopediaStore.shared.open() }
            iconButton("star.fill", help: "お気に入りの個体 (⌘K)") { PetStore.shared.showFavorites.toggle() }
            iconButton("flag.2.crossed.fill", help: "世代対決 — 第0世代と進化後を比べる (⌘D)") { DuelCoordinator.shared.open() }
            iconButton("square.split.bottomrightquarter", help: "下のパネル (B)") { model.showBottom.toggle() }
            iconButton("eye.slash", help: "パネルを隠す (H)") { model.showPanels = false }
            iconButton("plus.square.on.square", help: "新しい世界 (⌘N)") { model.showNewWorldSheet = true }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Small glowing creature mark used in the title bar.
struct Logo: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let body = Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.28, width: w * 0.62, height: h * 0.44))
            ctx.addFilter(.shadow(color: Color(red: 0.3, green: 1, blue: 0.8).opacity(0.9), radius: 4))
            ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(red: 0.4, green: 1, blue: 0.85), Color(red: 0.2, green: 0.6, blue: 1)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: h)))
            var tail = Path()
            tail.move(to: CGPoint(x: w * 0.22, y: h * 0.5))
            tail.addLine(to: CGPoint(x: w * 0.0, y: h * 0.3))
            tail.addLine(to: CGPoint(x: w * 0.04, y: h * 0.5))
            tail.addLine(to: CGPoint(x: w * 0.0, y: h * 0.7))
            tail.closeSubpath()
            ctx.fill(tail, with: .color(Color(red: 0.3, green: 0.75, blue: 1)))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.62, y: h * 0.38, width: w * 0.12, height: h * 0.12)), with: .color(.white))
        }
    }
}
