import AVFoundation
import HakoniwaCore
import Observation
import os
import QuartzCore
import SwiftUI

// Generative ambient sound: a quiet underwater bed (filtered surf, a slow pad, the odd bubble) plus soft
// notes for what happens on screen — hatching, predation, meteors, and creatures calling to each other.
// Everything is synthesised in one AVAudioSourceNode, then darkened and sent through a large reverb.
// Notes come from one pentatonic scale, are rate-limited per kind and panned to where they happen.

/// One note request, from the main thread to the audio thread.
struct SoundTrigger {
    enum Kind: UInt8 { case bell, thump, boom, call, bubble }
    var kind: Kind
    var freq: Float
    var pan: Float      // -1 left ... 1 right
    var gain: Float
}

/// Fixed-size hand-off queue. The audio thread only ever try-locks, so it never blocks.
final class TriggerQueue: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let items: UnsafeMutablePointer<SoundTrigger>
    private let capacity = 64
    private var count = 0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        items = .allocate(capacity: capacity)
        items.initialize(repeating: SoundTrigger(kind: .bell, freq: 0, pan: 0, gain: 0), count: capacity)
    }

    deinit {
        lock.deallocate()
        items.deallocate()
    }

    func push(_ t: SoundTrigger) {
        os_unfair_lock_lock(lock)
        if count < capacity { items[count] = t; count += 1 }
        os_unfair_lock_unlock(lock)
    }

    /// Audio thread.
    func drain(_ body: (SoundTrigger) -> Void) {
        guard os_unfair_lock_trylock(lock) else { return }
        for i in 0..<count { body(items[i]) }
        count = 0
        os_unfair_lock_unlock(lock)
    }
}

/// The synthesiser. All state is touched only on the audio render thread.
final class AmbientSynth: @unchecked Sendable {
    private struct Voice {
        var active = false
        var kind = SoundTrigger.Kind.bell
        var phase: Float = 0
        var freq: Float = 0
        var age: Float = 0
        var attack: Float = 0.005
        var decay: Float = 0.5
        var gain: Float = 0
        var left: Float = 0.7
        var right: Float = 0.7
        var lp: Float = 0
    }

    let queue = TriggerQueue()
    private let sampleRate: Float
    private let dt: Float
    private var voices: [Voice] = Array(repeating: Voice(), count: 32)
    private var rng: UInt32 = 0x9E37_79B9
    private var time: Double = 0
    // Surf: two-pole low-passed noise per channel.
    private var surfL1: Float = 0, surfL2: Float = 0, surfR1: Float = 0, surfR2: Float = 0
    private let surfK: Float
    // Pad: D2 A2 E3 F#3 A3, each a slightly detuned pair (L/R) with its own slow swell.
    private let padFreqs: [Float] = [73.42, 110.0, 164.81, 185.0, 220.0]
    private let padRates: [Float] = [0.023, 0.031, 0.047, 0.039, 0.057]
    private let padGains: [Float] = [0.020, 0.016, 0.010, 0.008, 0.007]
    private var padPhaseL: [Float] = [0, 0, 0, 0, 0]
    private var padPhaseR: [Float] = [0.3, 1.1, 2.0, 0.7, 2.6]
    private var padAmp: [Float] = [0, 0, 0, 0, 0]
    private var nextBubble: Double = 3

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        dt = 1 / Float(sampleRate)
        surfK = 1 - exp(-2 * .pi * 320 / Float(sampleRate))
    }

    private func random() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng) / Float(UInt32.max)
    }

    private func start(_ t: SoundTrigger) {
        var slot = -1
        var oldest: Float = -1
        for i in 0..<voices.count {
            if !voices[i].active { slot = i; break }
            if voices[i].age > oldest { oldest = voices[i].age; slot = i }
        }
        guard slot >= 0 else { return }
        var v = Voice()
        v.active = true
        v.kind = t.kind
        v.freq = t.freq
        v.gain = t.gain
        let p = max(-1, min(1, t.pan))
        v.left = ((1 - p) / 2).squareRoot()
        v.right = ((1 + p) / 2).squareRoot()
        switch t.kind {
        case .bell: v.attack = 0.004; v.decay = 0.9
        case .thump: v.attack = 0.003; v.decay = 0.28
        case .boom: v.attack = 0.02; v.decay = 2.2
        case .call: v.attack = 0.22; v.decay = 0.9
        case .bubble: v.attack = 0.002; v.decay = 0.05
        }
        voices[slot] = v
    }

    /// Fills `frames` samples of stereo audio.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        queue.drain { start($0) }

        // Slowly varying parameters, updated once per block.
        let t = Float(time)
        let swell = 0.62 + 0.38 * sin(2 * .pi * 0.045 * t) * sin(2 * .pi * 0.017 * t + 1.3)
        let surfGain: Float = 0.11 * swell
        for k in 0..<5 {
            let s = 0.5 + 0.5 * sin(2 * .pi * padRates[k] * t + Float(k) * 1.7)
            padAmp[k] = padGains[k] * (0.25 + 0.75 * s * s)
        }
        if time >= nextBubble {
            // A short train of 1-3 bubbles rising past.
            let n = 1 + Int(random() * 3)
            for j in 0..<n {
                start(SoundTrigger(kind: .bubble, freq: 380 + random() * 500 + Float(j) * 90, pan: random() * 1.6 - 0.8,
                                   gain: 0.010 + random() * 0.008))
            }
            nextBubble = time + 2.5 + Double(random()) * 7
        }

        for n in 0..<frames {
            // Surf.
            let wl = random() * 2 - 1, wr = random() * 2 - 1
            surfL1 += (wl - surfL1) * surfK; surfL2 += (surfL1 - surfL2) * surfK
            surfR1 += (wr - surfR1) * surfK; surfR2 += (surfR1 - surfR2) * surfK
            var l = surfL2 * surfGain * 3
            var r = surfR2 * surfGain * 3
            // Pad.
            for k in 0..<5 {
                padPhaseL[k] += 2 * .pi * padFreqs[k] * dt
                padPhaseR[k] += 2 * .pi * padFreqs[k] * 1.0021 * dt
                if padPhaseL[k] > 2 * .pi { padPhaseL[k] -= 2 * .pi }
                if padPhaseR[k] > 2 * .pi { padPhaseR[k] -= 2 * .pi }
                l += sin(padPhaseL[k]) * padAmp[k]
                r += sin(padPhaseR[k]) * padAmp[k]
            }
            // Notes.
            for i in 0..<voices.count where voices[i].active {
                var v = voices[i]
                let env = min(1, v.age / v.attack) * exp(-max(0, v.age - v.attack) / v.decay)
                var s: Float
                switch v.kind {
                case .bell:
                    // Sine with a quickly fading octave for a soft mallet attack.
                    v.phase += 2 * .pi * v.freq * dt
                    s = sin(v.phase) + 0.3 * sin(2 * v.phase) * exp(-v.age * 9)
                case .thump:
                    // Falling pitch plus a muffled noise click.
                    v.phase += 2 * .pi * v.freq * (0.65 + 0.35 * exp(-v.age * 14)) * dt
                    v.lp += (random() * 2 - 1 - v.lp) * 0.08
                    s = sin(v.phase) + v.lp * 1.6 * exp(-v.age * 40)
                case .boom:
                    // Deep falling sine and a long rumble.
                    v.phase += 2 * .pi * v.freq * (0.45 + 0.55 * exp(-v.age * 1.8)) * dt
                    v.lp += (random() * 2 - 1 - v.lp) * 0.02
                    s = sin(v.phase) * 0.8 + v.lp * 4 * exp(-v.age * 1.2)
                case .call:
                    // A gentle rising glide with a little vibrato, like a distant whale.
                    let glide = 1 + 0.5 * (1 - exp(-v.age * 3))
                    v.phase += 2 * .pi * v.freq * glide * (1 + 0.006 * sin(v.age * 31)) * dt
                    s = sin(v.phase) + 0.12 * sin(3 * v.phase)
                case .bubble:
                    v.phase += 2 * .pi * v.freq * (1 + v.age * 30) * dt
                    s = sin(v.phase)
                }
                if v.phase > 1000 { v.phase -= 2 * .pi * 159 }
                let out = s * env * v.gain
                l += out * v.left
                r += out * v.right
                v.age += dt
                if v.age > v.attack + v.decay * 8 { v.active = false }
                voices[i] = v
            }
            // Gentle saturation keeps rare pile-ups from clipping.
            left[n] = tanh(l)
            right[n] = tanh(r)
        }
        time += Double(frames) * Double(dt)
    }
}

/// App-facing controller: owns the AVAudioEngine, turns world events into notes.
@Observable
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled = false { didSet { if enabled != oldValue { enabled ? start() : stop() } } }
    var volume: Double = 0.6 {
        didSet {
            engine.mainMixerNode.outputVolume = Float(volume)
            UserDefaults.standard.set(volume, forKey: "hakoniwa.soundVolume")
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var synth: AmbientSynth?
    @ObservationIgnored private var built = false
    @ObservationIgnored private var lastSignalCheck: CFTimeInterval = 0
    /// Token buckets per kind (notes allowed now, refill per second, cap).
    @ObservationIgnored private var tokens: [SoundTrigger.Kind: Double] = [:]
    @ObservationIgnored private var lastRefill: CFTimeInterval = CACurrentMediaTime()
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()

    /// D major pentatonic, D4 upward.
    private static let scale: [Float] = [293.66, 329.63, 369.99, 440.0, 493.88]

    private init() {
        if let v = UserDefaults.standard.object(forKey: "hakoniwa.soundVolume") as? Double { volume = v }
    }

    // MARK: Engine

    /// Builds the graph: synth → low-pass (underwater) → reverb → output.
    private func build(on engine: AVAudioEngine, sampleRate: Double) -> AmbientSynth {
        let synth = AmbientSynth(sampleRate: sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        eq.bands[0].filterType = .lowPass
        eq.bands[0].frequency = 2600
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .highPass
        eq.bands[1].frequency = 38
        eq.bands[1].bypass = false
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 45
        engine.attach(source)
        engine.attach(eq)
        engine.attach(reverb)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        return synth
    }

    private func start() {
        if !built {
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            synth = build(on: engine, sampleRate: rate > 0 ? rate : 48000)
            built = true
        }
        engine.mainMixerNode.outputVolume = Float(volume)
        do {
            try engine.start()
        } catch {
            NSLog("sound: could not start audio engine: \(error)")
            DispatchQueue.main.async { self.enabled = false }
        }
    }

    private func stop() {
        engine.pause()
    }

    // MARK: Events

    private func take(_ kind: SoundTrigger.Kind, now: CFTimeInterval) -> Bool {
        let t = tokens[kind] ?? 1
        guard t >= 1 else { return false }
        tokens[kind] = t - 1
        return true
    }

    private func refill(now: CFTimeInterval) {
        let dt = min(now - lastRefill, 1)
        lastRefill = now
        // Notes per second (and burst size) for each kind.
        let rates: [(SoundTrigger.Kind, Double, Double)] = [(.bell, 2.2, 3), (.thump, 1.6, 2), (.call, 0.9, 1), (.boom, 1, 1)]
        for (k, rate, cap) in rates { tokens[k] = min(cap, (tokens[k] ?? cap) + rate * dt) }
    }

    private func note(_ hue: Float, octave: Float) -> Float {
        let h = hue - hue.rounded(.down)
        return Self.scale[min(Int(h * 5), 4)] * octave
    }

    /// Called by the renderer every frame (main thread) with the new effects and the visible creatures.
    func observe(fx: [FXEvent], camera: Camera, creatures: UnsafePointer<CreatureInstance>, count: Int,
                 paused: Bool, now: CFTimeInterval) {
        guard enabled, let synth else { return }
        refill(now: now)
        let view = camera.viewSize
        func screen(_ p: V2) -> (visible: Bool, pan: Float) {
            let px = camera.pixel(world: p)
            let margin = view * 0.1
            let visible = px.x > -margin.x && px.y > -margin.y && px.x < view.x + margin.x && px.y < view.y + margin.y
            return (visible, max(-1, min(1, px.x / max(view.x, 1) * 2 - 1)) * 0.75)
        }
        for e in fx {
            let s = screen(e.position)
            switch e.kind {
            case .meteor:
                if take(.boom, now: now) {
                    synth.queue.push(SoundTrigger(kind: .boom, freq: 62, pan: s.visible ? s.pan * 0.5 : 0, gain: 0.4))
                }
            case .birth, .hatch:
                guard s.visible, take(.bell, now: now) else { continue }
                synth.queue.push(SoundTrigger(kind: .bell, freq: note(e.hue, octave: 2), pan: s.pan,
                                              gain: e.kind == .birth ? 0.07 : 0.045))
            case .kill:
                guard s.visible, take(.thump, now: now) else { continue }
                synth.queue.push(SoundTrigger(kind: .thump, freq: note(e.hue, octave: 0.5), pan: s.pan, gain: 0.16))
            case .death, .feed:
                break
            }
        }

        // Creature calls: a few times a second, look at who is signalling on screen and sometimes voice one.
        guard !paused, now - lastSignalCheck > 0.3 else { return }
        lastSignalCheck = now
        var visible = 0, calling = 0
        var pick: CreatureInstance?
        for i in 0..<count {
            let c = creatures[i]
            if c.flags.truncatingRemainder(dividingBy: 2) >= 1 { continue }
            let s = screen(c.position)
            guard s.visible else { continue }
            visible += 1
            if c.signal > 0.55 {
                calling += 1
                if Int.random(in: 0..<calling, using: &rng) == 0 { pick = c }
            }
        }
        guard visible > 0, let c = pick else { return }
        let share = Double(calling) / Double(visible)
        guard Double.random(in: 0..<1, using: &rng) < min(0.35, 0.08 + share * 0.6), take(.call, now: now) else { return }
        synth.queue.push(SoundTrigger(kind: .call, freq: note(c.hue, octave: 1), pan: screen(c.position).pan,
                                      gain: 0.03 + 0.03 * min(c.signal, 1)))
    }

    // MARK: Offline check

    /// Renders `seconds` of the full graph offline with a scripted set of events, writes a WAV file and
    /// returns level statistics (for automated checks; the live engine is untouched).
    func renderOffline(to url: URL, seconds: Double) throws -> String {
        let engine = AVAudioEngine()
        let rate = 48000.0
        let synth = build(on: engine, sampleRate: rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        engine.mainMixerNode.outputVolume = 1
        try engine.start()
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        // Script: quiet bed, then births, a kill, calls, and a meteor at 6 s.
        var script: [(Double, SoundTrigger)] = []
        for k in 0..<6 { script.append((1.5 + Double(k) * 0.45, SoundTrigger(kind: .bell, freq: Self.scale[k % 5] * 2, pan: Float(k) / 3 - 0.8, gain: 0.045))) }
        script.append((3.0, SoundTrigger(kind: .thump, freq: Self.scale[1] * 0.5, pan: 0.3, gain: 0.16)))
        script.append((3.8, SoundTrigger(kind: .call, freq: Self.scale[3], pan: -0.4, gain: 0.05)))
        script.append((4.6, SoundTrigger(kind: .call, freq: Self.scale[0], pan: 0.5, gain: 0.05)))
        script.append((6.0, SoundTrigger(kind: .boom, freq: 62, pan: 0, gain: 0.4)))
        var report: [String] = []
        var t = 0.0
        var segPeak: Float = 0, segSum: Double = 0, segN = 0, segStart = 0.0
        while t < seconds {
            for (at, trig) in script where at >= t && at < t + 4096 / rate { synth.queue.push(trig) }
            let status = try engine.renderOffline(4096, to: buffer)
            guard status == .success else { break }
            try file.write(from: buffer)
            let n = Int(buffer.frameLength)
            for ch in 0..<2 {
                let p = buffer.floatChannelData![ch]
                for i in 0..<n { let v = p[i]; segPeak = max(segPeak, abs(v)); segSum += Double(v * v) }
            }
            segN += n * 2
            t += Double(n) / rate
            if t - segStart >= 1 {
                let rms = (segSum / Double(max(segN, 1))).squareRoot()
                report.append(String(format: "%4.1f-%4.1fs rms %6.1f dBFS peak %6.1f dBFS", segStart, t,
                                     20 * log10(max(rms, 1e-9)), 20 * log10(max(Double(segPeak), 1e-9))))
                segStart = t; segPeak = 0; segSum = 0; segN = 0
            }
        }
        engine.stop()
        return report.joined(separator: "\n")
    }
}

/// Sound on/off and volume, for the top bar.
struct SoundControl: View {
    @Bindable var sound = SoundEngine.shared

    var body: some View {
        HStack(spacing: 6) {
            Button { sound.enabled.toggle() } label: {
                Image(systemName: sound.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(sound.enabled ? Palette.accent : .white.opacity(0.7))
                    .frame(width: 30, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sound.enabled ? "音を消す" : "音を鳴らす(水中の環境音)")
            if sound.enabled {
                Slider(value: $sound.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 64)
                    .help("音量")
            }
        }
    }
}
