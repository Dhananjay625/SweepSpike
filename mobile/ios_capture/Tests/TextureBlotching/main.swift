import CoreGraphics
import Foundation
import simd

// Reproduces the SEVENTH device run's stitching failure and pins the fix.
//
// Run 7 turned a library carpet into hard-edged polygonal patches: frame-frustum boundaries
// visible as straight lines across the floor, texture wiped flat inside some of them. The
// colour veto added after run 6 was firing on CARPET, which is not a parallax disagreement.
//
// The cause is that the test compared RAW per-pixel colour. Carpet is high-frequency
// speckle, and two viewpoints a few centimetres apart do not sample corresponding grains,
// so honest per-channel differences of 50-80 levels occur on a surface both frames see
// perfectly correctly. Comparing raw pixels asks "is this the same speckle?", which has no
// answer across viewpoints. Comparing thumbnails asks "is this the same surface?", which
// does. This test sweeps the comparison scale and shows where the artifact disappears.
//
// A smooth rolloff was also tried, on the theory that a BINARY cut must draw hard edges
// wherever the measure crosses the threshold. It was removed: once the comparison is
// low-passed the veto stops firing spuriously, so there is no edge to soften, and the
// rolloff measured strictly worse on every number (see the changelog's run-7 section).
//
// The scene here is deliberately the hard case: a large uniformly-textured wall of pure
// high-frequency speckle, viewed from wandering viewpoints. There is NO real disagreement
// anywhere in it, so a correct blend must return a statistically uniform result. Any
// large-scale structure in the output is an artifact the stitcher invented.
//
// Build and run (macOS, no Xcode, no device):
//   swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift \
//     Tests/TextureBlotching/main.swift -o /tmp/blotch
//   /tmp/blotch

// MARK: - Scene

/// Deterministic value noise. `Math.random` is unavailable in this codebase's test style and
/// a fixed hash keeps the measurement reproducible across runs.
func hashNoise(_ x: Int, _ y: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h = h ^ (h >> 16)
    return Float(h % 1000) / 1000
}

/// A speckled surface at `distance` metres, sampled along a ray from `eye`.
/// Speckle is at the finest scale the frame can resolve, which is what defeats a
/// per-pixel comparison: neighbouring grains are uncorrelated.
func surfaceColour(eye: SIMD3<Float>, direction: SIMD3<Float>, distance: Float) -> Float {
    // Intersect the plane z = -distance.
    guard direction.z < -1e-5 else { return 128 }
    let t = -distance / direction.z
    let hit = eye + direction * t
    // ~7 mm speckle cells: fine enough that a few-centimetre viewpoint change decorrelates
    // them completely, exactly like real carpet pile or a rough painted wall.
    let cx = Int((hit.x / 0.007).rounded(.down))
    let cy = Int((hit.y / 0.007).rounded(.down))
    // Mean 128, +-60 levels of speckle. The amplitude is chosen to STRADDLE the 48-level
    // agreement tolerance, which is precisely the regime that broke run 7.
    return 128 + (hashNoise(cx, cy) - 0.5) * 120
}

let frameW = 320
let frameH = 240
let fx: Float = 300, fy: Float = 300
let surfaceDistance: Float = 3.0

func makeFrame(index: Int, total: Int) -> CapturedFrame {
    // Sweep across the wall, each frame from its own slightly different viewpoint — the
    // hand-held pivot that makes speckle decorrelate between frames.
    let yaw = (Float(index) / Float(total) - 0.5) * 1.1
    let phase = Float(index) * 1.7
    let eye = SIMD3<Float>(0.05 * sin(phase), 0.04 * cos(phase * 1.3), 0.05 * cos(phase))

    // Per-frame exposure offset, and it is ESSENTIAL to reproducing what the user saw.
    // Speckle alone does not make a visible patch: if the veto drops a rival on a uniformly
    // lit surface, the survivor has the same mean and nothing shows. What makes a patch
    // VISIBLE is that ARKit auto-exposure leaves each frame at a slightly different level
    // (5-20 levels across a sweep, per the project's own notes). Then wherever the veto
    // changes its mind, the region's mean jumps to a different frame's exposure — and a
    // region boundary with a mean step across it is precisely a seam. A test without this
    // measures speckle handling but not the artifact.
    let exposure = 9 * sin(Float(index) * 0.9)

    let forward = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
    let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
    let up = simd_cross(right, forward)
    let rot = simd_float3x3(right, up, -forward)

    var pixels = [UInt8](repeating: 0, count: frameW * frameH * 4)
    for v in 0 ..< frameH {
        for u in 0 ..< frameW {
            let camDir = SIMD3<Float>(
                (Float(u) + 0.5 - Float(frameW) / 2) / fx,
                -(Float(v) + 0.5 - Float(frameH) / 2) / fy,
                -1
            )
            let world = simd_normalize(rot * camDir)
            let c = surfaceColour(eye: eye, direction: world, distance: surfaceDistance)
            let byte = UInt8(max(0, min(255, c + exposure)))
            let p = (v * frameW + u) * 4
            pixels[p] = byte
            pixels[p + 1] = byte
            pixels[p + 2] = byte
            pixels[p + 3] = 255
        }
    }

    var m = simd_float4x4(SIMD4(rot.columns.0, 0), SIMD4(rot.columns.1, 0),
                          SIMD4(rot.columns.2, 0), SIMD4(0, 0, 0, 1))
    m.columns.3 = SIMD4(eye.x, eye.y, eye.z, 1)

    var k = matrix_identity_float3x3
    k[0][0] = fx
    k[1][1] = fy
    k[2][0] = Float(frameW) / 2
    k[2][1] = Float(frameH) / 2

    return CapturedFrame(width: frameW, height: frameH, pixels: pixels,
                         transform: m, intrinsics: k,
                         driftMeters: simd_length(eye))
}

let frameCount = 30
let frames = (0 ..< frameCount).map { makeFrame(index: $0, total: frameCount) }

// MARK: - Measurement

/// Reads the panorama back as greyscale.
func luma(_ image: CGImage) -> (pixels: [Float], width: Int, height: Int) {
    let w = image.width, h = image.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("context") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var out = [Float](repeating: 0, count: w * h)
    for i in 0 ..< w * h { out[i] = Float(rgba[i * 4]) }
    return (out, w, h)
}

/// BLOTCHINESS: the standard deviation of a heavily low-passed version of the output, over
/// the region the frames actually cover.
///
/// This is the measurement that matters, and it is chosen so that the thing it detects is
/// exactly the thing the user saw. The true surface is statistically uniform, so once
/// speckle is averaged away the result must be FLAT. Speckle itself vanishes under a large
/// box average; a patchwork of regions sourced from different frames does not, because each
/// region carries its own mean. High score = the stitcher invented large-scale structure.
func blotchiness(_ image: CGImage) -> Float {
    let (pixels, w, h) = luma(image)
    let box = 24
    // Sample the middle band, where the frames are and where the equirect distortion is
    // mildest. Blocks that touch an unpainted pixel are skipped so coverage edges — which
    // are legitimate, not artifacts — cannot inflate the score.
    let y0 = h / 2 - h / 12, y1 = h / 2 + h / 12
    let x0 = w / 2 - w / 8, x1 = w / 2 + w / 8

    var means: [Float] = []
    var by = y0
    while by + box <= y1 {
        var bx = x0
        while bx + box <= x1 {
            var sum: Float = 0
            var blank = false
            for y in by ..< by + box {
                for x in bx ..< bx + box {
                    let value = pixels[y * w + x]
                    if value == 0 { blank = true; break }
                    sum += value
                }
                if blank { break }
            }
            if !blank { means.append(sum / Float(box * box)) }
            bx += box
        }
        by += box
    }
    guard means.count > 1 else { return 0 }
    let mean = means.reduce(0, +) / Float(means.count)
    let variance = means.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(means.count)
    return variance.squareRoot()
}

/// EDGE HARDNESS: the 95th-percentile step between neighbouring block means.
///
/// Blotchiness alone cannot settle whether the smooth rolloff is worth keeping. It measures
/// how much large-scale structure exists, not how ABRUPTLY that structure changes — and two
/// images with identical block-mean variance can look completely different if one changes
/// gradually and the other in straight hard lines. What made run 7 conspicuous was the
/// hardness: frame boundaries drawn as visible lines across the floor. So hardness gets its
/// own number, and the rolloff is kept or deleted on the evidence rather than on the theory.
func edgeHardness(_ image: CGImage) -> Float {
    let (pixels, w, h) = luma(image)
    let box = 12
    let y0 = h / 2 - h / 12, y1 = h / 2 + h / 12
    let x0 = w / 2 - w / 8, x1 = w / 2 + w / 8
    let cols = (x1 - x0) / box, rows = (y1 - y0) / box
    guard cols > 1, rows > 1 else { return 0 }

    var means = [Float](repeating: -1, count: cols * rows)
    for r in 0 ..< rows {
        for c in 0 ..< cols {
            var sum: Float = 0
            var blank = false
            for y in (y0 + r * box) ..< (y0 + r * box + box) {
                for x in (x0 + c * box) ..< (x0 + c * box + box) {
                    let value = pixels[y * w + x]
                    if value == 0 { blank = true; break }
                    sum += value
                }
                if blank { break }
            }
            if !blank { means[r * cols + c] = sum / Float(box * box) }
        }
    }

    var steps: [Float] = []
    for r in 0 ..< rows {
        for c in 0 ..< cols {
            let a = means[r * cols + c]
            guard a >= 0 else { continue }
            if c + 1 < cols {
                let b = means[r * cols + c + 1]
                if b >= 0 { steps.append(abs(a - b)) }
            }
            if r + 1 < rows {
                let b = means[(r + 1) * cols + c]
                if b >= 0 { steps.append(abs(a - b)) }
            }
        }
    }
    guard !steps.isEmpty else { return 0 }
    steps.sort()
    return steps[min(steps.count - 1, Int(Float(steps.count) * 0.95))]
}

// MARK: - Run

print("Texture blotching test — 30 frames of pure speckle on a flat wall at 3 m")
print("Blotchiness = std-dev of the heavily blurred output. The true surface is uniform,")
print("so ANY large-scale structure is an artifact. Lower is better.\n")

func measure(
    _ label: String, agreement: Float, comparison: Int, seam: Float = 0
) -> (blotch: Float, hardness: Float) {
    guard let r = PanoramaStitcher.stitch(
        frames: frames, originYaw: 0, width: 2048, height: 1024,
        agreement: agreement, comparison: comparison, seam: seam
    ) else { fatalError("stitch nil") }
    let b = blotchiness(r.image)
    let e = edgeHardness(r.image)
    print(String(format: "  %@ blotch %6.3f   hardness %6.3f   coverage %5.1f%%",
                 label.padding(toLength: 40, withPad: " ", startingAt: 0),
                 b, e, r.coverage * 100))
    return (b, e)
}

let noVeto = measure("no veto (reference for 'smooth')",
                     agreement: .infinity, comparison: 4)
let run7 = measure("RUN 7: compared on RAW pixels",
                   agreement: 48, comparison: 1)
let thumbCoarse = measure("compared on 16x thumbnails",
                          agreement: 48, comparison: 16)
let thumbFine = measure("compared on 4x thumbnails",
                        agreement: 48, comparison: 4)
let shipping = measure("SHIPPING: compared on 8x thumbnails",
                       agreement: 48, comparison: 8)

// Seam routing sweep. This is the counterweight to ParallaxSharpness: that test rewards
// suppressing frames that disagree, and on a wall of pure speckle NO frame truly disagrees,
// so any large-scale structure routing introduces is an artifact it invented. A router that
// carves the wall into per-frame territories would show up here as blotchiness and nowhere
// else.
print("\n  --- seam routing sweep (shipping comparison scale) ---")
var seamOff: (blotch: Float, hardness: Float) = (0, 0)
var seamShipping: (blotch: Float, hardness: Float) = (0, 0)
for w in [Float(0), 0.05, 0.10, 0.25, 0.50, 1.00] {
    let r = measure(String(format: "seam %.2f", w), agreement: 48, comparison: 8, seam: w)
    if w == 0 { seamOff = r }
    if w == 0.10 { seamShipping = r }
}
print("")

var failed = false
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failed = true }
}

print("")

// The regression must reproduce, or this test proves nothing about the fix.
check(run7.blotch > noVeto.blotch * 1.15,
      String(format: "run 7 blotches a surface nothing disagrees about (%.3f vs %.3f clean)",
             run7.blotch, noVeto.blotch))
check(run7.hardness > noVeto.hardness * 1.15,
      String(format: "and does it with HARD edges, which is what made it conspicuous "
             + "(%.3f vs %.3f)", run7.hardness, noVeto.hardness))

// The fix must land back on the no-veto reference. A plain average is smooth by
// construction, so on a surface where nothing genuinely disagrees the shipping blend has
// no excuse to be less smooth than one.
check(shipping.blotch < noVeto.blotch * 1.1,
      String(format: "shipping is as smooth as no veto at all (%.3f vs %.3f)",
             shipping.blotch, noVeto.blotch))
check(shipping.hardness < noVeto.hardness * 1.1,
      String(format: "shipping edges are as soft as no veto at all (%.3f vs %.3f)",
             shipping.hardness, noVeto.hardness))
check(shipping.blotch < run7.blotch, "and strictly better than run 7 on blotching")
check(shipping.hardness < run7.hardness, "and strictly better than run 7 on hardness")

// How sharply the artifact switches off with comparison scale, printed so the next person
// choosing `comparisonScale` can see the shape rather than re-deriving it. Shipping moved
// 4x -> 8x when `exposureGains` landed: brightness noise in the comparison had been masking
// what a coarser low-pass could do, and with it removed 8x wins on texture AND on
// anti-ghosting sharpness (12.49 vs 12.36 in Tests/ParallaxSharpness), while 16x falls back.
print(String(format: """

  comparison scale sweep
    raw (1x)  blotch %.3f  hardness %.3f   <- run 7
    4x        blotch %.3f  hardness %.3f
    8x        blotch %.3f  hardness %.3f   <- shipping
    16x       blotch %.3f  hardness %.3f
""", run7.blotch, run7.hardness, thumbFine.blotch, thumbFine.hardness,
     shipping.blotch, shipping.hardness, thumbCoarse.blotch, thumbCoarse.hardness))

// Going coarser than shipping must not keep meaningfully improving, or `comparisonScale` is
// set too low and the veto is still partly firing on texture.
check(thumbCoarse.blotch > shipping.blotch * 0.9,
      "16x buys little over 8x, so 8x is already past the texture scale")

// Seam routing must be INERT on a surface nothing disagrees about. This is the guard on
// `SeamField.contested`: routing everywhere took this scene to 1.58 blotch / 7.81 hardness,
// most of the way back to the run-7 carpet patchwork. Any change that lets the router draw
// territories on agreeing ground shows up here first and nowhere else.
check(abs(seamShipping.blotch - seamOff.blotch) < 1e-3,
      String(format: "routing changes nothing where frames agree — blotch %.3f vs %.3f",
             seamShipping.blotch, seamOff.blotch))
check(abs(seamShipping.hardness - seamOff.hardness) < 1e-3,
      String(format: "and introduces no hard edges there — hardness %.3f vs %.3f",
             seamShipping.hardness, seamOff.hardness))

if failed { exit(1) }
print("ALL CHECKS PASSED")
