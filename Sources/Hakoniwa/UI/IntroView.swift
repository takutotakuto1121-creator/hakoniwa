import AppKit
import HakoniwaCore
import Observation
import SwiftUI

/// The short introduction laid over the live world at first launch (and from the Help menu).
@Observable
final class IntroCoordinator {
    static let shared = IntroCoordinator()
    static let shownKey = "hakoniwa.introShown.v1"
    static let pageCount = 4

    private(set) var isPresented = false
    var page = 0
    /// Direction of the last page turn, for the slide transition.
    private(set) var forward = true
    @ObservationIgnored private var presentedAt: CFTimeInterval = 0
    @ObservationIgnored private var panelsWereShown = true

    /// True once the current page has finished animating in (for automated screenshots).
    var settled: Bool { isPresented && CACurrentMediaTime() - presentedAt > 2.2 }

    /// Shows the intro once per user, never during automated captures.
    func presentIfFirstLaunch() {
        guard !DemoLaunch.automated, !DemoLaunch.flags.demo, !DuelLaunch.requested else { return }
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        // Let the world fade in first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.present() }
    }

    func present(page p: Int = 0) {
        guard !isPresented else { page = p; return }
        if DemoDirector.shared.isActive { DemoDirector.shared.stop() }
        let m = AppEnvironment.shared.model
        panelsWereShown = m.showPanels
        page = min(max(p, 0), Self.pageCount - 1)
        forward = true
        presentedAt = CACurrentMediaTime()
        // Present first, so the "show panels" button never appears underneath.
        withAnimation(.easeOut(duration: 0.8)) { isPresented = true }
        withAnimation(.easeOut(duration: 0.35)) { m.showPanels = false }
    }

    func close(startDemo: Bool = false) {
        guard isPresented else { return }
        if !DemoLaunch.automated { UserDefaults.standard.set(true, forKey: Self.shownKey) }
        withAnimation(.easeInOut(duration: 0.6)) { isPresented = false }
        let m = AppEnvironment.shared.model
        if startDemo {
            // The panels stay hidden; the demo shows them again when it ends.
            DemoDirector.shared.restorePanelsAfterIntro = panelsWereShown
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { DemoDirector.shared.start() }
        } else {
            withAnimation(.easeOut(duration: 0.5).delay(0.25)) { m.showPanels = panelsWereShown }
        }
    }

    func next() {
        if page >= Self.pageCount - 1 { close(); return }
        forward = true
        withAnimation(.easeInOut(duration: 0.5)) { page += 1 }
    }

    func back() {
        guard page > 0 else { return }
        forward = false
        withAnimation(.easeInOut(duration: 0.5)) { page -= 1 }
    }

    /// Arrow keys and Return turn pages, Esc closes. Every other key is swallowed while shown.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        switch event.keyCode {
        case 53: close()                   // esc
        case 36, 76, 124, 49: next()       // return, enter, right arrow, space
        case 123: back()                   // left arrow
        default: break
        }
        return true
    }
}

struct IntroHost: View {
    var intro = IntroCoordinator.shared
    var body: some View {
        ZStack {
            if intro.isPresented {
                IntroView(intro: intro, model: AppEnvironment.shared.model)
                    .transition(.opacity)
            }
        }
        .onAppear { intro.presentIfFirstLaunch() }
    }
}

struct IntroView: View {
    var intro: IntroCoordinator
    var model: AppModel

    private struct Page {
        var kicker: String
        var title: String
        var body: String
    }

    private let pages: [Page] = [
        Page(kicker: "箱庭へようこそ",
             title: "この世界の生き物の行動は、\nどれも誰もプログラムしていない。",
             body: "餌に向かうことも、獲物を追うことも、コードには書かれていない。\n書かれているのは、物理と代謝と感覚器だけ。\n行動はすべて、世代を重ねるなかで生き物たち自身が獲得したもの。"),
        Page(kicker: "脳と遺伝子",
             title: "脳はニューラルネット、\n体は遺伝子で決まる。",
             body: "目に映る植物・肉・ほかの生き物の近さが、36の入力として小さな脳に届く。\n16個のニューロンを経て、7つの出力が決まる ― 進む・曲がる・噛む・食べる・卵を産む・2つの信号。\n体の大きさ・食性・色・形は遺伝子が決め、子に受け継がれるとき少しずつ変わる。"),
        Page(kicker: "進化",
             title: "うまく生きた者が、\n次の世代を残す。",
             body: "エネルギーを十分に集めた個体だけが卵を産める。\n少しずつ違う子どもたちのうち、うまく食べられた者がまた子を残す。\nその繰り返しで脳が磨かれ、種は枝分かれしていく。"),
        Page(kicker: "操作の仕方",
             title: "眺めて、触れてみよう。",
             body: ""),
    ]

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                pageContent
                    .frame(maxWidth: 700, alignment: .leading)
                    .id(intro.page)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: intro.forward ? 36 : -36)),
                        removal: .opacity.combined(with: .offset(x: intro.forward ? -36 : 36))))
                Spacer(minLength: 40)
                footer
                    .frame(maxWidth: 700)
                    .padding(.bottom, 54)
            }
            .padding(.horizontal, 48)
        }
        .ignoresSafeArea()
    }

    private var backdrop: some View {
        ZStack {
            Color.black.opacity(0.64)
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 120, endRadius: 900)
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // keep clicks from reaching the world
    }

    @ViewBuilder private var pageContent: some View {
        let p = pages[min(intro.page, pages.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(String(format: "%02d", intro.page + 1))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.accent)
                Rectangle().fill(Palette.accent.opacity(0.5)).frame(width: 28, height: 1)
                Text(p.kicker)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.bottom, 26)
            Text(p.title)
                .font(.custom("HiraMinProN-W6", size: 40))
                .lineSpacing(12)
                .foregroundStyle(.white)
                .shadow(color: Palette.accent.opacity(0.25), radius: 18)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 30)
            if intro.page == IntroCoordinator.pageCount - 1 {
                controls
            } else {
                Text(p.body)
                    .font(.custom("HiraMinProN-W3", size: 16.5))
                    .lineSpacing(11)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                if intro.page == 0 && model.population > 0 {
                    liveLine.padding(.top, 34)
                }
            }
        }
    }

    private var liveLine: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.herbivore).frame(width: 6, height: 6)
                .shadow(color: Palette.herbivore, radius: 4)
            Text("いまこの箱庭には \(model.speciesAlive)種・\(formatCount(model.population))匹。最も進んだ系統は第\(model.maxGeneration)世代。")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 15) {
            row(["クリック"], "生き物を選ぶ。脳の動き・遺伝子・系統が見える")
            row(["ダブルクリック"], "その生き物を追いかける")
            row(["ドラッグ", "スクロール"], "移動・ズーム(トラックパッドはピンチでズーム)")
            row(["space"], "一時停止 / 再開")
            row(["1", "–", "5"], "速度(1×〜最大)。早送りすると進化が進む")
            row(["⌘⇧D"], "デモモード ― 見どころをカメラが自動で巡る")
            row(["H"], "パネルを隠す / 表示")
        }
    }

    private func row(_ keys: [String], _ text: String) -> some View {
        GridRow {
            HStack(spacing: 5) {
                ForEach(keys, id: \.self) { k in
                    if k == "–" {
                        Text("〜").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    } else {
                        Text(k)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    }
                }
            }
            .gridColumnAlignment(.trailing)
            Text(text)
                .font(.custom("HiraMinProN-W3", size: 15))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<IntroCoordinator.pageCount, id: \.self) { k in
                    Capsule()
                        .fill(k == intro.page ? Palette.accent : Color.white.opacity(0.22))
                        .frame(width: k == intro.page ? 22 : 6, height: 6)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.5)) { intro.page = k }
                        }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: intro.page)
            Spacer()
            let last = intro.page == IntroCoordinator.pageCount - 1
            if !last {
                Button("スキップ") { intro.close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Button { intro.close(startDemo: true) } label: {
                    Label("デモを見る", systemImage: "film.stack")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { intro.next() } label: {
                HStack(spacing: 8) {
                    Text(last ? "始める" : "次へ")
                    Image(systemName: last ? "arrow.right.circle.fill" : "arrow.right")
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(Palette.accent))
                .shadow(color: Palette.accent.opacity(0.5), radius: 12)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
