import AppKit
import HakoniwaCore
import MetalKit
import Observation
import SwiftUI

// MARK: - Coordinator

/// State of the generation duel overlay ("第0世代 vs 進化後"). Lives on the main thread.
@Observable
final class DuelCoordinator {
    static let shared = DuelCoordinator()
    static let teamSize = 30

    var isPresented = false
    var preparing = false
    var errorText: String?
    var reading = DuelReading()
    var history: [DuelReading] = []
    var finished = false
    var sessionID = 0
    var leftCount = 0
    var rightCount = 0
    var evolvedGeneration = 0
    var evolvedMaxGeneration = 0
    var evolvedWorldTime: Double = 0
    var roundTicks = 2400
    var ticksPerSecond: Double = 20
    var plantEnergy: Double = 40
    var multiplier: Double = 4 { didSet { session?.multiplier = multiplier } }
    var paused = false { didSet { session?.paused = paused } }

    @ObservationIgnored private(set) var session: DuelSession?
    @ObservationIgnored weak var leftView: ArenaMTKView?
    @ObservationIgnored weak var rightView: ArenaMTKView?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var teams: (primordial: [(Genes, BrainGenome)], evolved: [(Genes, BrainGenome)], config: SimConfig)?
    @ObservationIgnored private var mainWasPaused = false
    @ObservationIgnored private var round = 0

    var seconds: Double { Double(reading.tick) / ticksPerSecond }
    var roundSeconds: Double { Double(roundTicks) / ticksPerSecond }
    var leftPlants: Double { reading.left / plantEnergy }
    var rightPlants: Double { reading.right / plantEnergy }

    /// How many times better the evolved side forages, per creature. nil while too early to tell.
    var ratio: Double? {
        guard seconds >= 4, leftCount > 0, rightCount > 0 else { return nil }
        let l = reading.left / Double(leftCount), r = reading.right / Double(rightCount)
        guard l > plantEnergy * 0.25 / Double(leftCount) else { return nil }
        return r / l
    }

    // MARK: Open / close

    func open() {
        guard !isPresented else { return }
        let env = AppEnvironment.shared
        mainWasPaused = env.model.paused
        env.model.paused = true
        env.model.renderer?.view?.isPaused = true
        isPresented = true
        preparing = true
        errorText = nil
        reading = DuelReading()
        history = []
        finished = false
        let n = DuelCoordinator.teamSize
        env.controller.perform { [weak self] w in
            let evolved = w.sampleGenomes(n)
            let gens = w.sampledGenerations(n)
            let cfg = w.config, seed = w.seed, maxGen = Int(w.maxGeneration), time = w.worldTime
            DispatchQueue.global(qos: .userInitiated).async {
                let primordial = World.primordialGenomes(n, seed: seed, config: cfg)
                DispatchQueue.main.async {
                    guard let self, self.isPresented else { return }
                    guard !evolved.isEmpty, !primordial.isEmpty else {
                        self.preparing = false
                        self.errorText = "生き物がいないため、対決できません"
                        return
                    }
                    self.teams = (primordial, evolved, cfg)
                    self.leftCount = primordial.count
                    self.rightCount = evolved.count
                    self.evolvedGeneration = gens.isEmpty ? 0 : Int((Double(gens.reduce(0) { $0 + Int($1) }) / Double(gens.count)).rounded())
                    self.evolvedMaxGeneration = maxGen
                    self.evolvedWorldTime = time
                    self.plantEnergy = Double(cfg.plantEnergy)
                    self.ticksPerSecond = Double(cfg.ticksPerSecond)
                    self.startRound(seed: seed &* 31 &+ 7)
                }
            }
        }
    }

    /// Restarts on a fresh arena (both sides again get the identical plant layout).
    func rematch() {
        round += 1
        startRound(seed: UInt64(round) &* 0x9E37_79B9 &+ UInt64(Date().timeIntervalSince1970))
    }

    private func startRound(seed: UInt64) {
        guard let t = teams else { return }
        preparing = true
        let setup = DuelSetup(primordial: t.primordial, evolved: t.evolved, config: t.config, arenaSeed: seed)
        DispatchQueue.global(qos: .userInitiated).async {
            let s = DuelSession(setup)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented else { s.stop(); return }
                self.session?.stop()
                self.session = s
                self.roundTicks = s.roundTicks
                self.reading = DuelReading()
                self.history = []
                self.finished = false
                s.multiplier = self.multiplier
                s.paused = self.paused
                s.start()
                self.sessionID += 1
                self.preparing = false
                self.startTimer()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let s = self.session else { return }
            let r = s.latest
            if r.tick != self.reading.tick || r.left != self.reading.left || r.right != self.reading.right {
                self.reading = r
                self.history = s.history
            }
            let done = s.finished
            if done != self.finished {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { self.finished = done }
            }
        }
    }

    func close() {
        guard isPresented else { return }
        timer?.invalidate()
        timer = nil
        session?.stop()
        session = nil
        teams = nil
        isPresented = false
        preparing = false
        let env = AppEnvironment.shared
        env.model.renderer?.view?.isPaused = false
        env.model.paused = mainWasPaused
    }

    func toggle() { isPresented ? close() : open() }

    /// Keyboard handling while the duel is shown. Returns true when consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        switch event.keyCode {
        case 53: close(); return true          // escape
        case 49: paused.toggle(); return true  // space
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": multiplier = 1; paused = false
        case "2": multiplier = 4; paused = false
        case "3": multiplier = 16; paused = false
        case "r": rematch()
        default: break
        }
        return true
    }
}

// MARK: - Arena view

/// Non-interactive Metal view showing one arena with the regular renderer.
final class ArenaMTKView: MTKView {
    var renderer: Renderer?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct ArenaView: NSViewRepresentable {
    let controller: SimulationController
    let isLeft: Bool

    func makeNSView(context: Context) -> ArenaMTKView {
        let v = ArenaMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
        if let r = Renderer(view: v, controller: controller) {
            // Zoom is clamped so the arena exactly covers the (square) view.
            r.camera.zoom = 0.0001
            r.camera.targetZoom = 0.0001
            v.renderer = r
            v.delegate = r
        }
        if isLeft { DuelCoordinator.shared.leftView = v } else { DuelCoordinator.shared.rightView = v }
        return v
    }

    func updateNSView(_ nsView: ArenaMTKView, context: Context) {}

    static func dismantleNSView(_ nsView: ArenaMTKView, coordinator: ()) {
        nsView.isPaused = true
        nsView.delegate = nil
        nsView.renderer = nil
    }
}

// MARK: - Overlay

enum DuelPalette {
    static let primordial = Color(red: 0.70, green: 0.72, blue: 0.86)
    static let evolved = Color(red: 0.42, green: 0.93, blue: 0.78)
    static let gold = Color(red: 1.0, green: 0.84, blue: 0.45)
}

/// Placed in the main window's ZStack; shows the duel when requested.
struct DuelHost: View {
    var duel = DuelCoordinator.shared
    var body: some View {
        ZStack {
            if duel.isPresented {
                DuelView(duel: duel)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: duel.isPresented)
    }
}

struct DuelView: View {
    @Bindable var duel: DuelCoordinator

    var body: some View {
        ZStack {
            background
            VStack(spacing: 14) {
                header
                GeometryReader { g in
                    arenas(in: g.size)
                }
                footer
            }
            .padding(.horizontal, 26)
            .padding(.top, 34)
            .padding(.bottom, 20)
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.012, green: 0.022, blue: 0.035)
            RadialGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.16).opacity(0.9), .clear],
                           center: .center, startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "flag.2.crossed.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DuelPalette.gold)
                    Text("世代対決").font(.system(size: 20, weight: .bold, design: .rounded))
                }
                Text("同じ餌場に、原初の祖先と進化した子孫を\(DuelCoordinator.teamSize)匹ずつ。\(Int(duel.roundSeconds / 60))分間でどれだけ食べられるか。")
                    .font(.system(size: 12)).foregroundStyle(Palette.textDim)
            }
            Spacer()
            speedControl
            controlButton(duel.paused ? "play.fill" : "pause.fill", duel.paused ? "再開 (Space)" : "一時停止 (Space)") {
                duel.paused.toggle()
            }
            Button { duel.rematch() } label: {
                Label("もう一度", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("別の餌場でもう一度 (R)")
            Button { duel.close() } label: {
                Label("閉じる", systemImage: "xmark")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("元の世界に戻る (Esc)")
        }
    }

    private var speedControl: some View {
        HStack(spacing: 2) {
            ForEach([1.0, 4.0, 16.0], id: \.self) { m in
                let on = duel.multiplier == m && !duel.paused
                Button { duel.multiplier = m; duel.paused = false } label: {
                    Text("\(Int(m))×")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .frame(minWidth: 34, minHeight: 24)
                        .foregroundStyle(on ? Color.black : .white.opacity(0.8))
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Palette.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func controlButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Arenas

    private func arenas(in size: CGSize) -> some View {
        let centerW: CGFloat = min(220, max(150, size.width * 0.15))
        let labelH: CGFloat = 46, scoreH: CGFloat = 78
        let side = max(120, min((size.width - centerW - 36) / 2, size.height - labelH - scoreH - 16))
        let maxValue = max(duel.leftPlants, duel.rightPlants, 1)
        return HStack(alignment: .top, spacing: 18) {
            column(isLeft: true, side: side, labelH: labelH, maxValue: maxValue)
            centerPanel
                .frame(width: centerW, height: side + labelH + scoreH)
            column(isLeft: false, side: side, labelH: labelH, maxValue: maxValue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func column(isLeft: Bool, side: CGFloat, labelH: CGFloat, maxValue: Double) -> some View {
        let color = isLeft ? DuelPalette.primordial : DuelPalette.evolved
        let plants = isLeft ? duel.leftPlants : duel.rightPlants
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(isLeft ? "第0世代" : "第\(duel.evolvedGeneration)世代")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
                Text(isLeft ? "原初の祖先" : "進化後")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.16)))
                    .foregroundStyle(color)
                Spacer()
                Text(isLeft ? "でたらめな脳 · \(duel.leftCount)匹"
                            : "世界の時間 \(formatWorldTime(duel.evolvedWorldTime))から · \(duel.rightCount)匹")
                    .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
            .frame(height: labelH - 8, alignment: .bottom)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                if let s = duel.session, !duel.preparing {
                    ArenaView(controller: isLeft ? s.left : s.right, isLeft: isLeft)
                        .id(duel.sessionID)
                } else if let e = duel.errorText {
                    Text(e).font(.system(size: 13)).foregroundStyle(Palette.textDim)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: side, height: side)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(color.opacity(isLeft ? 0.22 : 0.4), lineWidth: 1)
            )
            .shadow(color: isLeft ? .clear : color.opacity(0.18), radius: 18)
            score(plants: plants, maxValue: maxValue, color: color, isLeft: isLeft)
                .frame(width: side)
        }
    }

    private func score(plants: Double, maxValue: Double, color: Color, isLeft: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(plants))")
                    .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(isLeft ? 0 : 0.45), radius: 10)
                    .contentTransition(.numericText(value: plants))
                Text("個").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(color.opacity(0.8))
                Text("食べた植物").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.textFaint)
                Spacer()
                let perMin = duel.seconds > 1 ? plants / Double(isLeft ? max(duel.leftCount, 1) : max(duel.rightCount, 1)) / (duel.seconds / 60) : 0
                Text(String(format: "1匹あたり 毎分 %.1f 個", perMin))
                    .font(.system(size: 10.5, design: .rounded)).monospacedDigit().foregroundStyle(Palette.textFaint)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, g.size.width * CGFloat(plants / maxValue)))
                        .shadow(color: color.opacity(0.6), radius: 5)
                }
            }
            .frame(height: 9)
            .animation(.easeOut(duration: 0.2), value: plants)
        }
    }

    private var centerPanel: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("VS").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(Palette.textFaint)
            Spacer().frame(height: 10)
            if duel.finished {
                Text("結果").font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(DuelPalette.gold.opacity(0.18)))
                    .foregroundStyle(DuelPalette.gold)
                    .transition(.scale.combined(with: .opacity))
            }
            if let r = duel.ratio {
                Text("進化後は").font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.textDim)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(r >= 100 ? String(format: "%.0f", r) : String(format: "%.1f", r))
                        .font(.system(size: duel.finished ? 62 : 54, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(LinearGradient(colors: [DuelPalette.gold, DuelPalette.evolved], startPoint: .top, endPoint: .bottom))
                        .shadow(color: DuelPalette.gold.opacity(0.35), radius: 14)
                        .contentTransition(.numericText(value: r))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("倍").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(DuelPalette.gold)
                }
                Text(r >= 1 ? "上手に食べている" : "食べるのが下手")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.textDim)
                Text("1匹あたりの採餌量で比較").font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint)
                    .padding(.top, 4)
            } else if duel.rightPlants >= 1 && duel.seconds >= 4 {
                Text("第0世代は\nまだ一口も\n食べていない")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textDim)
            } else {
                Text("計測中…").font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
            Spacer()
            if duel.finished {
                Button { duel.rematch() } label: {
                    Label("別の餌場でもう一度", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(DuelPalette.gold.opacity(0.16)))
                        .foregroundStyle(DuelPalette.gold)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            Spacer().frame(height: 60)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: duel.finished)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("経過").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
                Text("\(clock(duel.seconds)) / \(clock(duel.roundSeconds))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 96, alignment: .leading)
            DuelChart(history: duel.history, roundTicks: duel.roundTicks, plantEnergy: duel.plantEnergy,
                      progress: Double(duel.reading.tick) / Double(max(duel.roundTicks, 1)))
                .frame(height: 64)
            VStack(alignment: .leading, spacing: 5) {
                legend(DuelPalette.evolved, "進化後")
                legend(DuelPalette.primordial, "第0世代")
            }
            .frame(width: 70, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glass(14)
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(c).frame(width: 12, height: 3)
            Text(s).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Palette.textDim)
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Cumulative plants eaten by both sides over the round.
struct DuelChart: View {
    let history: [DuelReading]
    let roundTicks: Int
    let plantEnergy: Double
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let maxV = max(history.map { max($0.left, $0.right) }.max() ?? 0, plantEnergy * 4) / plantEnergy * 1.08
            func pt(_ r: DuelReading, _ left: Bool) -> CGPoint {
                let x = w * CGFloat(Double(r.tick) / Double(max(roundTicks, 1)))
                let v = (left ? r.left : r.right) / plantEnergy
                return CGPoint(x: x, y: h - h * CGFloat(v / maxV))
            }
            // Grid.
            for k in 1..<4 {
                let x = w * CGFloat(k) / 4
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) },
                           with: .color(.white.opacity(0.05)), lineWidth: 1)
            }
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: h - 0.5)); p.addLine(to: CGPoint(x: w, y: h - 0.5)) },
                       with: .color(.white.opacity(0.12)), lineWidth: 1)
            guard history.count > 1 else { return }
            for left in [true, false] {
                let color = left ? DuelPalette.primordial : DuelPalette.evolved
                var line = Path()
                for (i, r) in history.enumerated() {
                    if i == 0 { line.move(to: pt(r, left)) } else { line.addLine(to: pt(r, left)) }
                }
                var area = line
                area.addLine(to: CGPoint(x: pt(history.last!, left).x, y: h))
                area.addLine(to: CGPoint(x: 0, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(left ? 0.10 : 0.28), color.opacity(0)]),
                                                     startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
                ctx.stroke(line, with: .color(color.opacity(left ? 0.8 : 1)), style: StrokeStyle(lineWidth: left ? 1.5 : 2, lineJoin: .round))
                let end = pt(history.last!, left)
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(color))
            }
            // Playhead.
            let x = w * CGFloat(min(max(progress, 0), 1))
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) },
                       with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }
}

// MARK: - Launch option and automated capture

enum DuelLaunch {
    static let requested = CommandLine.arguments.contains("--duel")

    /// World seconds to advance the duel before an automated capture (`--duel-seconds S`, default 60).
    static var captureSeconds: Double {
        if let i = CommandLine.arguments.firstIndex(of: "--duel-seconds"), i + 1 < CommandLine.arguments.count,
           let v = Double(CommandLine.arguments[i + 1]) { return v }
        return 60
    }

    /// `--duel` opens the duel at launch; with `--screenshot PATH` it also captures it and quits.
    static func start(env: AppEnvironment) {
        guard requested else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DuelCoordinator.shared.open() }
        guard let path = env.options.screenshot else { return }
        let duel = DuelCoordinator.shared
        var advanced = false
        var target: Int64 = 0
        var frames = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            // Drive frames manually: the window stays in the background, so display links stop.
            duel.leftView?.draw()
            duel.rightView?.draw()
            guard let s = duel.session, !duel.preparing, duel.leftView != nil, duel.rightView != nil else { return }
            if !advanced {
                advanced = true
                target = Int64(min(captureSeconds, Double(s.setup.roundSeconds)) * s.ticksPerSecond)
                s.advanceNow(Int(target))
                return
            }
            guard s.latest.tick >= target else { return }
            frames += 1
            guard frames >= max(env.options.frames, 20) else { return }
            timer.invalidate()
            let r = s.latest
            print(String(format: "duel t=%.0fs primordial %.1f plants (%d) evolved %.1f plants (%d) ratio %.1fx",
                         Double(r.tick) / s.ticksPerSecond, r.left / duel.plantEnergy, duel.leftCount,
                         r.right / duel.plantEnergy, duel.rightCount, duel.ratio ?? .nan))
            capture { img in
                if let img {
                    writePNG(img, to: URL(fileURLWithPath: path))
                    print("screenshot \(path) \(img.width)x\(img.height)")
                } else {
                    print("screenshot failed")
                }
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    /// Composes the SwiftUI layer tree with both arena frames.
    static func capture(_ completion: @escaping (CGImage?) -> Void) {
        let duel = DuelCoordinator.shared
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let lv = duel.leftView, let rv = duel.rightView, let lr = lv.renderer, let rr = rv.renderer else {
            completion(nil); return
        }
        var images: [CGImage?] = [nil, nil]
        var pending = 2
        func done() {
            let scale = window.backingScaleFactor
            let w = Int(content.bounds.width * scale), h = Int(content.bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { completion(nil); return }
            var metalViews: [NSView] = []
            func collect(_ v: NSView) {
                if v is MTKView { metalViews.append(v) }
                v.subviews.forEach(collect)
            }
            collect(content)
            let hidden = metalViews.map { $0.layer?.isHidden ?? false }
            metalViews.forEach { $0.layer?.isHidden = true }
            if let layer = content.layer {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                if !content.isFlipped {
                    ctx.translateBy(x: 0, y: content.bounds.height)
                    ctx.scaleBy(x: 1, y: -1)
                }
                layer.render(in: ctx)
                ctx.restoreGState()
            }
            for (v, hid) in zip(metalViews, hidden) { v.layer?.isHidden = hid }
            for (view, img) in zip([lv, rv], images) {
                guard let img else { continue }
                let r = view.convert(view.bounds, to: nil)
                let rect = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
                ctx.clip()
                ctx.draw(img, in: rect)
                ctx.restoreGState()
            }
            completion(ctx.makeImage())
        }
        for (k, r) in [lr, rr].enumerated() {
            r.captureNextFrame { img in
                images[k] = img
                pending -= 1
                if pending == 0 { done() }
            }
        }
        lv.draw()
        rv.draw()
    }
}
