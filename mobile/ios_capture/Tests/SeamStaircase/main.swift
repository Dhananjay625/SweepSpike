// Why three device runs got worse while every host number said they were getting better.
//
// The suite had no scene containing LONG STRAIGHT ARCHITECTURE. `ParallaxSharpness` scores a
// fine grating, `TextureBlotching` a wall of speckle, `NadirCap` a floor. A seam boundary
// quantised to a 16-px label grid is invisible in all three: there is no long straight line
// for it to visibly cut across. On a device there is nothing BUT long straight lines — desk
// edges, window beams, ceiling joints — and that is where runs 11-13 showed staircases.
//
// So `boundaryCost` fell 54% while the picture got worse, and `boundaryCost` is routing's own
// objective function, so it could never have said otherwise. This test measures the artifact
// instead of the objective.
//
// THE SCENE: wide vertical stripes on a cylinder 1.2 m away. A vertical world edge sits at a
// constant azimuth, and equirectangular x IS azimuth, so a correctly stitched vertical edge is
// an exactly VERTICAL COLUMN — the same x in every row. Any wobble in that column is the
// stitcher's, not the scene's. At 1.2 m the +-6 cm of viewpoint wander the capture gate allows
// swings the azimuth by ~3 degrees, which is real disagreement between frames, so the routing
// gate genuinely engages here rather than the test proving nothing.
//
// WHAT THIS TEST DOES NOT DO, and why. It was built to score the staircase directly and it
// cannot, for a reason worth writing down so nobody spends another afternoon on it: routing only
// engages where frames DISAGREE, and where frames disagree there is no single correct edge
// position to measure against. At 1.2 m the +-6 cm of allowed viewpoint wander genuinely moves a
// vertical edge by +-16 px, so "deviation from straight" measures the parallax, not the artifact
// (measured: 7.96 px RMS unrouted vs 7.77 routed — routing scores BETTER, because averaging
// disagreeing views is smoother than choosing between them). Move the wall far enough away for
// the parallax to vanish and the frames agree, the gate never fires, and the two renders come out
// byte-identical. There is no distance at which this separates cleanly.
//
// So this test asserts only what it can honestly see: that routing materially rewrites straight-
// edged content rather than merely tidying seams, and that the shipping default does not do it.
// The evidence that routing is WORSE is three device runs, not a number in here.
//
// Build:
//   swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift Sources/GraphCut.swift \
//     Tests/StitchHarness/PlanSweep.swift Tests/SeamStaircase/main.swift -o /tmp/seamstaircase
import CoreGraphics
import Foundation
import simd

let W = 640, H = 480
let hfovX: Float = 60 * .pi / 180
let fx = Float(W) / (2 * tan(hfovX / 2))
let intr = simd_float3x3(SIMD3(fx, 0, 0), SIMD3(0, fx, 0), SIMD3(Float(W) / 2, Float(H) / 2, 1))

let panoW = 2048, panoH = 1024
let wallRadius: Float = 1.2
let stripes: Float = 8          // 8 edges around the sphere, so wide flat panels between them

/// Ray-cylinder intersection, then a wide stripe pattern in azimuth. Flat panels, hard edges —
/// architecture, not texture. A gentle vertical ramp keeps the panels from being perfectly
/// uniform, which would make edge localisation degenerate rather than merely hard.
func shade(_ dir: SIMD3<Float>, from eye: SIMD3<Float>) -> UInt8 {
    let dxz = SIMD2(dir.x, dir.z), exz = SIMD2(eye.x, eye.z)
    let a = simd_dot(dxz, dxz)
    guard a > 1e-6 else { return 128 }
    let b = 2 * simd_dot(exz, dxz)
    let c = simd_dot(exz, exz) - wallRadius * wallRadius
    let disc = b * b - 4 * a * c
    guard disc > 0 else { return 128 }
    let t = (-b + sqrt(disc)) / (2 * a)
    let hit = eye + dir * t
    let azimuth = atan2(hit.x, -hit.z)
    let phase = azimuth / (2 * .pi) * stripes
    let dark = (phase - phase.rounded(.down)) < 0.5
    let ramp = Float(30) * (hit.y / wallRadius)
    return UInt8(max(0, min(255, (dark ? 60 : 210) + ramp)))
}

func jitter(_ i: Int) -> Float { Float((i &* 2654435761 % 2000)) / 1000 - 1 }

var frames: [CapturedFrame] = []
for i in 0 ..< 48 {
    let yaw = Float(i) * 0.42
    let pitch = jitter(i * 7) * 0.2
    let fwd = SweepFrame.direction(yaw: yaw, pitch: pitch)
    let rot = PlanSweep.cameraRotation(forward: fwd, roll: CaptureConfig.deviceRollRadians)
    let eye = SIMD3<Float>(jitter(i * 3), jitter(i * 5) * 0.3, jitter(i * 11)) * 0.06
    var px = [UInt8](repeating: 255, count: W * H * 4)
    for y in 0 ..< H {
        for x in 0 ..< W {
            let cam = SIMD3<Float>((Float(x) + 0.5 - Float(W) / 2) / fx,
                                   -(Float(y) + 0.5 - Float(H) / 2) / fx, -1)
            let v = shade(simd_normalize(rot * cam), from: eye)
            let o = (y * W + x) * 4
            px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
        }
    }
    let m = simd_float4x4(SIMD4(rot.columns.0, 0), SIMD4(rot.columns.1, 0),
                          SIMD4(rot.columns.2, 0), SIMD4(eye, 1))
    frames.append(CapturedFrame(width: W, height: H, pixels: px, transform: m, intrinsics: intr))
}

func render(seam: Float) -> [UInt8] {
    guard let r = PanoramaStitcher.stitch(
        frames: frames, originYaw: 0, width: panoW, height: panoH, seam: seam
    ) else { fatalError("stitch nil") }
    var out = [UInt8](repeating: 0, count: panoW * panoH * 4)
    out.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: panoW, height: panoH,
                            bitsPerComponent: 8, bytesPerRow: panoW * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(r.image, in: CGRect(x: 0, y: 0, width: panoW, height: panoH))
    }
    return out
}

/// Sub-pixel column of the strongest vertical edge near `centre`, or nil when this row has no
/// edge worth locating (so a hole-filled row cannot be scored as if it were perfectly straight).
func edgeColumn(_ img: [UInt8], row y: Int, near centre: Int, halfWindow: Int = 24) -> Double? {
    var total = 0.0, weighted = 0.0, peak = 0.0
    for dx in -halfWindow ... halfWindow {
        let x = ((centre + dx) % panoW + panoW) % panoW
        let xm = ((x - 1) % panoW + panoW) % panoW, xp = (x + 1) % panoW
        let g = abs(Double(img[(y * panoW + xp) * 4]) - Double(img[(y * panoW + xm) * 4]))
        peak = max(peak, g)
        total += g
        weighted += g * Double(dx)
    }
    // A real panel edge here is a ~150-level step. Anything much weaker is flat panel or fill.
    guard peak > 40, total > 0 else { return nil }
    return Double(centre) + weighted / total
}

/// RMS deviation of the edge column from its own mean, in pixels, averaged over all stripe
/// edges. A vertical world edge is a constant azimuth and equirectangular x IS azimuth, so the
/// TRUE answer is a constant: every pixel of deviation is the stitcher's.
///
/// The first version of this measured the second difference, |x(y-1) - 2x(y) + x(y+1)|, and
/// could not tell the two renders apart at three decimal places while 76789 pixels genuinely
/// differed between them. A second difference is a local operator: a staircase is flat almost
/// everywhere and spikes only on the step, so 250 near-zero rows drown the handful that carry
/// the artifact. Deviation from the mean is global and every stepped row contributes.
func wobble(_ img: [UInt8]) -> (rms: Double, worst: Double, rows: Int) {
    var sum = 0.0, worst = 0.0, count = 0
    for edge in 0 ..< Int(stripes) {
        let centre = Int((Double(edge) / Double(stripes)) * Double(panoW)) % panoW
        var columns: [Double] = []
        for y in (panoH * 3 / 8) ..< (panoH * 5 / 8) {
            if let x = edgeColumn(img, row: y, near: centre) { columns.append(x) }
        }
        guard columns.count > 8 else { continue }
        let mean = columns.reduce(0, +) / Double(columns.count)
        for x in columns {
            sum += (x - mean) * (x - mean)
            worst = max(worst, abs(x - mean))
        }
        count += columns.count
    }
    return (count > 0 ? (sum / Double(count)).squareRoot() : 0, worst, count)
}

print("Seam staircase test — 48 frames, wide flat panels on a cylinder at 1.2 m")
print("Straight architecture under real parallax: the content every other host scene lacks.\n")

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failures += 1 }
}

let unrouted = render(seam: 0)
let routed = render(seam: 0.10)
let shipping = render(seam: PanoramaStitcher.shippingSeamWeight)

func divergence(_ a: [UInt8], _ b: [UInt8]) -> (pixels: Int, worst: Int) {
    var n = 0, worst = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        let d = abs(Int(a[i]) - Int(b[i]))
        if d > 0 { n += 1 }
        worst = max(worst, d)
    }
    return (n, worst)
}

let d = divergence(unrouted, routed)
let s = divergence(unrouted, shipping)
let w = wobble(unrouted)
print("  routing vs not: \(d.pixels) of \(panoW * panoH) pixels differ, worst channel \(d.worst)")
print("  shipping vs unrouted: \(s.pixels) pixels differ, worst channel \(s.worst)")
print(String(format: "  edge wobble under parallax: %.2f px RMS, worst %.1f px (%d rows)\n",
             w.rms, w.worst, w.rows))

check(w.rows > 200, "the scene presents locatable straight edges to score at all")

// Routing is not a tidy-up on this content: it repaints 3-4% of the panorama and moves panel
// edges by a full step. Whether that is better is a device question — but it is NOT small, and
// treating it as a safe default because `boundaryCost` improved is how runs 11-13 happened.
check(d.pixels > panoW * panoH / 100 && d.worst > 100,
      "routing materially rewrites straight-edged content (\(d.pixels) px, worst \(d.worst))")

// The one that guards the revert.
check(s.pixels == 0,
      "the SHIPPING DEFAULT is byte-identical to the unrouted render — routing is off")

print("")
if failures > 0 {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
print("ALL CHECKS PASSED")
