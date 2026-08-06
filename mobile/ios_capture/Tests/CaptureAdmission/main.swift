import Foundation
import simd

// Pins the two rules that decide what the user experiences during a sweep: when the drift
// banner is allowed to appear, and which frames are worth spending the frame budget on.
//
// Both were device-only behaviours until now, and both shipped broken because of it. The
// fourth device run showed the drift banner permanently and finished at "90 frames, 87.1%
// of the sphere captured" — budget exhausted with an eighth of the room unseen. Neither
// failure needs a camera to reproduce: one is a threshold machine over a stream of floats,
// the other is solid-angle bookkeeping. Both are tested here instead.
//
// Build and run (macOS, no Xcode, no device):
//   swiftc -O Sources/SweepGeometry.swift Tests/CaptureAdmission/main.swift -o /tmp/admission
//   /tmp/admission

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS  \(message)")
    } else {
        print("FAIL  \(message)")
        failures += 1
    }
}

func check(
    _ value: Float,
    near expected: Float,
    tolerance: Float,
    _ message: String
) {
    let ok = abs(value - expected) <= tolerance
    check(ok, "\(message) (got \(String(format: "%.4f", value)), "
        + "expected \(String(format: "%.4f", expected)) +- \(tolerance))")
}

// MARK: - Drift monitor

print("\n--- Drift warning ---")

/// Frame interval used throughout: ARKit delivers to a busy delegate at roughly 30 Hz.
let dt: Float = 1.0 / 30

/// Places the camera `drift` metres from where the sweep began, along +X. The monitor is fed
/// POSITIONS rather than distances, because its reference creeps — see `DriftMonitor`.
func at(_ drift: Float) -> SIMD3<Float> { SIMD3(drift, 0, 0) }

/// A monitor anchored at the sweep origin, as it always is in the app: the first tracked
/// frame of a sweep establishes the reference. Tests must start here — handing a fresh
/// monitor a displaced position anchors it THERE and it correctly reports no drift at all.
func anchored() -> DriftMonitor {
    var monitor = DriftMonitor()
    _ = monitor.update(position: at(0), dt: dt)
    return monitor
}

/// Feeds a constant position for `count` frames.
func run(_ monitor: inout DriftMonitor, drift: Float, frames: Int) {
    for _ in 0 ..< frames { _ = monitor.update(position: at(drift), dt: dt) }
}

// REVERSED DELIBERATELY (2026-08-06). These two checks used to assert that a 20-40 cm
// body-pivot arc never warns, and they were RIGHT about the ergonomics and WRONG about the
// physics. Misregistration is atan(offset / distance): a 28 cm arc puts an object half a metre
// away 29 degrees out of place, which is 330 px at 4096 wide, and no blend repairs that. The old
// assertions were pinning the app's largest defect in place.
//
// The resolution is not to tolerate the arc but to stop making it — hold the phone still and
// rotate the body around it, which is what Matterport ("as if it was on a monopod or
// broomstick") and Google Street View ("close to your body") both instruct. See
// `SweepAdvice.pivot`. So a sustained 28 cm arc must now WARN, and the small residual wobble of
// someone doing it correctly must not.
do {
    // A CONSTANT offset is still absorbed, and must be: the reference creeps precisely so that
    // VIO drift, which also looks like a constant offset, cannot raise a false alarm. That
    // defence is from run 7 and is not being touched. Recorded here so nobody mistakes it for
    // the threshold failing.
    var monitor = anchored()
    run(&monitor, drift: 0.28, frames: 600)
    check(!monitor.isWarning,
          "a CONSTANT 28 cm is still absorbed by the creeping reference — that is the VIO defence, not the threshold")
}

do {
    // A wide slow arc — 5 to 45 cm — now warns, where the old 0.30 m threshold let it through.
    var monitor = anchored()
    for step in 0 ..< 400 {
        let arc = 0.25 + 0.20 * sin(Float(step) * 0.05)
        _ = monitor.update(position: at(arc), dt: dt)
    }
    check(monitor.isWarning, "a wide 5-45 cm arm-length arc NOW warns")
}

do {
    // HONEST LIMIT, so nobody reads more into the banner than it can deliver. A FAST swing is
    // invisible to it whatever the threshold: `driftSustainedFrames` needs 15 consecutive frames
    // above the limit, and an oscillation spends only part of its cycle there. This 11-29 cm arc
    // reaches a measured 0.286 m — well past the 0.12 m limit — and still never warns.
    //
    // That is not a bug to fix by lowering the limit; a banner that fires on every wobble is the
    // run-4 defect. Parallax from motion the banner cannot see is handled where it belongs:
    // `driftHalfWeightMeters` prices those frames down in the blend, and the depth correction in
    // `PanoramaStitcher` removes the geometric error outright (Tests/ParallaxTruth). The banner
    // is advisory; the physics is handled elsewhere.
    var monitor = anchored()
    var peak: Float = 0
    for step in 0 ..< 400 {
        let arc = 0.20 + 0.09 * sin(Float(step) * 0.30)
        _ = monitor.update(position: at(arc), dt: dt)
        peak = max(peak, monitor.referenceDistance)
    }
    check(!monitor.isWarning && peak > CaptureQuality.driftWarningMeters,
          String(format: "a FAST 11-29 cm arc peaks at %.3f m yet never warns — the sustained-frames gate, documented not fixed", peak))
}

do {
    // And the motion the app now asks for must stay silent, or the warning is noise again.
    var monitor = anchored()
    for step in 0 ..< 400 {
        let wobble = 0.03 + 0.02 * sin(Float(step) * 0.05)  // 1..5 cm
        _ = monitor.update(position: at(wobble), dt: dt)
    }
    check(!monitor.isWarning, "a 1-5 cm wobble — a correct pivot about the phone — stays silent")
}

do {
    var monitor = anchored()
    run(&monitor, drift: 0.45, frames: CaptureQuality.driftSustainedFrames - 1)
    check(!monitor.isWarning, "45 cm for one frame less than the limit does not warn yet")
    check(monitor.update(position: at(0.45), dt: dt) == true,
          "the next frame flips it on, and reports the change")
    check(monitor.update(position: at(0.45), dt: dt) == nil,
          "a steady warning reports no further change")
}

do {
    var monitor = anchored()
    run(&monitor, drift: 0.50, frames: 60)
    check(monitor.isWarning, "walking half a metre away does warn")
    // Back to a displacement still INSIDE the hysteresis band. Note this is measured from
    // the creeping reference, not from the sweep origin, so the band sits at a different
    // absolute position than it used to — the guarantee is about the measured distance.
    // Steered to a MEASURED distance inside the band, not a camera position: the reference
    // creeps, so a fixed position no longer means a fixed distance.
    var camera: Float = 0.50
    let band = (CaptureQuality.driftClearMeters + CaptureQuality.driftWarningMeters) / 2
    for _ in 0 ..< 3 {
        camera += band - monitor.referenceDistance
        _ = monitor.update(position: at(camera), dt: dt)
    }
    check(monitor.referenceDistance > CaptureQuality.driftClearMeters
              && monitor.referenceDistance < CaptureQuality.driftWarningMeters,
          String(format: "test really is in the band (%.3f m)", monitor.referenceDistance))
    check(monitor.isWarning, "coming back into the band HOLDS the warning")
    camera -= 0.10
    check(monitor.update(position: at(camera), dt: dt) == false,
          "returning under the clear limit takes it down")
    check(!monitor.isWarning, "and it stays down")
}

do {
    // Strobing is its own defect: the banner appearing and vanishing every few frames is
    // what a single threshold produces when the user hovers on it. Driven by a small
    // controller that steers the MEASURED distance across the warn limit, because with a
    // creeping reference a fixed camera position no longer means a fixed distance.
    var monitor = anchored()
    run(&monitor, drift: 0.50, frames: 60)
    var camera: Float = 0.50
    var flips = 0
    var wentAbove = false, wentBelow = false
    for step in 0 ..< 300 {
        let target = CaptureQuality.driftWarningMeters + 0.02 * sin(Float(step) * 0.7)
        camera += target - monitor.referenceDistance
        if monitor.update(position: at(camera), dt: dt) != nil { flips += 1 }
        if monitor.referenceDistance > CaptureQuality.driftWarningMeters { wentAbove = true }
        if monitor.referenceDistance < CaptureQuality.driftWarningMeters { wentBelow = true }
    }
    check(wentAbove && wentBelow, "the hover really did straddle the warn limit both ways")
    check(flips == 0, "hovering on the warn limit for 300 frames produces no flicker")
}

do {
    var monitor = anchored()
    run(&monitor, drift: 0.90, frames: 60)
    check(monitor.isWarning, "warning is on before tracking drops")
    monitor.reset()
    check(!monitor.isWarning, "a tracking loss clears it — the origin may have moved")
}

// The run-7 failure. A rotate-in-place sweep is the pathological motion for visual
// odometry — pure rotation gives no translation baseline — so ARKit's reported position
// creeps away from truth over a long sweep. With a reference frozen at the first frame,
// that creep alone eventually exceeds any threshold and the app blames the user for the
// tracker's bookkeeping. Raising the threshold does not fix an unbounded ramp.
do {
    var monitor = anchored()
    // Three minutes of sweeping while VIO drifts a full metre. The user has not moved.
    let seconds: Float = 180
    let frames = Int(seconds * 30)
    for step in 0 ..< frames {
        let vioDrift = Float(step) / Float(frames) * 1.0
        _ = monitor.update(position: at(vioDrift), dt: dt)
    }
    check(!monitor.isWarning,
          "a metre of VIO drift over a 3-minute sweep never warns — the user did not move")
    check(monitor.referenceDistance < CaptureQuality.driftWarningMeters,
          String(format: "the reference tracked it to within %.3f m",
                 monitor.referenceDistance))
}

do {
    // ...and the same absorption must NOT swallow a real step. VIO drift is slow and
    // gradual; a person moving is fast. That rate difference is the whole basis of the fix,
    // so it has to be shown that the two are still told apart.
    var monitor = anchored()
    // A minute of ordinary sweeping with VIO drifting 30 cm underneath.
    for step in 0 ..< 1800 {
        _ = monitor.update(position: at(Float(step) / 1800 * 0.30), dt: dt)
    }
    check(!monitor.isWarning, "30 cm of accumulated VIO drift is silent")
    // Then the user takes a step: 60 cm in half a second, on top of that drift.
    for step in 0 ..< 15 {
        _ = monitor.update(position: at(0.30 + Float(step) / 15 * 0.60), dt: dt)
    }
    run(&monitor, drift: 0.90, frames: 20)
    check(monitor.isWarning, "but an actual step taken on top of it still warns")
}

// MARK: - Novelty

print("\n--- Frame budget novelty ---")

/// The real portrait frustum: `capturedImage` is landscape, so the wide axis is vertical.
let halfFOVx: Float = 46.8 / 2 * .pi / 180
let halfFOVy: Float = 60.0 / 2 * .pi / 180

/// Camera rotation looking along `direction`, gravity-up, in the app's convention.
/// ARKit columns are (right, up, backward), so the third column is -forward.
func look(yaw: Float, pitch: Float) -> simd_float3x3 {
    let forward = SweepFrame.direction(yaw: yaw, pitch: pitch)
    let worldUp = SIMD3<Float>(0, 1, 0)
    var right = simd_cross(forward, worldUp)
    // Straight up or down leaves the cross product degenerate; any perpendicular will do.
    right = simd_length(right) < 1e-4
        ? SIMD3<Float>(1, 0, 0)
        : simd_normalize(right)
    let up = simd_cross(right, forward)
    return simd_float3x3(right, up, -forward)
}

func novelty(_ map: CoverageMap, yaw: Float, pitch: Float, depth: UInt16 = 1) -> Float {
    map.novelty(
        rotation: look(yaw: yaw, pitch: pitch),
        halfFOVx: halfFOVx,
        halfFOVy: halfFOVy,
        depth: depth
    )
}

func add(_ map: CoverageMap, yaw: Float, pitch: Float) {
    map.add(rotation: look(yaw: yaw, pitch: pitch), halfFOVx: halfFOVx, halfFOVy: halfFOVy)
}

do {
    let map = CoverageMap()
    // Analytic solid angle of a rectangular frustum: 4 asin(sin hx sin hy) / 4pi = 6.36%.
    // The map answers 6.9%, and the 0.6 point gap is the 5x5 degree grid rather than an
    // error: a cell counts as inside the frustum whenever its CENTRE is, so the boundary
    // ring rounds outward. It biases every novelty answer the same way, which is why the
    // admission threshold is calibrated against this measure and not against the integral.
    let expected = 4 * asin(sin(halfFOVx) * sin(halfFOVy)) / (4 * .pi)
    check(novelty(map, yaw: 0, pitch: 0), near: expected, tolerance: 0.008,
          "an empty map values one frustum at its solid angle, up to grid quantisation")
}

do {
    let map = CoverageMap()
    add(map, yaw: 0, pitch: 0)
    check(novelty(map, yaw: 0, pitch: 0) == 0,
          "the identical view a second time is worth nothing")
    check(novelty(map, yaw: 0, pitch: 0, depth: 2) > 0.05,
          "...but at depth 2 it is worth a full frustum again, because overlap is the "
              + "thing being bought")
}

do {
    // The gate must not be confused with a wider separation angle. A 10-degree step off a
    // LONE frame really does uncover a 10-degree sliver of new wall, and refusing it would
    // punish a user closing a gap carefully. What has to be refused is the same 10-degree
    // step taken inside a neighbourhood that is already covered — that is the frame the
    // shipped build kept buying, and it is the next case below.
    let map = CoverageMap()
    add(map, yaw: 0, pitch: 0)
    let tenDegrees = novelty(map, yaw: 10 * .pi / 180, pitch: 0)
    let thirtyDegrees = novelty(map, yaw: 30 * .pi / 180, pitch: 0)
    check(tenDegrees >= CaptureQuality.minNoveltyFraction,
          "a 10-degree step off a lone frame uncovers a real sliver and is admitted")
    check(thirtyDegrees > 2 * tenDegrees,
          "a 30-degree step is worth several times more, so the gate ranks them correctly")
}

do {
    // The frame the 87.1% run kept spending its budget on: a direction 10 degrees from
    // everything nearby, in a patch three frames have already seen from both sides. It
    // passes the separation test and reveals nothing.
    let map = CoverageMap()
    for step in -1 ... 1 { add(map, yaw: Float(step) * 20 * .pi / 180, pitch: 0) }
    check(novelty(map, yaw: 10 * .pi / 180, pitch: 0) < CaptureQuality.minNoveltyFraction,
          "a 10-degree nudge inside already-covered ground is refused")
}

do {
    // The floor and the ceiling are the directions a natural sweep never points at, and
    // they are what the 87.1% run left behind. They must stay expensive to skip.
    let map = CoverageMap()
    for step in 0 ..< 12 { add(map, yaw: Float(step) * .pi / 6, pitch: 0) }
    check(map.coverage < 0.6, "a horizon-only sweep is nowhere near done")
    check(novelty(map, yaw: 0, pitch: -70 * .pi / 180) >= CaptureQuality.minNoveltyFraction,
          "the floor is still admissible after a full horizon ring")
    check(novelty(map, yaw: 0, pitch: 70 * .pi / 180) >= CaptureQuality.minNoveltyFraction,
          "so is the ceiling")
    check(novelty(map, yaw: .pi / 12, pitch: 0) < CaptureQuality.minNoveltyFraction,
          "another horizon frame between two existing ones is not")
}

do {
    // The end-to-end claim: with the gate in force, the 90-frame budget closes the sphere.
    // Simulates the worst realistic user — sweeping in small steps, revisiting the horizon,
    // and only reluctantly looking up and down — against the exact admission rule in
    // `Capture.swift`.
    let map = CoverageMap()
    var stored = 0
    var forwards: [SIMD3<Float>] = []
    let gateAt = Int(Float(CaptureQuality.maxStoredFrames) * CaptureQuality.noveltyGateFraction)

    // Three passes of the horizon before any pitch at all, in 8-degree steps.
    var candidates: [(Float, Float)] = []
    for pass in 0 ..< 3 {
        for step in 0 ..< 45 {
            candidates.append((Float(step) * 8 * .pi / 180, Float(pass) * 0.01))
        }
    }
    // Then, finally, the rings the user was avoiding.
    for pitch in [Float(33), -33, 70, -70] {
        for step in 0 ..< 24 {
            candidates.append((Float(step) * 15 * .pi / 180, pitch * .pi / 180))
        }
    }

    for (yaw, pitch) in candidates {
        guard stored < CaptureQuality.maxStoredFrames else { break }
        let forward = SweepFrame.direction(yaw: yaw, pitch: pitch)
        // Separation test, as in SweepState.isFarFromStoredFrames.
        guard !forwards.contains(where: {
            simd_dot($0, forward) > cos(CaptureQuality.minSeparationRadians)
        }) else { continue }
        if stored >= gateAt {
            let depth: UInt16 = map.coverage >= CaptureQuality.goodCoverage ? 2 : 1
            guard novelty(map, yaw: yaw, pitch: pitch, depth: depth)
                >= CaptureQuality.minNoveltyFraction else { continue }
        }
        add(map, yaw: yaw, pitch: pitch)
        forwards.append(forward)
        stored += 1
    }

    print(String(format: "      simulated sweep: %d frames, %.1f%% coverage, %.1f%% overlap",
                 stored, map.coverage * 100, map.overlap * 100))
    check(map.coverage > 0.99,
          "a horizon-heavy sweep still closes the sphere inside the frame budget")
    check(map.overlap > 0.9, "and keeps enough double coverage for the seams to blend")
}

// MARK: - Refused frames and the markers the user is staring at

// The twelfth device run stalled with a white marker on the window blinds that could not be
// cleared: "Hold here", 97% covered, 76 photos, forever. `Capture.swift` only ever marked a
// target after the novelty gate, so the very condition that finishes a direction — the gate
// refusing a frame because that ground is already held — was also the condition that stopped
// the target from ever being marked.
//
// The fix marks covered targets before the storage gates. It is only honest if this holds:
// a frame the gate refuses is aimed at ground the STORED map already covers. If that were
// false, the fix would be marking targets the stitch never captured. `SweepState` needs
// ARKit and cannot be built here, so this pins the invariant it rests on instead.
print("\n--- What a refused frame means ---")
do {
    let map = CoverageMap()
    // A closed horizon ring, so the equator is thoroughly held and nothing else is.
    for step in 0 ..< 24 {
        add(map, yaw: Float(step) * 2 * .pi / 24, pitch: 0)
    }

    var refused = 0, refusedAndCovered = 0, admitted = 0
    for step in 0 ..< 72 {
        let yaw = Float(step) * 2 * .pi / 72
        for pitch in [Float(0), 0.05, -0.05] {
            let forward = SweepFrame.direction(yaw: yaw, pitch: pitch)
            let depth: UInt16 = map.coverage >= CaptureQuality.goodCoverage ? 2 : 1
            if novelty(map, yaw: yaw, pitch: pitch, depth: depth)
                < CaptureQuality.minNoveltyFraction {
                refused += 1
                if map.isCovered(forward) { refusedAndCovered += 1 }
            } else {
                admitted += 1
            }
        }
    }

    print("      \(refused) directions refused, \(admitted) admitted")
    print("      of the refused, \(refusedAndCovered) are already covered by the stored map")
    // Both halves matter. Without the second the scene could be trivial — nothing refused,
    // and the invariant vacuously true.
    check(refused > 0, "a well-covered ring really does refuse frames aimed into it")
    check(refused == refusedAndCovered,
          "every refused direction is one the stored map ALREADY covers, so marking its "
          + "target claims nothing the stitch does not have")
}

// MARK: - Result

print("")
if failures == 0 {
    print("ALL CHECKS PASSED")
} else {
    print("\(failures) CHECK(S) FAILED")
    exit(1)
}
