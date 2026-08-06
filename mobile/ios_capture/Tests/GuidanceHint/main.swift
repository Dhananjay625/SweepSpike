// The guidance hint must never send the user the WRONG way.
//
// An inverted left/right or up/down is invisible in review and actively harmful on device:
// the user follows it, coverage gets worse, and the app looks broken. These cases pin the
// sign of every axis against the app's yaw/pitch conventions.
import Foundation
import simd

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "  PASS  \(label)" : "  FAIL  \(label)")
    if !condition { failures += 1 }
}

/// One uncaptured target at the given sweep-local yaw/pitch, nothing else outstanding.
func hint(lookingAtYaw yaw: Float, pitch: Float = 0,
          targetYaw: Float, targetPitch: Float = 0,
          originYaw: Float = 0) -> String? {
    let targets = [CaptureTarget(yaw: targetYaw, pitch: targetPitch)]
    // The camera's world forward for a sweep-local aim.
    let world = SweepFrame.toWorld(SweepFrame.direction(yaw: yaw, pitch: pitch),
                                   originYaw: originYaw)
    return SweepGuidance.hint(forward: world, originYaw: originYaw, targets: targets)
}

let right: Float = 60 * .pi / 180
let up: Float = 50 * .pi / 180
let down: Float = -50 * .pi / 180

print("Guidance hint — direction signs")
check(hint(lookingAtYaw: 0, targetYaw: right) == "Turn right",
      "target clockwise of aim says turn RIGHT")
check(hint(lookingAtYaw: 0, targetYaw: -right) == "Turn left",
      "target anticlockwise of aim says turn LEFT")
check(hint(lookingAtYaw: 0, targetYaw: 0, targetPitch: up) == "Look up",
      "target above aim says look UP")
check(hint(lookingAtYaw: 0, targetYaw: 0, targetPitch: down) == "Look down",
      "target below aim says look DOWN")
check(hint(lookingAtYaw: 0, targetYaw: right, targetPitch: down) == "Turn right and look down",
      "both axes combine")
check(hint(lookingAtYaw: 0, targetYaw: .pi) == "Turn around",
      "target directly behind says turn AROUND")

print("\nGuidance hint — wrap and frame independence")
// Aiming just short of +pi, target just past -pi: 45 deg apart ACROSS the seam. The raw
// difference is -5.5 rad, which unwrapped would say "turn left" and send the user 315 deg
// the wrong way round the room.
check(hint(lookingAtYaw: 3.0, targetYaw: -2.5) == "Turn right",
      "shortest way across the +-180 seam is chosen, not the long way")
// The whole sweep frame rotated must not change the instruction.
check(hint(lookingAtYaw: 0, targetYaw: right, originYaw: 2.4) ==
      hint(lookingAtYaw: 0, targetYaw: right, originYaw: 0),
      "instruction is independent of the sweep's origin heading")

print("\nGuidance hint — quiet cases")
check(hint(lookingAtYaw: 0, targetYaw: 0) == "Hold here",
      "target already centred says hold, not a direction")
check(hint(lookingAtYaw: 0, targetYaw: 10 * .pi / 180) == "Hold here",
      "inside the deadzone stays quiet instead of flickering")
check(SweepGuidance.hint(forward: SIMD3(0, 0, -1), originYaw: 0, targets: []) == nil,
      "no targets at all yields no hint")
var done = CaptureTarget(yaw: right, pitch: 0)
done.isCaptured = true
check(SweepGuidance.hint(forward: SIMD3(0, 0, -1), originYaw: 0, targets: [done]) == nil,
      "already-captured targets are ignored")

print("\nGuidance hint — the real plan, from a level start")
let plan = CaptureTarget.makePlan()
let level = SweepGuidance.hint(forward: SIMD3(0, 0, -1), originYaw: 0, targets: plan)
print("  level aim, nothing captured yet -> \(level ?? "nil")")
check(level != nil, "the shipping plan produces a hint")

// The floor cap is the direction three device runs kept missing. Standing level and
// looking at the horizon, the app must be able to send the user DOWN to it.
let floorOnly = plan.filter { $0.pitch < -1 }
check(!floorOnly.isEmpty, "the plan contains a floor ring to be sent to")
let floorHint = SweepGuidance.hint(forward: SIMD3(0, 0, -1), originYaw: 0, targets: floorOnly)
print("  only the floor ring outstanding -> \(floorHint ?? "nil")")
check(floorHint?.contains("look down") == true || floorHint == "Look down",
      "with only the floor ring left, the user is told to look DOWN")

if failures > 0 { print("\nFAILED: \(failures)"); exit(1) }
print("\nALL CHECKS PASSED")
