// Does dominance selection actually recover detail under parallax?
//
// Models the second device run: a dense free-form sweep (many overlapping frames) of a
// scene containing a NEAR object, captured from viewpoints that wander by a few cm --
// which is what a handheld pivot really does. Each frame renders the scene from ITS OWN
// position, so near detail lands in a different place in every frame. That is parallax,
// reproduced rather than assumed.
//
// Metric: mean |gradient| of the stitched output over the near object's band. A blend
// that averages disagreeing views destroys edges, so gradient energy IS sharpness here.
import CoreGraphics
import Foundation
import simd

let W = 900, H = 675
let hfovX: Float = 60 * .pi / 180
let fx = Float(W) / (2 * tan(hfovX / 2))
let intr = simd_float3x3(SIMD3(fx, 0, 0), SIMD3(0, fx, 0), SIMD3(Float(W) / 2, Float(H) / 2, 1))

// A fine vertical grating 0.6 m away: the "coat on a hook" of this test.
let nearRadius: Float = 0.6
func shade(_ dir: SIMD3<Float>, from eye: SIMD3<Float>) -> (UInt8, UInt8, UInt8) {
    // Intersect the ray with a sphere of radius nearRadius centred on the sweep origin.
    let b = 2 * simd_dot(eye, dir)
    let c = simd_dot(eye, eye) - nearRadius * nearRadius
    let disc = b * b - 4 * c
    let t = disc > 0 ? (-b + sqrt(disc)) / 2 : nearRadius
    let hit = eye + dir * t
    let stripe = sin(atan2(hit.x, -hit.z) * 90) + sin(asin(max(-1, min(1, hit.y / nearRadius))) * 90)
    let v = UInt8(max(0, min(255, (stripe * 0.25 + 0.5) * 255)))
    return (v, v, v)
}

func jitter(_ i: Int) -> Float { Float((i &* 2654435761 % 2000)) / 1000 - 1 }

// 60 frames on a dense free-form sweep: ~5 see any given direction, as measured on device.
var frames: [CapturedFrame] = []
for i in 0 ..< 60 {
    let yaw = Float(i) * 0.35
    let pitch = jitter(i * 7) * 0.25
    let fwd = SweepFrame.direction(yaw: yaw, pitch: pitch)
    let rot = PlanSweep.cameraRotation(forward: fwd, roll: CaptureConfig.deviceRollRadians)
    // Viewpoint wanders within the 12 cm the capture gate allows.
    let eye = SIMD3<Float>(jitter(i * 3), jitter(i * 5) * 0.3, jitter(i * 11)) * 0.06
    var px = [UInt8](repeating: 255, count: W * H * 4)
    for y in 0 ..< H {
        for x in 0 ..< W {
            let cam = SIMD3<Float>((Float(x) + 0.5 - Float(W) / 2) / fx,
                                   -(Float(y) + 0.5 - Float(H) / 2) / fx, -1)
            let world = simd_normalize(rot * cam)
            let (r, g, b) = shade(world, from: eye)
            let o = (y * W + x) * 4
            px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = 255
        }
    }
    let m = simd_float4x4(SIMD4(rot.columns.0, 0), SIMD4(rot.columns.1, 0),
                          SIMD4(rot.columns.2, 0), SIMD4(eye, 1))
    frames.append(CapturedFrame(width: W, height: H, pixels: px, transform: m, intrinsics: intr))
}

func sharpness(_ image: CGImage) -> Double {
    let w = image.width, h = image.height
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
    defer { buf.deallocate() }
    let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var total = 0.0, n = 0
    for y in (h * 2 / 5) ..< (h * 3 / 5) {
        for x in 1 ..< (w - 1) {
            let a = Double(buf[(y * w + x - 1) * 4]), b = Double(buf[(y * w + x + 1) * 4])
            total += abs(b - a); n += 1
        }
    }
    return n > 0 ? total / Double(n) : 0
}

print("Parallax sharpness test — 60 frames, viewpoint wandering +-6 cm, grating at 0.6 m")
print("Mean |horizontal gradient| across the equatorial band (higher = sharper)\n")
/// Runs one configuration and prints it. `agreement: .infinity` disables the colour veto,
/// which is the only way to isolate what each of the two defences contributes — the veto
/// keeps firing at dominance 0, so dominance 0 alone is no longer a plain average.
var coverages: [Double] = []

@discardableResult
func measure(_ label: String, dominance: Float, agreement: Float, seam: Float = 0) -> Double {
    let start = Date()
    guard let r = PanoramaStitcher.stitch(
        frames: frames, originYaw: 0, dominance: dominance, agreement: agreement, seam: seam
    ) else { fatalError("stitch nil") }
    let s = sharpness(r.image)
    coverages.append(r.coverage)
    print(String(format: "  %@ sharpness %6.2f   coverage %5.1f%%   seam %8.0f -> %8.0f   %.2f s",
                 label.padding(toLength: 34, withPad: " ", startingAt: 0),
                 s, r.coverage * 100, PanoramaStitcher.lastSeamCostBeforeRouting,
                 PanoramaStitcher.lastSeamCost, -start.timeIntervalSinceNow))
    return s
}

print("  --- what each defence is worth, in isolation ---")
let plainAverage = measure("plain average (no defence)", dominance: 0, agreement: .infinity)
let dominanceOnly = measure("dominance 0.50 only", dominance: 0.5, agreement: .infinity)
let vetoOnly = measure("colour veto 48 only", dominance: 0, agreement: 48)
let shipping = measure("SHIPPING: dominance 0.50 + veto 48", dominance: 0.5, agreement: 48)

print("\n  --- dominance sweep, with the veto in place ---")
for d in [Float(0.25), 0.5, 0.7] {
    measure(String(format: "dominance %.2f + veto 48", d), dominance: d, agreement: 48)
}

// Seam routing sweep. The number that matters here is `seam cost` — total colour
// disagreement along the chosen authorship boundaries, which is what routing minimises.
// Sharpness is the price being watched: routing must not buy a quieter boundary by
// smearing the image, which is exactly how the ICM version failed to earn its place.
print("\n  --- seam routing sweep (shipping blend throughout) ---")
var routedCostBefore: Float = 0, routedCostAfter: Float = 0
var unrouted: Double = 0, routed: Double = 0
for w in [Float(0), 0.02, 0.05, 0.10, 0.25, 0.50, 1.00] {
    let s = measure(String(format: "seam %.2f", w), dominance: 0.5, agreement: 48, seam: w)
    if w == 0 { unrouted = s }
    if w == 0.10 {
        routed = s
        routedCostBefore = PanoramaStitcher.lastSeamCostBeforeRouting
        routedCostAfter = PanoramaStitcher.lastSeamCost
    }
}

// How much of the panorama's gradient energy sits exactly on the label grid's cell edges.
//
// This is the run-11 blockiness measured rather than argued. The routing gate used to be a
// hard nearest-cell test on the same 16-px grid as the labels, so the routed and dominance
// paths — which contribute different WEIGHT even where they agree on colour — swapped along
// axis-aligned cell edges and drew them: rectangular chunks across the window beams, a clean
// staircase down the side of every sliver. A scene contains no such structure, so any excess
// energy on those columns is the stitcher's own signature.
//
// A centred gradient at x reads x-1 and x+1, so a boundary between cell c and c+1 shows up at
// x % seamScale == 15 and == 0 — two columns in every sixteen, hence a 12.5% null.
func gridEdgeShare(_ image: CGImage) -> Double {
    let w = image.width, h = image.height
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
    defer { buf.deallocate() }
    let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let s = PanoramaStitcher.seamScale
    var onGrid = 0.0, total = 0.0
    for y in (h * 2 / 5) ..< (h * 3 / 5) {
        for x in 1 ..< (w - 1) {
            let a = Double(buf[(y * w + x - 1) * 4]), b = Double(buf[(y * w + x + 1) * 4])
            let g = abs(b - a)
            total += g
            if x % s == 0 || x % s == s - 1 { onGrid += g }
        }
    }
    return total > 0 ? onGrid / total : 0
}

func share(seam: Float) -> Double {
    guard let r = PanoramaStitcher.stitch(
        frames: frames, originYaw: 0, dominance: 0.5, agreement: 48, seam: seam
    ) else { fatalError("stitch nil") }
    return gridEdgeShare(r.image)
}
// seam 0 builds no label field at all, so it is the honest null: whatever share the SCENE
// happens to put on those columns, with no grid involved.
let gridNull = share(seam: 0)
let gridRouted = share(seam: 0.10)
print(String(format: """

Label-grid signature — share of equatorial gradient energy on cell-edge columns
  chance (2 of every %d columns)   %5.2f%%
  seam 0.00, no label field        %5.2f%%
  seam 0.10, shipping              %5.2f%%
""", PanoramaStitcher.seamScale, 2.0 / Double(PanoramaStitcher.seamScale) * 100,
     gridNull * 100, gridRouted * 100))

print(String(format: """

  vs plain average:  dominance only %+.1f%%   veto only %+.1f%%   both %+.1f%%
""", (dominanceOnly / plainAverage - 1) * 100,
     (vetoOnly / plainAverage - 1) * 100,
     (shipping / plainAverage - 1) * 100))

var failed = false
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failed = true }
}

// The shipping pipeline must beat an undefended average by a wide margin. This is the
// headline claim and the reason both constants exist.
check(shipping > plainAverage * 1.5,
      "shipping blend is >50% sharper than a plain average at the same coverage")

// Routing must not leave its own grid in the output. The tolerance is a relative one against
// the unrouted render of the SAME scene, so a scene that naturally puts energy on those
// columns cannot be mistaken for a stitching artifact.
check(gridRouted <= gridNull * 1.10,
      String(format: "routing draws no grid of its own (%.2f%% on cell edges vs %.2f%% unrouted)",
             gridRouted * 100, gridNull * 100))

// The veto must be carrying most of that on its own. It is the defence that addresses
// PARALLAX specifically — two equally well-placed frames disagreeing — which is what the
// sixth device run showed as doubled chairs and a ghosted ceiling beam, and which
// dominance by construction cannot touch.
check(vetoOnly > dominanceOnly,
      "the colour veto outperforms geometric dominance alone against real parallax")

// Neither defence may buy sharpness by dropping pixels. Both work by choosing WHICH frame
// speaks for a direction, never by leaving it unpainted, so coverage must be untouched.
// This is the check that would catch a veto bug punching holes in the panorama — the
// failure mode that would look like sharpening while actually destroying the image.
// Seam routing must move the objective it exists to move. This is the assertion that
// separates alpha-expansion from the iterated-conditional-modes version it replaced: ICM
// managed 4.5% here, which is why routing shipped disabled. Anything back near that number
// means the minimiser has regressed to a greedy one.
let costReduction = routedCostBefore > 0 ? 1 - routedCostAfter / routedCostBefore : 0
check(costReduction > 0.4,
      String(format: "routing cuts boundary disagreement by >40%% (%.1f%%: %.0f -> %.0f)",
             costReduction * 100, routedCostBefore, routedCostAfter))

// And it must not pay for that with sharpness. A quieter boundary is trivial to buy by
// smearing, and the ICM version's 3.4% loss is what a smearing fix looks like.
check(routed >= unrouted,
      String(format: "routing does not cost sharpness (%.2f routed vs %.2f unrouted)",
             routed, unrouted))

let coverageSpread = (coverages.max() ?? 0) - (coverages.min() ?? 0)
check(coverageSpread < 1e-9,
      String(format: "coverage identical across all %d configurations (spread %.2e)",
             coverages.count, coverageSpread))

if failed { exit(1) }
