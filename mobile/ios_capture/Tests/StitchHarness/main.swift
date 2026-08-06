import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// Host-side verification of the panorama geometry, runnable on macOS without Xcode.
//
// Method: build a synthetic equirectangular source, render 24 virtual camera views of
// it with a forward projection written independently of the stitcher, stitch those
// views back, and compare against the source. A sign error anywhere in the yaw frame,
// the world->camera transform, or the ARKit->CV flip produces a large channel error.
//
// What this CANNOT prove: that ARKit's real `intrinsics` and `transform` match the
// conventions assumed here. Only a device run settles that.

// MARK: - Synthetic source

let sourceWidth = 2048
let sourceHeight = 1024
/// Non-zero on purpose: exercises SweepFrame.toWorld / toLocal rather than letting
/// an identity rotation hide a sign error.
let testOriginYaw: Float = 0.7

/// Strong independent gradients per axis: red encodes longitude, green encodes
/// latitude, and the blue checker exposes sub-degree misalignment.
func sourceColour(lon: Float, lat: Float) -> (UInt8, UInt8, UInt8) {
    let lonDegrees = lon * 180 / .pi
    let latDegrees = lat * 180 / .pi
    let checker = (Int(floor((lonDegrees + 180) / 10)) + Int(floor((latDegrees + 90) / 10))) % 2 == 0
    let red = UInt8(max(0, min(255, (lonDegrees + 180) / 360 * 255)))
    let green = UInt8(max(0, min(255, (latDegrees + 90) / 180 * 255)))
    return (red, green, checker ? 230 : 40)
}

func makeSource() -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: sourceWidth * sourceHeight * 4)
    for y in 0 ..< sourceHeight {
        let lat = .pi / 2 - (Float(y) + 0.5) / Float(sourceHeight) * .pi
        for x in 0 ..< sourceWidth {
            let lon = (Float(x) + 0.5) / Float(sourceWidth) * 2 * .pi - .pi
            let (r, g, b) = sourceColour(lon: lon, lat: lat)
            let index = (y * sourceWidth + x) * 4
            pixels[index] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
        }
    }
    return pixels
}

func sampleSource(_ source: [UInt8], localDirection d: SIMD3<Float>) -> (UInt8, UInt8, UInt8) {
    let lon = atan2(d.x, -d.z)
    let lat = asin(max(-1, min(1, d.y)))
    var x = Int(((lon + .pi) / (2 * .pi) * Float(sourceWidth)).rounded(.down))
    var y = Int(((.pi / 2 - lat) / .pi * Float(sourceHeight)).rounded(.down))
    x = ((x % sourceWidth) + sourceWidth) % sourceWidth
    y = max(0, min(sourceHeight - 1, y))
    let index = (y * sourceWidth + x) * 4
    return (source[index], source[index + 1], source[index + 2])
}

// MARK: - Virtual cameras

let frameWidth = 640
let frameHeight = 480
/// 60 degree horizontal field of view, roughly an iPhone wide camera.
let focal = Float(frameWidth) / 2 / tan(30 * .pi / 180)

/// ARKit camera transform: columns are right, up, backward, position.
func makeTransform(forward: SIMD3<Float>) -> simd_float4x4 {
    let backward = -simd_normalize(forward)
    // Guard the pole case, where world up is parallel to backward and the cross
    // product collapses to zero; normalising that yields an all-NaN frame.
    var right = simd_cross(SIMD3<Float>(0, 1, 0), backward)
    if simd_length(right) < 1e-4 {
        right = simd_cross(SIMD3<Float>(0, 0, 1), backward)
    }
    right = simd_normalize(right)
    let up = simd_cross(backward, right)
    return simd_float4x4(
        SIMD4(right.x, right.y, right.z, 0),
        SIMD4(up.x, up.y, up.z, 0),
        SIMD4(backward.x, backward.y, backward.z, 0),
        SIMD4(0, 0, 0, 1)
    )
}

/// Forward projection, written from the CV convention directly rather than by
/// inverting the stitcher, so the two are genuinely independent.
func renderFrame(source: [UInt8], transform: simd_float4x4) -> [UInt8] {
    let rotation = simd_float3x3(
        SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
        SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
        SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    )
    let cx = Float(frameWidth) / 2
    let cy = Float(frameHeight) / 2

    var pixels = [UInt8](repeating: 255, count: frameWidth * frameHeight * 4)
    for v in 0 ..< frameHeight {
        for u in 0 ..< frameWidth {
            let xCV = (Float(u) + 0.5 - cx) / focal
            let yCV = (Float(v) + 0.5 - cy) / focal
            // CV (x right, y down, z forward) -> ARKit camera (x right, y up, z backward).
            let inCamera = simd_normalize(SIMD3(xCV, -yCV, Float(-1)))
            let inWorld = rotation * inCamera
            let inLocal = SweepFrame.toLocal(inWorld, originYaw: testOriginYaw)
            let (r, g, b) = sampleSource(source, localDirection: inLocal)
            let index = (v * frameWidth + u) * 4
            pixels[index] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
        }
    }
    return pixels
}

// MARK: - Checks

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  PASS  \(description)")
    } else {
        print("  FAIL  \(description)")
        failures.append(description)
    }
}

print("SweepFrame round trips")
for yaw in stride(from: Float(-3.0), through: 3.0, by: 0.7) {
    for pitch in [Float(-0.5), 0, 0.5] {
        let direction = SweepFrame.direction(yaw: yaw, pitch: pitch)
        let recoveredYaw = SweepFrame.yaw(of: direction)
        let wrapped = atan2(sin(yaw), cos(yaw))
        if abs(recoveredYaw - wrapped) > 1e-4 {
            failures.append("yaw(direction(\(yaw), \(pitch))) = \(recoveredYaw)")
        }
        let world = SweepFrame.toWorld(direction, originYaw: testOriginYaw)
        let back = SweepFrame.toLocal(world, originYaw: testOriginYaw)
        if simd_distance(direction, back) > 1e-5 {
            failures.append("toLocal(toWorld(d)) != d at yaw \(yaw) pitch \(pitch)")
        }
        // toWorld must add originYaw to the heading, not subtract it.
        let expected = SweepFrame.direction(yaw: yaw + testOriginYaw, pitch: pitch)
        if simd_distance(world, expected) > 1e-5 {
            failures.append("toWorld does not add originYaw at yaw \(yaw) pitch \(pitch)")
        }
    }
}
check(failures.isEmpty, "yaw/direction/toWorld/toLocal are mutually consistent")

// Pinned, not `CaptureConfig.rings`: this test checks that projection and inverse
// projection agree, so it must not shift every time the capture plan is retuned.
let testPlan = CaptureTarget.makePlan(yawSteps: 8, pitchRings: [0, .pi / 6, -.pi / 6])

print("\nRendering \(testPlan.count) virtual frames")
let source = makeSource()
let intrinsics = simd_float3x3(
    SIMD3(focal, 0, 0),
    SIMD3(0, focal, 0),
    SIMD3(Float(frameWidth) / 2, Float(frameHeight) / 2, 1)
)

let frames: [CapturedFrame] = testPlan.map { target in
    let worldDirection = SweepFrame.toWorld(target.localDirection, originYaw: testOriginYaw)
    let transform = makeTransform(forward: worldDirection)
    return CapturedFrame(
        width: frameWidth,
        height: frameHeight,
        pixels: renderFrame(source: source, transform: transform),
        transform: transform,
        intrinsics: intrinsics
    )
}

print("Stitching at \(sourceWidth)x\(sourceHeight)")
let started = Date()
guard let result = PanoramaStitcher.stitch(
    frames: frames,
    originYaw: testOriginYaw,
    width: sourceWidth,
    height: sourceHeight
) else {
    print("  FAIL  stitch returned nil")
    exit(1)
}
let elapsed = Date().timeIntervalSince(started)
print(String(format: "  stitched in %.2f s, coverage %.1f%%", elapsed, result.coverage * 100))

// What the APP ships, not what a sweep can be talked into. Every other seam number in this
// suite comes from a test that passes `seam:` explicitly, so none of them can notice the
// default moving — and the default is exactly what three bad device runs were about. Routing
// is off; this fails the moment something turns it back on without saying so.
print(String(format: "  shipping default: seam field %@ (cost %.0f -> %.0f)",
             PanoramaStitcher.lastSeamCostBeforeRouting == 0 ? "not built" : "BUILT",
             PanoramaStitcher.lastSeamCostBeforeRouting, PanoramaStitcher.lastSeamCost))
check(PanoramaStitcher.lastSeamCostBeforeRouting == 0 && PanoramaStitcher.lastSeamCost == 0,
      "the shipping default builds NO seam field — routing stays off until the staircase "
      + "at seamScale 16 is fixed and proven on a device")

// MARK: - Compare against the source

var stitched = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
stitched.withUnsafeMutableBytes { raw in
    guard let base = raw.baseAddress,
          let context = CGContext(
              data: base,
              width: sourceWidth,
              height: sourceHeight,
              bitsPerComponent: 8,
              bytesPerRow: sourceWidth * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return }
    context.draw(result.image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
}

var totals = [Double](repeating: 0, count: 3)
var comparedPixels = 0
for y in 0 ..< sourceHeight {
    let lat = .pi / 2 - (Float(y) + 0.5) / Float(sourceHeight) * .pi
    // Only compare where the 3-ring plan can physically see; the poles are unreachable.
    guard abs(lat) < 40 * .pi / 180 else { continue }
    for x in 0 ..< sourceWidth {
        let index = (y * sourceWidth + x) * 4
        guard stitched[index] != 0 || stitched[index + 1] != 0 || stitched[index + 2] != 0
        else { continue }
        comparedPixels += 1
        for channel in 0 ..< 3 {
            totals[channel] += abs(Double(stitched[index + channel]) - Double(source[index + channel]))
        }
    }
}

// Where are the holes: polar caps, or longitude gaps between adjacent frames?
//
// This reads the OUTPUT IMAGE, so it now reports "not black" rather than "captured":
// the stitcher fills gaps before quantising, and a filled gap is not black. Keep it as a
// diagnostic — a band below 100% here means a hole so large even the pyramid fill could
// not reach it — but do NOT gate on it. `result.coverage` is the honest number.
print("\nStitched non-black by latitude band (post hole-fill)")
for band in stride(from: -90, to: 90, by: 15) {
    var filled = 0, total = 0
    let yLo = Int((90.0 - Double(band + 15)) / 180.0 * Double(sourceHeight))
    let yHi = Int((90.0 - Double(band)) / 180.0 * Double(sourceHeight))
    for y in max(0, yLo) ..< min(sourceHeight, yHi) {
        for x in 0 ..< sourceWidth {
            let index = (y * sourceWidth + x) * 4
            total += 1
            if stitched[index] != 0 || stitched[index + 1] != 0 || stitched[index + 2] != 0 {
                filled += 1
            }
        }
    }
    let percent = total > 0 ? Double(filled) / Double(total) * 100 : 0
    print(String(format: "  %+4d to %+4d deg  %5.1f%%", band, band + 15, percent))
}

let names = ["red (longitude)", "green (latitude)", "blue (checker)"]
print("\nMean absolute error over \(comparedPixels) compared pixels, 0-255 scale")
var worstError = 0.0
for channel in 0 ..< 3 {
    let mae = comparedPixels > 0 ? totals[channel] / Double(comparedPixels) : 999
    worstError = max(worstError, mae)
    print(String(format: "  %-18s %.2f", (names[channel] as NSString).utf8String!, mae))
}

// `Result.coverage` is cos-latitude weighted, so it is already true solid angle: the
// fraction of the SPHERE at least one frame saw, measured before any hole filling.
// Gating on an equirect PIXEL count instead would understate coverage badly, because a
// row near the pole carries the same pixel weight as a row at the equator despite
// subtending almost no solid angle (a plan reaching +-53 deg latitude covers 80% of the
// sphere but only 59% of the pixels).
//
// Re-measuring from the image is no longer possible: hole filling means "non-black" is
// not "captured". The pixel fraction below is printed only to show how far apart the two
// framings are, and is why the UI must never quote it as "% of the sphere".
var pixelsCovered = 0
for index in stride(from: 0, to: stitched.count, by: 4) {
    if stitched[index] != 0 || stitched[index + 1] != 0 || stitched[index + 2] != 0 {
        pixelsCovered += 1
    }
}
let pixelCoverage = Double(pixelsCovered) / Double(sourceWidth * sourceHeight)

print("")
print(String(
    format: "Coverage: %.1f%% of the sphere by solid angle (pre-fill), "
        + "%.1f%% of equirect pixels non-black (post-fill)",
    result.coverage * 100,
    pixelCoverage * 100
))
// This test renders a LEVEL virtual camera, so it measures projection correctness,
// not the shipping plan's coverage. Plan coverage is PlanSweep's job; the bar here is
// only that the frames land where the geometry says they should.
check(result.coverage > 0.70,
      String(format: "solid-angle coverage %.1f%% exceeds 70%%", result.coverage * 100))
// The whole point of the fill: whatever the sweep missed, the user must never be shown a
// black tear. Anything short of every pixel means a gap the pyramid could not reach.
check(pixelCoverage > 0.9999,
      String(format: "%.2f%% of output pixels are non-black after hole filling",
             pixelCoverage * 100))
check(worstError < 6.0, String(format: "worst channel MAE %.2f is below 6.0", worstError))

// MARK: - Write artefacts for eyeballing

let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sweepspike-harness", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, named name: String) {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) { print("  wrote \(url.path)") }
}

print("\nArtefacts")
writePNG(result.image, named: "stitched.png")
if let provider = CGDataProvider(data: Data(source) as CFData),
   let sourceImage = CGImage(
       width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bitsPerPixel: 32,
       bytesPerRow: sourceWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
   ) {
    writePNG(sourceImage, named: "source.png")
}

print("\nCapture plan coverage (analytic, real iPhone frustum)")
PlanSweep.report()
for failure in PlanSweep.planFailures {
    print("  FAIL  \(failure)")
    failures.append(failure)
}

print("")
if failures.isEmpty {
    print("ALL CHECKS PASSED")
    exit(0)
} else {
    print("FAILED: \(failures.count)")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
