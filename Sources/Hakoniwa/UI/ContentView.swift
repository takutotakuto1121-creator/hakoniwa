import HakoniwaCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            WorldView(model: model)
                .ignoresSafeArea()
            if !TimelapsePlayer.shared.active { NameTagLayer() }
            if TimelapsePlayer.shared.active {
                TimelapseOverlay(player: TimelapsePlayer.shared)
                    .transition(.opacity)
            } else if model.showPanels {
                overlay
                    .transition(.opacity)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Button { withAnimation(.easeOut(duration: 0.2)) { model.showPanels = true } } label: {
                            Image(systemName: "sidebar.squares.left").font(.system(size: 13, weight: .semibold))
                                .padding(9)
                        }
                        .buttonStyle(.plain)
                        .glass(12)
                        .help("パネルを表示 (H)")
                    }
                    Spacer()
                }
                .padding(14)
            }
            PetOverlay(model: model)
            EncyclopediaHost()
            ToastView(model: model)
            DuelHost()
        }
        .sheet(isPresented: $model.showNewWorldSheet) { NewWorldSheet(model: model) }
        .animation(.easeOut(duration: 0.2), value: model.showPanels)
    }

    private var overlay: some View {
        VStack(spacing: 10) {
            TopBar(model: model)
            HStack(alignment: .top, spacing: 10) {
                // Scrollable so that short windows never push the layout beyond the window.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ToolPalette(model: model)
                        GodPalette(model: model)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if model.showInspector, model.detail != nil {
                    InspectorPanel(model: model)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if model.showBottom {
                BottomPanel(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.detail?.uid)
        .animation(.easeOut(duration: 0.2), value: model.showBottom)
    }
}

struct ToastView: View {
    var model: AppModel
    var body: some View {
        VStack {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .glass(20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(model.toastID)
            }
            Spacer()
        }
        .padding(.top, 92)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.toastID)
    }
}

struct ToolPalette: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 4) {
            ForEach(Tool.allCases) { t in
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(model.tool == t ? Color.black : Color.white.opacity(0.85))
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(model.tool == t ? Palette.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(t.label) (\(t.shortcut))")
            }
            Divider().frame(width: 24).overlay(Palette.hairline)
            Button { AppEnvironment.shared.takeScreenshot() } label: {
                Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .help("スクリーンショット (⇧⌘S)")
            Button { AppEnvironment.shared.toggleRecording() } label: {
                Image(systemName: model.recording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.recording ? Palette.carnivore : .white.opacity(0.85))
                    .symbolEffect(.pulse, isActive: model.recording)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .help(model.recording ? "録画を停止 (⌘R)" : "録画を開始 (⌘R)")
        }
        .padding(5)
        .glass(14)
    }
}

struct NewWorldSheet: View {
    @Bindable var model: AppModel
    @State private var seedText = String(UInt64.random(in: 1...99_999))
    @State private var creatures = 900.0
    @State private var size: WorldSizePreset = .standard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "globe.asia.australia.fill").font(.system(size: 22)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新しい世界").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("ランダムな原初の生命から、進化をやり直します").font(.system(size: 11.5)).foregroundStyle(Palette.textDim)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("シード").foregroundStyle(Palette.textDim)
                    HStack {
                        TextField("シード", text: $seedText).textFieldStyle(.roundedBorder).frame(width: 140).monospacedDigit()
                        Button { seedText = String(UInt64.random(in: 1...99_999)) } label: { Image(systemName: "dice.fill") }
                            .help("ランダムなシード")
                    }
                }
                GridRow {
                    Text("初期個体数").foregroundStyle(Palette.textDim)
                    HStack {
                        Slider(value: $creatures, in: 200...2000, step: 50).frame(width: 200)
                        Text("\(Int(creatures))匹").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("世界の大きさ").foregroundStyle(Palette.textDim)
                    Picker("", selection: $size) {
                        ForEach(WorldSizePreset.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
            }
            .font(.system(size: 12.5))
            Text("同じシードなら、いつでも同じ進化が再現されます。").font(.system(size: 11)).foregroundStyle(Palette.textFaint)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("世界を作る") {
                    let seed = UInt64(seedText) ?? UInt64(abs(seedText.hashValue) % 100_000)
                    AppEnvironment.shared.newWorld(seed: seed, initialCreatures: Int(creatures), size: size)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
