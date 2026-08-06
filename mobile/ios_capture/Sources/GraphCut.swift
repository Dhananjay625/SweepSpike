import Foundation

/// Max-flow / minimum s-t cut over a small directed graph.
///
/// This exists for one caller: the seam router's alpha-expansion. Alpha-expansion asks, for
/// one candidate label at a time, "which cells should switch to this label, considering ALL
/// of them together" — and that question is exactly a minimum cut. Answering it one cell at a
/// time is what iterated conditional modes did, and why it never moved: flipping a single cell
/// creates two new boundaries where a coordinated flip of a whole region creates none.
///
/// Dinic's algorithm rather than Boykov-Kolmogorov. BK is faster on the long thin residual
/// paths typical of vision grids, but Dinic is a fraction of the code, has no tree-recycling
/// state to get wrong, and the graphs here are small — one expansion covers only the cells
/// where its label is a candidate, a few thousand at most, not the whole canvas.
///
/// Capacities are `Float` because every cost feeding this comes from colour differences that
/// are already `Float`. `epsilon` is what keeps that safe: residuals below it are treated as
/// saturated, so accumulated rounding cannot produce a vanishing augmenting path that the
/// search walks forever.
final class MaxFlow {
    /// Residual capacities below this count as saturated. Costs here are colour differences
    /// in 0...255 scaled by a smoothness weight, so 1e-6 is far below anything meaningful and
    /// far above `Float` rounding on those magnitudes.
    private static let epsilon: Float = 1e-6

    /// Edges are stored in pairs — edge `i` and its reverse `i ^ 1` — in flat arrays threaded
    /// into per-node singly-linked lists. Flat storage rather than `[[Int]]` because a full
    /// expansion cycle rebuilds one of these graphs per label, and per-node array allocation
    /// dominates everything else at that rate.
    private var head: [Int32]
    private var nextEdge: [Int32] = []
    private var target: [Int32] = []
    private var capacity: [Float] = []

    /// BFS layer of each node in the current level graph; -1 when unreachable.
    private var level: [Int32]
    /// Next un-explored edge per node, so the blocking-flow DFS never rescans a saturated
    /// edge within one phase. Without this Dinic degrades to Ford-Fulkerson.
    private var iterator: [Int32]

    let nodeCount: Int

    /// - Parameter nodes: total node count INCLUDING source and sink.
    init(nodes: Int) {
        nodeCount = nodes
        head = [Int32](repeating: -1, count: nodes)
        level = [Int32](repeating: -1, count: nodes)
        iterator = [Int32](repeating: -1, count: nodes)
    }

    /// Adds a directed edge `from -> to` with the given capacity, and its reverse with
    /// `reverseCapacity` (0 for a one-way edge, or the same value for an undirected one).
    ///
    /// Non-positive capacities are dropped rather than stored: a zero-capacity edge can never
    /// carry flow, and the seam construction produces many of them wherever two frames agree
    /// perfectly. Keeping them would only lengthen every adjacency walk.
    func addEdge(from: Int, to: Int, capacity forward: Float, reverseCapacity: Float = 0) {
        guard forward > 0 || reverseCapacity > 0 else { return }
        append(from: from, to: to, capacity: max(0, forward))
        append(from: to, to: from, capacity: max(0, reverseCapacity))
    }

    private func append(from: Int, to: Int, capacity value: Float) {
        target.append(Int32(to))
        self.capacity.append(value)
        nextEdge.append(head[from])
        head[from] = Int32(target.count - 1)
    }

    /// Pushes flow until no augmenting path remains, and returns the total — which is the
    /// value of the minimum cut. The graph is left in its residual state, which is what
    /// `sourceSide` then reads.
    @discardableResult
    func solve(source: Int, sink: Int) -> Float {
        var total: Float = 0
        while buildLevelGraph(source: source, sink: sink) {
            for node in 0 ..< nodeCount { iterator[node] = head[node] }
            while true {
                let pushed = augment(node: source, sink: sink, limit: .greatestFiniteMagnitude)
                guard pushed > MaxFlow.epsilon else { break }
                total += pushed
            }
        }
        return total
    }

    /// Nodes still reachable from the source through residual capacity. After `solve` these
    /// are exactly the source side of a minimum cut, which is the answer alpha-expansion
    /// wants: "these cells take the new label".
    func sourceSide(source: Int) -> [Bool] {
        var reached = [Bool](repeating: false, count: nodeCount)
        var queue = [Int32(source)]
        reached[source] = true
        var readIndex = 0
        while readIndex < queue.count {
            let node = Int(queue[readIndex])
            readIndex += 1
            var edge = head[node]
            while edge >= 0 {
                let index = Int(edge)
                let next = Int(target[index])
                if capacity[index] > MaxFlow.epsilon, !reached[next] {
                    reached[next] = true
                    queue.append(Int32(next))
                }
                edge = nextEdge[index]
            }
        }
        return reached
    }

    /// Layers the residual graph by distance from the source. Returns false once the sink is
    /// no longer reachable, which is the termination condition for the whole algorithm.
    private func buildLevelGraph(source: Int, sink: Int) -> Bool {
        for node in 0 ..< nodeCount { level[node] = -1 }
        level[source] = 0
        var queue = [Int32(source)]
        var readIndex = 0
        while readIndex < queue.count {
            let node = Int(queue[readIndex])
            readIndex += 1
            var edge = head[node]
            while edge >= 0 {
                let index = Int(edge)
                let next = Int(target[index])
                if capacity[index] > MaxFlow.epsilon, level[next] < 0 {
                    level[next] = level[node] + 1
                    queue.append(Int32(next))
                }
                edge = nextEdge[index]
            }
        }
        return level[sink] >= 0
    }

    /// Finds one augmenting path within the level graph and saturates it, returning how much
    /// it carried. Iterative rather than recursive: a level graph over tens of thousands of
    /// nodes can produce a path deep enough to overflow the stack, and a stitch that crashes
    /// is worse than one that seams.
    private func augment(node source: Int, sink: Int, limit: Float) -> Float {
        var pathEdges: [Int32] = []
        var node = source

        while true {
            if node == sink {
                // Saturate the path by its tightest edge, then resume from the node above
                // that bottleneck — everything before it still has capacity.
                var bottleneck = limit
                for edge in pathEdges { bottleneck = min(bottleneck, capacity[Int(edge)]) }
                for edge in pathEdges {
                    capacity[Int(edge)] -= bottleneck
                    capacity[Int(edge) ^ 1] += bottleneck
                }
                return bottleneck
            }

            var advanced = false
            var edge = iterator[node]
            while edge >= 0 {
                let index = Int(edge)
                let next = Int(target[index])
                if capacity[index] > MaxFlow.epsilon, level[next] == level[node] + 1 {
                    pathEdges.append(edge)
                    node = next
                    advanced = true
                    break
                }
                edge = nextEdge[index]
                iterator[node] = edge
            }
            if advanced { continue }

            // Dead end: this node reaches nothing useful in this phase. Retire it so no later
            // path re-enters, and back up one step.
            level[node] = -1
            guard let last = pathEdges.popLast() else { return 0 }
            node = Int(target[Int(last) ^ 1])
            iterator[node] = nextEdge[Int(last)]
        }
    }
}
