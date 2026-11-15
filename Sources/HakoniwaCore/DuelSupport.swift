import Foundation

// Helpers for the generation duel screen (primordial vs evolved creatures in twin arenas).

extension World {
    /// Generations of the creatures `sampleGenomes(count)` returns, in the same order.
    public func sampledGenerations(_ count: Int) -> [Int32] {
        var all: [Int] = []
        for i in 0..<highWater where stage[i] == Stage.alive.rawValue { all.append(i) }
        guard !all.isEmpty else { return [] }
        let step = max(1, all.count / count)
        return stride(from: 0, to: all.count, by: step).prefix(count).map { generation[all[$0]] }
    }
}
