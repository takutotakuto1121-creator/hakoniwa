import AppKit
import HakoniwaCore
import Observation
import SwiftUI

/// Plays back the recorded history of the world (one frame every three minutes of world
/// time) as a time-lapse that ends on the present moment. The live simulation is paused
/// while it plays and restored afterwards.
@Observable
final class TimelapsePlayer {
    static let shared = TimelapsePlayer()

    struct Marker: Identifiable {
        var id: Int
        var time: Double
        var kind: EventKind
        var message: String
    }

    struct Point {
        var time: Double
        var population: Int
        var carnivores: Int
    }

    private(set) var active = false
    private(set) var loading = false
    var playing = false
    /// Playback speed relative to the base rate (10 hours in about 30 seconds).
    var speedFactor: Double = 1
    /// Current playhead, world seconds.
    private(set) var time: Double = 0
    private(set) var startTime: Double = 0
    private(set) var endTime: Double = 1
    private(set) var series: [Point] = []
    private(set) var markers: [Marker] = []
    private(set) var population = 0
    private(set) var carnivores = 0
    private(set) var generation = 0
    /// World seconds advanced per wall second at speed 1×.
    private(set) var baseRate: Double = 1200

    @ObservationIgnored private var playback: HistoryPlayback?
    @ObservationIgnored private var lastWall: CFTimeInterval = 0
    @ObservationIgnored private var endedAt: CFTimeInterval?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var wasPaused = false
    @ObservationIgnored private var wasFollowing = false
    @ObservationIgnored private var savedCamera: (center: V2, zoom: Float)?
    @ObservationIgnored private var worldID = 0

    private var env: AppEnvironment { AppEnvironment.shared }

    var progress: Double { (time - startTime) / max(endTime - startTime, 1e-6) }
    var atEnd: Bool { time >= endTime - 1e-6 }

    // MARK: Start / stop

    /// Collects the history on the simulation thread and starts playing.
    /// `seek` (0...1) starts at that position, paused unless `play` (used for automated captures).
    func start(seek: Double? = nil, play: Bool = false) {
        guard !active, !loading else { return }
        let model = env.model
        loading = true
        wasPaused = model.paused
        // Freeze the world first so the final frame matches what is on screen afterwards.
        model.paused = true
        env.controller.perform { [weak self] w in
            let frames = w.history
            let present = w.presentFrame()
            let backdrop = w.historyBackdrop()
            let notable: Set<EventKind> = [.milestone, .firstCarnivore, .collapse, .intervention]
            let events = w.events.filter { notable.contains($0.kind) && $0.tick > 0 }
            DispatchQueue.main.async {
                self?.begin(frames: frames, present: present, backdrop: backdrop, events: events, seek: seek, play: play)
            }
        }
    }

    private func begin(frames history: [HistoryFrame], present: HistoryFrame, backdrop: HistoryBackdrop,
                       events: [WorldEvent], seek: Double?, play: Bool) {
        loading = false
        let model = env.model
        var frames = history.filter { $0.tick < present.tick }
        frames.append(present)
        guard frames.count >= 2, let renderer = model.renderer else {
            model.paused = wasPaused
            model.showToast("まだ歴史が記録されていません(世界時間3分ごとに記録されます)")
            return
        }
        let pb = HistoryPlayback(frames: frames, backdrop: backdrop, referencePlants: present.plants.count / 2)
        playback = pb
        startTime = pb.startTime
        endTime = pb.endTime
        let span = endTime - startTime
        // 10 hours in ~30 s; short histories still last ~10 s, very long ones at most ~60 s.
        baseRate = max(min(1200, span / 10), span / 60)
        series = zip(pb.times, frames).map { Point(time: $0, population: Int($1.population), carnivores: Int($1.carnivores)) }
        let tps = Double(backdrop.ticksPerSecond)
        markers = events.map { Marker(id: $0.id, time: Double($0.tick) / tps, kind: $0.kind, message: $0.message) }
            .filter { $0.time >= startTime && $0.time <= endTime }
        worldID = model.worldID

        wasFollowing = model.following
        model.following = false
        let cam = renderer.camera
        savedCamera = (cam.targetCenter, cam.targetZoom)
        cam.targetZoom = cam.minZoom

        if let s = seek {
            time = startTime + span * min(max(s, 0), 1)
            playing = play
        } else {
            time = startTime
            playing = true
        }
        endedAt = nil
        lastWall = CACurrentMediaTime()
        updateStats()
        renderer.snapshotSource = { [weak self] now in self?.frame(now) }
        withAnimation(.easeOut(duration: 0.35)) { active = true }
    }

    /// Leaves the time-lapse and returns to the live world.
    func stop() {
        guard active else { return }
        let model = env.model
        model.renderer?.snapshotSource = nil
        if let r = model.renderer, let s = savedCamera {
            r.camera.targetCenter = s.center
            r.camera.targetZoom = s.zoom
        }
        if model.worldID == worldID {
            model.following = wasFollowing && model.selectedUid != 0
            model.paused = wasPaused
        }
        playback = nil
        playing = false
        withAnimation(.easeOut(duration: 0.3)) { active = false }
    }

    func toggle() { active ? stop() : start() }

    // MARK: Playback

    func togglePlay() {
        if !playing && atEnd { time = startTime }
        playing.toggle()
        endedAt = nil
        lastWall = CACurrentMediaTime()
    }

    func seek(toFraction f: Double) {
        time = startTime + (endTime - startTime) * min(max(f, 0), 1)
        endedAt = nil
        updateStats()
    }

    func seek(by worldSeconds: Double) {
        seek(toFraction: (time + worldSeconds - startTime) / max(endTime - startTime, 1e-6))
    }

    func setScrubbing(_ on: Bool) {
        scrubbing = on
        lastWall = CACurrentMediaTime()
    }

    private func updateStats() {
        guard let pb = playback else { return }
        let s = pb.stats(at: time)
        if s.population != population { population = s.population }
        if s.carnivores != carnivores { carnivores = s.carnivores }
        if s.generation != generation { generation = s.generation }
    }

    /// Called by the renderer for every frame while active.
    private func frame(_ now: CFTimeInterval) -> RenderSnapshot? {
        guard let pb = playback else { return nil }
        let dt = min(now - lastWall, 0.1)
        lastWall = now
        if playing && !scrubbing {
            let t = min(time + dt * baseRate * speedFactor, endTime)
            time = t
            if t >= endTime {
                playing = false
                endedAt = now
            }
            updateStats()
        }
        if let e = endedAt, now - e > 1.4 {
            // Reached the present: hand back to the live world, which shows the same moment.
            endedAt = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.atEnd, !self.playing else { return }
                self.stop()
                self.env.model.showToast("現在の世界に戻りました")
            }
        }
        if env.model.worldID != worldID {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return nil
        }
        return pb.fill(at: time, wall: now)
    }

    /// Keyboard control while playing. Returns true when consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        let step = (endTime - startTime) / 40
        switch event.keyCode {
        case 49: togglePlay()                        // space
        case 53: stop()                              // escape
        case 123: seek(by: -step)                    // left
        case 124: seek(by: step)                     // right
        case 115: seek(toFraction: 0)                // home
        case 119: seek(toFraction: 1)                // end
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "l": stop()
            case "1": speedFactor = 0.5
            case "2": speedFactor = 1
            case "3": speedFactor = 2
            default: break
            }
        }
        // Swallow every other key so tools and speeds of the live world stay untouched.
        return true
    }
}

// MARK: - Overlay

struct TimelapseOverlay: View {
    var player: TimelapsePlayer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                TimelapseHUD(player: player)
                Spacer()
                closeButton
            }
            Spacer()
            TimelapseCaption(player: player)
                .padding(.bottom, 14)
            TimelapseControls(player: player)
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .background(alignment: .top) {
            // Soft vignette so the large numbers stay readable over a bright world.
            LinearGradient(colors: [Color.black.opacity(0.7), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .background(alignment: .bottom) {
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var closeButton: some View {
        Button { player.stop() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                Text("現在に戻る")
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glass(14)
        .help("タイムラプスを終える (Esc)")
    }
}

private struct TimelapseHUD: View {
    var player: TimelapsePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "film.stack")
                    .foregroundStyle(Palette.accent)
                Text("進化のタイムラプス")
                    .foregroundStyle(.white.opacity(0.8))
                Text(String(format: "%.0f倍速", player.baseRate * player.speedFactor))
                    .foregroundStyle(Palette.textFaint)
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(hm(player.time))
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: Palette.accent.opacity(0.45), radius: 18)
                .contentTransition(.numericText())
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                figure("世代", "第\(player.generation)世代", .white)
                figure("個体数", "\(formatCount(player.population))匹", Palette.herbivore)
                figure("肉食", "\(formatCount(player.carnivores))匹", Palette.carnivore)
            }
        }
        .fixedSize()
    }

    private func figure(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textDim)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.4), radius: 10)
        }
    }

    private func hm(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        return "\(s / 3600)時間\(String(format: "%02d", (s % 3600) / 60))分"
    }
}

/// Recent notable events (new carnivores, generation milestones, disasters) fade in as the
/// playhead passes them.
private struct TimelapseCaption: View {
    var player: TimelapsePlayer

    var body: some View {
        let hold = 2.8 * player.baseRate * player.speedFactor
        let recent = player.markers.filter { $0.time <= player.time && player.time - $0.time < hold }.suffix(2)
        VStack(spacing: 6) {
            ForEach(Array(recent)) { m in
                let age = (player.time - m.time) / hold
                HStack(spacing: 8) {
                    Image(systemName: icon(m.kind)).foregroundStyle(color(m.kind))
                    Text(m.message)
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .glass(16)
                .opacity(age < 0.75 ? 1 : max(0, (1 - age) / 0.25))
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(height: 96, alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: recent.map(\.id))
        .allowsHitTesting(false)
    }
}

private func icon(_ k: EventKind) -> String {
    switch k {
    case .firstCarnivore: return "exclamationmark.triangle.fill"
    case .collapse: return "bolt.fill"
    case .intervention: return "hand.point.up.left.fill"
    default: return "flag.fill"
    }
}

private func color(_ k: EventKind) -> Color {
    switch k {
    case .firstCarnivore, .collapse: return Palette.carnivore
    case .intervention: return Palette.omnivore
    default: return Palette.accent
    }
}

private struct TimelapseControls: View {
    var player: TimelapsePlayer

    var body: some View {
        HStack(spacing: 14) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.playing ? "pause.fill" : (player.atEnd ? "arrow.counterclockwise" : "play.fill"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Palette.accent))
                    .shadow(color: Palette.accent.opacity(0.5), radius: 8)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.playing ? "一時停止 (Space)" : "再生 (Space)")

            VStack(spacing: 4) {
                TimelapseScrubber(player: player)
                    .frame(height: 46)
                HStack {
                    Text(formatWorldTime(player.startTime))
                    Spacer()
                    HStack(spacing: 10) {
                        legend(Palette.herbivore, "個体数")
                        legend(Palette.carnivore, "肉食")
                        legend(Palette.accent, "出来事")
                    }
                    Spacer()
                    Text("現在 " + formatWorldTime(player.endTime))
                }
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.textFaint)
            }

            HStack(spacing: 2) {
                ForEach([0.5, 1.0, 2.0], id: \.self) { f in
                    Button { player.speedFactor = f } label: {
                        Text(f == 0.5 ? "½×" : "\(Int(f))×")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .frame(minWidth: 32, minHeight: 24)
                            .foregroundStyle(player.speedFactor == f ? Color.black : .white.opacity(0.8))
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(player.speedFactor == f ? Palette.accent : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .help("再生速度")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glass(18)
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(s)
        }
    }
}

/// Seek bar drawn over the population history, with event markers and a glowing playhead.
private struct TimelapseScrubber: View {
    var player: TimelapsePlayer
    @State private var hover: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .leading) {
                TimelapseSparkline(series: player.series, markers: player.markers,
                                   start: player.startTime, end: player.endTime)
                    .equatable()
                // Played part is brighter.
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: w * player.progress)
                    .allowsHitTesting(false)
                let x = w * player.progress
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: h + 6)
                    .shadow(color: Palette.accent, radius: 6)
                    .offset(x: x - 1.5)
                    .allowsHitTesting(false)
                if let hv = hover {
                    Text(formatWorldTime(player.startTime + (player.endTime - player.startTime) * hv))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .offset(x: min(max(w * hv - 30, 0), w - 60), y: -h / 2 - 10)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        player.setScrubbing(true)
                        player.seek(toFraction: v.location.x / max(w, 1))
                    }
                    .onEnded { _ in player.setScrubbing(false) }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = min(max(p.x / max(w, 1), 0), 1)
                case .ended: hover = nil
                }
            }
        }
    }
}

/// Static background of the scrubber; only redrawn when the history changes.
private struct TimelapseSparkline: View, Equatable {
    let series: [TimelapsePlayer.Point]
    let markers: [TimelapsePlayer.Marker]
    let start: Double
    let end: Double

    static func == (a: Self, b: Self) -> Bool {
        a.series.count == b.series.count && a.markers.count == b.markers.count && a.start == b.start && a.end == b.end
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.white.opacity(0.05)))
            guard series.count > 1 else { return }
            let span = max(end - start, 1e-6)
            let peak = Double(max(series.map(\.population).max() ?? 1, 1)) * 1.08
            func pt(_ t: Double, _ v: Int) -> CGPoint {
                CGPoint(x: (t - start) / span * size.width, y: size.height - Double(v) / peak * (size.height - 4))
            }
            func area(_ value: (TimelapsePlayer.Point) -> Int) -> (Path, Path) {
                var line = Path()
                for (k, p) in series.enumerated() {
                    let q = pt(p.time, value(p))
                    if k == 0 { line.move(to: q) } else { line.addLine(to: q) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                return (line, fill)
            }
            let (pl, pf) = area { $0.population }
            ctx.fill(pf, with: .linearGradient(Gradient(colors: [Palette.herbivore.opacity(0.32), Palette.herbivore.opacity(0.04)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(pl, with: .color(Palette.herbivore.opacity(0.85)), lineWidth: 1.3)
            let (cl, cf) = area { $0.carnivores }
            ctx.fill(cf, with: .color(Palette.carnivore.opacity(0.28)))
            ctx.stroke(cl, with: .color(Palette.carnivore.opacity(0.9)), lineWidth: 1.2)
            for m in markers {
                let x = (m.time - start) / span * size.width
                let c: Color = m.kind == .firstCarnivore || m.kind == .collapse ? Palette.carnivore
                    : (m.kind == .intervention ? Palette.omnivore : Palette.accent)
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(c.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 2, width: 5, height: 5)), with: .color(c))
            }
        }
        .allowsHitTesting(false)
    }
}
