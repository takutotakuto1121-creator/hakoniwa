import AppKit
import HakoniwaCore
import Observation
import SwiftUI

// MARK: - Caption

/// One subtitle of the demo. Every figure in it comes from the world.
struct DemoCaption: Equatable {
    var id: Int
    var kicker: String
    var title: String
    var body: String
    var facts: [String]
    var tint: Color
}

// MARK: - Director

/// Demo mode: hides the panels and lets the camera tour the world on its own, from one
/// highlight (hunt, herd, hatching egg, big carnivore, rare colour) to the next, with subtitles.
/// Main thread only; driven once per frame by the renderer through `Renderer.cameraDriver`.
@Observable
final class DemoDirector {
    static let shared = DemoDirector()
    /// `HAKONIWA_DEMO_LOG=1` prints every caption (for checking the tour without watching it).
    static let log = ProcessInfo.processInfo.environment["HAKONIWA_DEMO_LOG"] != nil

    private(set) var isActive = false
    private(set) var caption: DemoCaption?
    private(set) var captionVisible = false
    /// Seconds since the demo started.
    @ObservationIgnored private(set) var elapsed: Double = 0

    @ObservationIgnored private let camera = DirectorCamera()
    @ObservationIgnored private weak var renderer: Renderer?
    @ObservationIgnored private var saved: (panels: Bool, speed: SimSpeed, paused: Bool, vision: Bool)?
    @ObservationIgnored private var scan: DemoScan?
    @ObservationIgnored private var scanPending = false
    @ObservationIgnored private var scanRequestedAt: Double = 0
    @ObservationIgnored private var shotCount = 0
    @ObservationIgnored private var recentKinds: [DemoHighlight.Kind] = []
    @ObservationIgnored private var recentUids: [UInt64] = []
    @ObservationIgnored private var recentSpecies: [Int32] = []
    @ObservationIgnored private var captionCounter = 0
    @ObservationIgnored private var overviewVariant = 0
    @ObservationIgnored private var lostHandled = false
    @ObservationIgnored private var selectOnArrival: UInt64 = 0
    @ObservationIgnored private var currentKind: DemoHighlight.Kind?
    private static let hatchedTitle = "卵が孵った。"
    /// Panel visibility to restore when the demo was started from the intro (which hid the panels).
    @ObservationIgnored var restorePanelsAfterIntro: Bool?

    private var model: AppModel { AppEnvironment.shared.model }

    // MARK: Start / stop

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive, let r = model.renderer else { return }
        if DuelCoordinator.shared.isPresented { return }
        IntroCoordinator.shared.close()
        let m = model
        saved = (restorePanelsAfterIntro ?? m.showPanels, m.speed, m.paused, m.showVision)
        restorePanelsAfterIntro = nil
        renderer = r
        isActive = true
        elapsed = 0
        shotCount = 0
        recentKinds = []; recentUids = []; recentSpecies = []
        scan = nil
        scanPending = false
        m.select(nil)
        m.following = false
        m.tool = .select
        m.showVision = true
        m.speed = .x1
        m.paused = false
        withAnimation(.easeInOut(duration: 0.6)) { m.showPanels = false }
        r.hover = nil
        r.hidesSelectionRing = true
        r.cameraDriver = { [weak self] r, dt, extrap in self?.frame(r, dt: dt, extrap: extrap) }
        requestScan()
        beginOverview(establishing: true)
    }

    /// Ends the demo and restores the panels, speed and pause state. `keepClock` leaves the speed
    /// and pause alone (the duel, which pauses the main world itself, is taking over).
    func stop(keepClock: Bool = false) {
        guard isActive else { return }
        isActive = false
        captionVisible = false
        caption = nil
        camera.stop()
        if let r = renderer {
            r.cameraDriver = nil
            r.hidesSelectionRing = false
            r.camera.targetCenter = r.camera.center
            r.camera.targetZoom = r.camera.zoom
        }
        let m = model
        m.select(nil)
        m.following = false
        if let s = saved {
            m.showVision = s.vision
            if !keepClock {
                m.speed = s.speed
                m.paused = s.paused
            }
            withAnimation(.easeOut(duration: 0.3)) { m.showPanels = s.panels }
        }
        saved = nil
    }

    /// Esc ends the demo; H too, since showing the panels would fight the director.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "h" {
            stop()
            return true
        }
        return false
    }

    // MARK: Frame

    private func frame(_ r: Renderer, dt: Float, extrap: Float) {
        guard isActive else { return }
        elapsed += Double(dt)
        var subject: (position: V2, velocity: V2)?
        var isEgg = false
        if let s = camera.shot, s.subject != 0 {
            subject = r.controller.withFront { snap -> (position: V2, velocity: V2)? in
                guard let k = snap.uids.firstIndex(of: s.subject) else { return nil }
                let c = snap.creatures[k]
                isEgg = c.flags.truncatingRemainder(dividingBy: 2) >= 1
                return (c.position + c.velocity * extrap, c.velocity)
            }
        }
        camera.drive(camera: r.camera, dt: dt, subject: subject)

        // The egg we are watching has hatched.
        if currentKind == .hatch && subject != nil && !isEgg, var c = caption, c.title != Self.hatchedTitle {
            c.title = Self.hatchedTitle
            withAnimation(.easeInOut(duration: 0.6)) { caption = c }
        }

        // The subject died or was eaten: hold on the spot briefly, then move on.
        if camera.subjectLost && !lostHandled {
            lostHandled = true
            model.select(nil)
            shotEndsAt = min(shotEndsAt, camera.time + 2.2)
        }

        if selectOnArrival != 0 && !camera.isFlying && !camera.subjectLost {
            model.select(selectOnArrival)
            selectOnArrival = 0
        }

        let t = camera.time
        let showAt = camera.flightDuration * 0.72
        let wantCaption = t >= showAt && t < shotEndsAt - 1.0
        if wantCaption != captionVisible { captionVisible = wantCaption }

        if t >= shotEndsAt - 1.6 && !scanPending && (scan == nil || scanAge > 1.5) { requestScan() }
        if t >= shotEndsAt {
            // Wait a moment for a fresh scan, but never stall.
            if scanPending && elapsed - scanRequestedAt < 1.0 { return }
            nextShot()
        }
    }

    @ObservationIgnored private var shotEndsAt: Double = 0
    @ObservationIgnored private var scanReceivedAt: Double = -100
    private var scanAge: Double { elapsed - scanReceivedAt }

    private func requestScan() {
        scanPending = true
        scanRequestedAt = elapsed
        AppEnvironment.shared.controller.perform { [weak self] w in
            let s = w.demoScan()
            DispatchQueue.main.async {
                guard let self, self.isActive else { return }
                self.scan = s
                self.scanPending = false
                self.scanReceivedAt = self.elapsed
            }
        }
    }

    // MARK: Shot selection

    private func nextShot() {
        shotCount += 1
        // A wide shot every fourth shot, or whenever nothing interesting turned up.
        if shotCount % 4 == 0 || scan == nil {
            beginOverview(establishing: false)
            return
        }
        guard let pick = pickHighlight() else {
            beginOverview(establishing: false)
            return
        }
        begin(pick)
    }

    private func pickHighlight() -> DemoHighlight? {
        guard let scan else { return nil }
        let order: [DemoHighlight.Kind] = [.hunt, .hatch, .herd, .bigCarnivore, .rareColor, .forager]
        let avoidKinds = Set(recentKinds.suffix(3))
        func fresh(_ h: DemoHighlight) -> Bool {
            !recentUids.contains(h.uid) && recentSpecies.last != h.speciesId
        }
        for strict in [true, false] {
            for k in order where !(strict && avoidKinds.contains(k)) {
                if let h = scan.best(k).first(where: { strict ? fresh($0) : !recentUids.suffix(3).contains($0.uid) }) {
                    return h
                }
            }
        }
        return nil
    }

    private func remember(_ h: DemoHighlight) {
        recentKinds.append(h.kind)
        recentUids.append(h.uid)
        recentSpecies.append(h.speciesId)
        if recentKinds.count > 6 { recentKinds.removeFirst() }
        if recentUids.count > 12 { recentUids.removeFirst() }
        if recentSpecies.count > 6 { recentSpecies.removeFirst() }
    }

    private func startShot(_ s: DirectorCamera.Shot) {
        guard let r = renderer else { return }
        camera.begin(s, camera: r.camera)
        shotEndsAt = s.duration
        lostHandled = false
    }

    private func setCaption(kicker: String, title: String, body: String, facts: [String], tint: Color) {
        captionCounter += 1
        captionVisible = false
        caption = DemoCaption(id: captionCounter, kicker: kicker, title: title, body: body, facts: facts, tint: tint)
        if Self.log {
            print(String(format: "demo %6.1fs [%@] %@ %@ | %@", elapsed, kicker, title, body, facts.joined(separator: " · ")))
            fflush(stdout)
        }
    }

    private func beginOverview(establishing: Bool) {
        let m = model
        let ws = renderer?.camera.worldSize ?? V2(4000, 4000)
        let anchor = scan?.busiestPoint ?? ws * 0.5
        let a = Float.random(in: 0..<(2 * .pi))
        m.select(nil)
        selectOnArrival = 0
        currentKind = nil
        startShot(.init(anchor: anchor, wide: true, push: 1.12, duration: establishing ? 8 : 7.5,
                        drift: V2(cos(a), sin(a)) * 10))
        let pop = scan?.population ?? m.population
        let speciesAlive = scan?.speciesAlive ?? m.speciesAlive
        let gen = scan?.maxGeneration ?? m.maxGeneration
        let time = scan?.worldTime ?? m.worldSeconds
        let herb = scan?.herbivores ?? m.herbivores, omni = scan?.omnivores ?? m.omnivores, carn = scan?.carnivores ?? m.carnivores
        let variant = establishing ? 0 : (overviewVariant % 2) + 1
        if !establishing { overviewVariant += 1 }
        switch variant {
        case 1:
            setCaption(kicker: "生態系",
                       title: "草食\(herb)匹・雑食\(omni)匹・肉食\(carn)匹。",
                       body: "植物を草食が食べ、肉食が草食を食べ、死骸は土に還ってまた植物になる。",
                       facts: ["世界の総エネルギーは一定", "\(speciesAlive)種が共存"], tint: Palette.herbivore)
        case 2:
            setCaption(kicker: "箱庭の全体",
                       title: "最も進んだ系統は、第\(gen)世代。",
                       body: "どの生き物も、でたらめな脳を持った祖先から始まった。",
                       facts: ["世界の時間 \(formatWorldTime(time))", "\(pop)匹"], tint: Palette.accent)
        default:
            setCaption(kicker: "箱庭",
                       title: "\(speciesAlive)種・\(pop)匹が暮らす世界。",
                       body: "始まりから、世界の時間で\(formatWorldTime(time))。生き物の行動は、どれも誰もプログラムしていない。",
                       facts: ["最大 第\(gen)世代"], tint: Palette.accent)
        }
    }

    private func begin(_ h: DemoHighlight) {
        remember(h)
        currentKind = h.kind
        let m = model
        let name = "『\(h.speciesName)』"
        let genFact = "第\(h.generation)世代"
        // The hunter's field of view appears once the camera has arrived.
        m.select(nil)
        selectOnArrival = h.kind == .hunt ? h.uid : 0
        switch h.kind {
        case .hunt:
            startShot(.init(subject: h.uid, anchor: h.position, zoom: 2.5, push: 1.25, duration: 11))
            let evolved = h.generation >= 10
                ? "この行動は誰もプログラムしていない ― \(h.generation)世代の進化で生まれた。"
                : "この行動は誰もプログラムしていない。脳の重みの進化から生まれた。"
            var facts = [genFact]
            if let prey = h.preySpeciesName { facts.append("獲物は\(DemoHighlight.dietLabel(h.preyDiet))の『\(prey)』") }
            if h.kills > 0 { facts.append("これまでに\(h.kills)匹を仕留めた") }
            setCaption(kicker: "狩り", title: "\(h.dietLabel)種\(name)が狩りをしている。", body: evolved,
                       facts: facts, tint: Palette.carnivore)
        case .herd:
            let r = renderer
            let viewPoints = r.map { min($0.camera.viewSize.x, $0.camera.viewSize.y) / $0.camera.pixelRatio } ?? 800
            let zoom = min(max(viewPoints / max(h.groupRadius * 2 * 1.35, 1), 1.1), 3.0)
            startShot(.init(subject: h.uid, anchor: h.position, zoom: zoom, push: 1.18, duration: 10.5))
            let branched: String
            if let parent = h.parentSpeciesName {
                branched = "この種は\(agoText(h.speciesAge))に『\(parent)』から枝分かれした。"
            } else {
                branched = "この種は\(agoText(h.speciesAge))に現れた。"
            }
            var facts = [h.dietLabel, "中心の個体は第\(h.generation)世代"]
            if h.alignment > 0.55 { facts.insert("多くが同じ向きに泳いでいる", at: 0) }
            setCaption(kicker: "群れ", title: "この群れは、同じ祖先から分かれた\(h.groupCount)匹。",
                       body: "種の名は\(name)。\(branched)", facts: facts, tint: hueColor(h.hue, h.saturation))
        case .hatch:
            let d = Double(h.secondsLeft) + 2.8 + 5.5
            startShot(.init(subject: h.uid, anchor: h.position, zoom: 5.2, push: 1.12, duration: min(max(d, 9), 12.5)))
            setCaption(kicker: "誕生", title: "もうすぐ、卵が孵る。",
                       body: "\(name)の第\(h.generation)世代。親の遺伝子と脳は、少しだけ変異して受け継がれる。",
                       facts: ["\(h.dietLabel)の系統"], tint: Color(red: 0.95, green: 0.9, blue: 0.75))
        case .bigCarnivore:
            startShot(.init(subject: h.uid, anchor: h.position, zoom: 3.4, push: 1.2, duration: 10))
            let title = h.rank == 1
                ? "この\(name)は、この世界で最も大きな肉食の個体。"
                : "この\(name)は、この世界の肉食で\(h.rank)番目に大きい。"
            var facts = [genFact, "大人の肉食 \(h.groupCount)匹のうち"]
            if h.kills > 0 { facts.append("これまでに\(h.kills)匹を仕留めた") }
            setCaption(kicker: "大型の肉食", title: title,
                       body: "大きな体は強く噛めるが、そのぶん多くのエネルギーを使う。",
                       facts: facts, tint: Palette.carnivore)
        case .rareColor:
            startShot(.init(subject: h.uid, anchor: h.position, zoom: 4.2, push: 1.15, duration: 9.5))
            let pct = h.share < 0.01 ? "1%未満" : "\(Int((h.share * 100).rounded()))%"
            setCaption(kicker: "珍しい色", title: "この色合いの個体は、全体の\(pct)しかいない。",
                       body: "\(name)の\(genFact)。体の色も遺伝子で決まり、ほかの生き物の目にも映っている。",
                       facts: [h.dietLabel], tint: hueColor(h.hue, h.saturation))
        case .forager:
            startShot(.init(subject: h.uid, anchor: h.position, zoom: 3.6, push: 1.2, duration: 9.5))
            let how = h.generation >= 10 ? "\(h.generation)世代の進化で身についたものだ。" : "脳の重みの進化から生まれた。"
            var facts = [genFact]
            if h.offspring > 0 { facts.append("これまでに\(h.offspring)個の卵を産んだ") }
            setCaption(kicker: "採餌", title: "草食種\(name)が植物を食べている。",
                       body: "餌を見つけて近づく動きも、誰も書いていない。\(how)", facts: facts, tint: Palette.herbivore)
        }
    }

    private func agoText(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "ほんの少し前" }
        if s < 3600 { return "\(s / 60)分前" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)時間前" : "\(s / 3600)時間\(m)分前"
    }
}

// MARK: - Overlay

struct DemoHost: View {
    var director = DemoDirector.shared
    var duel = DuelCoordinator.shared

    var body: some View {
        ZStack {
            if director.isActive {
                DemoOverlay(director: director)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: director.isActive)
        .onChange(of: duel.isPresented) { _, presented in if presented { director.stop(keepClock: true) } }
    }
}

/// Letterbox, subtitles and the exit affordance. Any click ends the demo.
struct DemoOverlay: View {
    var director: DemoDirector
    @State private var showHint = true
    @State private var bars = false

    var body: some View {
        GeometryReader { g in
            let bar = max(34, g.size.height * 0.07)
            ZStack {
                // Clicks anywhere end the demo (and keep the world from panning underneath).
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { director.stop() }
                LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .init(x: 0.5, y: 0.55), endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black).frame(height: bars ? bar : 0)
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.black).frame(height: bars ? bar : 0)
                }
                .allowsHitTesting(false)
                VStack {
                    topRow.frame(height: bar)
                    Spacer()
                    captionView
                        .frame(maxWidth: min(g.size.width - 80, 860))
                        .padding(.bottom, bar + 26)
                }
                .padding(.horizontal, 28)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1)) { bars = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { withAnimation(.easeOut(duration: 1.2)) { showHint = false } }
        }
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Palette.carnivore).frame(width: 6, height: 6)
                    .shadow(color: Palette.carnivore.opacity(0.8), radius: 3)
                Text("デモモード").font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if showHint {
                Text("クリックか esc で終了").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                    .transition(.opacity)
            }
            Spacer()
            Button { director.stop() } label: {
                HStack(spacing: 6) {
                    Text("終了").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    Text("esc").font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.8))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("デモモードを終了 (esc)")
        }
    }

    @ViewBuilder private var captionView: some View {
        if let c = director.caption {
            let visible = director.captionVisible
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Rectangle().fill(c.tint.opacity(0.7)).frame(width: 22, height: 1)
                    Text(c.kicker)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .tracking(4)
                        .foregroundStyle(c.tint)
                    Rectangle().fill(c.tint.opacity(0.7)).frame(width: 22, height: 1)
                }
                Text(c.title)
                    .font(.custom("HiraMinProN-W6", size: 27))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                Text(c.body)
                    .font(.custom("HiraMinProN-W3", size: 16.5))
                    .foregroundStyle(.white.opacity(0.84))
                    .multilineTextAlignment(.center)
                    .lineSpacing(7)
                if !c.facts.isEmpty {
                    Text(c.facts.joined(separator: "   ·   "))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 2)
                }
            }
            .shadow(color: .black.opacity(0.85), radius: 10, y: 1)
            .fixedSize(horizontal: false, vertical: true)
            .id(c.id)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 10)
            .blur(radius: visible ? 0 : 5)
            .animation(.easeOut(duration: visible ? 1.1 : 0.7), value: visible)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Launch flags

/// `--demo` starts the demo at launch; `--demo-seconds N` delays a `--screenshot` until the demo
/// has run N seconds. `--intro` shows the intro (`--intro-page K` opens page K, from 1).
enum DemoLaunch {
    struct Flags {
        var demo = false
        var demoSeconds: Double?
        var intro = false
        var introPage = 0
    }

    static let flags: Flags = {
        var f = Flags()
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--demo": f.demo = true
            case "--demo-seconds":
                if i + 1 < args.count { f.demoSeconds = Double(args[i + 1]); i += 1 }
                f.demo = true
            case "--intro": f.intro = true
            case "--intro-page":
                if i + 1 < args.count { f.introPage = max((Int(args[i + 1]) ?? 1) - 1, 0); i += 1 }
                f.intro = true
            default: break
            }
            i += 1
        }
        return f
    }()

    /// True when an automated capture (screenshot, recording, card) is running.
    static var automated: Bool {
        let o = AppEnvironment.shared.options
        return o.screenshot != nil || o.record != nil || o.card != nil || o.soundTest != nil
    }

    static func apply(model: AppModel, renderer: Renderer) {
        let f = flags
        if f.demo {
            DispatchQueue.main.async { DemoDirector.shared.start() }
        } else if f.intro {
            DispatchQueue.main.async { IntroCoordinator.shared.present(page: f.introPage) }
        }
    }

    /// Holds a `--screenshot` until the requested moment of the demo or intro.
    static var readyToCapture: Bool {
        let f = flags
        if let s = f.demoSeconds { return DemoDirector.shared.isActive && DemoDirector.shared.elapsed >= s }
        if f.intro { return IntroCoordinator.shared.settled }
        return true
    }
}
