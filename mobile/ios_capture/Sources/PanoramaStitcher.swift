import CoreGraphics
import Foundation
import simd

/// Assembles captured frames into an equirectangular panorama by inverse projection.
///
/// For every output pixel we know the exact ray it represents, and for every frame we
/// know the exact camera pose and intrinsics, so each ray can be projected straight
/// into each frame. No feature matching is required — that is the whole reason the
/// capture step records poses. This is also why the sweep must be rotate-in-place:
/// the model assumes every ray originates from a single point.
enum PanoramaStitcher {
    struct Result: @unchecked Sendable {
        let image: CGImage
        /// Fraction of the SPHERE, by solid angle, that at least one frame saw. 0...1.
        ///
        /// Measured in solid angle, not in output pixels. An equirectangular canvas spends
        /// as many pixels on the 1-degree cap at the zenith as on a 1-degree band at the
        /// horizon, so a pixel count flatters any sweep that got the ceiling and libels one
        /// that only missed it — the number this is shown as ("% of the sphere covered")
        /// would then be false. Each row is weighted by cos(latitude), which is exactly the
        /// solid angle it represents.
        let coverage: Double
        let frameCount: Int
    }

    /// Excluded border, as a fraction of each image dimension. Lens distortion and
    /// vignetting are worst at the very edge and are not modelled here.
    private static let edgeMargin: Float = 0.02

    /// How close to the best-placed frame a frame must be, as a fraction of that best
    /// frame's weight, before it is allowed to contribute to a pixel at all.
    ///
    /// This is the single most important quality constant in the stitcher, and it exists
    /// because a free-form sweep gathers FAR more overlap than a plan does. The user's
    /// second device run stored 43 frames over 54.6% of the sphere; each frame spans
    /// ~60x46.8 degrees, so on average roughly FIVE frames see any given direction. A
    /// plain weighted average therefore blends five viewpoints, and because a handheld
    /// sweep never rotates exactly about the lens, those five disagree about where near
    /// objects are. Five disagreeing views averaged together is mush — and it is mush
    /// EVERYWHERE, not just in a thin seam, which is exactly what that run looked like:
    /// ceiling and far wall crisp, everything close streaked and doubled.
    ///
    /// Feathering alone cannot fix this. A smooth feather ranks the five frames but still
    /// gives the also-rans real weight, and raising the exponent to suppress them narrows
    /// the blend everywhere at once, which trades mush for hard exposure steps.
    ///
    /// Selecting against the per-pixel MAXIMUM decouples the two. Frames that are not
    /// competitive for a pixel are dropped outright, so almost every pixel is drawn from
    /// one or two frames and stays sharp, while the ones that ARE competitive still
    /// cross-fade smoothly and hide the seam. 0.5 means "within 71% of the best frame's
    /// distance-to-edge", which admits a genuine neighbour and rejects a fourth-best view.
    ///
    /// Lower it toward 0.3 if hard seams or brightness steps appear (ARKit auto-exposure
    /// makes frames differ); raise it toward 0.7 if near objects still double.
    private static let dominanceThreshold: Float = 0.5

    /// Drift at which a frame's weight is halved, in metres.
    ///
    /// The capture step no longer rejects drifted frames — banning them cost roughly half
    /// the sphere on two device runs — so the blend has to rank them instead. Weight falls
    /// as `1 / (1 + (drift / this)^2)`: gentle at first, then steep. Paired with
    /// `dominanceThreshold`, the effect is a clean priority order rather than a blur. A
    /// frame 12 cm off origin carries half weight, so wherever a well-placed frame also
    /// sees that direction the drifted one falls below the dominance cut and is dropped
    /// outright; where nothing else saw it, it is the only candidate and wins at whatever
    /// weight it has. Drift therefore costs sharpness only in the places that would
    /// otherwise have been holes.
    private static let driftHalfWeightMeters: Float = 0.12

    /// How far a frame's colour may differ from the BEST-placed frame's colour at the same
    /// pixel, per channel on a 0-255 scale, before that frame is refused a vote there.
    ///
    /// `dominanceThreshold` decides which frames are geometrically competitive for a pixel.
    /// It cannot decide whether they AGREE. Two frames can both see a direction dead-centre,
    /// both score ~1.0 relative weight, and still be looking at different things — because a
    /// hand-held sweep pivots around the user, not the lens, so a chair 1 m away shifts
    /// against the floor behind it between one frame and the next. Averaging those two is
    /// what produces the doubled chairs and the ghosted ceiling beam in the fifth and sixth
    /// device runs, and no amount of geometric ranking removes it: the frames are equally
    /// well placed, which is precisely why they both get to speak.
    ///
    /// So the blend now asks a second question. Where competitive frames AGREE on the
    /// colour, they are seeing the same surface and averaging is exactly right — it hides
    /// the seam and averages out sensor noise and exposure wobble. Where they DISAGREE by
    /// more than this, they are seeing different surfaces, one of them is wrong for this
    /// direction, and the best-placed frame is the one to believe. The loser is dropped
    /// rather than smeared across the winner.
    ///
    /// 48/255 is set well above what exposure and noise produce and well below what an
    /// object boundary does. ARKit auto-exposure moves frames by roughly 5-20 levels across
    /// a sweep and sensor noise by under 5, so both stay inside the tolerance and keep
    /// blending; a chair edge against carpet, or a ceiling beam against a ceiling, differs
    /// by 60-150 and is vetoed.
    ///
    /// The best-placed frame is compared against ITSELF here and always agrees, so every
    /// pixel that had any coverage still receives colour. The veto can only ever remove a
    /// second opinion, never the first — it cannot punch holes.
    ///
    /// The comparison is made on `comparisonScale` thumbnails, NOT on raw pixels, for
    /// reasons the seventh device run made unmissable — see there.
    /// REVERTED TO RUN 6 (2026-08-06), was 48. The colour veto did not exist at the sixth
    /// device run — it was written in response to that run's doubled chairs and first shipped
    /// for run 7. `.infinity` disables it: `disagreement` is finite, so the guard at the
    /// accumulation pass never rejects a rival. Restore 48 to re-enable.
    private static let agreementToleranceLevels: Float = .infinity

    /// Linear downscale factor of the per-frame thumbnail the agreement test compares.
    ///
    /// The seventh device run stitched a library carpet into hard-edged polygonal patches,
    /// with frame-frustum boundaries plainly visible as straight lines across the floor and
    /// the texture wiped flat inside some of them. The veto was firing on CARPET, which is
    /// not a parallax disagreement at all.
    ///
    /// The reason is that the first version of the test compared raw per-pixel colour, and
    /// carpet is high-frequency speckle. Two frames viewing the same square of carpet from
    /// viewpoints a few centimetres apart do not sample corresponding grains — the speckle
    /// simply does not correspond — so per-channel differences of 50-80 levels are normal
    /// there even though both frames are unambiguously seeing the same surface. Comparing
    /// raw pixels asks "is this the same speckle?", which is unanswerable across viewpoints.
    /// The question that has an answer is "is this the same surface?"
    ///
    /// Comparing a 4x-downscaled thumbnail asks that question instead. A 4x4 box average
    /// destroys speckle and sensor noise while preserving everything the veto actually needs
    /// to catch: a chair against a floor, or a beam against a ceiling, still differ by
    /// 60-150 levels at quarter resolution, because those are structures tens of pixels
    /// across. Cost is one O(pixels) pass per frame to build a 256x192 thumbnail, against
    /// the 8M-pixel canvas each frame is projected into twice.
    ///
    /// 8, raised from 4 once `exposureGains` landed. Before exposure matching, 8x measured
    /// no better than 4x and the coarser thumbnail was not worth taking on faith. With
    /// brightness differences removed from the comparison, 8x is cleanly better on BOTH
    /// axes — texture blotching 1.116 vs 1.211, anti-ghosting sharpness 12.49 vs 12.36 —
    /// and 16x falls back to 12.36, so 8 is the measured peak rather than an extreme.
    /// The two effects were confounded: exposure noise in the comparison was masking what a
    /// coarser low-pass could do.
    ///
    /// Lower toward 4 if genuinely doubled NEAR objects come back, since a coarser
    /// thumbnail also blurs away the smaller disagreements.
    private static let comparisonScale = 8

    /// Latitudes (radians, negative = below the horizon) between which the blend narrows
    /// from its normal behaviour down to a SINGLE frame, and below which exactly one
    /// frame — the best-placed — is allowed to paint at all.
    ///
    /// The bottom cap of the sphere is where the photographer is. The eighth device run
    /// rendered the user's own legs and feet as hard-edged wedges: a razor-straight
    /// diagonal across the denim, a triangle of chair seat, a leg drawn twice. No blend
    /// setting fixes that region, for two stacked reasons. Parallax is extreme — the
    /// subject is ~0.5 m away, so a 30 cm body pivot moves the viewpoint by more than half
    /// the subject distance, and the frames genuinely see different things. And the subject
    /// MOVES — it is the user's own body, which shifts as they turn, so there is no static
    /// scene for two frames to agree about even in principle. Every frame is telling the
    /// truth; there is simply no consistent answer to blend toward.
    ///
    /// When no correct blend exists, the only artifact-free output is a single source:
    /// one frame means zero inter-frame boundaries by construction. This is the standard
    /// resolution across the industry — Street View, Insta360's stitcher and Matterport
    /// all single-source the nadir, because the tripod or the operator is always down
    /// there. Nothing real is lost: the region being handed to one frame is exactly the
    /// region where blending had nothing coherent to add.
    ///
    /// The handover is ramped rather than switched. Between the two latitudes the
    /// dominance threshold rises continuously from its normal value to 1, so the blend
    /// narrows smoothly to the winner and no seam is drawn at the boundary line itself.
    /// −50°/−60° places the ramp below all furniture-height content (a desk 1 m away at
    /// eye height 1.5 m sits above −45°) while starting well above the user's feet.
    ///
    /// There is deliberately NO matching cap at the zenith: ceilings are far away, static,
    /// and blend fine — run 8's ceiling needed no help. Solo-sourcing it would discard
    /// real seam-hiding for no benefit.
    /// REVERTED TO RUN 6 (2026-08-06), was −50°/−60°. The bottom cap landed for run 8 and did
    /// not exist at run 6. Latitude never leaves [−90°, +90°], so putting the ramp below −90°
    /// makes `lat >= nadirNarrowLatRadians` true for every row: `rowDominance` stays at the
    /// plain `dominance` everywhere and the ramp arithmetic is never reached. Restore
    /// −50°/−60° to re-enable.
    private static let nadirNarrowLatRadians: Float = -91 * .pi / 180
    private static let nadirSoloLatRadians: Float = -92 * .pi / 180


    /// - Parameter dominance: overrides `dominanceThreshold`. Exposed only so the host
    ///   harness can sweep it and show what it buys; the app never passes it. 0 restores
    ///   the old behaviour of averaging every frame that sees a pixel.
    /// - Parameter agreement: overrides `agreementToleranceLevels`, same rationale.
    ///   `.infinity` disables the veto, which — together with `dominance: 0` — is the only
    ///   way to reproduce the plain weighted average the harness measures against. Without
    ///   this the two defences cannot be told apart, because the veto keeps working at
    ///   dominance 0 and there is no honest baseline left to compare with.
    static func stitch(
        frames: [CapturedFrame],
        originYaw: Float,
        /// Where the panorama is drawn FROM, in the same world frame as `CapturedFrame.transform`.
        /// Every frame's translation is measured against this, so it must be the sweep origin the
        /// user was told to pivot about. Defaults to the world origin, which is what the host
        /// tests use and what a zero-translation pivot reduces to.
        originPosition: SIMD3<Float> = .zero,
        width: Int = 4096,
        height: Int = 2048,
        dominance: Float = dominanceThreshold,
        agreement: Float = agreementToleranceLevels,
        comparison: Int = comparisonScale,
        // REVERTED TO RUN 6 (2026-08-06), was `true`. Per-frame exposure equalisation landed
        // for run 8 and did not exist at run 6. `false` substitutes a gain of 1 for every
        // frame, which is what the sixth-run stitcher did. Restore `true` to re-enable.
        exposure: Bool = false,
        seam: Float = seamSmoothnessWeight,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> Result? {
        guard !frames.isEmpty, width > 0, height > 0 else { return nil }

        let pixelCount = width * height
        let accumulator = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount * 3)
        let weights = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let peakWeights = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        // The colour the best-placed frame saw, kept so pass 2 can ask whether a rival
        // AGREES with it rather than only whether it is geometrically competitive.
        let peakColours = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount * 3)
        accumulator.initialize(repeating: 0, count: pixelCount * 3)
        weights.initialize(repeating: 0, count: pixelCount)
        peakWeights.initialize(repeating: 0, count: pixelCount)
        peakColours.initialize(repeating: 0, count: pixelCount * 3)
        defer {
            accumulator.deallocate()
            weights.deallocate()
            peakWeights.deallocate()
            peakColours.deallocate()
        }

        // Built once per frame and reused by both passes. This is the surface the agreement
        // test compares — never the full-resolution pixels. See `comparisonScale`.
        let thumbnails = frames.map { Thumbnail(frame: $0, scaleFactor: comparison) }

        // Per-frame exposure gains, estimated from the overlaps and applied consistently to
        // every sample this stitch takes — pass-1 records, pass-2 comparisons, and the
        // accumulated colour all see the same corrected values. See `exposureGains`.
        let gains = exposure
            ? exposureGains(frames: frames, thumbnails: thumbnails, agreement: agreement)
            : [Float](repeating: 1, count: frames.count)

        // Route the seams before anything is drawn. This decides WHERE authorship changes
        // hands; the passes below then honour that decision. `seam: 0` disables routing and
        // restores the per-pixel-argmax behaviour, which is how the harness measures what
        // routing is worth.
        let seamField = seam > 0
            ? routeSeams(frames: frames, thumbnails: thumbnails, gains: gains,
                         originYaw: originYaw, width: width, height: height,
                         smoothness: seam, tolerance: agreement)
            : nil

        // Pass 1 establishes, for every output pixel, how well the BEST-placed frame sees
        // it AND what that frame saw there. Nothing can be selected against the maximum
        // until the maximum is known, so this cannot be folded into the accumulation pass.
        // It samples colour only when a frame takes the lead at a pixel, so the fetch runs a
        // small number of times per pixel rather than once per covering frame.
        for (index, frame) in frames.enumerated() {
            project(frame: frame,
                    frameIndex: index,
                    thumbnail: thumbnails[index],
                    gain: gains[index],
                    seamField: seamField,
                    originYaw: originYaw,
                    originPosition: originPosition,
                    into: nil,
                    weights: peakWeights,
                    width: width,
                    height: height,
                    dominance: dominance,
                    agreement: agreement,
                    mode: .peak(colours: peakColours))
        }

        for (frameIndex, frame) in frames.enumerated() {
            project(frame: frame,
                    frameIndex: frameIndex,
                    thumbnail: thumbnails[frameIndex],
                    gain: gains[frameIndex],
                    seamField: seamField,
                    originYaw: originYaw,
                    originPosition: originPosition,
                    into: accumulator,
                    weights: weights,
                    width: width,
                    height: height,
                    dominance: dominance,
                    agreement: agreement,
                    mode: .accumulate(peak: peakWeights, peakColours: peakColours))
            progress?(Double(frameIndex + 1) / Double(frames.count))
        }

        return compose(accumulator: accumulator,
                       weights: weights,
                       width: width,
                       height: height,
                       frameCount: frames.count)
    }

    /// Which of the two projection passes is running.
    private enum ProjectionMode {
        /// Record the best weight any frame achieves at each pixel, and the colour that
        /// frame saw there — the reference the agreement test is made against.
        case peak(colours: UnsafeMutablePointer<Float>)
        /// Blend in the frames that are competitive against that best weight AND agree
        /// with it about what is there.
        case accumulate(peak: UnsafeMutablePointer<Float>, peakColours: UnsafeMutablePointer<Float>)
    }

    // MARK: - Hole filling

    /// One mip level: a colour image plus a per-pixel confidence in 0...1.
    private struct PyramidLevel {
        var width: Int
        var height: Int
        /// Row-major RGB, NOT premultiplied by `weight`.
        var colour: [Float]
        /// 0 where nothing is known, 1 where the level is fully determined.
        var weight: [Float]
    }

    /// Fills every uncovered pixel by interpolating the gap's border, via a pull-push
    /// image pyramid.
    ///
    /// An uncovered direction otherwise renders as pure BLACK, which reads as a tear in
    /// the room and is by far the most objectionable artefact a sweep can produce — much
    /// worse than a soft patch. Closing those gaps is therefore not cosmetic polish.
    ///
    /// Repeated dilation was the obvious approach and is the wrong tool: it costs a full
    /// 4096x2048 pass per PIXEL of gap radius, so the wedges a real handheld sweep leaves
    /// (hundreds of pixels across) would need hundreds of passes over 8.4M pixels — and a
    /// truncated dilation leaves the middle of every wedge still black, which is the exact
    /// failure it was added to prevent. Pull-push closes a hole of ANY size with one pass
    /// down the pyramid and one back up, ~1.33x the canvas in total work, and the fill is
    /// a smooth interpolation of the surrounding colour rather than an iterated blur.
    ///
    /// This does NOT invent detail and is not a substitute for covering the sphere.
    /// `Result.coverage` is measured before this runs, so the reported number stays honest
    /// about what the user actually captured.
    private static func fillHoles(
        rgb: UnsafeMutablePointer<Float>,
        covered: UnsafeMutablePointer<Bool>,
        width: Int,
        height: Int
    ) {
        let pixelCount = width * height
        var base = PyramidLevel(
            width: width,
            height: height,
            colour: [Float](repeating: 0, count: pixelCount * 3),
            weight: [Float](repeating: 0, count: pixelCount)
        )
        var anyMissing = false
        for index in 0 ..< pixelCount {
            guard covered[index] else {
                anyMissing = true
                continue
            }
            base.colour[index * 3] = rgb[index * 3]
            base.colour[index * 3 + 1] = rgb[index * 3 + 1]
            base.colour[index * 3 + 2] = rgb[index * 3 + 2]
            base.weight[index] = 1
        }
        // Nothing to fill, and no coarse level would have anything to say.
        guard anyMissing, base.weight.contains(where: { $0 > 0 }) else { return }

        var levels = [base]
        while levels[levels.count - 1].width > 1 || levels[levels.count - 1].height > 1 {
            levels.append(downsample(levels[levels.count - 1]))
        }

        for levelIndex in stride(from: levels.count - 2, through: 0, by: -1) {
            push(coarse: levels[levelIndex + 1], into: &levels[levelIndex])
        }

        let filled = levels[0]
        for index in 0 ..< pixelCount where !covered[index] && filled.weight[index] > 0 {
            rgb[index * 3] = filled.colour[index * 3]
            rgb[index * 3 + 1] = filled.colour[index * 3 + 1]
            rgb[index * 3 + 2] = filled.colour[index * 3 + 2]
            covered[index] = true
        }
    }

    /// Pull step: each coarse pixel is the confidence-weighted mean of its four children.
    private static func downsample(_ fine: PyramidLevel) -> PyramidLevel {
        let width = max(1, fine.width / 2)
        let height = max(1, fine.height / 2)
        var coarse = PyramidLevel(
            width: width,
            height: height,
            colour: [Float](repeating: 0, count: width * height * 3),
            weight: [Float](repeating: 0, count: width * height)
        )
        for y in 0 ..< height {
            for x in 0 ..< width {
                var r: Float = 0, g: Float = 0, b: Float = 0, w: Float = 0
                for dy in 0 ..< 2 {
                    let sy = min(fine.height - 1, y * 2 + dy)
                    for dx in 0 ..< 2 {
                        // Longitude wraps: the left and right edges are adjacent.
                        let sx = (x * 2 + dx) % fine.width
                        let source = sy * fine.width + sx
                        let sw = fine.weight[source]
                        guard sw > 0 else { continue }
                        r += fine.colour[source * 3] * sw
                        g += fine.colour[source * 3 + 1] * sw
                        b += fine.colour[source * 3 + 2] * sw
                        w += sw
                    }
                }
                guard w > 0 else { continue }
                let index = y * width + x
                coarse.colour[index * 3] = r / w
                coarse.colour[index * 3 + 1] = g / w
                coarse.colour[index * 3 + 2] = b / w
                // Divided by 4, so a coarse pixel only reaches full confidence when all
                // four children were known. A pixel backed by one child stays tentative
                // and is outvoted by better-supported neighbours on the way back down.
                coarse.weight[index] = min(1, w / 4)
            }
        }
        return coarse
    }

    /// Push step: fill each fine pixel's missing confidence from the coarser level.
    private static func push(coarse: PyramidLevel, into fine: inout PyramidLevel) {
        for y in 0 ..< fine.height {
            for x in 0 ..< fine.width {
                let index = y * fine.width + x
                let w = fine.weight[index]
                if w >= 1 { continue }

                // Half-pixel offsets: fine pixel centre (x+0.5) maps to coarse (x+0.5)/2.
                let up = bilinear(
                    coarse,
                    x: (Float(x) + 0.5) * 0.5 - 0.5,
                    y: (Float(y) + 0.5) * 0.5 - 0.5
                )
                let contribution = (1 - w) * up.weight
                let total = w + contribution
                guard total > 0 else { continue }
                let upColour: (Float, Float, Float) = up.colour
                let coarseChannels: [Float] = [upColour.0, upColour.1, upColour.2]
                for channel in 0 ..< 3 {
                    let existing: Float = fine.colour[index * 3 + channel] * w
                    let added: Float = coarseChannels[channel] * contribution
                    fine.colour[index * 3 + channel] = (existing + added) / total
                }
                fine.weight[index] = total
            }
        }
    }

    /// Confidence-weighted bilinear tap. Wraps in longitude, clamps in latitude.
    private static func bilinear(
        _ level: PyramidLevel,
        x: Float,
        y: Float
    ) -> (colour: (Float, Float, Float), weight: Float) {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)

        var r: Float = 0, g: Float = 0, b: Float = 0, w: Float = 0
        for dy in 0 ..< 2 {
            let sy = min(level.height - 1, max(0, y0 + dy))
            let wy = dy == 0 ? 1 - fy : fy
            for dx in 0 ..< 2 {
                let sx = ((x0 + dx) % level.width + level.width) % level.width
                let wx = dx == 0 ? 1 - fx : fx
                let index = sy * level.width + sx
                let tap = wx * wy * level.weight[index]
                guard tap > 0 else { continue }
                r += level.colour[index * 3] * tap
                g += level.colour[index * 3 + 1] * tap
                b += level.colour[index * 3 + 2] * tap
                w += tap
            }
        }
        guard w > 0 else { return ((0, 0, 0), 0) }
        return ((r / w, g / w, b / w), min(1, w))
    }

    // MARK: - Comparison thumbnail

    /// A box-averaged, `comparisonScale`-times-smaller copy of one frame, used ONLY by the
    /// agreement test. Never sampled for output colour — the panorama is always drawn from
    /// the full-resolution pixels, so this costs no sharpness anywhere.
    private struct Thumbnail {
        let width: Int
        let height: Int
        /// Row-major RGB, `width * height * 3` floats on a 0-255 scale.
        let pixels: [Float]
        /// Full-frame pixel coordinates times this land in thumbnail coordinates.
        let scale: Float

        init(frame: CapturedFrame, scaleFactor: Int) {
            let scaleFactor = max(1, scaleFactor)
            let w = max(1, frame.width / scaleFactor)
            let h = max(1, frame.height / scaleFactor)
            var out = [Float](repeating: 0, count: w * h * 3)
            frame.pixels.withUnsafeBufferPointer { source in
                guard let src = source.baseAddress else { return }
                for ty in 0 ..< h {
                    // Clamped so a frame size that is not an exact multiple of the scale
                    // still averages real pixels in its final row and column.
                    let y0 = ty * scaleFactor
                    let y1 = min(frame.height, y0 + scaleFactor)
                    for tx in 0 ..< w {
                        let x0 = tx * scaleFactor
                        let x1 = min(frame.width, x0 + scaleFactor)
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        var n: Float = 0
                        for y in y0 ..< y1 {
                            let rowBase = y * frame.width
                            for x in x0 ..< x1 {
                                let p = (rowBase + x) * 4
                                r += Float(src[p])
                                g += Float(src[p + 1])
                                b += Float(src[p + 2])
                                n += 1
                            }
                        }
                        guard n > 0 else { continue }
                        let o = (ty * w + tx) * 3
                        out[o] = r / n
                        out[o + 1] = g / n
                        out[o + 2] = b / n
                    }
                }
            }
            width = w
            height = h
            pixels = out
            scale = 1 / Float(scaleFactor)
        }

        /// Nearest-neighbour lookup in thumbnail space. Nearest rather than bilinear because
        /// the thumbnail is already a box average — interpolating a blur buys nothing and
        /// this runs inside the innermost loop.
        func sample(u: Float, v: Float) -> (Float, Float, Float) {
            let tx = min(width - 1, max(0, Int(u * scale)))
            let ty = min(height - 1, max(0, Int(v * scale)))
            let o = (ty * width + tx) * 3
            return (pixels[o], pixels[o + 1], pixels[o + 2])
        }
    }

    /// Total disagreement along the last routed seam. Diagnostic only, for the harness.
    nonisolated(unsafe) static var lastSeamCost: Float = 0

    /// The same total measured on the INITIAL labelling — the per-cell best-placed frame,
    /// which is exactly where the boundary fell before routing existed.
    ///
    /// Reported alongside `lastSeamCost` because the after-number alone is unreadable: it is
    /// large, scene-dependent, and has no natural scale. The pair is what says whether
    /// routing moved anything, and it is measured inside the same run on the same candidate
    /// set, so it cannot drift away from the thing it is the baseline for.
    nonisolated(unsafe) static var lastSeamCostBeforeRouting: Float = 0

    // MARK: - Seam routing

    /// Resolution divisor of the grid the seam is routed on. 4096x2048 / 16 = 256x128 cells.
    ///
    /// The seam does not need pixel precision — it needs to run AROUND a hand rather than
    /// through it, and a hand is hundreds of pixels across. A coarse grid is what makes the
    /// optimisation affordable: candidate colours for several frames per cell fit easily at
    /// 33k cells and would be gigabytes at full resolution.
    /// Internal so `Tests/ParallaxSharpness` can ask where the label grid's cell edges fall.
    /// A test that hardcoded 16 would stop measuring the grid the moment this changed.
    static let seamScale = 16

    /// How many frames compete for each cell. A direction is typically seen by ~5 frames,
    /// but the seam only ever chooses between the best few — a sixth-best frame is never
    /// the right answer, and carrying it costs memory and optimisation time.
    private static let seamCandidates = 4

    /// Relative price of putting a seam somewhere the two frames disagree, against the
    /// price of using a less well-placed frame.
    ///
    /// **DEFAULT 0.10 — seam routing is ON.** It was 0 while the minimiser was iterated
    /// conditional modes, which bought a 4.5% reduction in boundary disagreement for a 3.4%
    /// LOSS of sharpness. Replacing ICM with alpha-expansion over a max-flow reversed both
    /// signs. Measured on `Tests/ParallaxSharpness`, seam cost quoted as
    /// before-routing -> after:
    ///
    ///     smoothness   seam cost           sharpness   blotch   cap edges
    ///     0 (off)      148836              12.49       1.116    0.0131
    ///     0.02         148836 ->  84614    12.71       1.116    0.0131
    ///     0.05         148836 ->  74076    13.16       1.116    0.0131
    ///     0.10  <- SHIPPING  ->  69011     13.46       1.116    0.0131
    ///     0.25         148836 ->  64282    13.87       1.116    0.0131
    ///     1.00         148836 ->  57292    14.33       1.116    0.0131
    ///
    /// ICM moved the objective 4.5%; alpha-expansion moves it 54%, and sharpness rises
    /// rather than falls because a routed region is painted by ONE frame consistently
    /// instead of cross-fading between two wherever their frusta happen to meet.
    ///
    /// **0.10 is derived, not taken from the top of that table.** Sharpness there keeps
    /// climbing to 1.00 and the number is not to be believed: every frame in that scene is
    /// rendered at identical quality, so it cannot see the cost of letting one frame claim
    /// ground far outside its sweet spot — the same blindness that made `dominance` 0.70
    /// look best on the same test and get rejected. The data term is bounded by 1 per cell
    /// while a boundary term is `smoothness * colour distance`, so the ratio fixes how far
    /// the seam may detour: at 0.10 a boundary through content disagreeing at exactly the
    /// veto tolerance (48 levels) costs 4.8 cells' worth of placement quality, so the router
    /// will walk up to about five cells around a hand and no further. Raising it buys a
    /// quieter seam by using worse-placed frames, which no test here prices.
    ///
    /// Routing is gated two ways, and both are measured rather than assumed — see
    /// `SeamField.contested` (it does nothing where frames agree, which is what keeps the
    /// run-7 carpet patchwork closed) and the `rowDominance < 1` guard in `project` (it
    /// stops at the solo nadir cap, which measures better there).
    /// REVERTED TO 0 AFTER THREE DEVICE RUNS (2026-08-06). Routing is off by default again.
    ///
    /// Runs 11, 12 and 13 all shipped routing ON and all three were judged worse than run 9,
    /// which had it OFF — run 13 by the user, unprompted, as "the worst run so far". That is
    /// three independent real-scene verdicts against it and zero for it. The synthetic tests
    /// still say routing wins, and the honest reading is that they are measuring the wrong
    /// thing: `boundaryCost` is routing's own objective function, so of course routing
    /// lowers it, and `ParallaxSharpness` scores a synthetic grating that contains no long
    /// straight architecture for a 16-px-quantised boundary to visibly cut across. Neither
    /// measures the artifact the user is actually looking at.
    ///
    /// That artifact is a staircase. The label grid is `seamScale` = 16 px at 4096 wide, and
    /// `share`/`contestedFraction` ramp over ONE cell, so every routed boundary is a diagonal
    /// quantised to 16-px steps with a 16-px ramp. Feathering the gate (see
    /// `contestedFraction`) removed the axis-aligned block edges between the two paths and
    /// did nothing about this, because this is the label field itself, not the gate. Run 13
    /// shows the steps plainly along desk edges and window beams.
    ///
    /// This is a REVERT, not a deletion. Everything routing needs is still here and still
    /// tested — `GraphCut`, `routeSeams`, `dropSliverTerritories`, `contestedFraction` — and
    /// setting this back to 0.10 re-enables all of it. `Tests/ParallaxSharpness` and
    /// `Tests/TextureBlotching` both confirm 0 reproduces the pre-routing output exactly
    /// (sharpness 12.49, blotch 1.116, hardness 5.174 — identical to the unrouted rows), so
    /// this restores run 9's stitcher rather than approximating it.
    ///
    /// DO NOT turn this back on without first shrinking `seamScale` and proving on a device
    /// that the staircase is gone. Turning it on for a better `boundaryCost` is what produced
    /// three bad runs.
    private static let seamSmoothnessWeight: Float = 0

    /// What the app actually ships, for tests that must score the DEFAULT rather than a value
    /// they chose themselves. Every seam number in this suite used to come from a call that
    /// passed `seam:` explicitly, so none of them could notice this constant moving — which is
    /// precisely how routing shipped to three device runs on the strength of numbers that were
    /// never measuring it.
    static var shippingSeamWeight: Float { seamSmoothnessWeight }

    /// Passes over the full label set, each pass running one alpha-expansion per candidate
    /// label.
    ///
    /// Alpha-expansion converges fast — the first cycle does nearly all the work because
    /// every label gets to claim its best region against a field that has not yet been
    /// contested. Later cycles only trade small boundaries back and forth. The loop also
    /// breaks early the moment a whole cycle moves nothing, so this is a ceiling rather than
    /// a cost: on the test scenes it exits after two or three.
    private static let seamCycles = 4

    /// Which frame owns each direction, chosen so that authorship changes hands where the
    /// frames AGREE rather than wherever their frusta happen to cross.
    ///
    /// This is the piece that was missing from every earlier defence. Feather, dominance,
    /// drift pricing, the agreement veto and the nadir cap all answer "WHICH frame wins this
    /// pixel". None answers "WHERE does it stop winning", so the boundary fell where the
    /// geometry put it — straight through a hand, a face, a leg. With a non-static scene
    /// (people move between frames) that duplicates a person, slices a hand in half, and
    /// leaves a body partly present, which is exactly what the ninth device run showed.
    ///
    /// The field is built by minimising, over the whole grid at once,
    ///     sum over cells of  dataCost(cell, label)
    ///   + sum over neighbours of  seamSmoothnessWeight * disagreement(label_p, label_q)
    /// where `dataCost` is how far from best-placed the chosen frame is, and `disagreement`
    /// is how differently the two frames see that spot. A boundary between two frames that
    /// agree costs nothing, so the seam is free to run along it; a boundary through a hand
    /// costs a great deal, so it detours. This is the classic minimum-error-boundary
    /// criterion that separates a stitcher from a reprojector.
    private struct SeamField {
        let width: Int
        let height: Int
        /// Frame index owning each cell, or -1 where no frame saw it.
        let labels: [Int32]

        /// Whether the candidate frames actually disagree about this cell, dilated by one
        /// cell so a contested region's transition ramp lies wholly inside it.
        ///
        /// Routing is a defence against DISAGREEMENT, so it engages exactly where
        /// disagreement exists — the same principle the colour veto already runs on, and
        /// tested against the same tolerance. Everywhere else it is switched off and the
        /// ordinary dominance blend paints, because where frames agree that blend is
        /// strictly better: it feathers smoothly per pixel, while a label field is a
        /// partition of a 16-pixel grid and hands over across a single cell.
        ///
        /// Measured, and the reason this flag exists at all. Routing everywhere costs
        /// `Tests/TextureBlotching` 1.116 -> 1.58 blotch and 5.17 -> 7.81 hardness on a wall
        /// of pure speckle — most of the way back to the run-7 carpet patchwork that is
        /// supposed to be closed. Nothing on that wall genuinely disagrees, so every
        /// territory the router drew there was an artifact it invented.
        ///
        /// The gate does not need its own feathering: it fires where disagreement crosses
        /// the veto tolerance, and at that point the two paths are choosing between frames
        /// that agree to within that tolerance, so they produce near-identical colour. The
        /// switch is invisible by the same argument that makes the veto safe.
        let contested: [Bool]

        /// How much of this pixel lies in a region worth routing, in 0...1.
        ///
        /// Bilinear over the same grid and by the same rule as `share`, and for the same
        /// reason. This started as a hard nearest-cell test returning Bool, which made the
        /// GATE a step even though everything behind it was a ramp: the routed and dominance
        /// paths produce different colour, so switching between them along a 16-px cell
        /// boundary drew that boundary. Run 11 is what proved it — rectangular chunks eating
        /// into the wooden window beams and the ceiling panels, and a clean staircase along
        /// the edge of every sliver, all on axis-aligned block edges no scene contains.
        ///
        /// The reasoning that justified the step is in `contested` and it was not wrong, only
        /// incomplete: where the gate fires the two frames agree to within the veto tolerance,
        /// so the two paths pick near-identical COLOUR. But they do not pick identical
        /// WEIGHT — the routed path contributes `share`, the dominance path contributes a
        /// shaped `relative`, and those differ by much more than the tolerance. Feathering the
        /// gate costs nothing at either extreme: at 1 this is exactly the old routed path, at
        /// 0 exactly the old dominance path, so only the cell edge itself can change.
        @inline(__always)
        func contestedFraction(x: Int, y: Int, scale: Int) -> Float {
            let fx = (Float(x) + 0.5) / Float(scale) - 0.5
            let fy = (Float(y) + 0.5) / Float(scale) - 0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let tx = fx - Float(x0), ty = fy - Float(y0)

            var total: Float = 0
            for (dy, wy) in [(0, 1 - ty), (1, ty)] {
                let cy = min(height - 1, max(0, y0 + dy))
                for (dx, wx) in [(0, 1 - tx), (1, tx)] {
                    // Longitude wraps; latitude clamps. Same convention as `share`, and it
                    // must stay the same: the two are sampled at the same pixel and a
                    // disagreement about which cell that is would misalign the ramp with the
                    // labels it gates.
                    let cx = ((x0 + dx) % width + width) % width
                    if contested[cy * width + cx] { total += wx * wy }
                }
            }
            return total
        }

        /// Fraction of pixel (x, y) that belongs to `frame`, in 0...1.
        ///
        /// Bilinear over the four surrounding cells, which turns the hard label boundary
        /// into a ramp about one cell wide and makes the labels a partition of unity: the
        /// fractions across all frames sum to 1 wherever the grid is covered. That is what
        /// stops the routed seam from being a visible line of its own — the thing the
        /// per-pixel nadir cap got wrong when it removed blending entirely.
        @inline(__always)
        func share(frame: Int32, x: Int, y: Int, scale: Int) -> Float {
            let fx = (Float(x) + 0.5) / Float(scale) - 0.5
            let fy = (Float(y) + 0.5) / Float(scale) - 0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let tx = fx - Float(x0), ty = fy - Float(y0)

            var total: Float = 0
            for (dy, wy) in [(0, 1 - ty), (1, ty)] {
                let cy = min(height - 1, max(0, y0 + dy))
                for (dx, wx) in [(0, 1 - tx), (1, tx)] {
                    // Longitude wraps; latitude clamps.
                    let cx = ((x0 + dx) % width + width) % width
                    if labels[cy * width + cx] == frame { total += wx * wy }
                }
            }
            return total
        }
    }

    /// Builds the label field. Returns nil when there is nothing to route (a single frame,
    /// or a grid too small to have neighbours), in which case the caller keeps the
    /// per-pixel peak behaviour.
    private static func routeSeams(
        frames: [CapturedFrame],
        thumbnails: [Thumbnail],
        gains: [Float],
        originYaw: Float,
        width: Int,
        height: Int,
        smoothness: Float,
        tolerance: Float
    ) -> SeamField? {
        guard frames.count > 1 else { return nil }
        let gridW = max(1, width / seamScale)
        let gridH = max(1, height / seamScale)
        guard gridW > 1, gridH > 1 else { return nil }
        let cells = gridW * gridH
        let k = seamCandidates

        // Top-k candidates per cell, flat. -1 marks an unused slot.
        var candFrame = [Int32](repeating: -1, count: cells * k)
        var candWeight = [Float](repeating: 0, count: cells * k)
        var candColour = [Float](repeating: 0, count: cells * k * 3)

        // Cell centre directions, precomputed once — reused by every frame.
        var directions = [SIMD3<Float>](repeating: .zero, count: cells)
        for gy in 0 ..< gridH {
            let lat = .pi / 2 - (Float(gy) + 0.5) / Float(gridH) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            for gx in 0 ..< gridW {
                let lon = (Float(gx) + 0.5) / Float(gridW) * 2 * .pi - .pi
                let local = SIMD3(cosLat * sin(lon), sinLat, -cosLat * cos(lon))
                directions[gy * gridW + gx] = SweepFrame.toWorld(local, originYaw: originYaw)
            }
        }

        for (index, frame) in frames.enumerated() {
            guard let projector = FrameProjector(frame: frame) else { continue }
            let thumbnail = thumbnails[index]
            let gain = gains[index]
            for cell in 0 ..< cells {
                guard let hit = projector.sample(world: directions[cell]) else { continue }
                guard hit.weight > 0 else { continue }
                // Insertion into the top-k, smallest slot first.
                var slot = -1
                var worst: Float = hit.weight
                for j in 0 ..< k {
                    let base = cell * k + j
                    if candFrame[base] < 0 { slot = j; worst = -1; break }
                    if candWeight[base] < worst { worst = candWeight[base]; slot = j }
                }
                guard slot >= 0 else { continue }
                let base = cell * k + slot
                let colour = thumbnail.sample(u: hit.u, v: hit.v)
                candFrame[base] = Int32(index)
                candWeight[base] = hit.weight
                candColour[base * 3 + 0] = colour.0 * gain
                candColour[base * 3 + 1] = colour.1 * gain
                candColour[base * 3 + 2] = colour.2 * gain
            }
        }

        // Initial labels: the best-placed frame, i.e. exactly what the code did before seam
        // routing existed. The optimisation only ever moves labels away from this when doing
        // so buys more in seam quality than it costs in placement.
        var labels = [Int32](repeating: -1, count: cells)
        var peak = [Float](repeating: 0, count: cells)
        for cell in 0 ..< cells {
            var bestWeight: Float = 0
            var bestFrame: Int32 = -1
            for j in 0 ..< k {
                let base = cell * k + j
                guard candFrame[base] >= 0 else { continue }
                if candWeight[base] > bestWeight {
                    bestWeight = candWeight[base]
                    bestFrame = candFrame[base]
                }
            }
            labels[cell] = bestFrame
            peak[cell] = bestWeight
        }

        /// Colour this cell's candidate `frame` saw, if it is a candidate here.
        @inline(__always)
        func colour(cell: Int, frame: Int32) -> (Float, Float, Float)? {
            for j in 0 ..< k {
                let base = cell * k + j
                if candFrame[base] == frame {
                    return (candColour[base * 3], candColour[base * 3 + 1],
                            candColour[base * 3 + 2])
                }
            }
            return nil
        }

        /// How competitive `frame` is at this cell, 0 when it is not a candidate here.
        @inline(__always)
        func weight(cell: Int, frame: Int32) -> Float {
            for j in 0 ..< k where candFrame[cell * k + j] == frame {
                return candWeight[cell * k + j]
            }
            return 0
        }

        /// How differently `a` and `b` see one cell, or nil when the cell cannot compare
        /// them because one of them is not a candidate there.
        @inline(__always)
        func distance(cell: Int, _ a: Int32, _ b: Int32) -> Float? {
            guard let ca = colour(cell: cell, frame: a),
                  let cb = colour(cell: cell, frame: b) else { return nil }
            return max(abs(ca.0 - cb.0), max(abs(ca.1 - cb.1), abs(ca.2 - cb.2)))
        }

        // Cost of putting a boundary between `a` and `b` on the edge joining two cells: how
        // differently the two frames see that spot.
        //
        // Evaluated at BOTH cells and averaged when both can compare. Checking only one cell
        // looks right and is not: at a boundary the neighbour's frame is frequently absent
        // from this cell's top-k, so the comparison silently returned 0 and the optimiser
        // felt no pressure at precisely the boundaries it exists to move. Averaging also
        // makes the cost symmetric in the two cells, which matters now that it is a graph
        // edge weight rather than a term in a per-cell scan.
        //
        // When neither cell can compare them the two frames barely overlap here, so the
        // boundary is forced rather than chosen and is priced at zero — otherwise the
        // optimiser would pay to avoid coverage edges it has no power to move.
        @inline(__always)
        func disagreement(_ p: Int, _ q: Int, _ a: Int32, _ b: Int32) -> Float {
            guard a != b else { return 0 }
            switch (distance(cell: p, a, b), distance(cell: q, a, b)) {
            case let (dp?, dq?): return 0.5 * (dp + dq)
            case let (dp?, nil): return dp
            case let (nil, dq?): return dq
            case (nil, nil): return 0
            }
        }

        /// Every label that is a candidate somewhere. Only these can ever be expanded onto,
        /// and each one only reaches the cells that actually list it — which is what keeps a
        /// per-label max-flow affordable. A frame spans roughly 6% of the sphere, so its
        /// expansion graph is a few thousand cells, not the whole 32k grid.
        var labelSet = Set<Int32>()
        for label in candFrame where label >= 0 { labelSet.insert(label) }
        let expansionLabels = labelSet.sorted()

        /// One alpha-expansion move: every cell simultaneously decides whether to switch to
        /// `alpha` or keep what it has, and the globally best such decision is the minimum
        /// cut of the graph built below. Returns whether anything moved.
        ///
        /// This is the whole point of the rewrite. Iterated conditional modes asked each cell
        /// the same question alone, and flipping one cell in isolation creates two new
        /// boundaries where flipping a whole region creates none — so the field never left
        /// its initial argmax labelling and the seam cost barely moved. A cut moves regions.
        func expand(alpha: Int32) -> Bool {
            // Cells where alpha could plausibly win. Everywhere else it is not a candidate,
            // so its data cost is infinite and the answer is forced — excluding those cells
            // from the graph is the same optimisation, much smaller.
            var node = [Int32](repeating: -1, count: cells)
            var cellOf: [Int32] = []
            for cell in 0 ..< cells where labels[cell] >= 0 && peak[cell] > 0 {
                guard weight(cell: cell, frame: alpha) > 0 else { continue }
                node[cell] = Int32(cellOf.count)
                cellOf.append(Int32(cell))
            }
            guard cellOf.count > 1 else { return false }

            let count = cellOf.count
            let source = count, sink = count + 1
            // Cost charged when the cell ends on the SINK side (keeps its label) and on the
            // SOURCE side (takes alpha), respectively.
            var keepCost = [Float](repeating: 0, count: count)
            var takeCost = [Float](repeating: 0, count: count)

            /// Adds a cost incurred only when the node takes alpha. Negative values are legal
            /// in the reparameterised pairwise form below; a capacity is not, so a negative
            /// is folded into the opposite terminal instead, which shifts the energy by a
            /// constant and leaves the minimiser unchanged.
            @inline(__always)
            func chargeIfTaken(_ n: Int, _ cost: Float) {
                if cost >= 0 { takeCost[n] += cost } else { keepCost[n] -= cost }
            }

            let graph = MaxFlow(nodes: count + 2)

            // Data term: how far from best-placed the chosen frame is here. Unchanged from
            // the ICM version, so feather, dominance and drift pricing still decide the label
            // and the seam term only breaks ties and detours.
            for n in 0 ..< count {
                let cell = Int(cellOf[n])
                keepCost[n] += 1 - weight(cell: cell, frame: labels[cell]) / peak[cell]
                takeCost[n] += 1 - weight(cell: cell, frame: alpha) / peak[cell]
            }

            // Pairwise terms. Each undirected grid edge is visited once, as (cell, right) and
            // (cell, below); longitude wraps, latitude does not.
            for cell in 0 ..< cells where labels[cell] >= 0 {
                let gx = cell % gridW, gy = cell / gridW
                var neighbours = [gy * gridW + ((gx + 1) % gridW)]
                if gy < gridH - 1 { neighbours.append((gy + 1) * gridW + gx) }

                for other in neighbours where labels[other] >= 0 {
                    let np = node[cell], nq = node[other]
                    let fp = labels[cell], fq = labels[other]

                    // Only one side can move: the other's label is fixed, so the term
                    // collapses to a plain unary on whichever side is in the graph.
                    if np < 0 || nq < 0 {
                        if np >= 0 {
                            keepCost[Int(np)] += smoothness * disagreement(cell, other, fp, fq)
                            takeCost[Int(np)] += smoothness * disagreement(cell, other, alpha, fq)
                        } else if nq >= 0 {
                            keepCost[Int(nq)] += smoothness * disagreement(cell, other, fp, fq)
                            takeCost[Int(nq)] += smoothness * disagreement(cell, other, fp, alpha)
                        }
                        continue
                    }

                    // Both sides can move. The binary term over (keep, take) is
                    //   both keep -> V(fp, fq)     p keeps, q takes -> V(fp, alpha)
                    //   p takes, q keeps -> V(alpha, fq)     both take -> 0
                    // which a graph can represent only if it is submodular:
                    //   V(fp, fq) <= V(fp, alpha) + V(alpha, fq).
                    // That is the triangle inequality, and it holds whenever all three are
                    // measured against a common cell — but the pair costs fall back to
                    // whichever cell can compare them, so it can fail. Truncating the
                    // both-keep term to the sum restores submodularity by construction. It
                    // can only UNDER-price an existing boundary, never invent one, so the
                    // worst case is a seam left where it was.
                    let both = smoothness * disagreement(cell, other, fp, fq)
                    let pKeeps = smoothness * disagreement(cell, other, fp, alpha)
                    let qKeeps = smoothness * disagreement(cell, other, alpha, fq)
                    let anchored = min(both, pKeeps + qKeeps)

                    // Kolmogorov-Zabih reparameterisation of a submodular binary term into
                    // two unaries and one directed edge — no auxiliary node needed.
                    chargeIfTaken(Int(np), qKeeps - anchored)
                    chargeIfTaken(Int(nq), -qKeeps)
                    // Charged when q takes alpha and p does not, which is exactly when an
                    // edge from q to p crosses the cut.
                    graph.addEdge(from: Int(nq), to: Int(np),
                                  capacity: pKeeps + qKeeps - anchored)
                }
            }

            for n in 0 ..< count {
                graph.addEdge(from: source, to: n, capacity: keepCost[n])
                graph.addEdge(from: n, to: sink, capacity: takeCost[n])
            }

            graph.solve(source: source, sink: sink)
            let takesAlpha = graph.sourceSide(source: source)

            var moved = false
            for n in 0 ..< count where takesAlpha[n] {
                let cell = Int(cellOf[n])
                if labels[cell] != alpha {
                    labels[cell] = alpha
                    moved = true
                }
            }
            return moved
        }

        /// Total disagreement along whatever boundaries the current labelling produces. This
        /// is the quantity routing minimises, and it is the honest measure of whether the
        /// seam runs through agreeing ground — a hard-edge PIXEL COUNT cannot tell "seam
        /// through a hand" from "seam along a shadow", because both are hard edges.
        func boundaryCost() -> Float {
            var total: Float = 0
            for gy in 0 ..< gridH {
                for gx in 0 ..< gridW {
                    let cell = gy * gridW + gx
                    guard labels[cell] >= 0 else { continue }
                    let rc = gy * gridW + ((gx + 1) % gridW)
                    if labels[rc] >= 0 {
                        total += disagreement(cell, rc, labels[cell], labels[rc])
                    }
                    if gy < gridH - 1 {
                        let dc = (gy + 1) * gridW + gx
                        if labels[dc] >= 0 {
                            total += disagreement(cell, dc, labels[cell], labels[dc])
                        }
                    }
                }
            }
            return total
        }

        lastSeamCostBeforeRouting = boundaryCost()

        if smoothness > 0 {
            for _ in 0 ..< seamCycles {
                var moved = false
                for alpha in expansionLabels where expand(alpha: alpha) { moved = true }
                if !moved { break }
            }
        }

        // After the expansion, not instead of it: the optimiser is what draws good boundaries,
        // and this only removes the islands it had no term to price. Before `boundaryCost` so
        // the reported seam cost is the cost of what actually gets painted.
        labels = dropSliverTerritories(labels, gridW: gridW, gridH: gridH)

        lastSeamCost = boundaryCost()

        // Where do the candidates actually disagree? Measured as the widest gap between any
        // two candidates at a cell, against the same tolerance the colour veto uses — the
        // two are answering the same question about the same thumbnails, so they must not
        // use different numbers for "these frames show different things".
        var raw = [Bool](repeating: false, count: cells)
        for cell in 0 ..< cells {
            var worst: Float = 0
            for a in 0 ..< k where candFrame[cell * k + a] >= 0 {
                for b in (a + 1) ..< k where candFrame[cell * k + b] >= 0 {
                    worst = max(worst, distance(cell: cell,
                                                candFrame[cell * k + a],
                                                candFrame[cell * k + b]) ?? 0)
                }
            }
            raw[cell] = worst > tolerance
        }

        // Dilate by one cell so the bilinear ramp out of a contested region is itself routed;
        // without this the ramp's outer half falls in unrouted cells and the handover is a
        // step again.
        var contested = raw
        for gy in 0 ..< gridH {
            for gx in 0 ..< gridW where !raw[gy * gridW + gx] {
                let left = gy * gridW + ((gx - 1 + gridW) % gridW)
                let right = gy * gridW + ((gx + 1) % gridW)
                var near = raw[left] || raw[right]
                if gy > 0 { near = near || raw[(gy - 1) * gridW + gx] }
                if gy < gridH - 1 { near = near || raw[(gy + 1) * gridW + gx] }
                contested[gy * gridW + gx] = near
            }
        }

        return SeamField(width: gridW, height: gridH, labels: labels, contested: contested)
    }

    /// Smallest connected run of cells that counts as a frame's territory. Anything smaller
    /// is handed back to whichever label surrounds it.
    ///
    /// One frame covers roughly 6% of the sphere, so on the 256x128 grid a real territory is
    /// hundreds of cells. Run 11 produced the counter-example this exists for: thin dark
    /// blade-shaped ghosts of the operator's own forearm and phone lying across the floor,
    /// each a few dozen cells. The router was not malfunctioning — it detoured the seam around
    /// an object the frames disagreed about, which is precisely its job. But the object was
    /// the operator, present in some frames and absent from others, so the region it fenced
    /// off preserved a body part instead of a piece of the room.
    ///
    /// Nothing in the energy can tell those apart: a sliver of forearm and a sliver of genuine
    /// occlusion boundary look identical to a term that only knows colour disagreement. Size
    /// can. A frame that legitimately owns ground owns a lot of it, contiguously; an island
    /// this small means the data term found one good cell in a place its neighbours disown,
    /// and that is an artifact whatever produced it.
    ///
    /// Deliberately NOT a thinness test (perimeter^2/area), which was the first idea. Real
    /// territories are thin all the time — the overlap wedge between two adjacent frames in a
    /// ring is a long thin strip, and penalising it would undo the routing everywhere it works.
    ///
    /// Internal rather than private, with `dropSliverTerritories`, so `Tests/SeamTerritory`
    /// can drive the cleanup directly. Reaching it through `stitch` would mean building a
    /// scene whose alpha-expansion happens to produce an island, which pins the optimiser's
    /// current behaviour rather than the cleanup's — the test would break every time the
    /// energy changed, without ever having checked wrapping, ties or order independence.
    static let minTerritoryCells = 64

    /// Reassigns every connected label component smaller than `minTerritoryCells` to the label
    /// it borders most, leaving larger territories exactly as the expansion left them.
    ///
    /// Four-connected, wrapping in longitude and clamping in latitude, matching the grid the
    /// pairwise terms were built on. Components are found once on the incoming labels and all
    /// reassignments are written to a copy, so the result cannot depend on the order cells are
    /// visited in — an in-place version let one dissolved island change the majority vote of
    /// the next, which made the output depend on scan order.
    ///
    /// A component with no labelled neighbour at all is left alone: there is nothing to hand
    /// it to, and blanking it would open a hole for the filler to invent.
    ///
    /// Returns a new field rather than mutating in place: `labels` is captured by the local
    /// `expand` and `boundaryCost` closures at the call site, and passing a captured var as
    /// `inout` is an exclusivity violation.
    static func dropSliverTerritories(
        _ original: [Int32], gridW: Int, gridH: Int
    ) -> [Int32] {
        let cells = gridW * gridH
        guard cells > 0, cells == original.count, minTerritoryCells > 1 else { return original }
        // On a grid small enough that 64 cells is a large fraction of it, "smaller than 64"
        // stops meaning "an island" and starts meaning "any territory at all", and the
        // cleanup would silently flatten the whole field to one label. `routeSeams` only
        // requires a 2x2 grid, so nothing upstream rules this out. The shipping 4096x2048
        // panorama gives 256x128 = 32768 cells, four hundred times the floor.
        guard cells >= minTerritoryCells * 4 else { return original }
        var labels = original

        /// The four grid neighbours of a cell: longitude wraps, latitude does not.
        @inline(__always)
        func neighbours(_ cell: Int) -> [Int] {
            let gy = cell / gridW, gx = cell % gridW
            var out = [gy * gridW + ((gx + 1) % gridW),
                       gy * gridW + ((gx - 1 + gridW) % gridW)]
            if gy > 0 { out.append((gy - 1) * gridW + gx) }
            if gy < gridH - 1 { out.append((gy + 1) * gridW + gx) }
            return out
        }

        var visited = [Bool](repeating: false, count: cells)
        var component: [Int] = []
        var stack: [Int] = []

        for seed in 0 ..< cells where !visited[seed] && original[seed] >= 0 {
            let label = original[seed]
            component.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            visited[seed] = true

            // Flood fill, iterative — a 32k-cell grid can be one component and recursion here
            // would be a stack overflow on the largest input rather than the commonest one.
            // Counts how many cells of each OTHER label the component touches while walking,
            // so the majority vote costs nothing extra.
            var borderVotes: [Int32: Int] = [:]
            while let cell = stack.popLast() {
                component.append(cell)
                for next in neighbours(cell) {
                    let other = original[next]
                    if other == label {
                        if !visited[next] { visited[next] = true; stack.append(next) }
                    } else if other >= 0 {
                        borderVotes[other, default: 0] += 1
                    }
                }
            }

            guard component.count < minTerritoryCells else { continue }
            // Ties broken by the lower frame index so the result is deterministic; without
            // this a Dictionary's iteration order decides, and two runs of the same stitch
            // could differ.
            guard let winner = borderVotes.max(by: {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            })?.key else { continue }
            for cell in component { labels[cell] = winner }
        }
        return labels
    }

    // MARK: - Parallax correction

    /// Fixed-point passes resolving "which pixel of this frame shows the point on the ray I am
    /// drawing". Three, because the iteration contracts by roughly `offset / range` per pass:
    /// at the 0.10 m the tightened drift warning now allows and a 0.5 m object, that is a factor
    /// of five per pass, so three passes take a 350 px error below a tenth of a pixel. More
    /// passes cost time and buy nothing; `Tests/ParallaxTruth` sweeps the count and shows the
    /// curve flat after three.
    private static let parallaxIterations = 3

    /// Stop early once a pass moves the sample less than this. Most pixels are far away and
    /// converge on the first pass; only near objects need all three.
    private static let parallaxConvergencePixels: Float = 0.05

    /// ARKit confidence is .low/.medium/.high as 0/1/2, normalised to 0...1 here. Medium and
    /// above only: a wrong depth actively moves a pixel AWAY from the truth, while no depth
    /// merely leaves it where the old rotation-only model put it. Falling back is the safe
    /// failure, so the bar to override it is set high.
    private static let minDepthConfidence: Float = 0.5

    /// Reads metric depth out of a frame and turns a pixel into a range from the panorama
    /// centre. Nil for frames that carry no depth, which is every frame on a device without
    /// LiDAR and every frame in the host tests that predate this.
    private struct DepthSampler {
        let depths: [Float]
        let confidence: [Float]?
        let width: Int
        let height: Int
        let scaleX: Float
        let scaleY: Float

        init?(frame: CapturedFrame) {
            guard let depths = frame.depths,
                  frame.depthWidth > 1, frame.depthHeight > 1,
                  depths.count == frame.depthWidth * frame.depthHeight,
                  frame.width > 0, frame.height > 0
            else { return nil }
            self.depths = depths
            self.confidence = frame.depthConfidence?.count == depths.count
                ? frame.depthConfidence : nil
            self.width = frame.depthWidth
            self.height = frame.depthHeight
            // The depth map is its own resolution — ARKit's is 256x192 against a colour frame
            // up to 1024 wide — so pixel coordinates are mapped by ratio rather than assumed
            // equal. Getting this backwards would scale every correction by ~4.
            self.scaleX = Float(frame.depthWidth) / Float(frame.width)
            self.scaleY = Float(frame.depthHeight) / Float(frame.height)
        }

        /// Distance from `originPosition` to the scene point this frame sees at (u, v).
        ///
        /// Nearest-neighbour, not bilinear, and deliberately: depth maps are piecewise smooth
        /// with hard jumps at occlusion boundaries, and interpolating across one invents a
        /// surface at a range nothing occupies — precisely the flying-fragment artifact this
        /// change exists to remove.
        @inline(__always)
        func range(
            u: Float, v: Float, rotation: simd_float3x3, cameraPosition: SIMD3<Float>,
            originPosition: SIMD3<Float>, fx: Float, fy: Float, cx: Float, cy: Float
        ) -> Float? {
            let dx = Int(u * scaleX), dy = Int(v * scaleY)
            guard dx >= 0, dx < width, dy >= 0, dy < height else { return nil }
            let index = dy * width + dx
            if let confidence, confidence[index] < minDepthConfidence { return nil }
            let d = depths[index]
            // ARKit reports 0 where it has no return at all — glass, a mirror, or beyond range.
            guard d.isFinite, d > 0.05, d < 30 else { return nil }

            // Pixel -> camera ray -> world point. `d` is along the optical axis, not along the
            // ray, which is why x and y are scaled by d rather than the ray being normalised.
            let camPoint = SIMD3(((u - cx) / fx) * d, -((v - cy) / fy) * d, -d)
            let world = rotation * camPoint + cameraPosition
            let r = simd_length(world - originPosition)
            return r.isFinite && r > 0.05 ? r : nil
        }
    }

    // MARK: - Per-frame projection

    /// Everything needed to turn a world direction into a sample of one frame, plus that
    /// sample's quality weight. Extracted so the seam pass and the accumulation pass cannot
    /// disagree about where a frame sees a direction or how well — they compute the label
    /// and then honour it, so any divergence between them would place seams using one
    /// geometry and draw them using another.
    private struct FrameProjector {
        let worldToCamera: simd_float3x3
        let fx: Float, fy: Float, cx: Float, cy: Float
        let uMin: Float, uMax: Float, vMin: Float, vMax: Float
        let frameWidth: Float, frameHeight: Float
        let halfWidth: Float, halfHeight: Float
        let driftPenalty: Float

        init?(frame: CapturedFrame) {
            let t = frame.transform
            let rotation = simd_float3x3(
                SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            )
            let k = frame.intrinsics
            guard k[0][0] > 0, k[1][1] > 0 else { return nil }
            let w = Float(frame.width), h = Float(frame.height)
            let marginX = w * edgeMargin, marginY = h * edgeMargin
            guard w - 1 - marginX > marginX, h - 1 - marginY > marginY else { return nil }

            worldToCamera = rotation.transpose
            fx = k[0][0]; fy = k[1][1]; cx = k[2][0]; cy = k[2][1]
            uMin = marginX; uMax = w - 1 - marginX
            vMin = marginY; vMax = h - 1 - marginY
            frameWidth = w; frameHeight = h
            halfWidth = w * 0.5; halfHeight = h * 0.5
            let ratio = frame.driftMeters / driftHalfWeightMeters
            driftPenalty = 1 / (1 + ratio * ratio)
        }

        /// Where this frame sees `world`, and how centrally. nil when it does not see it.
        @inline(__always)
        func sample(world: SIMD3<Float>) -> (u: Float, v: Float, weight: Float)? {
            let camera = worldToCamera * world
            // ARKit camera space is -Z forward; anything with z >= 0 is behind.
            guard camera.z < 0 else { return nil }
            let invDepth = 1 / -camera.z
            // ARKit -> computer-vision convention: (x, -y, -z).
            let u = fx * camera.x * invDepth + cx
            let v = cy - fy * camera.y * invDepth
            guard u >= uMin, u <= uMax, v >= vMin, v <= vMax else { return nil }
            let tx = min(u, frameWidth - 1 - u) / halfWidth
            let ty = min(v, frameHeight - 1 - v) / halfHeight
            let feather = tx * ty
            return (u, v, feather * feather * driftPenalty)
        }
    }

    // MARK: - Exposure compensation

    /// Per-frame multiplicative gains that bring every frame to a common exposure before
    /// any of them is blended.
    ///
    /// ARKit's auto-exposure re-meters continuously, leaving each stored frame at a
    /// slightly different brightness — 5-20 levels across a sweep, per the measurements in
    /// the capture notes. The blend then shows that as a step wherever authorship changes
    /// hands: a wall that is one brightness on one side of a handover and another on the
    /// other side reads as a patch even when the geometry is perfect. The eighth device run
    /// still showed these mismatches after the geometry problems were fixed, which is what
    /// promoted this from nice-to-have to the next defect in line.
    ///
    /// The estimate comes from the overlaps themselves. For every pair of frames whose view
    /// cones can intersect, a coarse grid of directions from one frame is projected into
    /// the other; where both see the direction, their low-passed lumas are compared.
    /// Samples that disagree by more than the agreement tolerance are EXCLUDED — those are
    /// parallax or a moving subject, not exposure, and folding them in would "correct"
    /// brightness toward a difference that is not an exposure difference at all. (This is
    /// also what keeps the host tests honest: synthetic scenes with deliberately different
    /// per-frame content produce no valid samples and therefore no correction.)
    ///
    /// Each surviving pair yields one constraint: gain_a / gain_b should equal the luma
    /// ratio seen_b / seen_a. The constraints form a graph over frames, solved in the log
    /// domain by weighted Jacobi relaxation — each frame's log-gain repeatedly moves to the
    /// sample-count-weighted average its neighbours imply. Sixty-four sweeps over at most
    /// 90 nodes is microseconds. The mean log-gain is then subtracted so the OVERALL
    /// brightness of the panorama is untouched: this equalises frames against each other,
    /// it does not re-expose the image.
    ///
    /// Gains are clamped to 0.7...1.4. Real exposure wobble is well inside that; anything
    /// outside it means the estimate was polluted (a pathological scene, a mostly-dark
    /// overlap) and a clamped, mild correction is safer than an aggressive wrong one.
    private static func exposureGains(
        frames: [CapturedFrame],
        thumbnails: [Thumbnail],
        agreement: Float
    ) -> [Float] {
        let count = frames.count
        guard count > 1 else { return [Float](repeating: 1, count: count) }

        struct Camera {
            let rotation: simd_float3x3
            let worldToCamera: simd_float3x3
            let fx: Float, fy: Float, cx: Float, cy: Float
            let width: Float, height: Float
            let forward: SIMD3<Float>
        }
        let cameras: [Camera] = frames.map { frame in
            let t = frame.transform
            let rotation = simd_float3x3(
                SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            )
            let k = frame.intrinsics
            return Camera(
                rotation: rotation,
                worldToCamera: rotation.transpose,
                fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                width: Float(frame.width), height: Float(frame.height),
                forward: -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
            )
        }

        // Two portrait frusta stop intersecting once their forwards separate by roughly
        // twice the half-diagonal (~2 x 38 degrees). 75 degrees keeps every real overlap
        // and skips the pairs that cannot have one, which is most of them.
        let overlapCosine = cos(Float(75) * .pi / 180)
        // 12x9 directions per pair: enough for a stable mean, cheap enough that the full
        // pairwise sweep over 90 frames stays in the low milliseconds.
        let gridX = 12, gridY = 9
        let minSamples = 24
        // Near-black lumas make ratios explode; below this a sample says nothing about
        // exposure anyway.
        let minLuma: Float = 8

        struct Edge {
            let a: Int, b: Int
            /// log(mean luma seen by b / mean luma seen by a) over the shared directions.
            let logRatio: Float
            let weight: Float
        }
        var edges: [Edge] = []

        for a in 0 ..< count {
            for b in (a + 1) ..< count {
                guard simd_dot(cameras[a].forward, cameras[b].forward) > overlapCosine
                else { continue }
                let camA = cameras[a], camB = cameras[b]
                var logRatios: [Float] = []
                for gy in 0 ..< gridY {
                    let v = (Float(gy) + 0.5) / Float(gridY) * camA.height
                    for gx in 0 ..< gridX {
                        let u = (Float(gx) + 0.5) / Float(gridX) * camA.width
                        let ray = simd_normalize(camA.rotation * SIMD3(
                            (u - camA.cx) / camA.fx,
                            -(v - camA.cy) / camA.fy,
                            -1
                        ))
                        let inB = camB.worldToCamera * ray
                        guard inB.z < 0 else { continue }
                        let invDepth = 1 / -inB.z
                        let uB = camB.fx * inB.x * invDepth + camB.cx
                        let vB = camB.cy - camB.fy * inB.y * invDepth
                        guard uB >= 0, uB <= camB.width - 1,
                              vB >= 0, vB <= camB.height - 1 else { continue }

                        let sa = thumbnails[a].sample(u: u, v: v)
                        let sb = thumbnails[b].sample(u: uB, v: vB)
                        let lumaA = (sa.0 + sa.1 + sa.2) / 3
                        let lumaB = (sb.0 + sb.1 + sb.2) / 3
                        guard lumaA > minLuma, lumaB > minLuma,
                              abs(lumaA - lumaB) <= agreement else { continue }
                        logRatios.append(log(lumaB / lumaA))
                    }
                }
                guard logRatios.count >= minSamples else { continue }
                // MEDIAN of per-sample log ratios, not the ratio of the sums. The two agree
                // when the shared region is uniformly sampled, but the median is unmoved by
                // the asymmetries that are always present in practice: samples landing near
                // one frame's edge, a bright window in half the overlap, a person occluding
                // one view. Using sums let those bias the estimate — measurably, it cost
                // StitchHarness's projection MAE 1.27 -> 1.69 on a scene whose frames have
                // no exposure difference at all, which is the estimator inventing a
                // correction. The median restores it.
                logRatios.sort()
                let mid = logRatios.count / 2
                let median = logRatios.count.isMultiple(of: 2)
                    ? (logRatios[mid - 1] + logRatios[mid]) / 2
                    : logRatios[mid]
                edges.append(Edge(a: a, b: b,
                                  logRatio: median,
                                  weight: Float(logRatios.count)))
            }
        }
        guard !edges.isEmpty else { return [Float](repeating: 1, count: count) }

        // adjacency[i] lists (neighbour, the log-gain i should sit at given that
        // neighbour's current value, weight).
        var adjacency = [[(other: Int, offset: Float, weight: Float)]](
            repeating: [], count: count)
        for edge in edges {
            // gain_a / gain_b = seen_b / seen_a  =>  G_a - G_b = logRatio.
            adjacency[edge.a].append((edge.b, edge.logRatio, edge.weight))
            adjacency[edge.b].append((edge.a, -edge.logRatio, edge.weight))
        }

        var logGains = [Float](repeating: 0, count: count)
        for _ in 0 ..< 64 {
            var next = logGains
            for i in 0 ..< count where !adjacency[i].isEmpty {
                var sum: Float = 0
                var total: Float = 0
                for (other, offset, weight) in adjacency[i] {
                    sum += (logGains[other] + offset) * weight
                    total += weight
                }
                next[i] = sum / total
            }
            logGains = next
        }

        // Anchor to zero mean over the connected frames so the panorama's overall
        // brightness is preserved; isolated frames keep gain 1.
        let connected = (0 ..< count).filter { !adjacency[$0].isEmpty }
        let mean = connected.reduce(Float(0)) { $0 + logGains[$1] } / Float(connected.count)
        return (0 ..< count).map { index in
            guard !adjacency[index].isEmpty else { return 1 }
            return min(1.4, max(0.7, exp(logGains[index] - mean)))
        }
    }

    // MARK: - Projection of one frame

    private static func project(
        frame: CapturedFrame,
        frameIndex: Int,
        thumbnail: Thumbnail,
        gain: Float,
        seamField: SeamField?,
        originYaw: Float,
        originPosition: SIMD3<Float>,
        into accumulator: UnsafeMutablePointer<Float>?,
        weights: UnsafeMutablePointer<Float>,
        width: Int,
        height: Int,
        dominance: Float,
        agreement: Float,
        mode: ProjectionMode
    ) {
        let t = frame.transform
        // Camera rotation is orthonormal, so its inverse is its transpose.
        let rotation = simd_float3x3(
            SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
            SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
            SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        )
        let worldToCamera = rotation.transpose

        let k = frame.intrinsics
        let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
        guard fx > 0, fy > 0 else { return }

        // Where this frame's viewpoint actually was, and how far that is from the point the
        // panorama is being drawn FROM. Everything below this line is the parallax correction;
        // without it these two are assumed identical, which is the rotation-only model that
        // produced every ghosting artifact in runs 1-13. See `CapturedFrame.depths`.
        let cameraPosition = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let offset = cameraPosition - originPosition
        let depthMap = DepthSampler(frame: frame)
        // Below a millimetre of translation the correction is a no-op and the iteration is
        // pure cost. This is also what keeps every existing host test byte-identical: they
        // model a perfect pivot, so they take this branch and never enter the new code.
        let correctParallax = depthMap != nil && simd_length(offset) > 1e-3

        let frameWidth = Float(frame.width)
        let frameHeight = Float(frame.height)
        let marginX = frameWidth * edgeMargin
        let marginY = frameHeight * edgeMargin
        let uMin = marginX, uMax = frameWidth - 1 - marginX
        let vMin = marginY, vMax = frameHeight - 1 - marginY
        guard uMax > uMin, vMax > vMin else { return }

        guard let bounds = angularBounds(
            worldForward: -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z),
            originYaw: originYaw,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            fx: fx,
            fy: fy,
            panoWidth: width,
            panoHeight: height
        ) else { return }

        let halfWidthF = frameWidth * 0.5
        let halfHeightF = frameHeight * 0.5
        // Constant across the frame, so it is computed once rather than per pixel.
        let driftRatio = frame.driftMeters / driftHalfWeightMeters
        let driftPenalty = 1 / (1 + driftRatio * driftRatio)
        let rowCount = bounds.yEnd - bounds.yStart
        guard rowCount > 0 else { return }

        frame.pixels.withUnsafeBufferPointer { source in
            guard let pixels = source.baseAddress else { return }
            // Rows are disjoint across iterations, so concurrent writes never overlap.
            DispatchQueue.concurrentPerform(iterations: rowCount) { row in
                let y = bounds.yStart + row
                let lat = .pi / 2 - (Float(y) + 0.5) / Float(height) * .pi
                let cosLat = cos(lat)
                let sinLat = sin(lat)
                let rowBase = y * width

                // Below the horizon the blend narrows toward a single frame, reaching
                // solo-source at `nadirSoloLatRadians`. Constant per row, because latitude
                // is: computed here rather than per pixel. See those constants for why the
                // bottom cap cannot be blended coherently at all.
                let rowDominance: Float
                if lat >= nadirNarrowLatRadians {
                    rowDominance = dominance
                } else if lat <= nadirSoloLatRadians {
                    rowDominance = 1
                } else {
                    let t = (nadirNarrowLatRadians - lat)
                        / (nadirNarrowLatRadians - nadirSoloLatRadians)
                    rowDominance = dominance + (1 - dominance) * t
                }

                for rawX in bounds.xStart ... bounds.xEnd {
                    let x = ((rawX % width) + width) % width
                    let lon = (Float(x) + 0.5) / Float(width) * 2 * .pi - .pi

                    let local = SIMD3(cosLat * sin(lon), sinLat, -cosLat * cos(lon))
                    let world = SweepFrame.toWorld(local, originYaw: originYaw)
                    let camera = worldToCamera * world

                    // ARKit camera space is -Z forward; anything with z >= 0 is behind.
                    guard camera.z < 0 else { continue }
                    let invDepth = 1 / -camera.z

                    // ARKit -> computer-vision convention: (x, -y, -z).
                    // This is where the scene point would be IF it were infinitely far away.
                    // For a camera that only rotates, that assumption costs nothing: the ray
                    // from the panorama centre and the ray from the camera are the same ray.
                    var u = fx * camera.x * invDepth + cx
                    var v = cy - fy * camera.y * invDepth

                    // For a camera that has also MOVED, they are not, and the gap is
                    // atan(offset / distance) — 31 degrees for a 30 cm step and an object half a
                    // metre away, which is 353 px at 4096 wide. No blend, seam or veto can
                    // repair a misregistration that size; the only repair is to stop assuming
                    // infinity, which needs to know how far away the point actually is.
                    //
                    // Solved by fixed-point iteration rather than a closed form, because the
                    // unknown is on both sides: the depth to look up depends on which pixel we
                    // land on, and which pixel we land on depends on the depth. Each pass
                    // back-projects the current pixel to a world point, keeps its RANGE from the
                    // panorama centre, moves it onto the ray actually being drawn, and
                    // re-projects. With translation much smaller than range this contracts
                    // quickly — the measured residual after 3 passes is below a tenth of a pixel
                    // (see Tests/ParallaxTruth).
                    if correctParallax, let depthMap {
                        for _ in 0 ..< parallaxIterations {
                            guard let range = depthMap.range(
                                u: u, v: v, rotation: rotation, cameraPosition: cameraPosition,
                                originPosition: originPosition, fx: fx, fy: fy, cx: cx, cy: cy)
                            else { break }
                            // The point at that same range along the ray this pixel is drawing.
                            let target = world * range - offset
                            guard target.z != 0 || target.x != 0 || target.y != 0 else { break }
                            let cam2 = worldToCamera * target
                            guard cam2.z < 0 else { break }
                            let inv2 = 1 / -cam2.z
                            let nu = fx * cam2.x * inv2 + cx
                            let nv = cy - fy * cam2.y * inv2
                            guard nu.isFinite, nv.isFinite else { break }
                            let moved = abs(nu - u) + abs(nv - v)
                            u = nu; v = nv
                            if moved < parallaxConvergencePixels { break }
                        }
                    }
                    guard u >= uMin, u <= uMax, v >= vMin, v <= vMax else { continue }

                    // Separable feather: how centrally THIS frame sees this direction,
                    // falling to zero at the frame border. Squared, not raised higher —
                    // this value now only has to RANK the frames that see a pixel, and
                    // `dominanceThreshold` decides which of them are allowed to speak.
                    // Trying to do both jobs with one exponent is what produced the wide
                    // streaked bands: see the note on `dominanceThreshold`.
                    //
                    // There is deliberately NO floor added to this weight. An earlier
                    // version added 1e-4 so that a pixel seen only near a frame's edge
                    // still got colour, but that floor dominates wherever EVERY frame sees
                    // a direction near its edge — which is exactly the overlap band where
                    // seams live. There the peaked weight collapsed back into a flat
                    // average of misaligned frames: maximum ghosting, in the one place it
                    // hurts most. Coverage is tracked by "did any frame sample this", not
                    // by a weight threshold, so no floor is needed to keep those pixels
                    // lit. `edgeMargin` keeps the feather strictly positive.
                    let tx = min(u, frameWidth - 1 - u) / halfWidthF
                    let ty = min(v, frameHeight - 1 - v) / halfHeightF
                    let feather = tx * ty
                    let weight = feather * feather * driftPenalty

                    let index = rowBase + x

                    guard case let .accumulate(peak, peakColours) = mode else {
                        // Pass 1: record the best any frame does here, and what it saw.
                        guard case let .peak(colours) = mode, weight > weights[index] else {
                            continue
                        }
                        weights[index] = weight
                        // The LOW-PASSED colour, because that is what pass 2 compares
                        // against. Storing the full-resolution sample here would put the
                        // carpet speckle back into the test. Exposure-corrected, so the
                        // agreement test compares frames on equal terms — otherwise a
                        // brightness difference reads as a disagreement about content and
                        // the veto fires on exposure, which is what it must never do.
                        let sample = thumbnail.sample(u: u, v: v)
                        colours[index * 3 + 0] = sample.0 * gain
                        colours[index * 3 + 1] = sample.1 * gain
                        colours[index * 3 + 2] = sample.2 * gain
                        continue
                    }

                    // Pass 2: drop frames that are not competitive for this pixel, then
                    // rescale what survives so the winner reaches full weight and a
                    // borderline neighbour fades in from zero. Without the rescale the
                    // survivors would re-enter at their raw weights and average again.
                    let best = peak[index]
                    guard best > 0 else { continue }

                    // When the seam field exists it, not the per-pixel argmax, decides who
                    // paints here. `share` is bilinear over the label grid, so it is a
                    // partition of unity: the shares of all frames sum to 1 wherever the
                    // grid is covered, and the handover is a ramp about one cell wide
                    // rather than a step. That ramp is what the per-pixel nadir cap was
                    // missing — it removed the blend and so drew the boundary as a line.
                    //
                    // Routing stops at the solo cap (`rowDominance == 1`). Inside it the two
                    // are alternative answers to the same question, not complements, and the
                    // cap measures better: routing cuts the cap's boundary DISAGREEMENT by
                    // three quarters yet raises its hard-edge fraction 0.0131 -> 0.0216,
                    // because a label grid 16 px coarse plus a one-cell ramp lands the
                    // handover more abruptly than the per-pixel argmax it replaces, and at
                    // 0.5 m there is no colour distance small enough to hide it. Letting
                    // routing run everywhere would have traded a measured win in the room
                    // for a measured loss underfoot.
                    //
                    // The gate itself is a RAMP, not a switch — see `contestedFraction`. A
                    // pixel half inside a contested region takes half its colour from each
                    // path, so the two hand over across a cell instead of along a cell edge.
                    let routed: Float = seamField == nil || rowDominance >= 1
                        ? 0
                        : seamField!.contestedFraction(x: x, y: y, scale: seamScale)

                    if let seamField, let accumulator, routed > 0 {
                        let share = routed * seamField.share(
                            frame: Int32(frameIndex), x: x, y: y, scale: seamScale)
                        if share > 0 {
                            // The veto still applies INSIDE the transition band. Routing
                            // decides where authorship changes hands; it does not make the
                            // handover itself safe to blend. The ramp is a cell wide, and
                            // two disagreeing frames averaged across it ghost exactly as
                            // they did before the veto existed — measured, letting the ramp
                            // blend unconditionally cost 12.49 -> 10.94 sharpness, undoing
                            // most of what the veto is worth. Routing and vetoing answer
                            // different questions and both are needed.
                            let low = thumbnail.sample(u: u, v: v)
                            let dr = low.0 * gain - peakColours[index * 3 + 0]
                            let dg = low.1 * gain - peakColours[index * 3 + 1]
                            let db = low.2 * gain - peakColours[index * 3 + 2]
                            // Skipping the whole pixel, not just the routed addition, even
                            // though the dominance path below could still want this frame.
                            // That is safe because the two vetoes are the SAME test on the
                            // SAME values — identical thumbnail sample, identical `gain`,
                            // identical `peakColours`, identical `agreement` — so a frame
                            // rejected here is rejected again at the `disagreement` guard
                            // below without fail. If either test is ever changed, this
                            // shortcut must become a flag that skips only this addition.
                            guard max(abs(dr), max(abs(dg), abs(db))) <= agreement
                            else { continue }

                            let colour = bilinearSample(
                                pixels: pixels, width: frame.width, height: frame.height,
                                u: u, v: v)
                            accumulator[index * 3 + 0] += colour.0 * gain * share
                            accumulator[index * 3 + 1] += colour.1 * gain * share
                            accumulator[index * 3 + 2] += colour.2 * gain * share
                            weights[index] += share
                        } else if weight >= best {
                            // The label grid is coarse, so a pixel can fall in a cell owned
                            // by a frame that does not actually reach THIS pixel. Without
                            // this the pixel would be left unpainted and hole-filling would
                            // invent it. The best-placed frame backstops at a token weight,
                            // so coverage is exactly what it was before routing and the
                            // contribution is negligible wherever a labelled frame did
                            // reach.
                            let colour = bilinearSample(
                                pixels: pixels, width: frame.width, height: frame.height,
                                u: u, v: v)
                            let token: Float = 1e-3 * routed
                            accumulator[index * 3 + 0] += colour.0 * gain * token
                            accumulator[index * 3 + 1] += colour.1 * gain * token
                            accumulator[index * 3 + 2] += colour.2 * gain * token
                            weights[index] += token
                        }
                        // Fully inside a contested region the routed path is the whole
                        // answer, exactly as before. Partly inside, the dominance path below
                        // supplies the rest, each frame contributing
                        // `routed * share + (1 - routed) * blend`.
                        //
                        // Note what that is and is not. Both paths run for the same frame at
                        // the same pixel, which is intended: it is the WEIGHTS that
                        // interpolate, not the two finished colours. Because the accumulator
                        // normalises by total weight at the end, and the dominance weights
                        // sum to more than 1 while the routed shares sum to exactly 1, the
                        // result is not the linear blend of the two answers — it leans toward
                        // the dominance answer in the middle of the ramp. That is acceptable
                        // and it is why this is a ramp at all: it is continuous, monotone,
                        // and exact at both ends, which is everything the gate needs. It is
                        // NOT a partition of unity in between, and an earlier version of this
                        // comment claimed it was.
                        if routed >= 1 { continue }
                    }

                    let relative = weight / best
                    guard relative >= rowDominance else { continue }
                    // At rowDominance 1 — the nadir cap — only the frame that IS the peak
                    // survives the guard above, and it takes full weight. One source, so no
                    // inter-frame boundary can be drawn there at all.
                    let shaped = rowDominance < 1
                        ? (relative - rowDominance) / (1 - rowDominance)
                        : 1
                    let blend = shaped * shaped
                    guard let accumulator else { continue }

                    // Being well placed is not the same as being right. A rival that
                    // disagrees with the best-placed frame about what is HERE is looking at
                    // a different surface — parallax has slid a near object across a far one
                    // between the two viewpoints — and averaging the two is what draws a
                    // chair twice. Believe the best-placed frame and fade the rival out.
                    //
                    // Compared on THUMBNAILS, so that texture and sensor noise cannot
                    // masquerade as disagreement. This is the run-7 carpet fix and the
                    // whole of it: see `comparisonScale`.
                    //
                    // The best-placed frame meets itself here and scores zero disagreement,
                    // so it always keeps its full vote and no pixel can be left unpainted.
                    // Both sides exposure-corrected, so what remains is a disagreement about
                    // CONTENT rather than about metering.
                    let low = thumbnail.sample(u: u, v: v)
                    let dr = low.0 * gain - peakColours[index * 3 + 0]
                    let dg = low.1 * gain - peakColours[index * 3 + 1]
                    let db = low.2 * gain - peakColours[index * 3 + 2]
                    let disagreement = max(abs(dr), max(abs(dg), abs(db)))

                    // A plain cut, deliberately. A smooth rolloff was tried here first, on
                    // the theory that a binary test must draw hard edges. Once the
                    // comparison is low-passed it does not: the veto stops firing spuriously
                    // in the first place, so there is no boundary to soften. Measured in
                    // Tests/TextureBlotching and Tests/ParallaxSharpness, the rolloff was
                    // strictly WORSE on all three numbers that matter — sharpness 11.92 vs
                    // 12.35, blotching 3.51 vs 3.30, edge hardness 6.45 vs 6.11 — so it was
                    // removed rather than kept as insurance. Fixing the measure was the fix.
                    guard disagreement <= agreement else { continue }
                    // Scaled by whatever share of this pixel the routed path did not take.
                    // 1 everywhere outside a contested region, which is almost everywhere.
                    let voted = blend * (1 - routed)
                    guard voted > 0 else { continue }

                    let colour = bilinearSample(
                        pixels: pixels,
                        width: frame.width,
                        height: frame.height,
                        u: u,
                        v: v
                    )
                    // Gain applied here, on the full-resolution sample, so the equalisation
                    // reaches the actual output and not merely the comparison.
                    accumulator[index * 3 + 0] += colour.0 * gain * voted
                    accumulator[index * 3 + 1] += colour.1 * gain * voted
                    accumulator[index * 3 + 2] += colour.2 * gain * voted
                    weights[index] += voted
                }
            }
        }
    }

    // MARK: - Angular bounding box

    private struct Bounds {
        let xStart: Int
        let xEnd: Int
        let yStart: Int
        let yEnd: Int
    }

    /// Conservative equirectangular bounding box for a frame's view cone. Iterating the
    /// whole 4096x2048 canvas once per frame would be ~200M wasted tests for 24 frames.
    /// Over-estimating is safe: every pixel is still tested against the real projection.
    private static func angularBounds(
        worldForward: SIMD3<Float>,
        originYaw: Float,
        frameWidth: Float,
        frameHeight: Float,
        fx: Float,
        fy: Float,
        panoWidth: Int,
        panoHeight: Int
    ) -> Bounds? {
        let localForward = SweepFrame.toLocal(worldForward, originYaw: originYaw)
        let centreYaw = SweepFrame.yaw(of: localForward)
        let centrePitch = asin(max(-1, min(1, localForward.y)))

        let tanX = (frameWidth * 0.5) / fx
        let tanY = (frameHeight * 0.5) / fy
        // Half-angle of the cone that encloses the image corners, plus a safety margin.
        let halfAngle = atan(sqrt(tanX * tanX + tanY * tanY)) + 0.05

        let latMax = min(Float.pi / 2, centrePitch + halfAngle)
        let latMin = max(-Float.pi / 2, centrePitch - halfAngle)
        let yStart = max(0, Int(floor((.pi / 2 - latMax) / .pi * Float(panoHeight))))
        let yEnd = min(panoHeight, Int(ceil((.pi / 2 - latMin) / .pi * Float(panoHeight))) + 1)
        guard yEnd > yStart else { return nil }

        // Near the poles a fixed angular radius spans an unbounded longitude range.
        let worstLatitude = min(abs(centrePitch) + halfAngle, .pi / 2)
        let denominator = cos(worstLatitude)
        let lonHalfWidth: Float = denominator < 0.2 ? .pi : min(.pi, halfAngle / denominator)

        if lonHalfWidth >= .pi {
            return Bounds(xStart: 0, xEnd: panoWidth - 1, yStart: yStart, yEnd: yEnd)
        }
        let centreX = (centreYaw + .pi) / (2 * .pi) * Float(panoWidth)
        let spanX = lonHalfWidth / (2 * .pi) * Float(panoWidth)
        let xStart = Int(floor(centreX - spanX))
        let xEnd = Int(ceil(centreX + spanX))
        return Bounds(xStart: xStart, xEnd: max(xStart, xEnd), yStart: yStart, yEnd: yEnd)
    }

    // MARK: - Sampling

    private static func bilinearSample(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        u: Float,
        v: Float
    ) -> (Float, Float, Float) {
        let x0 = Int(u), y0 = Int(v)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fxFrac = u - Float(x0)
        let fyFrac = v - Float(y0)

        let i00 = (y0 * width + x0) * 4
        let i10 = (y0 * width + x1) * 4
        let i01 = (y1 * width + x0) * 4
        let i11 = (y1 * width + x1) * 4

        let w00 = (1 - fxFrac) * (1 - fyFrac)
        let w10 = fxFrac * (1 - fyFrac)
        let w01 = (1 - fxFrac) * fyFrac
        let w11 = fxFrac * fyFrac

        @inline(__always)
        func channel(_ offset: Int) -> Float {
            Float(pixels[i00 + offset]) * w00
                + Float(pixels[i10 + offset]) * w10
                + Float(pixels[i01 + offset]) * w01
                + Float(pixels[i11 + offset]) * w11
        }
        return (channel(0), channel(1), channel(2))
    }

    // MARK: - Composition

    private static func compose(
        accumulator: UnsafePointer<Float>,
        weights: UnsafePointer<Float>,
        width: Int,
        height: Int,
        frameCount: Int
    ) -> Result? {
        let pixelCount = width * height
        var output = [UInt8](repeating: 0, count: pixelCount * 4)

        // Normalise into float RGB first, tracking which pixels any frame actually saw,
        // so gaps can be closed before quantising to bytes.
        let rgb = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount * 3)
        let coveredFlags = UnsafeMutablePointer<Bool>.allocate(capacity: pixelCount)
        rgb.initialize(repeating: 0, count: pixelCount * 3)
        coveredFlags.initialize(repeating: false, count: pixelCount)
        defer {
            rgb.deallocate()
            coveredFlags.deallocate()
        }

        // Accumulated per row, because the solid angle a row represents depends on its
        // latitude: a row at the pole is a sliver, a row at the horizon is a full band.
        var coveredSolidAngle = 0.0
        var totalSolidAngle = 0.0
        for y in 0 ..< height {
            let lat = .pi / 2 - (Double(y) + 0.5) / Double(height) * .pi
            let rowSolidAngle = cos(lat)
            totalSolidAngle += rowSolidAngle * Double(width)
            let rowBase = y * width
            for x in 0 ..< width {
                let index = rowBase + x
                let weight = weights[index]
                // Any sample at all counts. See the note on the feather in `project`:
                // thresholding on weight here would silently drop pixels that only one
                // frame saw near its edge, and put the black back.
                guard weight > 0 else { continue }
                coveredFlags[index] = true
                coveredSolidAngle += rowSolidAngle
                for channel in 0 ..< 3 {
                    rgb[index * 3 + channel] = accumulator[index * 3 + channel] / weight
                }
            }
        }

        // `coverage` is measured BEFORE this, so the reported number stays honest about
        // what was actually captured rather than what was painted in.
        fillHoles(rgb: rgb, covered: coveredFlags, width: width, height: height)

        output.withUnsafeMutableBufferPointer { buffer in
            guard let out = buffer.baseAddress else { return }
            for index in 0 ..< pixelCount {
                let base = index * 4
                out[base + 3] = 255
                guard coveredFlags[index] else { continue }
                for channel in 0 ..< 3 {
                    out[base + channel] = UInt8(max(0, min(255, rgb[index * 3 + channel].rounded())))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        return Result(
            image: image,
            coverage: totalSolidAngle > 0 ? coveredSolidAngle / totalSolidAngle : 0,
            frameCount: frameCount
        )
    }
}
