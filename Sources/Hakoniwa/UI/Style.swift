import SwiftUI

enum Palette {
    static let herbivore = Color(red: 0.36, green: 0.89, blue: 0.54)
    static let omnivore = Color(red: 0.95, green: 0.79, blue: 0.30)
    static let carnivore = Color(red: 1.0, green: 0.37, blue: 0.37)
    static let accent = Color(red: 0.45, green: 0.85, blue: 1.0)
    static let textDim = Color.white.opacity(0.55)
    static let textFaint = Color.white.opacity(0.35)
    static let hairline = Color.white.opacity(0.09)

    static func diet(_ d: Float) -> Color {
        d < 0.35 ? herbivore : (d < 0.65 ? omnivore : carnivore)
    }
}

struct GlassPanel: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        // A live backdrop blur over the 60 fps Metal layer costs a lot of GPU time every frame,
        // so panels use a tinted translucent fill with a soft highlight instead.
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.13).opacity(0.88),
                                                  Color(red: 0.02, green: 0.04, blue: 0.07).opacity(0.90)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

extension View {
    func glass(_ radius: CGFloat = 16) -> some View { modifier(GlassPanel(radius: radius)) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textFaint)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

/// Horizontal bar used for genes and vitals.
struct MeterBar: View {
    var value: Double          // 0...1
    var color: Color
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * CGFloat(min(max(value, 0), 1))))
                    .shadow(color: color.opacity(0.6), radius: 3)
            }
        }
        .frame(height: height)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var color: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }
}

func formatCount(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
