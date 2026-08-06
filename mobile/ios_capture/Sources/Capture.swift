import ARKit
import CoreImage
import Foundation
import UIKit
import simd

// MARK: - Frame conversion

/// Converts `ARFrame.capturedImage` (YCbCr) into a downscaled RGBA8 buffer.
///
/// `capturedImage` is always landscape-right regardless of device orientation, and
/// `frame.camera.intrinsics` describes that same buffer, so no orientation transform
/// is applied here. Applying one would silently invalidate the intrinsics and the
/// stitch would be wrong in a way that looks like a blending bug.
///
/// Confined to `sessionQueue` like `SweepState`. `CIContext` is documented as safe to use
/// from multiple threads, and the serial queue makes the point moot in any case.
private final class FrameConverter: @unchecked Sendable {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    struct Output {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let intrinsics: simd_float3x3
    }

    func convert(
        pixelBuffer: CVPixelBuffer,
        intrinsics: simd_float3x3,
        maxDimension: Int
    ) -> Output? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, Float(maxDimension) / Float(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Float(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Float(sourceHeight) * scale).rounded()))

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let fullSize = ciContext.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        ) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(fullSize, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        // Row 0 of a CGBitmapContext buffer is the top row of the drawn image, which
        // matches the top-left origin the intrinsics assume. No flip is needed.
        let sx = Float(width) / Float(sourceWidth)
        let sy = Float(height) / Float(sourceHeight)
        var scaled = intrinsics
        scaled[0][0] *= sx // fx
        scaled[1][1] *= sy // fy
        scaled[2][0] *= sx // cx
        scaled[2][1] *= sy // cy

        return Output(pixels: pixels, width: width, height: height, intrinsics: scaled)
    }
}

// MARK: - Sweep state owned by the AR session queue

/// All mutable capture state lives here rather than on the `@MainActor` manager, so
/// the 60 Hz delegate callback never touches main-actor storage. The manager
/// publishes immutable snapshots of it.
///
/// `@unchecked Sendable` is load-bearing and the invariant is manual: every access must
/// happen on `sessionQueue`. That queue is serial, so confinement gives mutual exclusion
/// without locks. `ARSession.delegateQueue` is set to it, and the only other entry points
/// (`startSweep`, `finishSweep`) hop onto it explicitly. Touching `state` from anywhere
/// else — including the main actor — breaks this and races the 60 Hz delegate callback.
private final class SweepState: @unchecked Sendable {
    var targets: [CaptureTarget] = []
    var frames: [CapturedFrame] = []
    var originYaw: Float = 0
    var originPosition = SIMD3<Float>(repeating: 0)
    var hasOrigin = false
    var isActive = false
    var lastReportedTrackingIsGood: Bool?

    /// Forward direction of every stored frame, for the separation test.
    var frameForwards: [SIMD3<Float>] = []
    let coverage = CoverageMap()
    var lastForward: SIMD3<Float>?
    var smoothCount = 0
    var driftMonitor = DriftMonitor()
    /// Previous tracked frame's timestamp, so the drift monitor gets a real `dt`.
    var lastFrameTimestamp: TimeInterval?
    /// Last hint published, so the 60 Hz callback only hops to the main actor on a change.
    var lastHint: String?

    func begin(with plan: [CaptureTarget]) {
        targets = plan
        frames = []
        frameForwards = []
        coverage.reset()
        hasOrigin = false
        lastForward = nil
        smoothCount = 0
        driftMonitor.reset()
        lastFrameTimestamp = nil
        lastHint = nil
        isActive = true
    }

    /// Where to point next. Geometry lives in `SweepGuidance` so it is host-testable.
    func nextTargetHint(forward: SIMD3<Float>) -> String? {
        guard hasOrigin else { return nil }
        return SweepGuidance.hint(forward: forward, originYaw: originYaw, targets: targets)
    }

    /// True when this direction is far enough from everything already stored to be worth
    /// keeping. This is what stops a stationary phone from filling memory with duplicates
    /// while still letting the user capture as many genuinely different views as they like.
    func isFarFromStoredFrames(_ forward: SIMD3<Float>) -> Bool {
        for stored in frameForwards {
            if simd_dot(stored, forward) > cos(CaptureQuality.minSeparationRadians) {
                return false
            }
        }
        return true
    }

    /// Marks every outstanding target the coverage map already covers. Returns whether any
    /// changed, so the caller can stay off the main actor when nothing did.
    ///
    /// Separated from `capture` so it can run on EVERY tracked frame rather than only on
    /// stored ones. That distinction is the whole point: see the call site above the storage
    /// gates for the sweep it deadlocked.
    func markCoveredTargets() -> Bool {
        var changed = false
        for index in targets.indices where !targets[index].isCaptured {
            let world = SweepFrame.toWorld(
                targets[index].localDirection, originYaw: originYaw)
            if coverage.isCovered(world) {
                targets[index].isCaptured = true
                changed = true
            }
        }
        return changed
    }
}

// MARK: - Capture manager

@MainActor
final class ARCaptureManager: NSObject, ObservableObject {
    @Published private(set) var targets: [CaptureTarget] = []
    @Published private(set) var isSweeping = false
    @Published private(set) var status = SweepAdvice.start
    @Published private(set) var trackingIsGood = false
    /// Changes whenever a new sweep begins, so the renderer knows to rebuild markers.
    @Published private(set) var sweepID = UUID()
    @Published private(set) var sweepOriginYaw: Float = 0
    @Published private(set) var sweepOriginPosition = SIMD3<Float>(repeating: 0)
    /// False until the first tracked frame of a sweep fixes the local yaw frame.
    /// Markers must not be drawn before this, or they render at the previous sweep's heading.
    @Published private(set) var sweepOriginEstablished = false
    /// World positions of every completed sweep. Consecutive distances are the VIO readout.
    @Published private(set) var completedSweepPositions: [SIMD3<Float>] = []
    /// Fraction of the sphere seen so far. This, not a shot count, is the stopping condition.
    @Published private(set) var sweepCoverage: Float = 0
    /// Fraction seen by two or more frames — how well the seams will blend.
    @Published private(set) var sweepOverlap: Float = 0
    /// Photos stored in this sweep. Unbounded by the plan, capped only by memory.
    @Published private(set) var frameCount = 0
    /// True while the phone has wandered too far from where the sweep began.
    @Published private(set) var isDrifting = false
    /// Where to point next to close the biggest remaining gap, e.g. "Turn left and look down".
    @Published private(set) var guidance: String?

    let session = ARSession()

    private let sessionQueue = DispatchQueue(label: "com.dm360.sweepspike.session")
    private let converter = FrameConverter()
    private let state = SweepState()

    var capturedCount: Int { targets.filter(\.isCaptured).count }
    var totalTargets: Int { targets.count }

    /// Distance between the two most recent sweep origins, in metres.
    var lastSweepSeparation: Float? {
        guard completedSweepPositions.count >= 2 else { return nil }
        let a = completedSweepPositions[completedSweepPositions.count - 2]
        let b = completedSweepPositions[completedSweepPositions.count - 1]
        return simd_distance(a, b)
    }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = sessionQueue
    }

    func startSession() throws {
        guard ARWorldTrackingConfiguration.isSupported else { throw SweepError.notSupported }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.isAutoFocusEnabled = true
        if let best = highestResolutionFormat() { configuration.videoFormat = best }

        // Ask for LiDAR-fused metric depth. This is the single capability the app was missing:
        // without it the stitcher can only assume every point is infinitely far away, which is
        // exact for a camera that purely rotates and wrong by atan(offset / distance) for one
        // that does not — 31 degrees for the 0.30 m of drift the app used to tolerate and an
        // object half a metre away. With depth the correction is arithmetic instead of a guess.
        //
        // SOURCE: Apple, WWDC20 "Explore ARKit 4" — `.sceneDepth` delivers a dense depth map
        // plus a per-pixel confidence map on every ARFrame at 60 Hz, LiDAR-fused, on Pro devices
        // from the iPhone 12 Pro onward. Matterport Capture uses the same signal: on LiDAR
        // iPhones it "will use LiDAR data to improve image stitching"
        // (support.matterport.com/hc/en-us/articles/1500004898402).
        //
        // Gated on the device actually supporting it rather than assumed: a non-Pro iPhone runs
        // this same build and must simply fall back to the old rotation-only path, which is what
        // `CapturedFrame.depths == nil` already selects.
        // REVERTED TO RUN 6 (2026-08-06). `.sceneDepth` was enabled for run 14 and did not
        // exist at run 6. Leaving it off means `CapturedFrame.depths` is nil for every frame,
        // which `PanoramaStitcher` already treats as "no depth" and falls back to the
        // rotation-only model — a byte-exact restoration of the sixth-run projection, not an
        // approximation of it. The extraction code below is retained and unused. Restore the
        // `frameSemantics.insert(.sceneDepth)` call to re-enable.
        //
        // if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
        //     configuration.frameSemantics.insert(.sceneDepth)
        // }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pauseSession() {
        session.pause()
    }

    func startSweep() {
        let plan = CaptureTarget.makePlan()
        targets = plan
        isSweeping = true
        sweepID = UUID()
        sweepOriginEstablished = false
        sweepCoverage = 0
        sweepOverlap = 0
        frameCount = 0
        isDrifting = false
        guidance = nil
        status = "Turn slowly on the spot. Keep your feet planted."
        sessionQueue.async { [state] in state.begin(with: plan) }
    }

    /// Ends the sweep and hands back the frames for stitching off the main actor.
    func finishSweep() async -> (frames: [CapturedFrame], originYaw: Float, originPosition: SIMD3<Float>) {
        isSweeping = false
        let result: (frames: [CapturedFrame], originYaw: Float, origin: SIMD3<Float>?) =
            await withCheckedContinuation { continuation in
                sessionQueue.async { [state] in
                    state.isActive = false
                    continuation.resume(returning: (
                        state.frames,
                        state.originYaw,
                        state.hasOrigin ? state.originPosition : nil
                    ))
                }
            }
        if let origin = result.origin { completedSweepPositions.append(origin) }
        status = "Sweep finished with \(result.frames.count) frames."
        // The origin is now part of the contract: the stitcher measures every frame's
        // translation against it to correct parallax, so a stitch that did not know it
        // would silently fall back to the rotation-only model.
        return (result.frames, result.originYaw, result.origin ?? .zero)
    }

    func resetSweepHistory() {
        completedSweepPositions = []
    }

    /// Prefer the highest-resolution format so stitched detail is limited by the
    /// downscale in `FrameConverter`, not by the capture pipeline.
    private func highestResolutionFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats.max { lhs, rhs in
            lhs.imageResolution.width * lhs.imageResolution.height
                < rhs.imageResolution.width * rhs.imageResolution.height
        }
    }
}

// MARK: - ARSessionDelegate

extension ARCaptureManager: ARSessionDelegate {
    /// Runs on `sessionQueue`. ARKit drops frames while this is busy, which is the
    /// backpressure we want: conversion is far slower than 60 Hz.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let isNormal: Bool
        if case .normal = camera.trackingState { isNormal = true } else { isNormal = false }
        if state.lastReportedTrackingIsGood != isNormal {
            state.lastReportedTrackingIsGood = isNormal
            Task { @MainActor [weak self] in self?.trackingIsGood = isNormal }
        }

        guard state.isActive, isNormal else {
            state.smoothCount = 0
            state.lastForward = nil
            // Tracking has dropped, so the distance to the origin is no longer trustworthy
            // and the banner must not survive on stale evidence.
            let wasWarning = state.driftMonitor.isWarning
            state.driftMonitor.reset()
            state.lastFrameTimestamp = nil
            if wasWarning { Task { @MainActor [weak self] in self?.isDrifting = false } }
            return
        }

        let transform = camera.transform
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        if !state.hasOrigin {
            state.originYaw = SweepFrame.yaw(of: forward)
            state.originPosition = position
            state.hasOrigin = true
            let yaw = state.originYaw
            Task { @MainActor [weak self] in
                self?.sweepOriginYaw = yaw
                self?.sweepOriginPosition = position
                self?.sweepOriginEstablished = true
            }
        }

        // Reject frames taken while the phone is being whipped around: those are
        // motion-blurred, and a blurred frame poisons the blend wherever it lands.
        if let previous = state.lastForward {
            let step = acos(max(-1, min(1, simd_dot(previous, forward))))
            state.smoothCount = step > CaptureQuality.maxAngularStepRadians
                ? 0
                : state.smoothCount + 1
        }
        state.lastForward = forward

        // Recomputed on every callback, not only when a frame is stored, because the
        // instruction has to track where the phone is pointing in real time to be usable.
        // Cheap: at most 44 dot products. Only crosses to the main actor when the wording
        // actually changes, so a steady aim costs nothing.
        let hint = state.nextTargetHint(forward: forward)
        if hint != state.lastHint {
            state.lastHint = hint
            Task { @MainActor [weak self] in self?.guidance = hint }
        }

        // Drift is judged on EVERY tracked frame, before any of the storage gates below.
        // It used to be judged inside them, which meant the banner froze the moment the
        // frame budget filled or the user paused mid-turn: the fourth device run ended at
        // 90 frames with "Drifting" showing permanently, because nothing after the
        // capacity guard ever ran again to take it down. A warning that cannot switch off
        // is not a warning. `DriftMonitor` adds the tolerance a standing human needs.
        // Measured against the monitor's own creeping reference, NOT against the sweep
        // origin, so a long sweep's accumulated VIO drift cannot masquerade as the user
        // walking away — the run-7 failure. `dt` comes from the frame timestamp because
        // ARKit's delivery rate to a busy delegate varies by a factor of three.
        let dt = state.lastFrameTimestamp.map { Float(frame.timestamp - $0) } ?? 0
        state.lastFrameTimestamp = frame.timestamp
        if let isDrifted = state.driftMonitor.update(position: position, dt: dt) {
            Task { @MainActor [weak self] in self?.isDrifting = isDrifted }
        }

        // The stitcher's number stays anchored to the true sweep origin: it prices frames by
        // how far the viewpoint actually moved, which is a geometry question and has nothing
        // to do with what the user should be told.
        let drift = simd_distance(position, state.originPosition)

        // Clear any marker the map ALREADY covers, before the storage gates below can
        // return. This is the third time this exact bug has been fixed in this function and
        // the first time it was visible to the user rather than to a banner: the drift
        // warning froze at the capacity guard, the guidance hint froze with it, and the
        // white markers froze here. Anything the user is looking at has to be driven by what
        // the CAMERA SAW; only what is kept for stitching belongs behind the storage gates.
        //
        // The twelfth device run is what this is: a marker sat on the window blinds saying
        // "Hold here" at 97% covered · 76 photos, and holding there did nothing, forever. It
        // could not do anything. A frame aimed at that marker is refused by the novelty gate
        // BECAUSE the direction is already covered, and marking targets only ever happened
        // after that gate, inside `capture`. So the one condition that guarantees a target
        // is finished was also the condition that guaranteed it would never be marked. The
        // user cannot escape it by aiming better; there is nothing to aim at. They give up
        // and finish early, which is why run 12 stitched 76 frames where run 9 stitched 90.
        //
        // Note this cannot mark a target the stitch will not have: `isCovered` is asked of
        // the STORED-frame map, unchanged. A refusal for zero novelty is the map saying it
        // already holds this ground, so marking the target agrees with it rather than
        // overriding it. The novelty gate, the frame budget and what gets stitched are all
        // untouched — this only stops the UI lying about them.
        // REVERTED TO RUN 6 (2026-08-06). This pre-gate marking pass was the run-13 fix for
        // the run-12 deadlock and did not exist at run 6, so it is disabled here to restore
        // the sixth-run capture behaviour exactly.
        //
        // KNOWN CONSEQUENCE, ACCEPTED DELIBERATELY: the deadlock comes back. A target aimed
        // at ground the coverage map already holds can never be marked, because the only
        // remaining marking pass runs inside `capture` — behind the novelty gate that refuses
        // that frame precisely BECAUSE the direction is covered. The user gets a white marker
        // that says "Hold here" and cannot be cleared by aiming at it, which is what ended
        // run 12 at 76 frames. Watch the COVERAGE percentage, not the markers, and finish the
        // sweep on that number. Delete this `if false` to restore the fix.
        if false, state.markCoveredTargets() {
            let snapshot = state.targets
            let allDone = snapshot.allSatisfy(\.isCaptured)
            let covered = state.coverage.coverage
            let stored = state.frames.count
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.targets = snapshot
                // Clearing the last marker is NOT permission to finish, and saying it was is
                // what made run 13 the worst run so far. The plan is 44 sampled DIRECTIONS;
                // the sphere is a continuous surface. All 44 can be covered while wide bands
                // between them have never been seen, and run 13's output is full of exactly
                // that — blown white voids where hole-filling invented the ceiling and the
                // far wall. The previous version of this line said "Every marker reached —
                // tap Finish Sweep" the moment the last marker cleared, the user reasonably
                // did as they were told, and the sweep ended 10 seconds short.
                //
                // Coverage, not markers, decides when the sweep is done. The markers are
                // only where to point next.
                guard allDone else { return }
                self.status = covered >= CaptureQuality.goodCoverage
                    ? String(format: "Every marker reached · %d photos, %.0f%% covered — tap Finish Sweep.",
                             stored, covered * 100)
                    : String(format: "Markers done, but only %.0f%% covered — keep sweeping the gaps before finishing.",
                             covered * 100)
            }
        }

        guard state.frames.count < CaptureQuality.maxStoredFrames else { return }
        guard state.smoothCount >= CaptureQuality.smoothFramesRequired else { return }

        // Price drift, do not ban it. Moving the viewpoint really is what smears near
        // objects, but keep the frame, because discarding it cost roughly half the sphere
        // on two device runs and a drifted frame still beats an interpolated hole.
        // `PanoramaStitcher` down-weights by `driftMeters`, so these frames only win where
        // nothing better saw that direction. Past the hard limit the user has walked off.
        guard drift <= CaptureQuality.driftHardLimitMeters else { return }

        // This view must be a genuinely new DIRECTION...
        guard state.isFarFromStoredFrames(forward) else { return }

        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        let halfFOV = CoverageMap.halfFOVs(
            intrinsics: camera.intrinsics,
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )

        // ...and, once half the frame budget is gone, it must also show new GROUND.
        // Direction and ground are not the same test. A 10-degree step taken in a patch
        // several frames have already seen from both sides is a new direction that reveals
        // nothing, and buying 45 of those is exactly how the last run finished its budget
        // with 12.9% of the room never seen. Once the sphere is closed the same gate
        // switches to buying second views, which is what the seam blend runs on.
        if state.frames.count >= Int(Float(CaptureQuality.maxStoredFrames)
            * CaptureQuality.noveltyGateFraction) {
            let depth: UInt16 = state.coverage.coverage >= CaptureQuality.goodCoverage ? 2 : 1
            let novelty = state.coverage.novelty(
                rotation: rotation, halfFOVx: halfFOV.x, halfFOVy: halfFOV.y, depth: depth)
            guard novelty >= CaptureQuality.minNoveltyFraction else { return }
        }

        capture(
            frame: frame,
            forward: forward,
            drift: drift,
            rotation: rotation,
            halfFOV: halfFOV
        )
    }

    /// Copies `ARFrame.sceneDepth` out into plain arrays, in metres, at the depth map's own
    /// resolution — 256x192 on current hardware, against a colour frame up to 1024 wide.
    ///
    /// Kept at its native size deliberately: upsampling depth to the colour resolution would
    /// invent precision the sensor never had, and the stitcher already maps between the two by
    /// ratio. `smoothedSceneDepth` is preferred where available because it is temporally
    /// filtered, which matters here — a sweep holds each direction for only a few frames and
    /// raw LiDAR returns flicker frame to frame.
    ///
    /// SOURCE: Apple, WWDC20 "Explore ARKit 4"; `ARDepthData` carries `depthMap` (Float32
    /// metres) and `confidenceMap` (ARConfidenceLevel: low/medium/high as 0/1/2).
    nonisolated private static func extractDepth(
        from frame: ARFrame
    ) -> (values: [Float], confidence: [Float]?, width: Int, height: Int)? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map)
        else { return nil }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map)
        guard width > 1, height > 1 else { return nil }

        var values = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0 ..< width { values[y * width + x] = row[x] }
        }

        // Confidence is optional: without it every sample is trusted, which is the behaviour on
        // any future device that stops publishing one.
        var confidence: [Float]?
        if let raw = data.confidenceMap {
            CVPixelBufferLockBaseAddress(raw, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(raw, .readOnly) }
            if CVPixelBufferGetWidth(raw) == width, CVPixelBufferGetHeight(raw) == height,
               let cbase = CVPixelBufferGetBaseAddress(raw) {
                let cstride = CVPixelBufferGetBytesPerRow(raw)
                var out = [Float](repeating: 0, count: width * height)
                let top = Float(ARConfidenceLevel.high.rawValue)
                for y in 0 ..< height {
                    let row = cbase.advanced(by: y * cstride)
                        .assumingMemoryBound(to: UInt8.self)
                    for x in 0 ..< width {
                        out[y * width + x] = top > 0 ? Float(row[x]) / top : 1
                    }
                }
                confidence = out
            }
        }
        return (values, confidence, width, height)
    }

    nonisolated private func capture(
        frame: ARFrame,
        forward: SIMD3<Float>,
        drift: Float,
        rotation: simd_float3x3,
        halfFOV: (x: Float, y: Float)
    ) {
        guard let converted = converter.convert(
            pixelBuffer: frame.capturedImage,
            intrinsics: frame.camera.intrinsics,
            maxDimension: CaptureConfig.storedFrameMaxDimension
        ) else { return }

        let depth = Self.extractDepth(from: frame)
        state.frames.append(CapturedFrame(
            width: converted.width,
            height: converted.height,
            pixels: converted.pixels,
            transform: frame.camera.transform,
            intrinsics: converted.intrinsics,
            driftMeters: drift,
            depths: depth?.values,
            depthWidth: depth?.width ?? 0,
            depthHeight: depth?.height ?? 0,
            depthConfidence: depth?.confidence
        ))
        state.frameForwards.append(forward)

        // Fold this frame into the coverage map, then let the guidance markers follow the
        // map rather than an exact-aim test — a target counts as done once ANY frame sees
        // it, however the user happened to get there. The frustum is the same one the
        // novelty gate just measured, passed in rather than recomputed so the gate and the
        // map can never disagree about what this frame saw.
        state.coverage.add(rotation: rotation, halfFOVx: halfFOV.x, halfFOVy: halfFOV.y)

        // Again here, because this frame has just been folded into the map and may have
        // covered a target that the pass before the storage gates could not yet see. Same
        // routine, so the two can never disagree about what "covered" means.
        _ = state.markCoveredTargets()

        let snapshot = state.targets
        let coverage = state.coverage.coverage
        let overlap = state.coverage.overlap
        let stored = state.frames.count
        let atCapacity = stored >= CaptureQuality.maxStoredFrames

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.targets = snapshot
            self.sweepCoverage = coverage
            self.sweepOverlap = overlap
            self.frameCount = stored
            if atCapacity {
                // Say what was and was not reached. "Memory full" alone reads as a crash
                // to the user who is still being told to turn toward white markers they
                // can no longer capture.
                self.status = coverage >= CaptureQuality.goodCoverage
                    ? "Room covered at \(stored) photos — tap Finish Sweep."
                    : String(
                        format: "Photo memory full at %d — %.0f%% covered. Finish, then sweep again from here for the rest.",
                        stored, coverage * 100)
            } else if coverage >= CaptureQuality.goodCoverage {
                self.status = String(
                    format: "Room covered (%.0f%%). Keep sweeping to sharpen it, or finish.",
                    coverage * 100)
            } else {
                self.status = String(
                    format: "%.0f%% covered · %d photos. Turn toward the white markers — body around the phone.",
                    coverage * 100, stored)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
