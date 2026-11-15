import HakoniwaCore
import SwiftUI

/// Live visualisation of a creature's recurrent network.
/// Inputs on the left, hidden neurons in the middle, outputs on the right.
struct BrainView: View {
    let detail: CreatureDetail

    private static let excite = Color(red: 1.0, green: 0.62, blue: 0.25)
    private static let inhibit = Color(red: 0.35, green: 0.70, blue: 1.0)

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: &ctx, size: size)
        }
        .drawingGroup()
    }

    private func layout(_ size: CGSize) -> (inputs: [CGPoint], hidden: [CGPoint], outputs: [CGPoint]) {
        let top: CGFloat = 6, bottom = size.height - 6
        let xIn: CGFloat = 104, xHid = size.width * 0.58, xOut = size.width - 78
        func column(_ n: Int, _ x: CGFloat, pad: CGFloat) -> [CGPoint] {
            (0..<n).map { i in
                let t = n == 1 ? 0.5 : CGFloat(i) / CGFloat(n - 1)
                return CGPoint(x: x, y: top + pad + (bottom - top - 2 * pad) * t)
            }
        }
        return (column(Brain.inputs, xIn, pad: 0), column(Brain.hidden, xHid, pad: 18), column(Brain.outputs, xOut, pad: 60))
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let (inP, hidP, outP) = layout(size)
        let inputs = detail.inputs, hidden = detail.hidden, outputs = detail.outputs
        var connected = Set<Int>()
        for c in detail.brain.connections where Int(c.src) < Brain.inputs { connected.insert(Int(c.src)) }

        func srcPoint(_ s: Int) -> CGPoint { s < Brain.inputs ? inP[s] : hidP[s - Brain.inputs] }
        func srcValue(_ s: Int) -> Float { s < Brain.inputs ? inputs[s] : hidden[s - Brain.inputs] }

        // Connections (weakest first so strong ones sit on top).
        let conns = detail.brain.connections.sorted { abs($0.weight) < abs($1.weight) }
        for c in conns {
            let s = Int(c.src), dst = Int(c.dst)
            let a = srcPoint(s)
            let flow = min(1, abs(c.weight * srcValue(s)))
            let color = c.weight >= 0 ? Self.excite : Self.inhibit
            let width = 0.5 + CGFloat(min(abs(c.weight), 4)) * 0.45
            var path = Path()
            if dst < Brain.hidden {
                let b = hidP[dst]
                if s >= Brain.inputs {
                    // Recurrent hidden -> hidden: arc to the right.
                    let bulge = 18 + CGFloat(abs(dst - (s - Brain.inputs))) * 3
                    path.move(to: a)
                    path.addCurve(to: b, control1: CGPoint(x: a.x + bulge, y: a.y), control2: CGPoint(x: b.x + bulge, y: b.y))
                } else {
                    path.move(to: a)
                    path.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                }
            } else {
                let b = outP[dst - Brain.hidden]
                path.move(to: a)
                path.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
            }
            ctx.stroke(path, with: .color(color.opacity(0.10 + 0.85 * Double(flow))), lineWidth: width)
        }

        // Nodes.
        func node(_ p: CGPoint, _ v: Float, _ r: CGFloat, dim: Bool) {
            let mag = Double(min(abs(v), 1))
            let color = v >= 0 ? Self.excite : Self.inhibit
            if mag > 0.05 && !dim {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.2, y: p.y - r * 2.2, width: r * 4.4, height: r * 4.4)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.45 * mag), color.opacity(0)]),
                                               center: p, startRadius: 0, endRadius: r * 2.2))
            }
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.12)))
            ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(dim ? 0.08 : 0.15 + 0.85 * mag)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(dim ? 0.08 : 0.25)), lineWidth: 0.6)
        }

        for (i, p) in inP.enumerated() {
            let dim = !connected.contains(i)
            node(p, inputs[i], 3.2, dim: dim)
            let name = Brain.inputNames[i]
            let text = Text(name).font(.system(size: 8, design: .rounded)).foregroundColor(.white.opacity(dim ? 0.22 : 0.72))
            ctx.draw(text, at: CGPoint(x: p.x - 7, y: p.y), anchor: .trailing)
            // Sector group separators.
            if i % Brain.perSector == 0 && i > 0 && i <= 25 {
                var sep = Path()
                sep.move(to: CGPoint(x: 6, y: p.y - (inP[1].y - inP[0].y) / 2))
                sep.addLine(to: CGPoint(x: p.x + 4, y: p.y - (inP[1].y - inP[0].y) / 2))
                ctx.stroke(sep, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
            }
        }
        for (i, p) in hidP.enumerated() { node(p, hidden[i], 5, dim: false) }
        for (i, p) in outP.enumerated() {
            let v = outputs[i]
            node(p, v, 6.5, dim: false)
            let active = activeOutput(i, v)
            let label = Text(Brain.outputNames[i]).font(.system(size: 10, weight: active ? .bold : .regular, design: .rounded))
                .foregroundColor(active ? .white : .white.opacity(0.55))
            ctx.draw(label, at: CGPoint(x: p.x + 11, y: p.y - 5), anchor: .leading)
            // Value bar under the label.
            let barW: CGFloat = 52
            let bar = CGRect(x: p.x + 11, y: p.y + 4, width: barW, height: 3)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(.white.opacity(0.08)))
            let mid = bar.minX + barW / 2
            let len = CGFloat(v) * barW / 2
            let r = CGRect(x: min(mid, mid + len), y: bar.minY, width: abs(len), height: 3)
            ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(v >= 0 ? Self.excite : Self.inhibit))
        }
        // Column captions.
        ctx.draw(Text("隠れ層").font(.system(size: 8.5, design: .rounded)).foregroundColor(.white.opacity(0.35)),
                 at: CGPoint(x: hidP[0].x, y: hidP[0].y - 12), anchor: .center)
    }

    /// Whether an output is currently driving behaviour (matches the thresholds in the simulation).
    private func activeOutput(_ i: Int, _ v: Float) -> Bool {
        switch i {
        case Brain.outThrust, Brain.outTurn: return abs(v) > 0.3
        default: return v > 0
        }
    }
}
