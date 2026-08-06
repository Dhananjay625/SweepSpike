import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// End-to-end demo of the real capture plan and the real stitcher, at the resolution the
// app actually ships. ARKit is only needed to ACQUIRE frames; the plan and the stitch are
// pure geometry, so both can be exercised on a host with no device.
//
// It renders a synthetic room, simulates the phone visiting every target in
// `CaptureConfig.rings` (with the portrait roll a real hand applies, plus aiming error),
// then stitches the result with the shipping `PanoramaStitcher`.
//
// What this DOES establish: the shipping plan closes the sphere, the stitcher runs to
// completion at 4096x2048, how long that takes, and whether seams appear under realistic
// aiming error.
// What this does NOT establish: that ARKit's real intrinsics and poses match the
// conventions assumed here, or that a real room's parallax stitches cleanly. Only a
// device run settles those.

// MARK: - Synthetic room

let roomWidth = 4096
let roomHeight = 2048

/// A room panorama: four differently-toned walls, a bright window, a dark floor, a light
/// ceiling, and a fine grid. The grid is the point — a misaligned frame breaks grid lines
/// at its boundary, which is far easier to see than a smooth gradient shifting.
func roomColour(lon: Float, lat: Float) -> (Float, Float, Float) {
    let latDegrees = lat * 180 / .pi
    let lonDegrees = lon * 180 / .pi

    var rgb: (Float, Float, Float)
    if latDegrees > 55 {
        rgb = (232, 232, 238)                       // ceiling
    } else if latDegrees < -50 {
        rgb = (92, 74, 60)                          // floor
    } else {
        // Four walls, each a different tone so seams between walls are obvious.
        let wall = Int(floor((lonDegrees + 180) / 90)) % 4
        switch wall {
        case 0: rgb = (196, 188, 174)
        case 1: rgb = (176, 186, 196)
        case 2: rgb = (198, 180, 170)
        default: rgb = (182, 192, 180)
        }
        // A bright window on one wall: a hard high-dynamic-range edge, which is exactly
        // where exposure-blending artefacts show up first.
        if lonDegrees > -70, lonDegrees < -20, latDegrees > -12, latDegrees < 28 {
            rgb = (250, 250, 244)
        }
    }

    // Fine grid, ~5 degrees, for detecting sub-degree misalignment at frame boundaries.
    let gridLon = abs(lonDegrees.truncatingRemainder(dividingBy: 5)) < 0.35
    let gridLat = abs(latDegrees.truncatingRemainder(dividingBy: 5)) < 0.35
    if gridLon || gridLat {
        rgb = (rgb.0 * 0.55, rgb.1 * 0.55, rgb.2 * 0.55)
    }
    return rgb
}

func makeRoom() -> [Float] {
    var pixels = [Float](repeating: 0, count: roomWidth * roomHeight * 3)
    for y in 0 ..< roomHeight {
        let lat = .pi / 2 - (Float(y) + 0.5) / Float(roomHeight) * .pi
        for x in 0 ..< roomWidth {
            let lon = (Float(x) + 0.5) / Float(roomWidth) * 2 * .pi - .pi
            let (r, g, b) = roomColour(lon: lon, lat: lat)
            let index = (y * roomWidth + x) * 3
            pixels[index] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
        }
    }
    return pixels
}

func sampleRoom(_ room: [Float], direction d: SIMD3<Float>) -> (Float, Float, Float) {
    let lon = atan2(d.x, -d.z)
    let lat = asin(max(-1, min(1, d.y)))
    var x = Int((lon + .pi) / (2 * .pi) * Float(roomWidth))
    var y = Int((.pi / 2 - lat) / .pi * Float(roomHeight))
    x = ((x % roomWidth) + roomWidth) % roomWidth
    y = max(0, min(roomHeight - 1, y))
    let index = (y * roomWidth + x) * 3
    return (room[index], room[index + 1], room[index + 2])
}

// MARK: - Simulated device frames

// iPhone wide camera proportions, downscaled exactly as `FrameConverter` would.
let capturedLongAxis = CaptureConfig.storedFrameMaxDimension
let capturedShortAxis = capturedLongAxis * 3 / 4
let demoFocal = Float(capturedLongAxis) / 2 / tan(30 * .pi / 180)

let demoIntrinsics = simd_float3x3(
    SIMD3(demoFocal, 0, 0),
    SIMD3(0, demoFocal, 0),
    SIMD3(Float(capturedLongAxis) / 2, Float(capturedShortAxis) / 2, 1)
)

/// Deterministic pseudo-random in [-1, 1], so runs are reproducible.
func jitter(_ seed: Int) -> Float {
    let x = sin(Float(seed) * 12.9898) * 43758.547
    return 2 * (x - x.rounded(.down)) - 1
}

func renderCapturedFrame(room: [Float], transform: simd_float4x4) -> [UInt8] {
    let rotation = simd_float3x3(
        SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
        SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
        SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    )
    let cx = Float(capturedLongAxis) / 2
    let cy = Float(capturedShortAxis) / 2

    var pixels = [UInt8](repeating: 255, count: capturedLongAxis * capturedShortAxis * 4)
    for v in 0 ..< capturedShortAxis {
        for u in 0 ..< capturedLongAxis {
            let xCV = (Float(u) + 0.5 - cx) / demoFocal
            let yCV = (Float(v) + 0.5 - cy) / demoFocal
            // CV (x right, y down, z forward) -> ARKit camera (x right, y up, z backward).
            let inCamera = simd_normalize(SIMD3(xCV, -yCV, Float(-1)))
            let (r, g, b) = sampleRoom(room, direction: rotation * inCamera)
            let index = (v * capturedLongAxis + u) * 4
            pixels[index] = UInt8(max(0, min(255, r)))
            pixels[index + 1] = UInt8(max(0, min(255, g)))
            pixels[index + 2] = UInt8(max(0, min(255, b)))
        }
    }
    return pixels
}

// MARK: - Run

print("SweepSpike end-to-end panorama demo")
print(String(format: "  plan            %d targets in %d rings",
             CaptureTarget.makePlan().count, CaptureConfig.rings.count))
print("  frame           \(capturedLongAxis) x \(capturedShortAxis) (as stored by FrameConverter)")
print("  output          4096 x 2048 equirectangular")

let room = makeRoom()
let plan = CaptureTarget.makePlan()

// The app fires when the aim is within `aimThresholdRadians`, so frames are never
// perfectly on target. Simulating that is the point: a plan that only closes the sphere
// when aimed perfectly will show gaps in a real hand.
let aimError = CaptureConfig.aimThresholdRadians
var frames: [CapturedFrame] = []
for (index, target) in plan.enumerated() {
    let yaw = target.yaw + jitter(index * 3 + 1) * aimError
    let pitch = max(-Float.pi / 2 + 0.01,
                    min(.pi / 2 - 0.01, target.pitch + jitter(index * 3 + 2) * aimError))
    let forward = SweepFrame.direction(yaw: yaw, pitch: pitch)

    // Portrait roll, plus a few degrees of hand tilt.
    let roll = CaptureConfig.deviceRollRadians + jitter(index * 3 + 3) * 0.05
    let rotation = PlanSweep.cameraRotation(forward: forward, roll: roll)
    let transform = simd_float4x4(
        SIMD4(rotation.columns.0, 0),
        SIMD4(rotation.columns.1, 0),
        SIMD4(rotation.columns.2, 0),
        SIMD4(0, 0, 0, 1)
    )

    frames.append(CapturedFrame(
        width: capturedLongAxis,
        height: capturedShortAxis,
        pixels: renderCapturedFrame(room: room, transform: transform),
        transform: transform,
        intrinsics: demoIntrinsics
    ))
}
print(String(format: "  aiming error    +-%.1f deg, plus +-2.9 deg roll (worst case)",
             aimError * 180 / .pi))

let started = Date()
guard let result = PanoramaStitcher.stitch(frames: frames, originYaw: 0) else {
    print("  FAIL  stitch returned nil")
    exit(1)
}
let elapsed = Date().timeIntervalSince(started)

// Solid-angle coverage, not the pixel fraction: equirect rows near the pole carry equal
// pixel weight but almost no solid angle.
var covered = 0.0, total = 0.0
var output = [UInt8](repeating: 0, count: 4096 * 2048 * 4)
output.withUnsafeMutableBytes { raw in
    guard let base = raw.baseAddress,
          let context = CGContext(
              data: base, width: 4096, height: 2048, bitsPerComponent: 8,
              bytesPerRow: 4096 * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return }
    context.draw(result.image, in: CGRect(x: 0, y: 0, width: 4096, height: 2048))
}
for y in 0 ..< 2048 {
    let lat = .pi / 2 - (Float(y) + 0.5) / 2048 * .pi
    let weight = Double(cos(lat))
    for x in 0 ..< 4096 {
        let i = (y * 4096 + x) * 4
        total += weight
        if output[i] != 0 || output[i + 1] != 0 || output[i + 2] != 0 { covered += weight }
    }
}
let solidAngle = covered / total

print("")
print(String(format: "  stitched        %d frames in %.2f s on this Mac", result.frameCount, elapsed))
print(String(format: "  coverage        %.2f%% of solid angle", solidAngle * 100))

let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sweepspike-demo-panorama.png")
if let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) {
    CGImageDestinationAddImage(destination, result.image, nil)
    if CGImageDestinationFinalize(destination) { print("  wrote           \(outputURL.path)") }
}

// Where the holes are matters more than that they exist: a gap at the zenith is a cap-ring
// problem, a gap at mid-latitude is a yaw-spacing problem, and they have different fixes.
print("\n  Uncovered pixels by latitude band (bands with any hole)")
for band in stride(from: -90, to: 90, by: 10) {
    var filled = 0, count = 0
    let yLo = Int((90.0 - Double(band + 10)) / 180.0 * 2048)
    let yHi = Int((90.0 - Double(band)) / 180.0 * 2048)
    for y in max(0, yLo) ..< min(2048, yHi) {
        for x in 0 ..< 4096 {
            let i = (y * 4096 + x) * 4
            count += 1
            if output[i] != 0 || output[i + 1] != 0 || output[i + 2] != 0 { filled += 1 }
        }
    }
    let pct = count > 0 ? Double(filled) / Double(count) * 100 : 100
    if pct < 99.95 {
        print(String(format: "    %+4d to %+4d deg   %6.2f%% covered", band, band + 10, pct))
    }
}

var failed = false
if solidAngle < 0.999 {
    print(String(format: "\n  FAIL  coverage %.2f%% leaves a hole even before parallax", solidAngle * 100))
    failed = true
}
print(failed ? "\nDEMO FAILED" : "\nDEMO OK — full sphere covered under realistic aiming error")
exit(failed ? 1 : 0)
