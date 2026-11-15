import AppKit
import HakoniwaCore
import Metal
import SwiftUI
import simd
import UniformTypeIdentifiers

// MARK: - Portrait (Metal, off-screen)

/// Renders one creature, large, with the same shaders, bloom and tone mapping as the live view.
final class CreaturePortraitRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let background: MTLRenderPipelineState
    private let food: MTLRenderPipelineState
    private let creature: MTLRenderPipelineState
    private let down: MTLRenderPipelineState
    private let up: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let fertility: MTLTexture

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue(), let library = try? device.makeLibrary(source: shaderSource, options: nil) else { return nil }
        func make(_ v: String, _ f: String, _ format: MTLPixelFormat, blend: Int) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            if blend == 1 {
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else if blend == 2 {
                ca.isBlendingEnabled = true
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let hdr = MTLPixelFormat.rgba16Float
        guard let bg = make("fullscreenVertex", "backgroundFragment", hdr, blend: 0),
              let fd = make("foodVertex", "foodFragment", hdr, blend: 1),
              let cr = make("creatureVertex", "creatureFragment", hdr, blend: 1),
              let dn = make("fullscreenVertex", "bloomDownsample", hdr, blend: 0),
              let upP = make("fullscreenVertex", "bloomUpsample", hdr, blend: 2),
              let co = make("fullscreenVertex", "compositeFragment", .bgra8Unorm_srgb, blend: 0) else { return nil }
        // A gently varying fertility patch so the backdrop has some depth.
        let n = 16
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: n, height: n, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        var values = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let dx = Float(x) / Float(n) - 0.5, dy = Float(y) / Float(n) - 0.5
                values[y * n + x] = 0.75 - 1.4 * (dx * dx + dy * dy)
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: values, bytesPerRow: n * 4)
        self.device = device
        queue = q
        background = bg; food = fd; creature = cr; down = dn; up = upP; composite = co
        fertility = tex
    }

    /// The creature drawn at the centre of a `width`×`height` pixel image.
    func render(_ d: CreatureDetail, width: Int, height: Int) -> CGImage? {
        let g = d.genes
        var c = CreatureInstance.make(
            position: .zero, velocity: .zero, heading: d.isEgg ? 0 : -0.28, radius: max(d.radius, 1),
            hue: g.hue, saturation: g.saturation, diet: g.diet, swimPhase: 1.1,
            segments: g.segments, fins: g.fins, tail: g.tail, pattern: g.pattern, eyes: g.eyes,
            energy: max(0.7, min(d.energy / max(d.capacity, 1), 1)), hurt: 0, flags: d.isEgg ? 1 : 0,
            maturity: d.isEgg ? 0.6 : max(d.maturity, 0.85), signal: 0)
        // Frame the whole body: head at +2.4 units, tail end at -(body + tail + 1.4) units.
        let segs = Float(2 + min(Int(g.segments * 5), 4))
        let body = (segs - 1) * (0.82 + 0.13 * g.diet)
        let back = body + 0.6 + g.tail * 2.4 + 1.4
        let lengthUnits: Float = d.isEgg ? 4.4 : back + 2.4
        let heightUnits: Float = d.isEgg ? 4.4 : 2 * (1.9 + g.fins * 1.1)
        let r = c.radius
        let zoom = min(Float(width) * 0.62 / (lengthUnits * r), Float(height) * 0.62 / (heightUnits * r))
        // World position is arbitrary; put the creature somewhere with a nice caustic pattern.
        let anchor = V2(1830, 1260)
        c.position = anchor
        let mid: Float = d.isEgg ? 0 : (2.4 - back) / 2
        let dir = V2(cos(c.heading), sin(c.heading))
        let center = anchor + dir * mid * r

        // A few plants drifting around the creature.
        var plants: [FoodInstance] = []
        var seed: UInt64 = d.uid &* 0x9E37_79B9_7F4A_7C15 | 1
        func rnd() -> Float {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Float(seed % 10_000) / 10_000
        }
        let viewW = Float(width) / zoom, viewH = Float(height) / zoom
        for _ in 0..<16 {
            let p = center + V2((rnd() - 0.5) * viewW, (rnd() - 0.5) * viewH)
            if simd_length((p - center) / V2(lengthUnits * r * 0.6, heightUnits * r * 0.7)) < 1 { continue }
            // Keep the corners where the card puts its labels and title clear.
            let sx = (p.x - center.x) / viewW + 0.5, sy = (p.y - center.y) / viewH + 0.5
            if sx < 0.5 && (sy < 0.2 || sy > 0.55) { continue }
            if sx > 0.7 && sy < 0.15 { continue }
            plants.append(FoodInstance.make(position: p, energy: 3 + rnd() * 5, kind: g.diet > 0.65 && rnd() < 0.6 ? 1 : 0))
        }

        var u = Uniforms()
        u.viewSize = V2(Float(width), Float(height))
        u.camCenter = center
        u.worldSize = V2(4000, 4000)
        u.zoom = zoom
        u.time = 12.5
        u.pixelRatio = 2
        u.season = 1
        u.selected = -1
        u.bloomStrength = 0.75

        func target(_ w: Int, _ h: Int, _ format: MTLPixelFormat, shared: Bool = false) -> MTLTexture? {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: td)
        }
        guard let hdr = target(width, height, .rgba16Float), let out = target(width, height, .bgra8Unorm_srgb, shared: true),
              let cmd = queue.makeCommandBuffer() else { return nil }
        var mips: [MTLTexture] = []
        var w = width / 2, h = height / 2
        for _ in 0..<6 {
            guard let t = target(w, h, .rgba16Float) else { return nil }
            mips.append(t)
            w = max(w / 2, 1); h = max(h / 2, 1)
        }
        func pass(_ t: MTLTexture, load: MTLLoadAction = .dontCare) -> MTLRenderCommandEncoder? {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = t
            p.colorAttachments[0].loadAction = load
            p.colorAttachments[0].storeAction = .store
            return cmd.makeRenderCommandEncoder(descriptor: p)
        }
        if let enc = pass(hdr) {
            enc.setRenderPipelineState(background)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(fertility, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if !plants.isEmpty {
                enc.setRenderPipelineState(food)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setVertexBytes(plants, length: MemoryLayout<FoodInstance>.stride * plants.count, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: plants.count)
            }
            enc.setRenderPipelineState(creature)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBytes(&c, length: MemoryLayout<CreatureInstance>.stride, index: 1)
            enc.setFragmentBytes(&c, length: MemoryLayout<CreatureInstance>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            enc.endEncoding()
        }
        for (i, dst) in mips.enumerated() {
            let src = i == 0 ? hdr : mips[i - 1]
            var params = SIMD4<Float>(1 / Float(src.width), 1 / Float(src.height), i == 0 ? 1 : 0, 1.0)
            if let enc = pass(dst) {
                enc.setRenderPipelineState(down)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentBytes(&params, length: 16, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        for i in stride(from: mips.count - 1, through: 1, by: -1) {
            var params = SIMD4<Float>(1 / Float(mips[i].width), 1 / Float(mips[i].height), 0.85, 0)
            if let enc = pass(mips[i - 1], load: .load) {
                enc.setRenderPipelineState(up)
                enc.setFragmentTexture(mips[i], index: 0)
                enc.setFragmentBytes(&params, length: 16, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        if let enc = pass(out) {
            enc.setRenderPipelineState(composite)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(hdr, index: 0)
            enc.setFragmentTexture(mips[0], index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return Renderer.makeImage(out)
    }
}

// MARK: - Card layout (SwiftUI, 600×800 pt rendered at 2×)

struct CreatureCardView: View {
    let detail: CreatureDetail
    let lineage: [SpeciesInfo]
    let portrait: CGImage?
    let worldSeconds: Double

    static let size = CGSize(width: 600, height: 800)
    static let heroHeight: CGFloat = 332
    private var tint: Color { hueColor(detail.genes.hue, detail.genes.saturation) }
    private var dietName: String { detail.genes.diet < 0.35 ? "草食" : (detail.genes.diet < 0.65 ? "雑食" : "肉食") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 14) {
                stats
                HStack(alignment: .top, spacing: 18) {
                    genes.frame(width: 214)
                    brain
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(
            LinearGradient(colors: [Color(red: 0.035, green: 0.06, blue: 0.09), Color(red: 0.012, green: 0.02, blue: 0.035)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(LinearGradient(colors: [tint.opacity(0.55), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 2)
        )
        .environment(\.colorScheme, .dark)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let portrait {
                    Image(decorative: portrait, scale: 2).resizable()
                } else {
                    Color.black
                }
            }
            .frame(width: Self.size.width, height: Self.heroHeight)
            .clipped()
            // Fade into the card body so the title reads well.
            LinearGradient(colors: [.clear, Color(red: 0.035, green: 0.06, blue: 0.09).opacity(0.92)],
                           startPoint: UnitPoint(x: 0.5, y: 0.55), endPoint: .bottom)
                .frame(height: Self.heroHeight)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    pill(dietName, Palette.diet(detail.genes.diet))
                    pill("第\(detail.generation)世代", Palette.accent)
                    if detail.isEgg { pill("卵", .white) }
                }
                Text(detail.speciesName)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: tint.opacity(0.8), radius: 14)
                Text("個体 #\(detail.uid)" + (detail.parentUid != 0 ? "  ・  親 #\(detail.parentUid)" : "  ・  原初の個体"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .frame(width: Self.size.width, height: Self.heroHeight)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Logo().frame(width: 18, height: 18)
                Text("箱庭").font(.system(size: 13, weight: .bold, design: .rounded))
                Text("生き物カード").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Text(formatWorldTime(worldSeconds) + " の世界")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.35)))
                .padding(16)
        }
    }

    private func pill(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.22)))
            .overlay(Capsule().strokeBorder(c.opacity(0.5), lineWidth: 0.8))
            .foregroundStyle(c)
    }

    private var stats: some View {
        HStack(spacing: 8) {
            tile("世代", "\(detail.generation)", "代目", Palette.accent)
            tile("食性", dietName, String(format: "%.2f", detail.genes.diet), Palette.diet(detail.genes.diet))
            tile("年齢", ageText, String(format: "寿命 %.0f秒", detail.lifespan), Color(red: 0.75, green: 0.8, blue: 1))
            tile("子の数", "\(detail.offspring)", "匹", Palette.herbivore)
            tile("捕食", "\(detail.kills)", "回", detail.kills > 0 ? Palette.carnivore : Color.white.opacity(0.7))
        }
    }

    private var ageText: String {
        let s = Int(detail.age)
        return s >= 60 ? "\(s / 60)分\(s % 60)秒" : "\(s)秒"
    }

    private func tile(_ label: String, _ value: String, _ sub: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textFaint)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.system(size: 9.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textDim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.8))
    }

    private var genes: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(text: "遺伝子")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<Genes.count, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text(Genes.names[i]).font(.system(size: 10, design: .rounded)).foregroundStyle(Palette.textDim)
                            .frame(width: 62, alignment: .leading)
                        MeterBar(value: Double(detail.genes.v[i]), color: geneColor(i), height: 5)
                        Text(String(format: "%.2f", detail.genes.v[i])).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Palette.textFaint).frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func geneColor(_ i: Int) -> Color {
        switch i {
        case 1: return Palette.diet(detail.genes.diet)
        case 2, 3: return tint
        default: return Palette.accent.opacity(0.85)
        }
    }

    private var brain: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle(text: "脳(結合 \(detail.brain.connections.count) 本)")
                Spacer()
                HStack(spacing: 6) {
                    legend(Color(red: 1, green: 0.62, blue: 0.25), "興奮")
                    legend(Color(red: 0.35, green: 0.7, blue: 1), "抑制")
                }
            }
            BrainView(detail: detail)
                .frame(height: 286)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(c).frame(width: 10, height: 3)
            Text(s).font(.system(size: 9)).foregroundStyle(Palette.textFaint)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("系譜").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textFaint)
                Text(lineageText).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.textDim).lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text("hakoniwa").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
        }
    }

    private var lineageText: String {
        let names = lineage.map(\.name)
        if names.count <= 1 { return names.first.map { "\($0)(原初の種)" } ?? "—" }
        return names.reversed().joined(separator: " → ")
    }
}

// MARK: - Export

enum CreatureCard {
    /// Renders the card for the current selection, or nil if nothing is selected.
    @MainActor
    static func makeImage(model: AppModel) -> CGImage? {
        guard let d = model.detail else { return nil }
        let device = model.renderer?.device ?? MTLCreateSystemDefaultDevice()
        let portrait = device.flatMap { CreaturePortraitRenderer(device: $0) }?.render(d, width: 1200, height: Int(CreatureCardView.heroHeight * 2))
        let view = CreatureCardView(detail: d, lineage: model.lineage, portrait: portrait, worldSeconds: model.worldSeconds)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(CreatureCardView.size)
        return renderer.cgImage
    }

    static func suggestedName(_ d: CreatureDetail) -> String {
        "\(d.speciesName) 第\(d.generation)世代 #\(d.uid).png"
    }

    /// Asks where to save (default ~/Pictures/箱庭) and writes the PNG.
    @MainActor
    static func export(model: AppModel) {
        guard let d = model.detail else { return }
        guard let img = makeImage(model: model) else { model.showToast("カードを作れませんでした"); return }
        let panel = NSSavePanel()
        panel.title = "生き物カードを保存"
        panel.allowedContentTypes = [.png]
        panel.directoryURL = AppEnvironment.outputFolder(.picturesDirectory)
        panel.nameFieldStringValue = suggestedName(d)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if writePNG(img, to: url) {
            model.showToast("生き物カードを保存しました")
        } else {
            model.showToast("カードを保存できませんでした")
        }
    }
}
