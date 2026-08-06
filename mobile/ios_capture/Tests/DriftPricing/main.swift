// Drift must be PRICED, not banned: a drifted frame has to lose wherever a well-placed
// frame also saw the direction, and win wherever nothing else did.
//
// Banning drifted frames cost roughly half the sphere across two device runs (~98% -> 54.6%
// and 58.6%). This checks the replacement does both halves of its job.
import CoreGraphics
import Foundation
import simd

let W = 640, H = 480
let fx = Float(W) / (2 * tan(60 * .pi / 180 / 2))
let intr = simd_float3x3(SIMD3(fx, 0, 0), SIMD3(0, fx, 0), SIMD3(Float(W)/2, Float(H)/2, 1))

func frame(yaw: Float, pitch: Float, drift: Float, grey: UInt8) -> CapturedFrame {
    let fwd = SweepFrame.direction(yaw: yaw, pitch: pitch)
    let rot = PlanSweep.cameraRotation(forward: fwd, roll: CaptureConfig.deviceRollRadians)
    let m = simd_float4x4(SIMD4(rot.columns.0, 0), SIMD4(rot.columns.1, 0),
                          SIMD4(rot.columns.2, 0), SIMD4(0, 0, 0, 1))
    var px = [UInt8](repeating: 255, count: W * H * 4)
    for i in 0 ..< W * H { px[i*4] = grey; px[i*4+1] = grey; px[i*4+2] = grey }
    return CapturedFrame(width: W, height: H, pixels: px, transform: m,
                         intrinsics: intr, driftMeters: drift)
}

// Two frames aimed identically: one on-origin (grey 60), one 25 cm adrift (grey 200).
// Plus a drifted frame alone on the far side, which nothing else covers.
let frames = [
    frame(yaw: 0, pitch: 0, drift: 0,    grey: 60),
    frame(yaw: 0, pitch: 0, drift: 0.25, grey: 200),
    frame(yaw: .pi, pitch: 0, drift: 0.25, grey: 200),
]

guard let r = PanoramaStitcher.stitch(frames: frames, originYaw: 0, width: 1024, height: 512)
else { fatalError("stitch nil") }

let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024*512*4)
let ctx = CGContext(data: buf, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 1024*4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(r.image, in: CGRect(x: 0, y: 0, width: 1024, height: 512))
func sample(_ x: Int) -> Int { Int(buf[(256 * 1024 + x) * 4]) }

// Longitude 0 is the canvas centre; longitude 180 is the wrap column.
let contested = sample(512)
let uncontested = sample(0)
print("Drift pricing")
print("  contested direction (on-origin + 25 cm adrift): grey \(contested)  [want ~60]")
print("  uncontested direction (25 cm adrift only):      grey \(uncontested)  [want ~200]")
print(String(format: "  coverage %.1f%%", r.coverage * 100))

var failures = 0
if contested > 90 {
    print("  FAIL drifted frame polluted a direction a good frame already covered")
    failures += 1
} else { print("  PASS well-placed frame wins where both saw it") }
if uncontested < 150 {
    print("  FAIL drifted frame was discarded where nothing else saw it")
    failures += 1
} else { print("  PASS drifted frame fills what nothing else reached") }
if failures > 0 { exit(1) }
print("\nALL CHECKS PASSED")
