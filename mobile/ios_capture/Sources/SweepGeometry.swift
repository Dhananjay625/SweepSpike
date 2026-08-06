import Foundation
import simd

// This file deliberately imports nothing beyond Foundation and simd, so the geometry
// that the panorama depends on can be compiled and tested on macOS without ARKit.
// See Tests/StitchHarness.

// MARK: - Configuration

/// One horizontal ring of capture targets.
///
/// Yaw steps are per-ring rather than global because a ring near a pole needs far
/// fewer frames: the same angular frustum spans a much larger slice of longitude
/// there. A uniform count would spend a dozen frames on a cap two frames can cover.
struct CaptureRing: Equatable {
    let pitch: Float
    let yawSteps: Int
}

enum CaptureConfig {
    /// The app is portrait-locked, so the phone is always rolled 90 degrees relative
    /// to `capturedImage`, which is always a landscape-right buffer. The consequence
    /// is that the image's LONG axis runs vertically in the world: the wide field of
    /// view buys vertical coverage, and yaw spacing must fit the NARROW axis.
    static let deviceRollRadians: Float = .pi / 2

    /// Capture plan. Chosen by the coverage search in Tests/StitchHarness against the
    /// real portrait frustum (~46.8 degrees horizontal, ~60 degrees vertical); see
    /// `PlanSweep.report()`. Horizon ring first so the user starts with the easy one.
    /// 44 targets, balanced against two gates that pull in opposite directions:
    ///   - COVERAGE under realistic aiming error wants the mid ring HIGHER, to close the
    ///     gap against the cap ring (Tests/PanoramaDemo).
    ///   - OVERLAP wants it LOWER, so adjacent rings share enough of the wall band for
    ///     the feathered blend to cross-fade (Tests/StitchHarness).
    /// 33 degrees is the value that satisfies both: 100% coverage under +-8 degree aim
    /// error, 90.5% wall overlap. The margin on overlap is thin — if seams appear on real
    /// hardware, lower the mid ring toward 30 (94.3% overlap) and add yaw steps to the cap
    /// rings to keep coverage, rather than widening the rings further.
    static let rings: [CaptureRing] = [
        CaptureRing(pitch: 0, yawSteps: 12),
        CaptureRing(pitch: .pi * 11 / 60, yawSteps: 12),   // 33 degrees
        CaptureRing(pitch: -.pi * 11 / 60, yawSteps: 12),
        CaptureRing(pitch: .pi * 7 / 18, yawSteps: 4),
        CaptureRing(pitch: -.pi * 7 / 18, yawSteps: 4),
    ]
    // Caps sit at 70 degrees, not 80. Analytically the two are identical (both 100%/94.3%),
    // but 80 leaves a hole at +-50..60 once the +-8 degree aim tolerance is simulated: the
    // mid ring mis-aimed low stops reaching up while the cap mis-aimed low stops reaching
    // down, and the two shortfalls meet. At 70 the cap still clears the zenith even when
    // mis-aimed (70 - 8 + 30 = 92 degrees) and overlaps the mid ring with room to spare.
    // See Tests/PanoramaDemo, which simulates aiming error; the analytic search does not.

    /// Angular distance at which a target counts as aimed at (~8 degrees).
    static let aimThresholdRadians: Float = 0.14
    /// Consecutive in-threshold frames required before firing. Rejects motion blur.
    static let steadyFramesRequired = 5
    /// Frames are downscaled before storage; at full resolution 44 RGBA frames would
    /// be roughly half a gigabyte and the app would be jetsammed mid-sweep.
    ///
    /// Sized from the 4096x2048 output rather than guessed. A frame spans 60 degrees
    /// along image-x and 46.8 along image-y, so to match output resolution it needs
    /// 60/180 * 2048 = 683 px on the long axis and 46.8/360 * 4096 = 532 on the short.
    ///
    /// 800 (giving 800x600) was the first choice and it is CRITICALLY sampled: 13.3 px
    /// per degree against the output's 11.4, only 1.17x of headroom. Every stage between
    /// the sensor and the panorama then spends some of that — the Core Graphics downscale
    /// here, and the bilinear fetch in the stitcher — so detail arrives already soft.
    /// 1024 (1024x768) gives 1.5x and leaves room for both resamplings.
    static let storedFrameMaxDimension = 1024
    /// Distance from the sweep origin at which target markers are drawn.
    static let markerDistanceMeters: Float = 2.0
}

// MARK: - Sweep-local coordinate frame

/// Yaw convention for this app: yaw 0 points along world -Z (ARKit forward) and
/// increasing yaw turns toward +X. Targets live in a *sweep-local* frame whose
/// yaw 0 is the heading the camera had when the sweep started, so the user never
/// has to find a fixed compass direction.
enum SweepFrame {
    /// Yaw of a world-space forward vector, in the app convention.
    static func yaw(of forward: SIMD3<Float>) -> Float {
        atan2(forward.x, -forward.z)
    }

    /// Unit direction for a yaw/pitch pair, in whichever frame the angles are expressed.
    static func direction(yaw: Float, pitch: Float) -> SIMD3<Float> {
        SIMD3(cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
    }

    /// Rotate a sweep-local direction into world space.
    static func toWorld(_ local: SIMD3<Float>, originYaw: Float) -> SIMD3<Float> {
        let c = cos(originYaw)
        let s = sin(originYaw)
        return SIMD3(local.x * c - local.z * s, local.y, local.x * s + local.z * c)
    }

    /// Rotate a world-space direction into the sweep-local frame.
    static func toLocal(_ world: SIMD3<Float>, originYaw: Float) -> SIMD3<Float> {
        let c = cos(originYaw)
        let s = sin(originYaw)
        return SIMD3(world.x * c + world.z * s, world.y, -world.x * s + world.z * c)
    }
}

// MARK: - Opportunistic capture

/// Capture is NOT limited to the ring plan. The rings are guidance — they show the user
/// where to point — but the app stores every frame that adds new information, so a user
/// who keeps sweeping gets a denser, better-blended panorama than the plan alone would.
enum CaptureQuality {
    /// A new frame must point at least this far from every frame already stored.
    /// Without it, standing still would fill memory with near-identical frames. At 10
    /// degrees a sphere holds roughly 4/(0.175^2) ~= 130 distinct viewpoints, which is
    /// about 3x the ring plan and gives the blender far more to work with.
    static let minSeparationRadians: Float = 10 * .pi / 180

    /// Hard ceiling, set by memory rather than by the plan. Each stored frame is
    /// 1024 x 768 x 4 bytes = 3.15 MB, so 90 frames is ~283 MB — near the limit of what
    /// an ARKit app can hold without being jetsammed. Lowered from 150 in step with the
    /// frame size going 800 -> 1024, to hold the same memory ceiling. If it ever needs to
    /// rise, spend the budget on RESOLUTION rather than count — past roughly five frames
    /// per direction, extra views are discarded by `dominanceThreshold` anyway.
    ///
    /// This IS now the binding constraint: the fourth device run ended "90 frames, 87.1%
    /// of the sphere captured", i.e. the budget ran out with an eighth of the room unseen.
    /// The fix is not a bigger ceiling — 90 frustums are 5.7x the sphere's solid angle,
    /// far more than enough — it is spending them on directions nothing has seen yet.
    /// See `noveltyGateFraction`.
    static let maxStoredFrames = 90

    /// Fraction of the frame budget that may be spent on ANY sufficiently-new direction.
    /// Past it, admission becomes coverage-driven: see `minNoveltyFraction`.
    ///
    /// The first half is deliberately ungated, because early frames cannot be judged on
    /// novelty — almost everything is novel, and gating them would starve the blend of the
    /// overlapping views it needs for seams. The second half is where the 87.1% run went
    /// wrong: a 10-degree separation is enough to admit a frame whose 47x60 degree frustum
    /// lands almost entirely on ground already seen, so the tail of the budget bought
    /// re-runs of the same wall while the floor and the ceiling stayed empty.
    static let noveltyGateFraction: Float = 0.5

    /// Once gated, the share of the WHOLE SPHERE a frame must newly reveal to be stored.
    ///
    /// One frame's frustum measures about 6.9% of the sphere on the coverage grid, so 0.5%
    /// is a fourteenth of a frame's worth of genuinely new ground: a frame is refused once
    /// it overlaps what is already captured by more than ~93%. That is deliberately NOT
    /// the same as widening `minSeparationRadians` — a 10 degree step off a lone frame
    /// uncovers a real sliver and is kept, while the same step inside a patch already seen
    /// from both sides is refused. With 45 gated frames left it is a floor of +22%
    /// coverage over what an ungated tail buys. Verified end to end in
    /// `Tests/CaptureAdmission`, which replays a horizon-heavy sweep through this exact
    /// rule: 76 frames to 99.8% of the sphere, against the device run's 90 to 87.1%.
    static let minNoveltyFraction: Float = 0.005

    /// Below this the user is told the sweep is incomplete.
    static let goodCoverage: Float = 0.99

    /// Per-frame angular step above which the phone is being whipped around and the
    /// frame will be motion-blurred. 0.6 deg at 60 Hz is ~36 deg/s, which permits a
    /// normal continuous sweep while rejecting fast jerks. This replaces the old
    /// "hold still on a target" gate, which would rarely fire during a smooth turn.
    /// Measured on device: at 0.6 deg/frame a normal sweep yielded only 33 frames of a
    /// possible ~130, because ARKit delivers frames slower than 60 Hz while conversion is
    /// running, making the per-frame step much larger than the ideal maths predicts.
    /// 2.5 deg/frame keeps genuinely blurred frames out while accepting a real sweep.
    static let maxAngularStepRadians: Float = 2.5 * .pi / 180

    /// Consecutive smooth frames required before storing.
    static let smoothFramesRequired = 2

    /// Drift past which the user is WARNED, and past which a frame starts losing weight in
    /// the blend. Not a rejection threshold — see `driftHardLimitMeters`.
    ///
    /// A panorama assumes every ray leaves one point. Users naturally rotate their BODY,
    /// swinging the phone on a ~30 cm arc, which moves the viewpoint a lot relative to
    /// nearby objects — so close things land in different places in each frame, while
    /// distant walls look fine.
    ///
    /// This was briefly a HARD reject at 12 cm and that was a bad trade, measured across
    /// three device runs: without it a sweep reached ~98% of the sphere; with it the next
    /// two reached 54.6% and 58.6%. It roughly halved coverage, because pivoting far
    /// enough to see behind yourself moves a hand-held phone well past 12 cm no matter how
    /// carefully you do it. Half a room stitched sharply is worse than a whole room with
    /// some soft patches — and the user reported exactly that ("couldn't get the full
    /// room"). A drifted frame is also still far better than the alternative for a
    /// direction nothing else saw, which is an interpolated hole.
    ///
    /// So drift is now priced rather than banned: `PanoramaStitcher` down-weights a frame
    /// by how far it drifted, and `dominanceThreshold` then excludes it outright wherever
    /// a better-placed frame exists. Drifted frames win only where they are all there is.
    ///
    /// 30 cm, not the 12 cm this used to be. 12 cm is below what a standing human can hold
    /// while turning through 360 degrees: the phone is held at arm's length, so pivoting
    /// the BODY — which is how anyone turns all the way round — swings the camera on a
    /// 20-40 cm arc before any actual stepping happens. The fourth device run showed the
    /// warning essentially permanently, which is the worst outcome for a warning: it stops
    /// carrying information and the user learns to ignore it. 30 cm is past the arc and
    /// into genuinely walking away from the sweep point.
    ///
    /// This threshold is ADVISORY ONLY. It does not gate storage, and it is deliberately
    /// decoupled from the stitcher's own `driftHalfWeightMeters` (0.12), which still starts
    /// pricing frames from the first centimetre — the blend should keep caring about small
    /// drift even when it is not worth interrupting the user about.
    /// TIGHTENED 0.30 -> 0.12 (2026-08-06), after research into why runs 1-13 all ghosted.
    ///
    /// 0.30 m was chosen in run 5 so that "a 20-40 cm body-pivot arc never warns" — the arc you
    /// get by turning on the spot with the phone at arm's length. That reasoning accepted the
    /// single largest source of the app's own artifacts. Misregistration is atan(offset /
    /// distance): at 0.30 m and an object half a metre away that is 31 degrees, which is 353 px
    /// at 4096 wide. No blend, seam or veto repairs an error that size, which is the whole
    /// story of thirteen device runs.
    ///
    /// The answer is not to tolerate the arc, it is to stop making it. Both commercial
    /// competitors instruct exactly that: Matterport tells users to "rotate your body around the
    /// device (as if it was on a monopod or broomstick)" because "this minimizes parallax
    /// errors" (support.matterport.com/hc/en-us/articles/1500004898402); Google's Street View
    /// app says "hold your device vertically and close to your body". Both keep the entrance
    /// pupil still and move the human around it. `SweepGuidance.pivotAdvice` now says the same.
    ///
    /// 0.12 m matches `driftHalfWeightMeters`, so the number the user is warned at and the
    /// number the stitcher prices by are finally the same quantity. Depth correction (see
    /// `CapturedFrame.depths`) recovers most of what remains at this scale — measured at 77% in
    /// `Tests/ParallaxTruth` — but it works best when there is less to recover.
    /// REVERTED TO RUN 6 (2026-08-06), was 0.12. The 0.30 -> 0.12 tightening was made for run
    /// 14 on research grounds, not on a device result; 0.30 is the value that was live for the
    /// sixth run. Advisory only either way — it gates no storage. Restore 0.12 to re-tighten.
    static let driftWarningMeters: Float = 0.30

    /// Drift below which the warning is taken back down. Separate from, and lower than,
    /// `driftWarningMeters` on purpose: a single threshold makes the banner strobe on and
    /// off while the user hovers around it, which reads as a broken app.
    static let driftClearMeters: Float = 0.08

    /// Consecutive frames above `driftWarningMeters` before the warning appears. ARKit
    /// delivers frames to a busy delegate at roughly 20-60 Hz, so 15 is a quarter to three
    /// quarters of a second: long enough that leaning to see round a chair is silent,
    /// short enough that walking away is called out while it still matters.
    static let driftSustainedFrames = 15

    /// How fast the warning's reference point is allowed to follow the camera, in metres
    /// per second. This is what makes the warning immune to VIO drift.
    ///
    /// The seventh device run showed the warning again, on a long sweep, after run 6 had
    /// been clean. Raising the threshold a second time would be the wrong move and would
    /// keep being the wrong move, because the cause is not the threshold: it is that the
    /// reference was FIXED at the first frame of the sweep and ARKit's world origin does not
    /// hold still for minutes. A rotate-in-place sweep is the pathological motion for visual
    /// odometry — pure rotation gives no translation baseline to triangulate against — so
    /// the reported position creeps away from truth the longer the sweep runs. Past a few
    /// minutes that creep alone exceeds any sane threshold, and the app blames the user for
    /// the tracker's bookkeeping.
    ///
    /// The two things are separable by their RATE, which is the whole idea here. VIO drift
    /// is slow, gradual and unbounded; a person stepping away is fast and over in a second.
    /// So the reference is allowed to follow the camera at 2 cm/s. Genuine drift is absorbed
    /// completely — over a three-minute sweep this soaks up 3.6 m of accumulated error —
    /// while someone walking half a metre in half a second outruns it by two orders of
    /// magnitude and still trips the warning.
    ///
    /// This affects ONLY the warning. `CapturedFrame.driftMeters`, which the stitcher prices
    /// frames by, and `driftHardLimitMeters`, which rejects frames from a relocated
    /// viewpoint, both stay anchored to the true sweep origin — those care about geometry,
    /// not about what the user should be told.
    static let driftReferenceCreepMetersPerSecond: Float = 0.02

    /// Drift past which a frame is genuinely discarded.
    ///
    /// Beyond roughly half a metre the viewpoint has moved so far that the frame is beyond
    /// what down-weighting can rescue: it is no longer a slightly-off view of the same
    /// vantage point but a different one, and it would drag geometry visibly if it ever
    /// won a pixel. This is also the guard against the user walking off mid-sweep.
    static let driftHardLimitMeters: Float = 0.6
}

// MARK: - Drift warning

/// Decides when the "you are drifting" banner is shown, from a stream of per-frame
/// distances between the camera and the sweep origin.
///
/// Split out of `Capture.swift` for two reasons. It is the piece a human actually
/// experiences — a warning that is on when it should be off is a product defect, not a
/// numerical one — and it is pure arithmetic, so it can be pinned by a host test rather
/// than by another trip to a physical room. See `Tests/CaptureAdmission`.
///
/// Three behaviours, each added because a device run showed the banner misbehaving:
///   - HYSTERESIS (run 4). Rising past `driftWarningMeters` warns; only falling back below
///     the lower `driftClearMeters` clears. Between them the state simply holds, so the
///     banner cannot strobe while the user hovers on the limit.
///   - PERSISTENCE (run 4). A momentary excursion is not a warning. The distance must stay
///     over the limit for `driftSustainedFrames` consecutive frames.
///   - A CREEPING REFERENCE (run 7). The distance is measured against a point that follows
///     the camera at `driftReferenceCreepMetersPerSecond`, not against the frozen sweep
///     origin, so slow VIO drift is absorbed and only real movement is reported. See that
///     constant for why this is a rate problem rather than a threshold problem.
struct DriftMonitor {
    private(set) var isWarning = false
    private var framesOverLimit = 0
    private var reference: SIMD3<Float>?

    /// Distance from the creeping reference as of the last update, in metres. Exposed for
    /// tests and diagnostics; it is NOT the number the stitcher prices frames by.
    private(set) var referenceDistance: Float = 0

    /// - Parameter position: the camera position this frame, in ARKit world coordinates.
    /// - Parameter dt: seconds since the previous tracked frame. Taken from
    ///   `ARFrame.timestamp` rather than assumed, because ARKit's delivery rate to a busy
    ///   delegate varies by a factor of three and a per-frame creep would then mean
    ///   different things at different moments.
    /// - Returns: the new warning state when it CHANGED, otherwise nil. The caller
    ///   publishes only on a change, so a steady hand costs no main-actor hops.
    mutating func update(position: SIMD3<Float>, dt: Float) -> Bool? {
        guard let current = reference else {
            reference = position
            referenceDistance = 0
            return nil
        }

        let offset = position - current
        let distance = simd_length(offset)
        referenceDistance = distance

        // Follow the camera, but only ever this far in this much time. Clamped rather than
        // proportional so the creep rate is an absolute guarantee: no matter how far away
        // the camera is, the reference cannot chase it faster than a slow drift.
        if distance > 0 {
            let step = min(distance, CaptureQuality.driftReferenceCreepMetersPerSecond
                * max(0, dt))
            reference = current + offset * (step / distance)
        }

        let wasWarning = isWarning
        if distance > CaptureQuality.driftWarningMeters {
            framesOverLimit += 1
            if framesOverLimit >= CaptureQuality.driftSustainedFrames { isWarning = true }
        } else if distance < CaptureQuality.driftClearMeters {
            framesOverLimit = 0
            isWarning = false
        }
        // Inside the band the counter is left alone: neither charging toward a warning nor
        // discharging out of one. Resetting it here would let a user who hovers on the
        // limit never trip it; clearing here would reintroduce the strobe.
        return isWarning == wasWarning ? nil : isWarning
    }

    /// Forgets everything, including the reference point. Called when tracking drops,
    /// because ARKit can shift the world origin on relocalisation and a distance measured
    /// across that jump is meaningless — carrying a warning over it would blame the user for
    /// the tracker's bookkeeping.
    mutating func reset() {
        isWarning = false
        framesOverLimit = 0
        reference = nil
        referenceDistance = 0
    }
}

/// Tracks which directions have been seen, and by how many frames, on a coarse
/// solid-angle grid. This is what makes free-form capture possible: without it the app
/// cannot tell the user when the room is actually covered, and coverage is the only
/// honest stopping condition when there is no fixed shot count.
final class CoverageMap: @unchecked Sendable {
    private static let lonBins = 72
    private static let latBins = 36

    private static let cells: (directions: [SIMD3<Float>], weights: [Float], total: Float) = {
        var directions: [SIMD3<Float>] = []
        var weights: [Float] = []
        var total: Float = 0
        for latIndex in 0 ..< latBins {
            let lat = .pi / 2 - (Float(latIndex) + 0.5) / Float(latBins) * .pi
            // Cells shrink toward the poles; weight by cos(lat) for true solid angle.
            let weight = cos(lat)
            for lonIndex in 0 ..< lonBins {
                let lon = (Float(lonIndex) + 0.5) / Float(lonBins) * 2 * .pi - .pi
                directions.append(SweepFrame.direction(yaw: lon, pitch: lat))
                weights.append(weight)
                total += weight
            }
        }
        return (directions, weights, total)
    }()

    private var counts: [UInt16]

    init() {
        counts = [UInt16](repeating: 0, count: Self.lonBins * Self.latBins)
    }

    func reset() {
        for index in counts.indices { counts[index] = 0 }
    }

    /// Mark every cell inside this frame's frustum. Compared against `tan` rather than
    /// via `atan` per cell — same test, far cheaper, and this runs per captured frame.
    func add(rotation: simd_float3x3, halfFOVx: Float, halfFOVy: Float) {
        let worldToCamera = rotation.transpose
        let tx = tan(halfFOVx)
        let ty = tan(halfFOVy)
        let directions = Self.cells.directions
        for index in counts.indices {
            let camera = worldToCamera * directions[index]
            guard camera.z < 0 else { continue }
            let invDepth = 1 / -camera.z
            if abs(camera.x * invDepth) <= tx, abs(camera.y * invDepth) <= ty {
                counts[index] = counts[index] &+ 1
            }
        }
    }

    /// Share of the whole sphere this frustum would raise toward `depth` views — that is,
    /// the solid angle it can see that has been seen fewer than `depth` times so far.
    ///
    /// This is the question the capture step has to answer BEFORE paying for a frame, and
    /// it is a different question from "is this direction far from the ones I stored".
    /// Two frames ten degrees apart are distinct directions but near-identical frustums;
    /// the separation test says yes and this says almost nothing, which is why the budget
    /// used to run out with the room unfinished.
    ///
    /// `depth: 1` means unseen ground. `depth: 2` means ground only one frame has seen,
    /// which is what the blend needs to feather a seam.
    ///
    /// Costs the same 2592-cell sweep as `add`, and runs only for candidates that already
    /// passed the separation test — deliberately BEFORE the frame is downscaled, so a
    /// refused frame costs a loop rather than a Core Graphics render.
    func novelty(
        rotation: simd_float3x3,
        halfFOVx: Float,
        halfFOVy: Float,
        depth: UInt16
    ) -> Float {
        let worldToCamera = rotation.transpose
        let tx = tan(halfFOVx)
        let ty = tan(halfFOVy)
        let directions = Self.cells.directions
        let weights = Self.cells.weights
        var gained: Float = 0
        for index in counts.indices where counts[index] < depth {
            let camera = worldToCamera * directions[index]
            guard camera.z < 0 else { continue }
            let invDepth = 1 / -camera.z
            if abs(camera.x * invDepth) <= tx, abs(camera.y * invDepth) <= ty {
                gained += weights[index]
            }
        }
        return gained / Self.cells.total
    }

    /// Half-angles of the frustum described by these intrinsics over a buffer this size.
    ///
    /// Scale-invariant — `FrameConverter` scales the focal lengths and the dimensions by
    /// the same factor — so the raw camera buffer and the downscaled stored frame give
    /// identical answers. That is what lets the novelty test run before the downscale.
    static func halfFOVs(
        intrinsics: simd_float3x3,
        width: Int,
        height: Int
    ) -> (x: Float, y: Float) {
        (atan(Float(width) / 2 / intrinsics[0][0]), atan(Float(height) / 2 / intrinsics[1][1]))
    }

    private func fraction(atLeast threshold: UInt16) -> Float {
        let weights = Self.cells.weights
        var covered: Float = 0
        for index in counts.indices where counts[index] >= threshold {
            covered += weights[index]
        }
        return covered / Self.cells.total
    }

    /// Fraction of the sphere seen by at least one frame.
    var coverage: Float { fraction(atLeast: 1) }
    /// Fraction seen by two or more — what predicts seam quality.
    var overlap: Float { fraction(atLeast: 2) }

    func isCovered(_ direction: SIMD3<Float>) -> Bool {
        let lon = atan2(direction.x, -direction.z)
        let lat = asin(max(-1, min(1, direction.y)))
        var lonBin = Int((lon + .pi) / (2 * .pi) * Float(Self.lonBins))
        var latBin = Int((.pi / 2 - lat) / .pi * Float(Self.latBins))
        lonBin = max(0, min(Self.lonBins - 1, lonBin))
        latBin = max(0, min(Self.latBins - 1, latBin))
        return counts[latBin * Self.lonBins + lonBin] >= 1
    }
}

// MARK: - Guidance

/// How to hold the phone, which matters more than anything in the stitcher.
///
/// A panorama is only exactly stitchable from a camera that rotates about its own entrance
/// pupil. Any translation moves near and far points by different amounts and no 2D mapping
/// aligns them both — the artifact is called parallax and it is what runs 1-13 spent thirteen
/// device runs failing to blend away. Turning on the spot with the phone at arm's length swings
/// the camera through a 20-40 cm arc; pivoting your body AROUND the phone keeps it near zero.
///
/// This is the same instruction both commercial competitors give, and it is the cheapest
/// improvement available to this app by a wide margin:
///   - Matterport Capture for iOS: "rotate your body around the device (as if it was on a
///     monopod or broomstick)" — "this minimizes parallax errors".
///     https://support.matterport.com/hc/en-us/articles/1500004898402
///   - Google Street View photo sphere: "hold your device vertically and close to your body".
///     https://developers.google.com/streetview/android/panorama
enum SweepAdvice {
    static let pivot =
        "Keep the phone still and turn your body around it — like it is on a broomstick. "
        + "Moving the phone through an arc is what blurs and doubles the room."

    static let start =
        "Tap Start Sweep. Hold the phone close, then rotate your BODY around it — "
        + "keep the phone in one spot rather than swinging it around you."
}

/// Turns the remaining capture targets into a spoken-language instruction.
///
/// The on-screen markers are spheres two metres away, so a target behind, above or below
/// the user is simply not on screen, and "turn toward the white markers" is unactionable
/// for exactly the directions that go missing. Three device runs stalled at 54.6%, 58.6%
/// and 69.6% of the sphere, and the user's account of the third was that they could not
/// scan the full room. The floor and the polar caps are the consistent shortfall —
/// precisely the directions a natural sweep never points at.
///
/// Lives here rather than in `Capture.swift` so it can be tested on macOS without ARKit,
/// which matters because an inverted left/right or up/down would actively mislead the
/// user and would be invisible in a code review. See `Tests/GuidanceHint`.
enum SweepGuidance {
    /// Below these the user is close enough that naming a direction would only flicker
    /// between "left" and "right" as they wobble.
    static let yawDeadzoneRadians: Float = 20 * .pi / 180
    static let pitchDeadzoneRadians: Float = 15 * .pi / 180
    /// Past this the target is behind the user, where "left" and "right" are both true
    /// and neither is useful.
    static let turnAroundRadians: Float = 2

    /// - Returns: an instruction such as "Turn left and look down", "Hold here" when the
    ///   nearest uncovered target is already in front of the camera, or nil when every
    ///   target is covered.
    static func hint(
        forward: SIMD3<Float>,
        originYaw: Float,
        targets: [CaptureTarget]
    ) -> String? {
        let local = SweepFrame.toLocal(forward, originYaw: originYaw)

        var best: CaptureTarget?
        var bestDot = -Float.greatestFiniteMagnitude
        for target in targets where !target.isCaptured {
            let dot = simd_dot(local, target.localDirection)
            if dot > bestDot {
                bestDot = dot
                best = target
            }
        }
        guard let target = best else { return nil }

        let currentYaw = SweepFrame.yaw(of: local)
        let currentPitch = asin(max(-1, min(1, local.y)))
        var yawDelta = target.yaw - currentYaw
        while yawDelta > .pi { yawDelta -= 2 * .pi }
        while yawDelta < -.pi { yawDelta += 2 * .pi }
        let pitchDelta = target.pitch - currentPitch

        var parts: [String] = []
        if abs(yawDelta) > yawDeadzoneRadians {
            if abs(yawDelta) > turnAroundRadians {
                parts.append("turn around")
            } else {
                // Yaw increases toward +X, which is a turn to the user's RIGHT.
                parts.append(yawDelta > 0 ? "turn right" : "turn left")
            }
        }
        if abs(pitchDelta) > pitchDeadzoneRadians {
            parts.append(pitchDelta > 0 ? "look up" : "look down")
        }
        guard !parts.isEmpty else { return "Hold here" }

        let sentence = parts.joined(separator: " and ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

// MARK: - Models

struct CaptureTarget: Identifiable, Equatable {
    let id = UUID()
    let yaw: Float
    let pitch: Float
    var isCaptured = false

    /// Unit direction in the sweep-local frame.
    var localDirection: SIMD3<Float> {
        SweepFrame.direction(yaw: yaw, pitch: pitch)
    }

    static func makePlan(rings: [CaptureRing] = CaptureConfig.rings) -> [CaptureTarget] {
        var targets: [CaptureTarget] = []
        for (ringIndex, ring) in rings.enumerated() {
            let steps = max(1, ring.yawSteps)
            // Stagger alternate rings so targets do not stack into vertical columns,
            // which would leave wedge-shaped gaps between those columns.
            let offset = ringIndex.isMultiple(of: 2) ? 0 : Float.pi / Float(steps)
            for i in 0 ..< steps {
                let yaw = offset + 2 * .pi * Float(i) / Float(steps)
                targets.append(CaptureTarget(yaw: yaw, pitch: ring.pitch))
            }
        }
        return targets
    }

    /// Convenience for uniform plans, used by the coverage search.
    static func makePlan(yawSteps: Int, pitchRings: [Float]) -> [CaptureTarget] {
        makePlan(rings: pitchRings.map { CaptureRing(pitch: $0, yawSteps: yawSteps) })
    }
}

/// One captured frame, downscaled to RGBA8 with intrinsics rescaled to match.
struct CapturedFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Row-major RGBA8, `width * height * 4` bytes, top-left origin.
    let pixels: [UInt8]
    /// ARKit camera transform: columns are right, up, backward, position.
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    /// How far this frame's viewpoint sat from the sweep origin, in metres.
    ///
    /// The stitcher prices frames by this rather than the capture step banning them, so a
    /// drifted frame still fills a direction nothing else reached. Defaults to 0 so the
    /// host tests, which model a perfect pivot, need not state it.
    var driftMeters: Float = 0

    /// Metric depth in metres along the camera's optical axis, row-major, or nil when this
    /// device or frame had none. Its own resolution: ARKit's LiDAR-fused map is 256x192 while
    /// `pixels` is up to 1024 wide, and resampling it up would invent precision it does not
    /// have.
    ///
    /// This is what makes parallax CORRECTABLE rather than merely maskable, and its absence is
    /// why runs 1-13 could not be fixed by any amount of blending. A panorama assembled by
    /// rotation alone assumes every point is at infinity; when the camera also translates, points
    /// at different depths move by different amounts and no 2D mapping aligns them all. Depth
    /// turns the guess into arithmetic: back-project the pixel to a world point, then ask where
    /// that point lies as seen from the sweep origin.
    ///
    /// SOURCE: Matterport Capture on LiDAR iPhones "will use LiDAR data to improve image
    /// stitching" (support.matterport.com, Matterport Capture for iOS). Nikon US11568516B2,
    /// "Depth-based image stitching for handling parallax", claims essentially this correction
    /// and additionally places seams at depth discontinuities rather than by colour.
    /// ARKit exposes it as `ARFrame.sceneDepth` at 60 Hz — Apple, WWDC20 "Explore ARKit 4".
    var depths: [Float]?
    var depthWidth: Int = 0
    var depthHeight: Int = 0

    /// 0...1 per depth sample, ARKit's `ARDepthData.confidenceMap` flattened. Low-confidence
    /// samples are ignored rather than trusted, because a wrong depth moves a pixel further from
    /// the truth than no depth at all — the naive projection is at least unbiased.
    var depthConfidence: [Float]?
}

enum SweepError: LocalizedError {
    case noFrames
    case stitchFailed
    case notSupported

    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames were captured in this sweep."
        case .stitchFailed: return "The panorama could not be assembled."
        case .notSupported: return "This device does not support ARKit world tracking."
        }
    }
}
