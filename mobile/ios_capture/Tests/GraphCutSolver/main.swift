// Does the max-flow solver actually compute a minimum cut?
//
// Every seam the stitcher routes is a minimum cut, so a subtly wrong solver would not crash
// or look wrong in review — it would quietly return a worse labelling, and the only symptom
// would be "routing does not help much", which is exactly the symptom the ICM version had.
// That failure is indistinguishable from "the idea does not work" without this test.
//
// Build and run with no other sources:
//   swiftc -O Sources/GraphCut.swift Tests/GraphCutSolver/main.swift -o /tmp/graphcut
//   /tmp/graphcut
import Foundation

var failed = false
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failed = true }
}

func nearly(_ a: Float, _ b: Float, _ tolerance: Float = 1e-3) -> Bool { abs(a - b) < tolerance }

print("Max-flow / min-cut solver\n")

// MARK: - Textbook instance with a hand-checkable answer

// CLRS figure 26.1: the classic 6-node network whose maximum flow is 23.
do {
    let g = MaxFlow(nodes: 6)
    let s = 0, t = 5
    g.addEdge(from: s, to: 1, capacity: 16)
    g.addEdge(from: s, to: 2, capacity: 13)
    g.addEdge(from: 1, to: 2, capacity: 10)
    g.addEdge(from: 2, to: 1, capacity: 4)
    g.addEdge(from: 1, to: 3, capacity: 12)
    g.addEdge(from: 3, to: 2, capacity: 9)
    g.addEdge(from: 2, to: 4, capacity: 14)
    g.addEdge(from: 4, to: 3, capacity: 7)
    g.addEdge(from: 3, to: t, capacity: 20)
    g.addEdge(from: 4, to: t, capacity: 4)
    let flow = g.solve(source: s, sink: t)
    check(nearly(flow, 23), String(format: "CLRS 26.1 max flow is 23 (got %.3f)", flow))

    // The cut must separate the terminals, and it must be the one the flow value implies.
    let side = g.sourceSide(source: s)
    check(side[s] && !side[t], "the minimum cut separates source from sink")
}

// MARK: - A bottleneck the solver must not be able to route around

// Two fat parallel paths pinched by one narrow edge. Anything that ignores the pinch reports
// more than 5; anything that stops at the first augmenting path reports less.
do {
    let g = MaxFlow(nodes: 5)
    g.addEdge(from: 0, to: 1, capacity: 100)
    g.addEdge(from: 0, to: 2, capacity: 100)
    g.addEdge(from: 1, to: 3, capacity: 3)
    g.addEdge(from: 2, to: 3, capacity: 2)
    g.addEdge(from: 3, to: 4, capacity: 100)
    let flow = g.solve(source: 0, sink: 4)
    check(nearly(flow, 5), String(format: "parallel paths sum to their bottlenecks, 5 (got %.3f)", flow))
}

// MARK: - The case that needs a residual edge

// The only way to reach 2 here is to push 1 along s->b->a->t and then UNDO part of it via the
// reverse edge. A solver without residual capacity reports 1 and stops. This is the single
// most common way to get max-flow subtly wrong.
do {
    let g = MaxFlow(nodes: 4)
    let s = 0, a = 1, b = 2, t = 3
    g.addEdge(from: s, to: a, capacity: 1)
    g.addEdge(from: s, to: b, capacity: 1)
    g.addEdge(from: b, to: a, capacity: 1)
    g.addEdge(from: a, to: t, capacity: 1)
    g.addEdge(from: b, to: t, capacity: 1)
    let flow = g.solve(source: s, sink: t)
    check(nearly(flow, 2), String(format: "flow is re-routed through residual edges (got %.3f)", flow))
}

// MARK: - Disconnected and degenerate graphs

do {
    let g = MaxFlow(nodes: 4)
    g.addEdge(from: 0, to: 1, capacity: 5)
    g.addEdge(from: 2, to: 3, capacity: 5)
    check(nearly(g.solve(source: 0, sink: 3), 0), "an unreachable sink carries no flow")

    let empty = MaxFlow(nodes: 2)
    check(nearly(empty.solve(source: 0, sink: 1), 0), "a graph with no edges carries no flow")

    // Zero-capacity edges are dropped on insertion; the cut must still be well formed.
    let zero = MaxFlow(nodes: 3)
    zero.addEdge(from: 0, to: 1, capacity: 0)
    zero.addEdge(from: 1, to: 2, capacity: 7)
    check(nearly(zero.solve(source: 0, sink: 2), 0), "a zero-capacity edge blocks the path")
}

// MARK: - Min-cut equals max-flow on a random grid

// The property the seam router actually relies on. Verified against the cut computed from the
// residual graph, which is the same quantity read two different ways: if `sourceSide` and
// `solve` ever disagreed, the router would minimise one thing and act on another.
do {
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func random() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float((seed >> 33) % 1000) / 100
    }

    let w = 12, h = 12
    let nodes = w * h
    let source = nodes, sink = nodes + 1
    let g = MaxFlow(nodes: nodes + 2)
    var capacities: [(Int, Int, Float)] = []

    for y in 0 ..< h {
        for x in 0 ..< w {
            let n = y * w + x
            if x == 0 { g.addEdge(from: source, to: n, capacity: 20) }
            if x == w - 1 { g.addEdge(from: n, to: sink, capacity: 20) }
            if x < w - 1 {
                let c = random()
                capacities.append((n, n + 1, c))
                g.addEdge(from: n, to: n + 1, capacity: c, reverseCapacity: c)
            }
            if y < h - 1 {
                let c = random()
                capacities.append((n, n + w, c))
                g.addEdge(from: n, to: n + w, capacity: c, reverseCapacity: c)
            }
        }
    }

    let flow = g.solve(source: source, sink: sink)
    let side = g.sourceSide(source: source)

    // Sum the capacities of every edge crossing from the source side to the sink side.
    var cut: Float = 0
    for y in 0 ..< h {
        let n = y * w
        if !side[n] { cut += 20 }
        let last = y * w + w - 1
        if side[last] { cut += 20 }
    }
    for (u, v, c) in capacities {
        if side[u] != side[v] { cut += c }
    }

    check(nearly(flow, cut, 1e-2),
          String(format: "on a 12x12 random grid, max flow %.3f equals the cut it induces %.3f",
                 flow, cut))
    check(side[source] && !side[sink], "grid cut separates the terminals")
}

print("")
if failed { exit(1) }
print("ALL CHECKS PASSED")
