import HakoniwaCore
import simd

extension Tool {
    var isWallTool: Bool { self == .wall || self == .eraseWall }

    /// HDR colour of the dashed cursor ring.
    var cursorColor: SIMD4<Float> {
        switch self {
        case .meteor: return SIMD4(1.6, 0.5, 0.2, 1)
        case .wall: return SIMD4(0.85, 0.72, 0.55, 1)
        case .eraseWall: return SIMD4(1.4, 0.45, 0.75, 1)
        default: return SIMD4(0.4, 1.4, 0.6, 1)
        }
    }
}

extension WorldMTKView {
    func beginWallStroke(at p: V2) {
        guard let model else { return }
        wallStroke = p
        GodActions.paintWall(model, from: p, to: p, erase: model.tool == .eraseWall)
    }

    /// Paints from the last stroke point once the cursor has moved far enough.
    func continueWallStroke(to p: V2) {
        guard let model, let r = renderer, let last = wallStroke else { return }
        let d = r.camera.torusDelta(p - last)
        guard simd_length(d) > GodActions.wallRadius * 0.4 else { return }
        GodActions.paintWall(model, from: last, to: last + d, erase: model.tool == .eraseWall)
        wallStroke = p
    }
}
