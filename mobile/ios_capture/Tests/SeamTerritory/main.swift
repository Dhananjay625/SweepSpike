// The seam router's job is to detour a boundary around anything the frames disagree about.
// Run 11 showed the cost of doing that job perfectly: the thing they disagreed about was the
// operator's own forearm and phone, so the router fenced it off and preserved it — thin dark
// blade-shaped ghosts lying across the floor in several directions.
//
// `dropSliverTerritories` is the answer, and nothing else in the suite can check it. The
// stitcher tests measure colour; this one measures the label field, because the defect is a
// label decision and a colour test could only reach it by constructing a scene whose
// alpha-expansion happens to produce an island today.
//
// Build:
//   swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift Sources/GraphCut.swift \
//     Tests/SeamTerritory/main.swift -o /tmp/seamterritory
import Foundation

let gridW = 64, gridH = 32
let minCells = PanoramaStitcher.minTerritoryCells

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  PASS  \(name)")
    } else {
        print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        failures += 1
    }
}

/// A field of `background`, with `label` painted into the axis-aligned block [x0,x1)x[y0,y1).
/// x wraps, so x0 > x1 paints across the seam.
func field(background: Int32) -> [Int32] {
    [Int32](repeating: background, count: gridW * gridH)
}

func paint(_ f: inout [Int32], _ label: Int32,
           x: Range<Int>, y: Range<Int>) {
    for gy in y {
        for gx in x {
            f[gy * gridW + ((gx % gridW) + gridW) % gridW] = label
        }
    }
}

func count(_ f: [Int32], _ label: Int32) -> Int { f.filter { $0 == label }.count }

func clean(_ f: [Int32]) -> [Int32] {
    PanoramaStitcher.dropSliverTerritories(f, gridW: gridW, gridH: gridH)
}

print("Seam territory cleanup — minTerritoryCells = \(minCells)")
print("  grid \(gridW)x\(gridH) = \(gridW * gridH) cells\n")

// --- 1. The defect itself: a small island is dissolved into what surrounds it. --------------
print("--- Sliver removal ---")
do {
    var f = field(background: 3)
    paint(&f, 7, x: 20 ..< 26, y: 10 ..< 15)   // 30 cells, under the 64-cell floor
    let before = count(f, 7)
    let after = clean(f)
    check("a \(before)-cell island is dissolved", count(after, 7) == 0,
          "\(count(after, 7)) cells of label 7 survived")
    check("and the ground it held goes to the label that surrounded it",
          count(after, 3) == gridW * gridH)
}

// --- 2. The counterweight: a real territory is NOT touched. ---------------------------------
// Without this the test would pass just as well if the function blanked everything.
do {
    var f = field(background: 3)
    paint(&f, 7, x: 20 ..< 40, y: 10 ..< 20)   // 200 cells, a genuine territory
    let after = clean(f)
    check("a 200-cell territory is left exactly alone", after == f)
}

// A territory of exactly minCells stays; one cell smaller goes. Pins the boundary itself,
// which is where an off-by-one would hide.
do {
    var atLimit = field(background: 3)
    paint(&atLimit, 7, x: 0 ..< 8, y: 0 ..< 8)          // 64
    check("exactly \(minCells) cells survives", clean(atLimit) == atLimit)

    var under = field(background: 3)
    paint(&under, 7, x: 0 ..< 8, y: 0 ..< 8)
    under[7 * gridW + 7] = 3                            // 63
    check("one cell fewer does not", count(clean(under), 7) == 0)
}

// --- 3. Longitude wraps. -------------------------------------------------------------------
// The grid is a sphere: the last column touches the first. A component split by the seam must
// be counted whole, or every territory straddling longitude 180 is destroyed as two halves.
print("\n--- Sphere topology ---")
do {
    var f = field(background: 3)
    paint(&f, 7, x: 60 ..< 68, y: 0 ..< 10)    // 80 cells, straddling the wrap
    check("a territory straddling the +-180 seam counts as ONE component and survives",
          clean(f) == f)

    var small = field(background: 3)
    paint(&small, 7, x: 62 ..< 66, y: 0 ..< 5) // 20 cells, straddling the wrap
    check("a small straddling island is still dissolved", count(clean(small), 7) == 0)
}

// Latitude does NOT wrap: the top row is the zenith, not the bottom row's neighbour.
do {
    var f = field(background: 3)
    paint(&f, 7, x: 0 ..< 8, y: 0 ..< 5)                    // 40 at the top
    paint(&f, 7, x: 0 ..< 8, y: gridH - 5 ..< gridH)        // 40 at the bottom
    let after = clean(f)
    check("two 40-cell caps at opposite poles are NOT joined into one 80-cell territory",
          count(after, 7) == 0, "\(count(after, 7)) cells survived")
}

// --- 4. Where the dissolved ground goes. ---------------------------------------------------
print("\n--- Reassignment ---")
do {
    // An island touching label 3 on three sides and label 5 on one: 3 must win.
    var f = field(background: 3)
    paint(&f, 5, x: 0 ..< 64, y: 0 ..< 1)      // a strip of 5 along the top
    paint(&f, 7, x: 20 ..< 25, y: 1 ..< 5)     // 20 cells, sitting on that strip
    let after = clean(f)
    check("an island goes to the label it borders MOST, not the first one found",
          after[2 * gridW + 22] == 3, "went to \(after[2 * gridW + 22])")
}

do {
    // A tie: an island split evenly between two labels goes to the lower index, every time.
    var f = field(background: 5)
    paint(&f, 3, x: 0 ..< 32, y: 0 ..< gridH)  // left half 3, right half 5
    paint(&f, 7, x: 30 ..< 34, y: 10 ..< 15)   // 20 cells, centred on the divide
    let a = clean(f), b = clean(f)
    check("a tie is broken deterministically", a == b)
    check("...toward the lower frame index", a[12 * gridW + 31] == 3,
          "went to \(a[12 * gridW + 31])")
}

do {
    // Two touching islands. Votes are counted on the INCOMING field, so neither can be
    // dissolved INTO the other and the answer cannot depend on which is visited first.
    var f = field(background: 3)
    paint(&f, 7, x: 20 ..< 24, y: 10 ..< 14)   // 16 cells
    paint(&f, 8, x: 24 ..< 28, y: 10 ..< 14)   // 16 cells, sharing an edge with the first
    let after = clean(f)
    check("two touching islands both dissolve to the surround, not into each other",
          count(after, 7) == 0 && count(after, 8) == 0,
          "7:\(count(after, 7)) 8:\(count(after, 8))")
}

// --- 5. Cells nothing saw. -----------------------------------------------------------------
// -1 means no frame reached this direction. Those must neither be adopted by a territory nor
// created by one: adopting them would claim coverage the stitch does not have, and creating
// them would open a hole for the filler to invent.
print("\n--- Unlabelled ground ---")
do {
    var f = field(background: -1)
    paint(&f, 7, x: 20 ..< 26, y: 10 ..< 15)   // a 30-cell island with NOTHING around it
    let after = clean(f)
    check("an island with no labelled neighbour is left alone rather than blanked", after == f)
    check("and no -1 cell was adopted", count(after, -1) == count(f, -1))
}

do {
    var f = field(background: 3)
    paint(&f, -1, x: 40 ..< 50, y: 0 ..< 10)   // an uncovered patch
    paint(&f, 7, x: 20 ..< 26, y: 10 ..< 15)   // and a sliver elsewhere
    let after = clean(f)
    check("dissolving a sliver leaves the uncovered patch exactly as it was",
          count(after, -1) == count(f, -1))
    check("and the sliver still goes", count(after, 7) == 0)
}

// --- 6. Degenerate inputs. -----------------------------------------------------------------
print("\n--- Degenerate input ---")
do {
    check("an empty field is returned unchanged",
          PanoramaStitcher.dropSliverTerritories([], gridW: 0, gridH: 0).isEmpty)
    let mismatched: [Int32] = [1, 2, 3]
    check("a field whose length disagrees with the grid is refused, not indexed out of bounds",
          PanoramaStitcher.dropSliverTerritories(mismatched, gridW: gridW, gridH: gridH)
              == mismatched)
    let allSame = field(background: 4)
    check("a field that is one big territory is unchanged", clean(allSame) == allSame)
    let allEmpty = field(background: -1)
    check("a field nothing covered is unchanged", clean(allEmpty) == allEmpty)

    // On a grid too small for 64 to mean "island", the cleanup must decline rather than
    // flatten everything to one label. `routeSeams` permits grids down to 2x2.
    let tinyW = 8, tinyH = 8
    var tiny = [Int32](repeating: 3, count: tinyW * tinyH)
    for i in 0 ..< 10 { tiny[i] = 7 }
    check("a grid too small for the floor to be meaningful is left alone",
          PanoramaStitcher.dropSliverTerritories(tiny, gridW: tinyW, gridH: tinyH) == tiny)
}

print("")
if failures > 0 {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
print("ALL CHECKS PASSED")
