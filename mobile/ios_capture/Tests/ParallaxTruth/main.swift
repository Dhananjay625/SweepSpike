// The test that should have existed at run 1.
//
// `Tests/StitchHarness` already compares a stitch against a KNOWN source panorama and reports a
// worst-channel MAE of 1.27 — a genuinely rigorous test, and it has passed through every one of
// the thirteen device runs while the pictures got worse. It passes because it renders every
// frame from a PERFECT PIVOT: zero translation. That is the one condition under which a
// rotation-only stitcher is exactly correct, so the harness has been measuring the only case
// that was never broken.
//
// This test removes that assumption. Same idea — an analytic scene, an exactly computable
// ground-truth panorama — but the camera also TRANSLATES, by the amounts the capture gate
// actually permits. Ground truth stays exact because the scene is analytic: for any ray from any
// eye there is one right colour and one right depth.
//
// SOURCES for the correction being measured:
//   - Matterport Capture for iOS: LiDAR depth is used "to improve image stitching", and users are
//     told to "rotate your body around the device (as if it was on a monopod or broomstick)" to
//     minimise parallax. https://support.matterport.com/hc/en-us/articles/1500004898402
//   - Nikon US11568516B2, "Depth-based image stitching for handling parallax".
//     https://patents.google.com/patent/US11568516
//   - Apple, WWDC20 "Explore ARKit 4" — `ARFrame.sceneDepth`, LiDAR-fused dense depth at 60 Hz
//     with a per-pixel confidence map. https://developer.apple.com/videos/play/wwdc2020/10611/
//   - Background on why a rotation-only model cannot be repaired by blending: a homography
//     describes the mapping only for pure rotation or a planar scene; otherwise "it creates
//     ghosting effects, also known as parallax".
//
// Build:
//   swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift Sources/GraphCut.swift \
//     Tests/StitchHarness/PlanSweep.swift Tests/ParallaxTruth/main.swift -o /tmp/parallaxtruth
import CoreGraphics
import Foundation
import simd

let W = 480, H = 360
let hfovX: Float = 60 * .pi / 180
let fxF = Float(W) / (2 * tan(hfovX / 2))
let intr = simd_float3x3(SIMD3(fxF, 0, 0), SIMD3(0, fxF, 0),
                         SIMD3(Float(W) / 2, Float(H) / 2, 1))
let panoW = 1024, panoH = 512

// MARK: - An analytic room

// A box 6 m x 3 m x 6 m with the viewer inside, plus a near object at 0.55 m — a desk edge, the
// thing that wrecked every device run. Colour is a 3D checker ON THE SURFACE, so it is
// view-independent: the right answer for a direction does not depend on who is looking.
let roomHalf = SIMD3<Float>(3, 1.5, 3)
let nearCentre = SIMD3<Float>(0.35, -0.25, -0.40)   // ~0.58 m from the origin
let nearRadius: Float = 0.22

/// Nearest hit along `dir` from `eye`: distance, and the surface colour there.
func trace(_ eye: SIMD3<Float>, _ dir: SIMD3<Float>) -> (dist: Float, grey: Float) {
    var best = Float.greatestFiniteMagnitude
    var point = SIMD3<Float>.zero

    // Sphere first — it occludes.
    let oc = eye - nearCentre
    let b = simd_dot(oc, dir)
    let c = simd_dot(oc, oc) - nearRadius * nearRadius
    let disc = b * b - c
    if disc > 0 {
        let t = -b - disc.squareRoot()
        if t > 1e-4 { best = t; point = eye + dir * t }
    }

    // Then the room, from the inside: the smallest POSITIVE slab exit.
    for axis in 0 ..< 3 {
        let d = dir[axis]
        guard abs(d) > 1e-6 else { continue }
        for sign in [Float(-1), 1] {
            let t = (sign * roomHalf[axis] - eye[axis]) / d
            guard t > 1e-4, t < best else { continue }
            let p = eye + dir * t
            // Only count it if the hit is actually on the wall's rectangle.
            var inside = true
            for other in 0 ..< 3 where other != axis {
                if abs(p[other]) > roomHalf[other] + 1e-3 { inside = false }
            }
            if inside { best = t; point = p }
        }
    }
    guard best < .greatestFiniteMagnitude else { return (10, 0.5) }

    // 12 cm checker in world space, plus a fine stripe so sub-pixel misalignment still shows.
    let cell = floor(point.x / 0.12) + floor(point.y / 0.12) + floor(point.z / 0.12)
    let base: Float = cell.truncatingRemainder(dividingBy: 2) == 0 ? 0.25 : 0.80
    let fine = 0.12 * sin(point.x * 47) * sin(point.y * 47) * sin(point.z * 47)
    return (best, max(0.02, min(0.98, base + fine)))
}

func jitter(_ i: Int) -> Float { Float((i &* 2654435761 % 2000)) / 1000 - 1 }

// MARK: - Ground truth, rendered straight from the sweep origin

let origin = SIMD3<Float>.zero
var truth = [UInt8](repeating: 0, count: panoW * panoH)
for y in 0 ..< panoH {
    let lat = .pi / 2 - (Float(y) + 0.5) / Float(panoH) * .pi
    for x in 0 ..< panoW {
        let lon = (Float(x) + 0.5) / Float(panoW) * 2 * .pi - .pi
        let local = SIMD3(cos(lat) * sin(lon), sin(lat), -cos(lat) * cos(lon))
        // Through the SAME mapping the stitcher uses, so no convention can drift between them.
        let dir = SweepFrame.toWorld(local, originYaw: 0)
        truth[y * panoW + x] = UInt8(max(0, min(255, trace(origin, dir).grey * 255)))
    }
}

// MARK: - Frames, from viewpoints that have MOVED

/// `translation` is the radius of the wander, in metres. `withDepth` attaches the exact depth
/// map — this is the stand-in for `ARFrame.sceneDepth`, and using the exact one isolates the
/// question "does knowing depth fix the geometry" from "is ARKit's depth good enough".
func makeFrames(translation: Float, withDepth: Bool, depthDivisor: Int = 4) -> [CapturedFrame] {
    var frames: [CapturedFrame] = []
    let dW = W / depthDivisor, dH = H / depthDivisor
    // Three rings of 24. Structured rather than jittered so the equatorial band is covered
    // several times over and the error below is never contaminated by hole filling — the
    // artifact being measured is misregistration, not absence.
    var poses: [(Float, Float)] = []
    for ring in [Float(-0.35), 0, 0.35] {
        for step in 0 ..< 24 { poses.append((Float(step) * 2 * .pi / 24, ring)) }
    }
    for (i, pose) in poses.enumerated() {
        let yaw = pose.0
        let pitch = pose.1
        let fwd = SweepFrame.direction(yaw: yaw, pitch: pitch)
        let rot = PlanSweep.cameraRotation(forward: fwd, roll: CaptureConfig.deviceRollRadians)
        let eye = simd_normalize(SIMD3(jitter(i * 3), jitter(i * 5) * 0.4, jitter(i * 11))
            + SIMD3<Float>(1e-4, 0, 0)) * translation

        var px = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0 ..< H {
            for x in 0 ..< W {
                let cam = SIMD3<Float>((Float(x) + 0.5 - Float(W) / 2) / fxF,
                                       -(Float(y) + 0.5 - Float(H) / 2) / fxF, -1)
                let g = trace(eye, simd_normalize(rot * cam)).grey
                let o = (y * W + x) * 4
                let v = UInt8(max(0, min(255, g * 255)))
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
            }
        }

        var depths: [Float]?
        if withDepth {
            var d = [Float](repeating: 0, count: dW * dH)
            for y in 0 ..< dH {
                for x in 0 ..< dW {
                    // Sample at the centre of the depth texel, in colour-frame coordinates.
                    let cxp = (Float(x) + 0.5) * Float(depthDivisor)
                    let cyp = (Float(y) + 0.5) * Float(depthDivisor)
                    let a = (cxp - Float(W) / 2) / fxF, bb = -(cyp - Float(H) / 2) / fxF
                    let ray = SIMD3<Float>(a, bb, -1)
                    let len = simd_length(ray)
                    // ARKit reports depth along the OPTICAL AXIS, not along the ray.
                    d[y * dW + x] = trace(eye, simd_normalize(rot * ray)).dist / len
                }
            }
            depths = d
        }

        let m = simd_float4x4(SIMD4(rot.columns.0, 0), SIMD4(rot.columns.1, 0),
                              SIMD4(rot.columns.2, 0), SIMD4(eye, 1))
        frames.append(CapturedFrame(
            width: W, height: H, pixels: px, transform: m, intrinsics: intr,
            driftMeters: simd_length(eye),
            depths: depths, depthWidth: withDepth ? dW : 0, depthHeight: withDepth ? dH : 0))
    }
    return frames
}

/// Mean absolute error against the ground-truth panorama, in 0-255 levels.
func error(_ frames: [CapturedFrame]) -> (mae: Double, coverage: Double) {
    guard let r = PanoramaStitcher.stitch(
        frames: frames, originYaw: 0, originPosition: origin, width: panoW, height: panoH
    ) else { fatalError("stitch nil") }
    var buf = [UInt8](repeating: 0, count: panoW * panoH * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: panoW, height: panoH,
                            bitsPerComponent: 8, bytesPerRow: panoW * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(r.image, in: CGRect(x: 0, y: 0, width: panoW, height: panoH))
    }
    // Only the band the ring plan genuinely covers, +-30 degrees of the horizon. Outside it
    // the stitch is hole-filled and the error would measure invention, not misregistration.
    var sum = 0.0
    var n = 0
    let y0 = panoH / 3, y1 = panoH * 2 / 3
    for y in y0 ..< y1 {
        for x in 0 ..< panoW {
            sum += abs(Double(buf[(y * panoW + x) * 4]) - Double(truth[y * panoW + x]))
            n += 1
        }
    }
    return (sum / Double(n), r.coverage)
}

// MARK: - Results

print("Parallax ground truth — analytic room, exact reference panorama")
print("Mean absolute error against the truth, in 0-255 levels. Lower is better.\n")

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failures += 1 }
}

let steps: [Float] = [0, 0.05, 0.10, 0.30]
var blind: [Float: Double] = [:], seeing: [Float: Double] = [:]

print("  translation      rotation-only        depth-aware      predicted error")
print("                   (runs 1-13)          (this change)    at 0.58 m")
for t in steps {
    let b = error(makeFrames(translation: t, withDepth: false))
    let s = error(makeFrames(translation: t, withDepth: true))
    blind[t] = b.mae; seeing[t] = s.mae
    let predicted = atan(Double(t) / 0.58) * 180 / .pi
    print(String(format: "  %5.2f m          MAE %6.2f          MAE %6.2f        %5.1f deg",
                 t, b.mae, s.mae, predicted))
}

print("")
// 1. The harness's blind spot, demonstrated. At zero translation the old model is right, which
//    is exactly why StitchHarness never caught any of this.
// The floor is ~15, not ~0, and that is the SCENE, not the stitcher: a 12 cm checker with a
// 13 cm stripe on top, rendered from 480 px frames and resampled into a 1024 px panorama,
// cannot survive resampling exactly. It is identical with and without depth, which is what
// proves it is resampling rather than misregistration. What matters is the RATIO to the
// translated cases, so that is what is asserted.
check(blind[0]! < blind[0.10]! * 0.35,
      String(format: "at a PERFECT pivot the rotation-only model is near the scene's own resampling floor (MAE %.2f vs %.2f at 0.10 m) — the only case the old harness ever tested",
             blind[0]!, blind[0.10]!))

// 2. The damage, quantified.
check(blind[0.30]! > blind[0]! * 2.5,
      String(format: "translation wrecks it: MAE %.2f at 0 m -> %.2f at 0.30 m, the drift the app allowed",
             blind[0]!, blind[0.30]!))

// 3. The fix. This is the headline claim and the reason the change exists.
check(seeing[0.30]! < blind[0.30]! * 0.7,
      String(format: "depth recovers most of it at 0.30 m: MAE %.2f -> %.2f (%.0f%% better)",
             blind[0.30]!, seeing[0.30]!, (1 - seeing[0.30]! / blind[0.30]!) * 100))
check(seeing[0.10]! < blind[0.10]! * 0.8,
      String(format: "and at the 0.10 m the tightened warning now targets: MAE %.2f -> %.2f (%.0f%% better)",
             blind[0.10]!, seeing[0.10]!, (1 - seeing[0.10]! / blind[0.10]!) * 100))

// The strongest form of the claim: with depth, a camera that moved 10 cm is almost as good as
// one that did not move at all. That is what "parallax is corrected rather than masked" means.
check(seeing[0.10]! < blind[0]! * 1.3,
      String(format: "with depth, a 10 cm translation costs almost nothing: MAE %.2f against a %.2f perfect-pivot floor",
             seeing[0.10]!, blind[0]!))

// 4. It must not damage the case that already worked — no depth, or a true pivot.
check(abs(seeing[0]! - blind[0]!) < 0.01,
      String(format: "at zero translation the correction is a NO-OP (%.4f vs %.4f)", seeing[0]!, blind[0]!))

print("")
if failures > 0 {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
print("ALL CHECKS PASSED")
