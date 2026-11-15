import AppKit
import HakoniwaCore
import MetalKit
import SwiftUI

/// MTKView that turns mouse, trackpad and scroll input into camera moves and tool actions.
final class WorldMTKView: MTKView {
    var renderer: Renderer?
    weak var model: AppModel?
    private var downPoint: NSPoint?
    private var dragging = false
    private var lastDrag: NSPoint?
    private var lastPaint: CFTimeInterval = 0
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private var scale: Float { Float(window?.backingScaleFactor ?? 2) }

    /// View point (y up) -> drawable pixel (y down).
    private func pixel(_ p: NSPoint) -> V2 {
        V2(Float(p.x) * scale, Float(bounds.height - p.y) * scale)
    }

    private func worldPoint(_ event: NSEvent) -> V2? {
        guard let r = renderer else { return nil }
        return r.camera.worldPoint(pixel: pixel(convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { renderer?.hover = nil }

    private func updateHover(_ event: NSEvent) {
        guard let model, let r = renderer, let wp = worldPoint(event) else { return }
        let tool = model.tool
        if tool.radius > 0 && tool != .remove {
            let color: SIMD4<Float> = tool == .meteor ? SIMD4(1.6, 0.5, 0.2, 1) : SIMD4(0.4, 1.4, 0.6, 1)
            r.hover = (wp, tool.radius, color)
        } else {
            r.hover = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
        lastDrag = downPoint
        dragging = false
        if event.clickCount == 2 {
            handleDoubleClick(event)
            downPoint = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let r = renderer else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging && hypot(p.x - start.x, p.y - start.y) > 3 { dragging = true }
        guard dragging, let last = lastDrag else { return }
        if model?.tool == .food && !event.modifierFlags.contains(.option) {
            let now = CACurrentMediaTime()
            if now - lastPaint > 0.06, let wp = worldPoint(event) {
                lastPaint = now
                r.controller.perform { w in w.dropFood(at: wp, radius: Tool.food.radius, count: 6) }
            }
            updateHover(event)
        } else {
            let d = V2(Float(p.x - last.x), Float(last.y - p.y)) * scale
            r.camera.pan(byPixels: d)
            model?.following = false
        }
        lastDrag = p
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil; dragging = false }
        guard downPoint != nil, !dragging else { return }
        handleClick(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let last = lastDrag, let r = renderer else { return }
        let p = convert(event.locationInWindow, from: nil)
        r.camera.pan(byPixels: V2(Float(p.x - last.x), Float(last.y - p.y)) * scale)
        model?.following = false
        lastDrag = p
    }

    override func scrollWheel(with event: NSEvent) {
        guard let r = renderer else { return }
        let px = pixel(convert(event.locationInWindow, from: nil))
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Trackpad: two-finger scroll pans.
            r.camera.pan(byPixels: V2(Float(event.scrollingDeltaX), Float(event.scrollingDeltaY)) * scale)
            if abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0.5 { model?.following = false }
        } else {
            let dy = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08)
            let factor = exp(dy)
            if model?.following == true, let sel = r.selectedPosition {
                r.camera.zoom(by: factor, at: r.camera.pixel(world: sel))
            } else {
                r.camera.zoom(by: factor, at: px)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        guard let r = renderer else { return }
        let px = pixel(convert(event.locationInWindow, from: nil))
        let factor = Float(1 + event.magnification)
        if model?.following == true, let sel = r.selectedPosition {
            r.camera.zoom(by: factor, at: r.camera.pixel(world: sel))
        } else {
            r.camera.zoom(by: factor, at: px)
        }
    }

    private func pickTolerance() -> Float {
        guard let r = renderer else { return 10 }
        return 12 * scale / r.camera.zoom + 4
    }

    private func handleClick(_ event: NSEvent) {
        guard let model, let r = renderer, let wp = worldPoint(event) else { return }
        let tol = pickTolerance()
        switch model.tool {
        case .select:
            r.controller.perform { w in
                let uid = w.creature(near: wp, maxDistance: tol)
                DispatchQueue.main.async {
                    if let uid { model.select(uid) } else { model.select(nil) }
                }
            }
        case .food:
            r.controller.perform { w in w.dropFood(at: wp, radius: Tool.food.radius, count: 30) }
        case .spawn:
            let source = model.selectedUid == 0 ? nil : model.selectedUid
            r.controller.perform { w in
                let uid = w.spawnCreature(at: wp, copying: source)
                DispatchQueue.main.async {
                    model.showToast(uid == nil ? "土のエネルギーが足りない" : (source == nil ? "新しい生き物を置いた" : "選択個体の子を置いた"))
                }
            }
        case .remove:
            r.controller.perform { w in
                if let uid = w.creature(near: wp, maxDistance: tol) {
                    w.remove(uid: uid)
                }
            }
        case .meteor:
            r.controller.perform { w in w.meteor(at: wp, radius: Tool.meteor.radius) }
        }
    }

    private func handleDoubleClick(_ event: NSEvent) {
        guard let model, let r = renderer, let wp = worldPoint(event) else { return }
        let tol = pickTolerance() * 1.5
        r.controller.perform { w in
            let uid = w.creature(near: wp, maxDistance: tol)
            DispatchQueue.main.async {
                if let uid {
                    model.select(uid)
                    model.following = true
                    if r.camera.targetZoom < 3 * r.camera.pixelRatio { r.camera.targetZoom = 4 * r.camera.pixelRatio }
                }
            }
        }
    }
}

struct WorldView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> WorldMTKView {
        let v = WorldMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.model = model
        if let r = Renderer(view: v, controller: model.controller) {
            r.model = model
            v.renderer = r
            v.delegate = r
            model.renderer = r
            AppEnvironment.shared.rendererDidLoad(r)
        }
        return v
    }

    func updateNSView(_ nsView: WorldMTKView, context: Context) {}
}
