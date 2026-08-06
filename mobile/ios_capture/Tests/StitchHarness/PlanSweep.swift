import CoreGraphics
import Foundation
import simd

/// Measures how much of the sphere a candidate capture plan actually reaches.
///
/// The capture geometry is easy to get wrong on paper: `capturedImage` is always
/// landscape, so a phone held in portrait presents its LONG image axis vertically.
/// The wide field of view therefore buys vertical coverage, and the yaw spacing has
/// to fit inside the NARROW axis. Getting this backwards leaves vertical seams that
/// only show up after a room has already been walked.
enum PlanSweep {
    struct Geometry {
        let imageWidth: Int
        let imageHeight: Int
        let focal: Float

        /// Half-angle along the image x axis.
        var halfFOVx: Float { atan(Float(imageWidth) / 2 / focal) }
        /// Half-angle along the image y axis.
        var halfFOVy: Float { atan(Float(imageHeight) / 2 / focal) }
    }

    struct Coverage {
        let overall: Double
        /// Coverage restricted to |latitude| < 40 degrees, i.e. the walls of a room.
        let wallBand: Double
        /// Fraction of the wall band seen by TWO OR MORE frames.
        ///
        /// This, not `overall`, is what predicts seam quality. The stitcher feathers
        /// each frame's contribution to zero at its border, so a direction seen by
        /// exactly one frame near that frame's edge gets colour with almost no weight
        /// and no neighbour to cross-fade into. A plan can reach 100% coverage and
        /// still show a seam at every frame boundary.
        let wallBandOverlap: Double
        let targetCount: Int
    }

    /// Analytic coverage: rasterise the sphere and mark every cell that falls inside
    /// at least one frame's rectangular frustum. Cheaper and less noisy than stitching,
    /// and it isolates plan geometry from blending.
    ///
    /// `roll` is the rotation of the camera about its own forward axis. It is not
    /// cosmetic: at `CaptureConfig.deviceRollRadians` the wide image-x axis lies
    /// vertically, so the frustum is tall and narrow rather than short and wide.
    /// Modelling a level camera here is what makes a portrait plan look sufficient
    /// on paper while leaving vertical seams in the room.
    static func coverage(
        rings: [CaptureRing],
        geometry: Geometry,
        roll: Float = CaptureConfig.deviceRollRadians,
        edgeMargin: Float = 0.02
    ) -> Coverage {
        let plan = CaptureTarget.makePlan(rings: rings)
        let rotations: [simd_float3x3] = plan.map { target in
            cameraRotation(forward: target.localDirection, roll: roll)
        }

        // Usable half-angles shrink by the edge margin excluded during stitching.
        let usableX = atan(tan(geometry.halfFOVx) * (1 - 2 * edgeMargin))
        let usableY = atan(tan(geometry.halfFOVy) * (1 - 2 * edgeMargin))

        let lonSteps = 720
        let latSteps = 360
        var coveredWeight = 0.0
        var totalWeight = 0.0
        var wallCovered = 0.0
        var wallTotal = 0.0
        var wallOverlapped = 0.0

        for latIndex in 0 ..< latSteps {
            let lat = .pi / 2 - (Float(latIndex) + 0.5) / Float(latSteps) * .pi
            // Cells shrink toward the poles; weight by cos(lat) for true solid angle.
            let weight = Double(cos(lat))
            let isWallBand = abs(lat) < 40 * .pi / 180

            for lonIndex in 0 ..< lonSteps {
                let lon = (Float(lonIndex) + 0.5) / Float(lonSteps) * 2 * .pi - .pi
                let direction = SweepFrame.direction(yaw: lon, pitch: lat)

                var seenBy = 0
                for rotation in rotations {
                    let camera = rotation.transpose * direction
                    guard camera.z < 0 else { continue }
                    let invDepth = 1 / -camera.z
                    if abs(atan(camera.x * invDepth)) <= usableX,
                       abs(atan(camera.y * invDepth)) <= usableY {
                        seenBy += 1
                        if seenBy >= 2 { break }
                    }
                }

                totalWeight += weight
                if seenBy >= 1 { coveredWeight += weight }
                if isWallBand {
                    wallTotal += weight
                    if seenBy >= 1 { wallCovered += weight }
                    if seenBy >= 2 { wallOverlapped += weight }
                }
            }
        }

        return Coverage(
            overall: coveredWeight / totalWeight,
            wallBand: wallCovered / wallTotal,
            wallBandOverlap: wallOverlapped / wallTotal,
            targetCount: plan.count
        )
    }

    static func cameraRotation(forward: SIMD3<Float>, roll: Float) -> simd_float3x3 {
        let backward = -simd_normalize(forward)
        // Straight up or down, world up is parallel to backward and the cross product
        // collapses to zero. Normalising that yields NaN and silently voids the whole
        // frame, so fall back to an axis guaranteed not to be parallel.
        var right = simd_cross(SIMD3<Float>(0, 1, 0), backward)
        if simd_length(right) < 1e-4 {
            right = simd_cross(SIMD3<Float>(0, 0, 1), backward)
        }
        right = simd_normalize(right)
        let up = simd_cross(backward, right)

        let c = cos(roll), s = sin(roll)
        return simd_float3x3(right * c + up * s, up * c - right * s, backward)
    }

    static func report() {
        // iPhone wide camera, 4:3 landscape buffer, ~60 degrees across the long axis.
        let longAxis = 1920, shortAxis = 1440
        let focal = Float(longAxis) / 2 / tan(30 * .pi / 180)

        // Held in portrait, capturedImage's x axis (the long one) runs vertically,
        // so the frustum is TALL: wide vertically, narrow horizontally.
        let portrait = Geometry(imageWidth: longAxis, imageHeight: shortAxis, focal: focal)
        print(String(
            format: "Frame frustum: %.1f deg across image-x, %.1f deg across image-y",
            portrait.halfFOVx * 2 * 180 / .pi,
            portrait.halfFOVy * 2 * 180 / .pi
        ))
        print("Held in portrait the image-y axis is HORIZONTAL, so yaw spacing must fit it.\n")

        // Same plan, modelled level rather than rolled. The gap between these two rows
        // is the cost of getting the orientation wrong, and it is not small.
        let uniform = [CaptureRing(pitch: 0, yawSteps: 8),
                       CaptureRing(pitch: .pi / 6, yawSteps: 8),
                       CaptureRing(pitch: -.pi / 6, yawSteps: 8)]
        let asPortrait = coverage(rings: uniform, geometry: portrait)
        let asLandscape = coverage(rings: uniform, geometry: portrait, roll: 0)
        print(String(
            format: "24-target plan 8 x [0/30/-30]: %.1f%% sphere held portrait, "
                + "%.1f%% if modelled level (wrong).\n",
            asPortrait.overall * 100,
            asLandscape.overall * 100
        ))

        // Search: a horizon ring, a symmetric mid ring, and a symmetric cap ring whose
        // yaw count is allowed to be small. Ranked by target count, since capture time
        // is what the user actually pays.
        var scored: [(Coverage, String)] = []
        for horizonSteps in [8, 10, 12, 14] {
            for midDegrees in [30, 36, 45] {
                for capDegrees in [0, 70, 80] {
                    for capSteps in [2, 3, 4] where capDegrees > 0 || capSteps == 2 {
                        var rings = [CaptureRing(pitch: 0, yawSteps: horizonSteps)]
                        let mid = Float(midDegrees) * .pi / 180
                        rings.append(CaptureRing(pitch: mid, yawSteps: horizonSteps))
                        rings.append(CaptureRing(pitch: -mid, yawSteps: horizonSteps))
                        var label = "\(horizonSteps)x[0/±\(midDegrees)]"
                        if capDegrees > 0 {
                            let cap = Float(capDegrees) * .pi / 180
                            rings.append(CaptureRing(pitch: cap, yawSteps: capSteps))
                            rings.append(CaptureRing(pitch: -cap, yawSteps: capSteps))
                            label += " + \(capSteps)x[±\(capDegrees)]"
                        }
                        scored.append((coverage(rings: rings, geometry: portrait), label))
                    }
                }
            }
        }

        // Only plans that actually close the sphere are worth comparing; among those,
        // the cheapest plan with good overlap wins, not simply the cheapest.
        print("  targets  plan                              sphere    walls   overlap")
        for (result, label) in scored
            .filter({ $0.0.overall > 0.999 })
            .sorted(by: { $0.0.targetCount < $1.0.targetCount })
        {
            print(String(
                format: "  %7d  %-32s  %6.1f%%  %6.1f%%  %6.1f%%",
                result.targetCount,
                (label as NSString).utf8String!,
                result.overall * 100,
                result.wallBand * 100,
                result.wallBandOverlap * 100
            ))
        }

        let shipping = coverage(rings: CaptureConfig.rings, geometry: portrait)
        print(String(
            format: "\n  SHIPPING PLAN: %d targets, %.1f%% sphere, %.1f%% walls, %.1f%% overlap",
            shipping.targetCount,
            shipping.overall * 100,
            shipping.wallBand * 100,
            shipping.wallBandOverlap * 100
        ))
        planFailures = []
        if shipping.overall <= 0.999 {
            planFailures.append(String(
                format: "shipping plan covers only %.1f%% of the sphere", shipping.overall * 100))
        }
        // Below roughly this, adjacent frames abut instead of overlapping and the
        // feathered blend has nothing to cross-fade into at the boundary.
        if shipping.wallBandOverlap < 0.90 {
            planFailures.append(String(
                format: "shipping plan wall overlap is only %.1f%%, seams likely",
                shipping.wallBandOverlap * 100))
        }
    }

    /// Populated by `report()`; consumed by the harness's exit status.
    static var planFailures: [String] = []
}
