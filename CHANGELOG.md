# Changelog

## Current state

**Product:** `PLAN.md` (v2) is authoritative — a sweep-panorama Matterport-style pipeline: guided
rotate-in-place 360° capture at points 1.5–2.5 m apart inside an AR session (VIO poses = metric
scale), on-device stitching, Supabase backend, Three.js skybox tour viewer (Phase A, zero ML),
then neural depth for measurement (Phase B) and fused dollhouse mesh (Phase C).

### What works
- `PLAN.md` v2 — complete, every decision sourced.
- **Iteration 0 app is fully written**: `mobile/ios_capture/Sources/{SweepGeometry,Capture,
  PanoramaStitcher,App}.swift` (~1030 lines). Guided AR capture with on-screen target spheres,
  pose-based equirect stitching, panorama preview, save-to-Photos, inter-sweep distance readout.
- `SweepSpike.xcodeproj` generated (`xcodegen generate`, exit 0). Info.plist is generated from
  `project.yml` `info.properties` — there is no hand-written Info.plist and none is needed.
- **All four sources compile AND link for arm64 iOS: 0 errors, 0 warnings.** Verified without
  `xcodebuild` (see "What's blocked"):
  ```
  SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \\
    -sdk $SDK -target arm64-apple-ios16.0 -O mobile/ios_capture/Sources/*.swift -o /tmp/SweepSpike
  ```
  Produces a Mach-O 64-bit arm64 executable. This is a real compile + link check of `Capture.swift`
  and `App.swift` (ARKit, SwiftUI, SceneKit, Photos), not just a typecheck. It does NOT prove
  runtime behaviour, which still needs a device.
- **Host verification harness passes all checks** (`Tests/StitchHarness`). Runs on macOS with no
  Xcode and no device. Build + run:
  ```
  cd mobile/ios_capture
  swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift \
    Tests/StitchHarness/PlanSweep.swift Tests/StitchHarness/main.swift -o /tmp/stitchharness
  /tmp/stitchharness
  ```
  Current results (2026-08-05): ALL CHECKS PASSED. Yaw-frame round trips PASS; synthetic stitch
  worst-channel MAE **1.28/255** (projection + inverse projection agree to well under a degree);
  solid-angle coverage **78.6%**, which matches PlanSweep's independent analytic figure for the
  same plan to the decimal; **100.00% of output pixels non-black after hole filling**; shipping
  plan **44 targets, 100% sphere, 90.5% wall overlap**.
- **`Tests/ParallaxSharpness` measures the anti-smudge blend against reproduced parallax.** Swap it
  for `StitchHarness` in the swiftc line above (it also needs `Tests/StitchHarness/PlanSweep.swift`).
  Renders 60 frames each from its OWN wandering viewpoint, so parallax is real rather than assumed,
  and isolates what each defence is worth against a TRUE undefended baseline: dominance alone
  +32.8%, **colour veto alone +124.8%**, shipping (both) +122.5% — all at byte-identical coverage
  (spread 0.00e+00) and slightly faster than the undefended average. This is the test to re-run
  before touching the blend, and the assertion that coverage never moves is what would catch a
  veto bug punching holes while appearing to sharpen. Current: **+125.3%**.
- **`Tests/TextureBlotching` is the counterweight to ParallaxSharpness and must be run WITH it**,
  because the two pull in opposite directions: one rewards suppressing disagreeing frames, the
  other punishes suppressing them where nothing actually disagrees. Standalone:
  `swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift
  Tests/TextureBlotching/main.swift`. Sweeps `comparisonScale` over a wall of pure speckle with
  per-frame exposure variation; shipping 4x scores blotch 3.303 / hardness 6.111 against a
  no-veto reference of 3.295 / 6.104. (Absolute values dropped once `exposureGains` landed —
  current shipping is 1.116 / 5.174 against a 1.212 / 5.194 reference.)
- **`Tests/NadirCap` pins the bottom cap and the exposure equalisation.** Runs standalone:
  `swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift
  Tests/NadirCap/main.swift`. A close, per-frame-inconsistent subject below the horizon over a
  static textured floor. Asserts the solo cap is free of hard edges AND still fully painted —
  the second check is what makes the first mean anything, since a cap that punched a hole would
  also score zero hard edges. Also measures exposure: horizon brightness spread 5.965 -> 1.646.
- **`Tests/GuidanceHint` pins the direction signs of the capture instruction.** Runs with no
  other sources: `swiftc -O Sources/SweepGeometry.swift Tests/GuidanceHint/main.swift`. Covers
  left/right, up/down, turn-around, the ±180° seam, origin-heading independence, the deadzones,
  and that only-the-floor-ring-left yields "Look down".
- **`Tests/DriftPricing` proves drifted frames are ranked, not banned and not averaged in.** An
  on-origin frame and a 25 cm drifted frame aimed identically, plus a drifted frame alone on the
  far side. Asserts the contested direction takes the on-origin colour EXACTLY and the uncontested
  one is still filled by the drifted frame.
- **End-to-end demo runs the real plan through the real stitcher** (`Tests/PanoramaDemo`), at the
  production 4096×2048, with portrait roll and ±8° aiming error simulated. Swap `PanoramaDemo` for
  `StitchHarness` in the swiftc line above. Result: **44 frames stitched in 0.44 s, 100.00%
  solid-angle coverage**, output PNG shows continuous grid lines and no black wedges. This is the
  closest thing to "the app working" that exists without a device — everything except ARKit frame
  acquisition is exercised.
- **360° viewers, in the app and on the web.** `SphericalPanoramaView` (SceneKit) in the app lets
  the user drag to look around instead of seeing a flat rectangle. `web/viewer/index.html` is a
  dependency-free WebGL equirect viewer (Phase A) — open it directly in a browser, no server or
  build step; it loads `panorama.jpg` beside it or `?pano=<url>`. Both invert the SAME mapping the
  stitcher applies, so projection and display cannot drift apart.
- **`Tests/CaptureAdmission` pins the two rules the user actually experiences during a sweep**:
  when the drift banner may appear, and which frames are worth the frame budget. Runs with no
  other sources:
  ```
  cd mobile/ios_capture
  swiftc -O Sources/SweepGeometry.swift Tests/CaptureAdmission/main.swift -o /tmp/admission
  /tmp/admission
  ```
  ALL CHECKS PASSED (2026-08-05). Covers the hysteresis band, the sustained-frames delay, that a
  20–40 cm body-pivot arc never warns, that hovering on the limit produces zero flicker, and that
  a horizon-heavy sweep now closes the sphere inside the budget: **76 frames, 99.8% coverage,
  97.4% overlap** (the fifth device run managed 90 frames / 87.1% without the gate).
- **Seam routing is OFF** (`seamSmoothnessWeight` 0) after runs 11-13 were all judged worse than
  run 9, which had it off. `Tests/StitchHarness` asserts the shipping default builds no seam
  field. The machinery below is all still present and tested; it is disabled, not removed. See
  the thirteenth-run section for why the host numbers that endorsed it were measuring the wrong
  thing.
- **(Disabled, retained) Seam routing** (`seamSmoothnessWeight` 0.10 to re-enable). `routeSeams` runs
  alpha-expansion over the Dinic max-flow in `Sources/GraphCut.swift`, replacing the greedy ICM
  that made routing not worth shipping. Boundary disagreement **148836 -> 69011 (-54%)** with
  sharpness **12.49 -> 13.46 (+7.8%)** at byte-identical coverage. Gated twice: off where frames
  agree (keeps carpet patchwork closed) and off inside the solo nadir cap (which measures better
  there). See the seam-routing section dated 2026-08-06.
- **`Tests/GraphCutSolver` pins the max-flow solver**, which nothing else can. Runs with no other
  sources: `swiftc -O Sources/GraphCut.swift Tests/GraphCutSolver/main.swift`. Nine checks,
  including that `solve` and `sourceSide` agree on a random grid — a wrong max-flow does not
  crash, it silently returns a worse labelling.
- **`Tests/SeamTerritory` pins the sliver cleanup, which nothing else can.** Runs with the three
  stitcher sources: `swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift
  Sources/GraphCut.swift Tests/SeamTerritory/main.swift`. 22 checks: the wrap seam counts as one
  component, the poles do not join, the 64/63 boundary is exact, reassignment goes to the
  majority border label with ties to the lower index, two touching islands both dissolve to the
  surround, −1 cells are neither adopted nor created, and small/empty/mismatched grids are
  declined rather than flattened.
- **The sweep can be finished again.** `Capture.swift:135` `markCoveredTargets()` runs on every
  tracked frame, before the storage gates, so a white marker clears when the camera sees it
  rather than only when a frame is stored. Run 12 deadlocked without this; see the twelfth-run
  section for why that also made the image worse.
- **`Tests/SeamStaircase` holds the only scene with long straight architecture under parallax.**
  Build: `swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift
  Sources/GraphCut.swift Tests/StitchHarness/PlanSweep.swift Tests/SeamStaircase/main.swift`.
  Asserts the shipping default is byte-identical to the unrouted render, and that routing is not
  a small effect on this content (76789 px / 3.7%, worst channel 152). Read its header before
  trying to score seam quality — it documents why that cannot be done here.
- **Parallax is CORRECTED, not masked, when depth is available.** `.sceneDepth` is enabled
  (`Capture.swift:216`), stored per frame, and `PanoramaStitcher` resolves each output ray against
  it by fixed-point iteration instead of assuming infinite distance. Measured in
  `Tests/ParallaxTruth`: MAE 75.74 -> 17.53 at 0.10 m of camera translation, against a 14.80
  perfect-pivot floor. Byte-exact no-op at zero translation and on frames without depth.
- **`Tests/ParallaxTruth` is now the test that matters.** Build: `swiftc -O
  Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift Sources/GraphCut.swift
  Tests/StitchHarness/PlanSweep.swift Tests/ParallaxTruth/main.swift`. Every other stitcher test
  renders from a perfect pivot, which is the one case a rotation-only model gets exactly right —
  that blind spot is why thirteen device runs got worse while every number improved.
- **The five sources compile AND link for arm64 iOS with 0 errors and 0 warnings, and TEN of
  twelve host tests pass** (2026-08-06, after the revert to the sixth run's configuration).
  `Tests/CaptureAdmission` (4 checks) and `Tests/SeamStaircase` (1 check) are RED ON PURPOSE —
  both assert run-14 behaviour that the revert deliberately undid. Read the revert section
  before touching either; going green by editing the assertions would erase the record of what
  the revert cost. All twelve passed before the revert.
- **NOT VERIFIED: the output image.** No device run since runs 11-13, all three of which were
  judged worse than run 9 while every host number improved. The stitcher is provably back to
  run 9's configuration, but that is a claim about CODE, not about a photograph. Run 14 is the
  measurement and only a device can produce it. Run the whole suite with
  the script recipe in the run-12 section; the last full run had zero failures and every quality
  number unchanged or better against the pre-fix baseline.

### What's blocked
- **`sudo xcodebuild -runFirstLaunch` has not been run.** Xcode 26.6 is installed and its licence
  is accepted, but `/Library/Developer/PrivateFrameworks/DVTDownloads.framework` is dated
  Oct 2 2025 (left by CommandLineTools) and shadows the version Xcode 26.6 needs. Every
  `xcodebuild` invocation — device or simulator — dies with
  `Symbol not found: _$s12DVTDownloads21DownloadableAssetTypeO22developerDocumentation...`
  before compiling anything. Fix: `sudo xcodebuild -runFirstLaunch`, or just open Xcode.app once.
  **This blocks only .app packaging/signing/install, NOT compilation** — invoking `swiftc`
  directly against the iPhoneOS SDK bypasses `xcodebuild` and its plugin loader entirely, and
  that path compiles and links all four sources cleanly (see "What works").
- Disk: 30GB free on `/System/Volumes/Data`. Android Studio will not fit; defer to Iteration 5.

### Exact next step
**Run 15, on a device. The stitcher and the capture gates have been REVERTED TO THE SIXTH
DEVICE RUN'S CONFIGURATION** (2026-08-06) — see the revert section below for the six edits and
what each one gives up. Run 15 answers one question and one only: **does the reverted build
reproduce the sixth run's image?** If it does, that is the baseline to protect and every future
change goes back to one-at-a-time with a device run between. If it does not, the regression is
NOT in the six reverted knobs and the search moves to `App.swift` or the capture plan.

Two things run 15 must produce that run 14 did not:
1. **The raw 4096x2048 equirect** (`IMG_*.JPG`), saved to Photos. Run 14 produced only a
   recording of the fullscreen viewer, which has no caption bar, so its frame count and
   coverage percentage are unknown and it cannot be compared numerically to anything.
2. **A recording that includes the caption bar** ("N frames · X% of the sphere captured"), i.e.
   the non-immersive preview, not the fullscreen viewer.

**Expect the run-12 deadlock to return** — see the revert section. Watch the COVERAGE
percentage and finish the sweep on that number; do NOT wait for the white markers to clear,
because some of them no longer can.

**(Superseded) Run 14, on a device — and the sweep TECHNIQUE has changed, so read this first.**

**Hold the phone still and rotate your BODY around it, as if it were mounted on a broomstick.**
Do not swing the phone through an arc at arm's length. This is the single largest improvement
available and it is what Matterport and Google Street View both instruct; see the research
section. The app now says so on screen and warns at 12 cm instead of 30.

Run 14 answers, in order:
1. **Is the ghosting gone?** Depth-aware parallax correction is in and measures 77% of the error
   removed at 10 cm of translation (`Tests/ParallaxTruth`). This is the first run where the
   stitcher is not assuming everything is infinitely far away.
2. **Did `.sceneDepth` actually arrive?** If the panorama is no better, check depth is being
   captured at all before touching anything else — a non-LiDAR device silently falls back.
3. Sweep until the COVERAGE number is high, not until the markers clear.

Keep the raw 4096x2048 equirect (`IMG_*.JPG`). It is far more diagnostic than a recording of the
viewer, and run 12 vs 13 could not be compared properly without it.

**(Superseded by the above) Sweep until the COVERAGE number is high — not until the markers
clear.** Runs 11-13 were all worse than run 9. Seam routing is now OFF again
(`seamSmoothnessWeight` 0), which restores run 9's stitcher exactly, and the status line no
longer invites you to finish while the sphere is still open. Stand, do not sit. Keep the raw
4096x2048 equirect as `IMG_*.JPG` — it is far more diagnostic than a screen recording of the
viewer. If run 14 matches run 9, that is the baseline to protect, and every future change goes
back to being one-at-a-time with a device run between. See the thirteenth-run section.

**(Superseded) Run 13, on a device.** Run 12 is done and its result is in the twelfth-run section: the app
DEADLOCKS mid-sweep — a marker that can never be cleared, because targets were only ever marked
after the novelty gate that refuses frames aimed at already-covered ground. Fixed in
`Sources/Capture.swift:135` and `:341`. **The first thing run 13 must show is that the white
markers now clear and the sweep can be finished**, which no run since the gate landed has been
able to do. Expect the frame count to go UP from 76 toward the 90 budget, and the image to
improve for that reason alone.

Everything below still applies to run 13.

**Run 12 happened. The build is ready and waiting — nothing is outstanding on the host.**

Shoot a **cinema row, a sofa, or any scene with a person at 1–2 m who MOVES between frames**,
and **stand rather than sit** (run 10 showed a seated sweep cannot reach the rings behind the
shoulders). A static office cannot exhibit defect 13 at all, which is exactly why run 11 —
82 frames, 97.9%, the best horizon band yet — still did not answer the only question routing
was built for.

Run 12 must answer four things:
1. **Is the face still cut?** Defect 13. Untested against alpha-expansion routing on a device.
   This is the whole point of the run.
2. **Are the operator slivers gone?** The knife-edge forearm ghosts across the floor. Fixed by
   `dropSliverTerritories` and asserted on synthetic label fields, but only a device settles it.
   The knee and jeans at true nadir are a REAL object and will still be there — that is not the
   defect being fixed.
3. **Is the blockiness gone?** The rectangular chunks in the window beams and the staircase
   edges. Look at long straight architecture: beams, door frames, ceiling panel joints. No host
   scene exercises this, so the device IS the test — see the honest gap in the run-12 section.
4. **How slow is the stitch?** Still never measured on a device, through two runs that were
   supposed to measure it. 1.7 s for 60 frames on a Mac. If it is unbearable, the dial is
   `seamScale` (coarser grid), not `seamSmoothnessWeight`.

Then D-C, the washout: **keep the raw frames from run 12**, not just the panorama. Without them
there is no way to tell `exposureGains` from camera AE.

(The run-11 brief below is superseded on points 1–3 but its warnings still stand.)

**Run 11, on a device, with seam routing ON.** Ten device runs done. Run 9
(`ScreenRecording_08-05-2026 3-57-50 pm_1.MP4`, 90 frames / 98.1%) was the best output and the
user said so; run 10 (`IMG_3209.JPG`, cinema, seated) is the hardest scene attempted and
confirmed defect 13 is severe and unchanged — a razor-straight boundary through a face, with a
second forehead beside it.

**The build no longer reproduces run 9 byte-for-byte, and that is deliberate.** Seam routing is
now ON (`seamSmoothnessWeight` 0 -> 0.10) because alpha-expansion replaced the greedy minimiser
and reversed both signs: boundary disagreement -54% (was -4.5%) and sharpness +7.8% (was -3.4%),
at byte-identical coverage and unchanged MAE. Everything closed in runs 6-9 is held closed by
assertion, not by hope — see the two gates in the seam-routing section below.

Run 11 must answer three things, in this order:
1. **Is the face still cut?** The only question routing was built to answer. Shoot a scene with
   a person at 1-2 m who moves between frames — a cinema row or a sofa — because a static room
   cannot show the defect at all.
2. **How slow is the stitch now?** 0.44 s -> 1.79 s for 44 frames on a Mac, and expansion is
   per-label, so a 90-frame sweep will be worse than double. If it is unbearable on device, the
   dial to turn is `seamScale` (coarser grid), not `seamSmoothnessWeight`.
3. **Did carpet patchwork stay away?** `SeamField.contested` exists precisely to keep it away and
   is asserted on synthetic speckle, but only a real carpet settles it.

**Watch the frame budget.** Run 9 hit exactly 90 = `maxStoredFrames` at 98.1%. If run 11 also
lands on exactly 90, raise `minNoveltyFraction` before raising `maxStoredFrames`.

SOLVED, do not reopen: coverage (four runs at 97.9-99.1%), near-field ghosting, carpet
patchwork, exposure mismatch, drift warnings.

**Do not touch** `dominanceThreshold` (0.50), `driftHalfWeightMeters` (0.12),
`agreementToleranceLevels` (48), `comparisonScale` (8). All four are measured optima.

**Then the VIO distance number below** — still unmeasured, still the only thing gating whether
measurement is a product feature or an "estimate".

**Gate 1, stitch quality, is PASSED and closed.**

**Coverage is CLOSED** for a STANDING sweep: 54.6 -> 58.6 -> 69.6 -> 87.1 -> 99.1 -> 98.8 ->
97.9 -> 98.1%. Run 10 shows it is NOT closed for a SEATED one — the upper rear came back as wide
hole-filled interpolation, because a seated operator cannot reach the rings behind the shoulders.
Either guide the user to stand, or accept a documented seated mode with a smaller sphere.

The code is compile-clean (all four sources plus `GraphCut.swift` compile AND link for arm64 iOS,
0 errors, 0 warnings) and all nine host tests pass. Everything remaining is packaging and the
device run.
1. `sudo xcodebuild -runFirstLaunch` (or open Xcode.app once) to repair the plugin loader.
2. `open mobile/ios_capture/SweepSpike.xcodeproj`, Signing & Capabilities, set Team.
3. Plug in an iPhone, Cmd-R. AR cannot run in the simulator.

### The two gate numbers Iteration 0 must produce (both need a device — neither is measured yet)
1. **Stitch quality** — subjective pass/fail per room: seam ghosting (parallax), exposure banding,
   blur. Test a hard room too: bright window + close furniture.
2. **VIO distance error** — mark two floor points a known distance apart (e.g. 2.00 m), sweep at
   each, compare the app's reported separation to a tape. ~10 reps at 1/2/4 m. **<3% worst case →
   proceed with the measurement product; >3% → Phase A tour still ships, measurement gets
   relabelled "estimate".**

### Verified design facts (do not re-derive)
- **Portrait roll is the thing that is easy to get wrong.** `ARFrame.capturedImage` is ALWAYS a
  landscape-right buffer, and the app is portrait-locked, so the camera is rolled 90° relative to
  that buffer. The image's LONG axis (60° FOV) therefore runs VERTICALLY in the world and the
  SHORT axis (46.8°) runs horizontally. Yaw spacing must fit 46.8°, not 60°. Modelling a level
  camera makes a plan look ~7 points better than it is. `CaptureConfig.deviceRollRadians` encodes
  this and `PlanSweep.coverage(roll:)` applies it.
- **Coverage is not the objective; overlap is.** The stitcher feathers each frame's weight to zero
  at its border, so a direction seen by exactly one frame near that frame's edge gets colour with
  almost no weight and no neighbour to cross-fade into. A plan can hit 100% coverage and still
  seam at every boundary. `Coverage.wallBandOverlap` (fraction of the wall band seen by ≥2 frames)
  is the metric that ranks plans; the harness fails the build below 90%.
- Cheapest plans by target count are NOT the best: 28 targets reaches 100% coverage at 37% overlap.
- **Separation is not coverage.** "This direction is ≥10° from every frame I stored" and "this
  frustum shows ground nothing has seen" are different tests, and only the second one bounds how
  fast the frame budget is spent. A 47x60° frustum 10° from its neighbours in a covered patch
  passes the first and fails the second. Run 5 spent half its budget on exactly those frames.
- **A warning that cannot switch itself off is worse than no warning.** Publish user-facing state
  from a code path that runs on EVERY frame, never from inside the storage gates — the gates stop
  running when the budget fills or the user pauses, and the last value then sticks forever.
- **Geometric ranking cannot fix parallax, because the frames that ghost are equally well
  placed.** Two frames seeing a direction dead-centre both score ~1.0 relative weight and both
  get to speak, so no `dominanceThreshold` value removes the double image. The blend has to ask
  the SECOND question — do they agree on the colour — and believe the best-placed frame when they
  do not. Measured: dominance alone +32.8% sharpness, the colour veto alone **+124.8%**.
- **Our sharpness advantage over Matterport is real; our reliability disadvantage is the one
  that matters.** Same room, run 6: we resolve book spines and keyboard keys where their scan is
  soft everywhere, but they never draw an object twice and we do. Users forgive soft. They do not
  forgive a chair rendered twice — that reads as a broken app, not a low-res one.
- **A wrong MEASURE cannot be fixed by moving its THRESHOLD.** The veto fired on carpet because
  it compared raw pixels, and raw pixels of speckle never correspond across viewpoints; raising
  the tolerance would have moved the patch boundaries, not removed them. Comparing 4x thumbnails
  removed them completely. Defect 10 is the same shape: the drift warning returned because its
  reference was frozen while ARKit's pose ramps, and no threshold survives an unbounded ramp.
  **When a threshold has needed raising twice, the quantity being measured is the bug.**
- **Rotate-in-place is the pathological motion for VIO.** Pure rotation gives no translation
  baseline to triangulate against, so ARKit's reported position creeps over a long sweep. The
  whole capture model is rotate-in-place, so this is a permanent property of the app rather than
  an incident: anything comparing a live pose against one recorded minutes earlier must account
  for it. It is also a warning sign for the not-yet-measured VIO distance number.
- **A silent zero in a cost function disables the thing it prices.** The seam optimiser's
  `disagreement` term returned 0 whenever the neighbour's frame was missing from a cell's
  candidate list — common precisely AT boundaries, the only place the term matters. It looked
  correct in review and surfaced only as "the objective barely moves". When an optimiser will
  not move, suspect the cost before the minimiser.
- **Choosing WHICH frame wins is not the same as choosing WHERE it stops winning.** Every
  defence in this stitcher — feather, dominance, drift pricing, the agreement veto, the nadir
  cap — answers the first question. None answers the second, so the boundary lands wherever the
  frusta cross: through a hand, a face, a leg. This is the difference between a pose-based
  reprojector and a real stitcher, and it is what seam routing exists to fix.
- **A test whose scene is milder than reality will certify a broken fix.** `Tests/NadirCap`
  passed the nadir cap at 0.68% hard edges. Resizing its synthetic subject to the size and
  contrast of real legs against carpet took the SAME code to 1.31%. The fix was over-claimed as
  working "by construction"; the scene was simply too easy to contradict it.
- **Some regions cannot be blended, only chosen.** The nadir holds the operator's own body:
  parallax is extreme at 0.5 m AND the subject moves between frames, so every frame is telling
  the truth and no consistent answer exists. When there is no correct blend, a SINGLE source is
  the only artifact-free output — one frame means zero inter-frame boundaries by construction.
  The whole industry solo-sources the nadir for exactly this reason. Recognising an unsolvable
  region is a different skill from fixing a solvable one, and cheaper.
- **Constants tuned against a noisy measure need revisiting once the noise is removed.**
  `comparisonScale` measured no better at 8 than at 4 for two sessions. Once `exposureGains`
  took brightness differences out of the comparison, 8 became cleanly better on BOTH texture
  and anti-ghosting. The two effects were confounded, and the earlier measurement was not
  wrong so much as taken through a dirty window.
- **When a defence is added, the old baseline usually stops being a baseline.** The veto keeps
  firing at `dominance: 0`, so the harness's long-standing "plain average" reference silently
  became something else. Any new defence needs its own off-switch on `stitch` or the numbers
  quietly stop meaning what the labels say.
- **Coverage and overlap pull in OPPOSITE directions and must be balanced, not maximised.** Raising
  the mid ring closes the coverage gap against the cap ring but starves overlap; lowering it does
  the reverse. Shipping plan is 12×[0/±33] + 4×[±70] = 44 targets, the balance point:
  100% coverage under ±8° aim error, 90.5% overlap. Overlap margin is THIN (gate is 90%).
  If seams show on hardware, lower the mid ring toward 30° and add cap yaw steps — do not
  widen the rings.
- **Analytic coverage assumes perfect aiming and is therefore optimistic.** The app fires within
  `aimThresholdRadians` (8°), so frames are never on target. Simulating that (Tests/PanoramaDemo)
  turned a nominal 100% into 99.83% with visible black wedges at ±50–60°, where the mid ring
  mis-aimed low and the cap ring mis-aimed low both fall short at the same longitude. Any future
  plan change must be re-checked against the DEMO, not just the analytic search.
- **Do NOT apply an orientation transform when converting `capturedImage` to a CGImage.** The
  intrinsics describe the un-rotated landscape buffer; rotating the pixels silently invalidates
  them and the stitch fails in a way that looks like a blending bug.
- ARKit→CV convention flip in the stitcher: `p_cv = (x, −y, −z)`, so `u = fx·x/(−z) + cx` and
  `v = cy − fy·y/(−z)`. The harness confirms this is self-consistent, but it CANNOT confirm that
  real ARKit intrinsics match it — only a device run settles that.
- Pole singularity: `cross(worldUp, backward)` collapses to zero looking straight up/down and
  normalising it yields an all-NaN frame. Both camera-basis builders now fall back to a Z axis.
- `PanoramaStitcher.Result.coverage` is TRUE SOLID ANGLE (cos-latitude weighted per row), measured
  BEFORE hole filling. It is the honest "% of the sphere captured" and is safe to gate on and to
  show the user. It was formerly an equirect PIXEL count, which is a different and much more
  flattering number — a plan reaching ±53° latitude covers 80% of the sphere but 59% of the pixels
  — so any pre-2026-08-05 note about it, or any code re-deriving it from the output image, is
  stale. Never re-measure coverage from the output image: hole filling makes gaps non-black.
- **Uncovered directions are never black.** `fillHoles` is a pull-push image pyramid, so a gap of
  any size is closed in O(canvas). It interpolates; it does not invent detail.

### Open decisions
- Exact iPhone model for testing (unknown — determines whether LiDAR is available as a bonus).
- Apple Developer Program $99/yr — not needed yet, needed by ~Iteration 3 (TestFlight).

### DO NOT
- Do not plan cloud COLMAP photogrammetry for the MVP — violates the $0 constraint and gives no
  absolute scale. Deferred to a paid HQ mode (PLAN.md §2).
- Do not try walk-and-scan capture for panoramas — a panorama needs all rays from one point;
  walking creates parallax that cannot be stitched. Free-viewpoint walking needs Gaussian
  splatting, a Phase D idea, not an MVP path.
- Do not read free space from `df /` — that's the sealed snapshot. Use `/System/Volumes/Data`.
- Do not attempt AR builds in the iOS simulator — ARKit requires physical hardware.

## REVERTED TO THE SIXTH RUN'S CONFIGURATION (2026-08-06) — user decision, after run 14

**Why.** The user compared all six device recordings and judged run 14 materially worse than
its predecessors, then asked for the settings that were live at the best run. The recordings
carry the numbers on-screen and settle the ranking:

| Recording | Frames | Coverage | Changelog run |
|---|---|---|---|
| `ScreenRecording_08-05-2026 9-49-47 am_1.MP4` | 43 | 54.6% | second |
| `ScreenRecording_08-05-2026 10-15-23 am_1.MP4` | 50 | 58.6% | third |
| `ScreenRecording_08-05-2026 11-04-23 am_1.MP4` | 67 | 69.6% | fourth |
| `ScreenRecording_08-05-2026 12-47-12 pm_1.MP4` | 90 (cap) | 87.1% | fifth |
| `ScreenRecording_08-05-2026 1-32-01 pm_1.MP4` | 79 | **99.1%** | **sixth — the target** |
| `ScreenRecording_08-06-2026 2-33-37 pm_1.MP4` | unknown | unknown | fourteenth |

`IMG_3215.JPG` is almost certainly the sixth run's equirect — same room, same furniture,
4096x2048, and it is clean: full sphere, no white voids, only the usual nadir smear. **It is
the visual baseline run 15 is measured against.** Run 14 left no equirect at all.

**The revert was requested in full, and delivered in full, after the narrower option was
recommended and declined.** The recommendation was to revert only `.sceneDepth` and
`driftWarningMeters`, which would have restored run 9's configuration — the one this file
already calls "the baseline to protect" — while keeping the colour veto, exposure equalisation,
nadir cap and the run-12 deadlock fix. The user asked for run 6 literally. That is what this is.

**Reverted by CONFIGURATION, not by deleting code.** Every mechanism below is still present,
still compiled, and still tested; each is switched off at a single constant with the previous
value recorded in a comment beside it. There is no git history to recover these from — the
repository was initialised at this commit — so the comments are the only record. Six edits:

| # | File | Change | Restores |
|---|---|---|---|
| 1 | `PanoramaStitcher.swift:102` | `agreementToleranceLevels` 48 -> `.infinity` | colour veto did not exist at run 6 (added for run 7) |
| 2 | `PanoramaStitcher.swift:193` | `exposure:` default `true` -> `false` | exposure gains added for run 8 |
| 3 | `PanoramaStitcher.swift:172` | nadir ramp -50°/-60° -> -91°/-92° (unreachable) | nadir cap added for run 8 |
| 4 | `Capture.swift:238` | `.sceneDepth` insertion commented out | depth capture added for run 14 |
| 5 | `Capture.swift:403` | pre-gate `markCoveredTargets()` behind `if false` | deadlock fix added for run 13 |
| 6 | `SweepGeometry.swift:225` | `driftWarningMeters` 0.12 -> 0.30 | tightened for run 14 |

Edit 4 is exact rather than approximate: with `.sceneDepth` off, `CapturedFrame.depths` is nil
for every frame, and the stitcher's existing no-depth path is the rotation-only model byte for
byte. Edit 3 works because latitude never leaves [-90°, +90°], so the ramp arithmetic is never
reached and `rowDominance` stays at the plain `dominance` on every row.

**Two consequences that are NOT bugs and must not be "fixed" without a decision:**

- **The run-12 deadlock is back** (edit 5). A target aimed at ground the coverage map already
  holds can never be marked, because the only surviving marking pass is inside `capture`,
  behind the novelty gate that refuses that frame BECAUSE the direction is covered. A white
  marker will sit there saying "Hold here" and aiming at it does nothing, forever. **Finish on
  the coverage percentage, not on the markers.** Delete the `if false,` to undo.
- **Seam routing is now inert even if re-enabled** (edit 1). `routeSeams` is called with
  `tolerance: agreement`, and its gate switches routing off wherever frames agree — at infinite
  tolerance they always agree. Setting `seamSmoothnessWeight > 0` will silently do nothing
  until `agreementToleranceLevels` is restored to 48. `Tests/SeamStaircase` catches exactly
  this and is currently red because of it.

**Verification.** All five sources compile AND link for arm64 iOS, 0 errors, 0 warnings.
Ten of twelve host tests pass. Two are red, both tracking the deliberate config change rather
than a defect, and both left red on purpose so the next session sees the cost:
- `Tests/CaptureAdmission` — 4 checks, all asserting warning behaviour at
  `driftWarningMeters` 0.12. At 0.30 a 5-45 cm arm-length arc no longer warns, which is
  precisely the sixth run's documented behaviour.
- `Tests/SeamStaircase` — 1 check, asserting routing materially rewrites straight-edged
  content. It now measures 0 px, for the reason in the second bullet above.

**NOT VERIFIED: the output image.** This is a claim about CODE. Whether it reproduces the
sixth run's photograph is what run 15 measures, and only a device can produce it.

---

## SECOND DEVICE RUN (2026-08-05) — office, half a room
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 9-49-47 am_1.MP4`, 43 frames, in-app
label "54.6% of the sphere captured". User report: "the drift warning is working", "I couldn't get
the full room so it's just half the room, it's better but it's still smudgy."

**CONFIRMED FIXED by the first round of changes:**
- **No black wedges anywhere.** Pull-push fill works on real data.
- **Frame count 33 → 43** despite the new 12 cm drift gate also rejecting frames. The
  `maxAngularStepRadians` 0.6° → 2.5° change did what it was meant to.
- **The honest coverage label works and is doing its job**: "54.6% of the sphere captured / The
  rest was filled in from its surroundings". The old pixel-count metric would have quoted a much
  higher number for the same sweep. The user correctly read this as "I only got half the room".
- **Drift warning fires and is understood by the user.**
- Geometry still correct on hardware: ceiling tile grid, desk edges and window frames are straight.

**BROKE — 4. Uniform smudging, and it is NOT the two-frame seam problem previously assumed.**
Diagnosis from the native-resolution frames: near objects (people, chairs, foreground desks) show
DOUBLED edges and horizontal streaking across WIDE bands, while ceiling and far wall are crisp.
A two-frame crossover would smear a band only ~4° wide (~45 px at 4096). The observed bands are
several hundred px. The arithmetic explains it: 43 frames over 54.6% of the sphere, each spanning
~60°×46.8° ≈ 6% of the sphere, is **~5 frames seeing every direction**. Opportunistic capture
(`minSeparationRadians` = 10°) gathers far more overlap than the 44-target plan does, and the
weighted average was blending all five parallax-offset viewpoints, everywhere. Not a seam
artefact — a five-way average.

Fix: **`PanoramaStitcher.dominanceThreshold` = 0.5**, a second projection pass.
Pass 1 records the best weight any frame achieves per output pixel (pure geometry — no texture
sampling, so it is cheap); pass 2 admits only frames within 50% of that peak and rescales the
survivors so the winner reaches full weight and a borderline neighbour fades in from zero.
Most pixels now come from one or two frames. The feather exponent went back **feather⁶ → feather²**
in the same change: the feather now only has to RANK frames, and `dominanceThreshold` decides who
speaks. Trying to do both jobs with one exponent is what forced the choice between mush and hard
seams.

Verified by a new permanent test, `Tests/ParallaxSharpness` — 60 frames, viewpoint wandering ±6 cm
(inside what the capture gate allows), fine grating at 0.6 m, measuring mean |gradient| over the
equatorial band. Every frame is rendered from ITS OWN position, so parallax is reproduced, not
assumed:
```
dominance 0.00 (old plain average)  sharpness 5.48   coverage 59.2%   0.78 s
dominance 0.25                      sharpness 6.20   coverage 59.2%   0.61 s
dominance 0.50  <- SHIPPING         sharpness 7.28   coverage 59.2%   0.57 s
dominance 0.70                      sharpness 8.63   coverage 59.2%   0.56 s
```
**+32.8% sharpness at zero coverage cost, and FASTER** (pass 2 skips most bilinear fetches, which
more than pays for pass 1). Harness MAE unchanged at 1.28, so no geometric accuracy was traded.

0.70 scores higher still and was NOT taken: that test scene has uniform exposure, so it is blind
to the cost being paid — ARKit auto-exposure makes real frames differ in brightness, and a harder
cutoff turns that into visible steps. Do not raise this constant on the strength of that number
alone; raise it only if a device run still shows doubling AND shows no seams.

**Also: `storedFrameMaxDimension` 800 → 1024, `maxStoredFrames` 150 → 90.**
800×600 is CRITICALLY sampled against a 4096×2048 output — 13.3 px/degree against 11.4, only 1.17×
of headroom — and the Core Graphics downscale plus the stitcher's bilinear fetch each spend some of
it, so detail arrived soft before any blending. 1024×768 gives 1.5×. Frame count dropped in step to
hold the same ~283 MB memory ceiling (3.15 MB/frame); the two device runs stored 33 and 43, so 90
is not binding. Past ~5 frames per direction, extra views are discarded by `dominanceThreshold`
anyway — so spend the budget on resolution, not count.

## THIRD DEVICE RUN (2026-08-05) — same office, 50 frames, 58.6% of the sphere
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 10-15-23 am_1.MP4`.

**CONFIRMED FIXED — the smudging is gone.** At native resolution the panorama now resolves
individual ceiling tiles and their grid lines, the slats of an air-conditioning vent, a ceiling
projector and its cable, individual keys on a keyboard, the slats of a window blind, and the
toolbar icons of the CAD application on a monitor. The previous run turned all of that into mush.
People and chair backs have clean edges with no doubling. `dominanceThreshold` = 0.5 is validated
on hardware; the ~5-frames-per-direction average was the right diagnosis.

**No seams and no brightness steps**, which was the predicted cost and the reason 0.7 was not
shipped. Checked against the ceiling, which is the worst case (regular grid, uniform tone, so any
step would be glaring): tile lines run continuous and straight across frame boundaries.
**Do not raise `dominanceThreshold`** — 0.5 is buying the sharpness without paying the cost.

Residual softness is confined to (a) MOVING PEOPLE, which no geometric fix can address, and
(b) objects under ~1 m. Both are inherent. Treat the stitch quality gate as PASSED.

**BROKE — 5. The 12 cm hard drift reject was costing roughly half the sphere.**
This only became visible once three runs could be compared, and it is the clearest regression in
the project so far:

| run | drift gate | frames | solid-angle coverage |
|-----|-----------|--------|----------------------|
| 1   | none      | 33     | **~98%** (reported 97.9% of PIXELS with the poles missing; missing poles cost many pixels but little solid angle, so the true figure is higher still) |
| 2   | 12 cm hard reject | 43 | **54.6%** |
| 3   | 12 cm hard reject | 50 | **58.6%** |

Frame COUNT went up while COVERAGE nearly halved — the gate was not thinning a sweep evenly, it
was amputating whole directions. Pivoting far enough to see behind yourself moves a hand-held
phone well past 12 cm however carefully it is done, so the frames it rejected were exactly the
ones covering the far half of the room. The user reported the symptom directly: "I couldn't get
the full room". Half a room stitched sharply is worse than a whole room with some soft patches.

Fix: **price drift, do not ban it.**
- `CaptureQuality.maxTranslationMeters` (0.12, hard reject) → `driftWarningMeters` (0.12, warn
  only) + `driftHardLimitMeters` (0.6, genuine reject — past half a metre a frame is a different
  vantage point, not a slightly-off one, and would drag geometry if it ever won a pixel).
- `CapturedFrame.driftMeters` records the distance from the sweep origin. Defaults to 0 so the
  host tests, which model a perfect pivot, are unaffected.
- `PanoramaStitcher.driftHalfWeightMeters` (0.12): weight is multiplied by
  `1 / (1 + (drift/0.12)²)`, computed once per frame, not per pixel.
- The yellow banner now reads "Drifting — pivot around the phone, not your body, for sharper
  detail". It no longer implies frames are being discarded, because they are not, and implying it
  pushes the user to stop sweeping — which is the failure that cost two runs half the room.

This works BECAUSE of `dominanceThreshold`, and would not have been safe before it. A frame 12 cm
adrift carries half weight, so wherever a well-placed frame also sees that direction the drifted
one falls below the dominance cut and is dropped OUTRIGHT rather than averaged in. Where nothing
else saw it, it is the only candidate and wins. Drift therefore costs sharpness only in the places
that would otherwise have been interpolated holes.

Verified by a new permanent test, `Tests/DriftPricing`: an on-origin frame (grey 60) and a 25 cm
drifted frame (grey 200) aimed identically, plus a drifted frame alone on the far side.
Result: contested direction reads **grey 60** (drifted frame contributed nothing), uncontested
direction reads **grey 200** (drifted frame filled it). Both halves of the claim hold.

## FOURTH DEVICE RUN (2026-08-05) — 67 frames, 69.6% of the sphere
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 11-04-23 am_1.MP4`.

**CONFIRMED — drift pricing works, and sharpness held.** Coverage 58.6% → **69.6%**, frames
50 → 67, with no loss of detail: window blind slats and radiator fins resolve individually, a
recycling-bin logo is legible, wooden window frames and distant workstations are clean, and a
monitor back at arm's length shows no doubling. Removing the hard 12 cm reject cost nothing
visible, exactly as `Tests/DriftPricing` predicted. **Both stitch-quality dials are now settled:
`dominanceThreshold` 0.5 and `driftHalfWeightMeters` 0.12. Stop tuning them.**

**BROKE — 6. Coverage recovered only partway: the app cannot tell the user where to point.**
69.6% is +11 points, not the 90% predicted, so drift was A cause and not the whole cause. The
user's own account: "the missing 30% could be as I could not scan the full room." The arithmetic
matches the floor plus the top of the zenith — everything below −40° is 17.9% of the sphere and
everything above +60° is 6.7%, together ~25%.

Root cause is guidance, not capture. The targets are rendered as SCNSphere markers two metres
away, so a target behind, above or below the user is NOT ON SCREEN, and the status line
("keep turning toward the white markers") asks the user to turn toward something they cannot see.
That is unactionable for exactly the directions that go missing — nobody spontaneously points a
phone at their own feet.

Fix: **`SweepGuidance.hint`** turns the coverage map into an instruction — "Turn left and look
down", "Turn around", "Hold here" — for the nearest UNCAPTURED target, recomputed on every ARKit
callback (at most 44 dot products) and published to the main actor only when the wording changes.
Shown as a prominent blue label above the coverage bar, because incomplete sweeps rather than
stitch quality are now the thing limiting the product.

It lives in `SweepGeometry.swift`, not `Capture.swift`, specifically so it can be tested without
ARKit: an inverted left/right or up/down is invisible in review and actively harmful on device —
the user follows it, coverage gets *worse*, and the app looks broken. `Tests/GuidanceHint` pins
the sign of every axis, plus the ±180° seam (aiming at yaw 3.0 with a target at −2.5 must say
"turn right"; the unwrapped difference is −5.5 rad and would send the user 315° the wrong way),
independence from the sweep's origin heading, the deadzones, and — the case that matters most —
that with only the floor ring outstanding the app says **"Look down"**.

### Session friction (environment, not code)
GateGuard (`pre:edit-write:gateguard-fact-force`) blocks every Write/Edit once, requiring facts to
be restated before a retry. Disable with `ECC_GATEGUARD=off claude` or add the hook name to
`ECC_DISABLED_HOOKS`.

Bash tool `cd` does not persist between calls here — a `cd x && cmd` that fails mid-chain leaves
the next call at the repo root. Use absolute paths for the harness build.

---

## FIFTH DEVICE RUN (2026-08-05) — 90 frames, 87.1% of the sphere
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 12-47-12 pm_1.MP4` (the preview sheet
only; the capture screen was not recorded). On-screen readout: **"90 frames · 87.1% of the sphere
captured"**.

**CONFIRMED — the guidance hint works.** Coverage 69.6% → **87.1%**, +17.5 points, and the
panorama is a clean library interior: ceiling grid, window frames, monitors and bookshelves all
sharp, no seams, no brightness steps. Gate 1 stays passed. The guidance label is what bought this.

**BROKE — 7. The sweep ran out of FRAMES, not out of room.** 90 is exactly
`CaptureQuality.maxStoredFrames`, so the run did not end because the sphere closed; it ended
because the budget did, with 12.9% never seen. The ceiling was never the real constraint — 90
frustums are 5.7x the sphere's solid angle. The budget was being spent on frames that revealed
nothing: `minSeparationRadians` (10°) tests the frame's DIRECTION against stored frames, and a
direction 10° from its neighbours inside an already-covered patch passes that test while its
47x60° frustum lands almost entirely on ground three other frames have seen.

Fix: **a novelty gate on the second half of the budget** (`CoverageMap.novelty`,
`CaptureQuality.noveltyGateFraction` 0.5, `minNoveltyFraction` 0.005). The first 45 frames are
admitted as before — early frames cannot be judged on novelty and the blend needs the overlap.
Past 45, a frame must newly reveal ≥0.5% of the sphere (a fourteenth of a frustum, i.e. it is
refused once >93% of what it sees is already captured). Once coverage passes `goodCoverage` the
same gate switches from buying first views to buying second ones, which is what the seam blend
runs on. The test runs BEFORE the Core Graphics downscale, so a refused frame costs a 2592-cell
loop rather than a render.
`Tests/CaptureAdmission` replays a deliberately horizon-heavy sweep through the exact admission
rule: **76 frames to 99.8% coverage / 97.4% overlap**, against this run's 90 to 87.1%.

**BROKE — 8. The drift banner was stuck on, and its threshold was not survivable anyway.**
User's report: "at one point the app is not able to recognize its original position and always
displays the drifting warning; a human will not be able to stay still at a point however hard
they try." Two independent defects, both real:

1. *Structural.* `isDrifting` was published from inside the storage path, AFTER
   `guard state.frames.count < maxStoredFrames` and `guard smoothCount >= ...`. Once the budget
   filled at 90 frames, that guard returned on every subsequent callback and nothing ever ran to
   take the banner down again — it froze on whatever it last said, for the rest of the sweep.
   The same freeze happened whenever the user paused mid-turn. Drift is now evaluated on EVERY
   tracked frame, before all storage gates, and cleared on tracking loss (ARKit can shift the
   world origin on relocalisation, and a distance measured across that jump is meaningless).
2. *Numerical.* `driftWarningMeters` was 0.12 m. That is below what a standing human can hold:
   the phone is at arm's length, so pivoting the body — the only way to turn through 360° —
   swings the camera on a 20–40 cm arc before any stepping happens. Now 0.30 m to warn, 0.20 m
   to clear (hysteresis, so it cannot strobe while the user hovers on the limit), and 15
   consecutive frames over the limit before it appears (~0.25–0.75 s), so leaning round a chair
   is silent. Extracted into `DriftMonitor` in `SweepGeometry.swift` so it is host-testable —
   a warning that is on when it should be off is a product defect, not a numerical one, and it
   should not need a room to reproduce.

**Unchanged on purpose:** the stitcher's own `driftHalfWeightMeters` stays at 0.12. The blend
should keep pricing small drift even when it is not worth interrupting the user about; the
advisory threshold and the blending threshold are now deliberately decoupled.

Changed files: `Sources/SweepGeometry.swift` (`DriftMonitor`, `CoverageMap.novelty`,
`CoverageMap.halfFOVs`, drift + novelty constants), `Sources/Capture.swift` (drift moved ahead of
the storage gates, novelty gate, frustum computed once and shared with the coverage map, honest
at-capacity status), `Tests/CaptureAdmission/main.swift` (new).

---

## SIXTH DEVICE RUN (2026-08-05) — 79 frames, 99.1% of the sphere, + Matterport A/B
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 1-32-01 pm_1.MP4` (ours) and
`ScreenRecording_08-05-2026 1-41-12 pm_1.MP4` (Matterport, same room — Frederick Lanchester
Building library, "1 Scan", Simple Scan mode).

**CONFIRMED — both run-5 fixes landed, and the prediction was accurate.** On-screen:
**"79 frames · 99.1% of the sphere captured"**, against run 5's 90 frames / 87.1%. The novelty
gate closed the sphere while spending ELEVEN FEWER frames. `Tests/CaptureAdmission` predicted
76 frames / 99.8% from a synthetic horizon-heavy sweep; the device delivered 79 / 99.1%. The
drift banner did not appear at all. **Coverage is now a solved problem — 54.6 → 58.6 → 69.6 →
87.1 → 99.1%. Stop working on it.**

### The Matterport A/B — the honest read
Our instinct going in was that we were ahead. Half right, and the half that is wrong is the
half that matters commercially.

**We win the far field, and not narrowly.** At the same viewing distance our panorama resolves
book spines on the shelves, individual ceiling coffers, keyboard keys, denim texture on a
jacket, and faces at neighbouring workstations. Matterport's equivalent view is soft
everywhere — edges washed, no legible text, ceiling structure smeared into a gradient. This is
a real and defensible advantage: we shoot 1024 px frames at the full sensor resolution and
select rather than average, and it shows.

**They win the near field, and it is the failure that reads as "broken".** Every Matterport
near object is intact: chair backs, castors, table legs, all single and solid. Ours doubles
them — a chair 1 m away appears twice, translucently, with a smeared blob beside it, and the
carpet around it goes to mush. A soft image reads to a user as "a bit low-res"; a doubled chair
reads as "this app does not work". **They are more RELIABLE and we are more DETAILED**, and
reliability is the one a customer judges first.

Their softness is very likely deliberate and is the same trade seen from the other side: blur
the composite enough and disagreements between viewpoints never surface as ghosts.

### The smudges: root cause, and the fix
Not a tuning problem — a missing question. `dominanceThreshold` asks which frames are
GEOMETRICALLY competitive for a pixel. It has no way to ask whether they AGREE. Two frames can
both see a direction dead-centre, both score ~1.0 relative weight, and still be looking at
different things, because a hand-held sweep pivots around the user rather than the lens and a
near object slides across its background between them. They are equally well placed — which is
exactly why both get to speak, and why raising dominance cannot help.

Fix: **`agreementToleranceLevels` (48/255) — a colour veto**, in `PanoramaStitcher`. Pass 1 now
records not just the peak weight per pixel but the COLOUR the best-placed frame saw there.
Pass 2 refuses a vote to any rival whose colour differs by more than 48 levels on any channel.
Where competitive frames agree they are on the same surface and averaging is right (it hides
seams and averages out exposure wobble and noise); where they disagree one of them is wrong and
the best-placed frame is believed. The best frame meets itself and always agrees, so **the veto
can only ever remove a second opinion, never the first — it cannot punch holes.**

`Tests/ParallaxSharpness` was rewritten to isolate what each defence is worth. It now measures a
TRUE baseline, which required exposing `agreement:` on `stitch` alongside `dominance:` — the
veto keeps firing at dominance 0, so dominance 0 was no longer a plain average and the old
"+32.8%" baseline had silently stopped being one:

```
plain average (no defence)          sharpness   5.48   coverage 59.2%   0.86 s
dominance 0.50 only                 sharpness   7.28   coverage 59.2%   0.66 s   +32.8%
colour veto 48 only                 sharpness  12.32   coverage 59.2%   0.65 s  +124.8%
SHIPPING: dominance 0.50 + veto 48  sharpness  12.19   coverage 59.2%   0.60 s  +122.5%
```

**The veto is worth roughly four times what geometric dominance is**, against reproduced
parallax, at byte-identical coverage (spread 0.00e+00 across all seven configurations) and
slightly FASTER — vetoed frames skip their accumulator writes. `StitchHarness` MAE also improved
1.28 → 1.27. Dominance is kept at 0.50 despite the sweep marginally preferring 0.25: the
synthetic scene has no exposure variation, so it cannot see the seam-banding that dominance
exists to prevent. Do not lower it on this evidence.

**Not yet proven on hardware.** The +124.8% is against reproduced parallax in a synthetic scene.
Run 7 is what confirms it against real doubled chairs.

### Full-screen viewer
`PanoramaPreview` gained an immersive mode (`fullScreenCover`, expand button top-right of the
thumbnail). Edge-to-edge including under the notch, controls auto-fade after 2.5 s and return on
tap, tap gesture chosen over a button overlay so it cannot block the drag that turns the camera.
The 320-point box reads as a thumbnail of a photo rather than a place, and it is also the only
view in which our output can be compared like-for-like against Matterport, which presents scans
full-bleed.

Changed files: `Sources/PanoramaStitcher.swift` (`agreementToleranceLevels`, peak-colour buffer,
`agreement:` parameter, veto in the accumulation pass), `Sources/App.swift` (immersive viewer),
`Tests/ParallaxSharpness/main.swift` (rewritten to isolate both defences and assert coverage is
untouched).

---

## SEVENTH DEVICE RUN (2026-08-05) — 85 frames, 98.8%; veto backfired, drift returned
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 2-11-15 pm_1.MP4`. The recording is
entirely inside the new immersive viewer, so the capture screen and its banner are not in it —
the drift report is the user's, not the video's.

**CONFIRMED — coverage and the full-screen viewer.** 85 frames / 98.8%, second run in a row to
close the sphere. The immersive viewer works as intended. **Ceiling ghosting is GONE** — the
run-6 doubled beam is a clean single beam, and near chairs in the wide shots are single and
solid. The colour veto did the job it was added for.

**BROKE — 9. The veto fired on CARPET and stitched the floor into hard-edged patches.**
Straight-line frame-frustum boundaries plainly visible across the carpet, with texture wiped
flat inside some of them. This is the exact failure mode flagged as the one to watch after run 6
("hard-edged blotches on flat walls, where the veto fires on shading rather than an object
boundary") — but the prescribed remedy there, raising `agreementToleranceLevels` toward 64, was
**wrong**, and would only have moved the boundaries rather than removing them.

Root cause is the MEASURE, not the threshold. The veto compared RAW per-pixel colour, and carpet
is high-frequency speckle. Two frames viewing the same square of carpet from viewpoints a few
centimetres apart do not sample corresponding grains — the speckle simply does not correspond —
so honest per-channel differences of 50-80 levels occur on a surface both frames see perfectly
correctly. Comparing raw pixels asks *"is this the same speckle?"*, which has no answer across
viewpoints. The question that does have one is *"is this the same surface?"*

Fix: **`comparisonScale` = 4.** The agreement test now compares 4x-downscaled per-frame
thumbnails, never the full-resolution pixels. A 4x4 box average destroys speckle and sensor
noise while preserving everything the veto needs — a chair against a floor still differs by
60-150 levels at quarter resolution, because that is a structure tens of pixels across. Output
colour is still always drawn from full-resolution pixels, so this costs no sharpness anywhere.

`Tests/TextureBlotching` (new) reproduces the failure on a synthetic wall of pure speckle where
NOTHING genuinely disagrees, so any large-scale structure in the output is invented. Two
measures: *blotchiness* (std-dev of the heavily blurred output) and *edge hardness* (95th
percentile step between neighbouring block means — because what made run 7 conspicuous was that
the boundaries were hard, and blotchiness alone cannot see that).

```
no veto (reference for 'smooth')     blotch 3.295   hardness 6.104
RUN 7: compared on RAW pixels        blotch 4.046   hardness 7.681
compared on 2x thumbnails            blotch 3.603   hardness 6.604
SHIPPING: compared on 4x thumbnails  blotch 3.303   hardness 6.111
compared on 8x thumbnails            blotch 3.295   hardness 6.104
```

4x lands on the no-veto reference to three decimal places, and 8x buys nothing further — so 4x
is already past the texture scale and going coarser would only blur away real disagreements.
**Per-frame exposure variation turned out to be essential to reproducing the artifact at all**:
speckle alone produces no visible patch, because a rejected rival on uniformly lit ground has
the same mean as the survivor. What makes a patch VISIBLE is that ARKit auto-exposure leaves
each frame at a different level, so wherever the veto changes its mind the region's mean steps.
A test without that measures speckle handling but not the defect.

Anti-ghosting did not merely survive the change, it improved: `ParallaxSharpness` now reports
**+125.3%** over a plain average, against the run-7 build's +122.5%.

**A smooth rolloff was tried and REMOVED.** The hypothesis was that a binary cut must draw hard
edges wherever the measure crosses the threshold, so agreement should scale weight continuously.
Measured, it was strictly worse on all three numbers once the comparison was low-passed —
sharpness 11.92 vs 12.35, blotching 3.51 vs 3.30, hardness 6.45 vs 6.11 — because with a correct
measure the veto stops firing spuriously and there is no boundary left to soften. Deleted rather
than kept as insurance. **Fixing the measure was the fix; the ramp was treating the symptom.**

**BROKE — 10. The drift warning returned, and for a different reason than run 5.**
Run 6 was clean, run 7 was not, and the difference is sweep LENGTH. The reference was frozen at
the first frame of the sweep, and ARKit's world origin does not hold still for minutes. A
rotate-in-place sweep is the pathological motion for visual odometry — pure rotation gives no
translation baseline to triangulate against — so the reported position creeps away from truth
the longer the sweep runs. Past a few minutes that creep alone exceeds any sane threshold.
**This is a rate problem, not a threshold problem, and raising the threshold a third time would
have kept being wrong**: an unbounded ramp crosses any fixed line eventually.

Fix: **`driftReferenceCreepMetersPerSecond` = 0.02.** `DriftMonitor` now takes positions rather
than distances and measures against a reference that follows the camera at 2 cm/s, with `dt`
taken from `ARFrame.timestamp` (ARKit's delivery rate to a busy delegate varies threefold, so a
per-frame creep would mean different things at different moments). VIO drift is slow, gradual
and unbounded; a person stepping away is fast and over in a second — separable by RATE, which is
the whole basis of the fix. Over a three-minute sweep the creep absorbs 3.6 m of accumulated
error, while someone walking half a metre in half a second outruns it by two orders of magnitude.

Scoped to the WARNING only. `CapturedFrame.driftMeters`, which the stitcher prices frames by,
and `driftHardLimitMeters`, which rejects frames from a genuinely relocated viewpoint, both stay
anchored to the true sweep origin — those are geometry questions, not user-messaging ones.

`Tests/CaptureAdmission` gains both halves: a metre of VIO drift over three simulated minutes
never warns, and a real 60 cm step taken on top of 30 cm of accumulated drift still does.

**Test-authoring note worth keeping.** Handing a fresh `DriftMonitor` a displaced position
anchors it THERE and it correctly reports zero drift. Tests must start at the origin like a real
sweep does — three assertions failed on this before the tests were fixed, not the code. The
hysteresis and flicker tests also had to be restated in terms of the MEASURED distance, since
with a creeping reference a fixed camera position no longer means a fixed distance.

Changed files: `Sources/PanoramaStitcher.swift` (`comparisonScale`, `Thumbnail`, thumbnail-based
agreement, `comparison:` harness parameter; rolloff added then removed),
`Sources/SweepGeometry.swift` (`driftReferenceCreepMetersPerSecond`, `DriftMonitor` creeping
reference + position/dt API), `Sources/Capture.swift` (frame timestamps, drift measured against
the monitor's reference while the stitcher's stays origin-anchored),
`Tests/TextureBlotching/main.swift` (new), `Tests/CaptureAdmission/main.swift` (position API,
VIO-drift cases, restated hysteresis/flicker).

---

## EIGHTH DEVICE RUN (2026-08-05) — 88 frames, 97.9%; carpet fixed, nadir exposed
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 3-23-09 pm_1.MP4`.

**CONFIRMED — the run-7 carpet fix works on hardware.** Mid-field carpet is continuous texture
with no patches and no straight-line boundaries, exactly as `Tests/TextureBlotching` predicted.
Chair castors sharp and single, shoes sharp and single, far field (bookshelves, ceiling grid,
monitors) the best yet. **88 frames / 97.9% — third clean coverage run running.** Ceiling
rectangles that looked like artifacts at preview resolution turned out, at full resolution, to
be a real boxed soffit and ducting.

**BROKE — 11. The nadir is wedges, and it is not a bug in any measure.** Looking straight down
at the operator's own legs and feet: a razor-straight diagonal across denim, a triangle of chair
seat, a leg drawn twice. Unlike defects 1-10 there is nothing here to correct, because two
things make the bottom cap unblendable in principle:
  1. **Parallax is extreme.** The subject is ~0.5 m away, so a 30 cm body pivot moves the
     viewpoint by more than half the subject distance and frames genuinely see different things.
  2. **The subject moves.** It is the user's own body, shifting as they turn, so there is no
     static scene for two frames to agree about even in principle.
Every frame is telling the truth and there is no consistent answer to blend toward. Tuning
`agreementToleranceLevels` or `comparisonScale` cannot help.

Fix: **`nadirNarrowLatRadians` (-50 deg) / `nadirSoloLatRadians` (-60 deg).** Below -50 the
dominance threshold ramps continuously to 1, and below -60 exactly one frame — the best-placed —
paints. One source means zero inter-frame boundaries by construction. This is the standard
industry resolution (Street View, Insta360, Matterport all single-source the nadir, because the
tripod or the operator is always there), and nothing real is lost: the region handed to one
frame is precisely the region where blending had nothing coherent to add. The handover is ramped
rather than switched so no seam is drawn at the boundary line itself. **No matching zenith cap**
— ceilings are far, static and blend fine, so capping them would discard real seam-hiding for
no benefit.

**BROKE — 12. Brightness mismatches between overlapping photos** (user: "there are some overlaps
and mis match in the photos as well"). ARKit re-meters continuously, so each stored frame sits
at a slightly different exposure, and the blend shows that as a step wherever authorship changes
hands — a wall at one brightness on one side of a handover and another on the other.

Fix: **`exposureGains`**, a per-frame multiplicative correction estimated from the overlaps
themselves. For every pair of frames whose view cones can intersect, a coarse grid of directions
is projected from one into the other and their low-passed lumas compared; samples disagreeing by
more than the agreement tolerance are EXCLUDED, because those are parallax or a moving subject
and "correcting" brightness toward them would be correcting toward something that is not an
exposure difference. Each pair yields one constraint, solved in the log domain by weighted
Jacobi relaxation (64 sweeps over <=90 nodes, microseconds), then mean-centred so the panorama's
overall brightness is untouched and clamped to 0.7...1.4. Applied to pass-1 records, pass-2
comparisons AND accumulated colour, so the agreement veto compares frames on equal terms —
otherwise a brightness difference reads as a disagreement about content and the veto fires on
exposure, which is the one thing it must never do.

Measured (`Tests/NadirCap`): horizon brightness spread **5.965 -> 1.646**, a 72% reduction, with
byte-identical coverage. `Tests/TextureBlotching` blotching **3.30 -> 1.19**.

**The median matters.** The estimator first used the ratio of summed lumas per pair. That is
biased by the asymmetries always present in practice — samples landing near one frame's edge, a
bright window in half the overlap — and it cost `StitchHarness`'s projection MAE 1.27 -> 1.69 on
a scene whose frames have NO exposure difference at all, i.e. the estimator inventing a
correction. Switching to the median of per-sample log ratios restored MAE to 1.28.

**`comparisonScale` raised 4 -> 8, and only because exposure matching landed first.** Before it,
8x measured no better than 4x. With brightness noise removed from the comparison, 8x is cleanly
better on BOTH axes — texture blotching 1.116 vs 1.211, anti-ghosting sharpness 12.49 vs 12.36 —
and 16x falls back to 12.36, so 8 is a measured peak rather than an extreme. **The two effects
were confounded: exposure noise in the comparison was masking what a coarser low-pass could
do.** A reminder that constants tuned against a noisy measure need revisiting once the noise is
removed.

Net: anti-ghosting **+125.3% -> +128.8%** over a plain average. Exposure estimation is free —
90 frames stitch in ~1.0 s with it on or off.

`Tests/NadirCap` (new) reproduces the failure directly: a close, per-frame-INCONSISTENT subject
below the horizon over a static textured floor, with per-frame exposure variation. Asserts the
solo-sourced cap is free of hard edges (0.68%), is still fully painted (100% — a cap that
punched a hole would also score zero hard edges, so this is what makes the first check mean
anything), and that the normally-blended band above it is untouched (0.00%).

Changed files: `Sources/PanoramaStitcher.swift` (`nadirNarrowLatRadians`, `nadirSoloLatRadians`,
`exposureGains`, per-row dominance ramp, gain threaded through both passes, `comparisonScale`
4 -> 8, `exposure:` harness parameter), `Tests/NadirCap/main.swift` (new),
`Tests/TextureBlotching/main.swift` (scale sweep re-centred on 8).

---

## NINTH DEVICE RUN (2026-08-05) — 90 frames, 98.1%; audit findings
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 3-57-50 pm_1.MP4`.

**CONFIRMED — exposure matching and the nadir cap both do real work.** Carpet is continuous with
uniform brightness across the whole floor; no exposure steps anywhere, which is the visible form
of the 5.97 -> 1.64 horizon-spread measurement. Chair castors sharp and single, a cream puffer
jacket rendered single and solid with real fabric detail, and **the legs that run 8 drew as a
doubled bowtie are now single and continuous**. Fourth clean coverage run: 98.1%.

**BROKE — 13. The "by construction" claim about the nadir cap was WRONG, and the test that
should have caught it was too weak.** Run 9 still shows hard-edged regions in the bottom cap:
a flat pale shape with razor-straight boundaries cutting across a leg.

The claim in the run-8 entry — "one source means zero inter-frame boundaries by construction" —
does not hold. The cap picks a winner PER PIXEL, so the winning frame still changes across the
cap; at 0.5 m two frames disagree so violently that the changeover is itself a hard edge.
Solo-sourcing removed the BLEND (hence no more ghosting or translucency — a real and visible
win) but not the authorship BOUNDARY.

`Tests/NadirCap` passed at 0.68% hard edges because its synthetic subject was too small and too
low-contrast. Enlarging it to the size and contrast of real legs against carpet takes the same
code to 1.31%, above the 0.2% a genuinely edge-free cap would score. The assertion now records
1.31% as an OPEN DEFECT with the target stated, rather than asserting a number the code happens
to pass. **A test whose scene is milder than reality will certify a broken fix.**

**Root cause, and it is the same one behind the user's three questions** ("why is the image of
that girl duplicated, why is the hand cut off, why is the guy to my right not fully captured"):
the authorship boundary follows FRUSTUM GEOMETRY, not image content. Wherever two frames' claim
regions meet, the boundary falls where the geometry puts it — straight through a hand, a face, a
leg. Combined with a scene that is not static (people move between frames, so a person genuinely
occupies different places in different photos), the result is a person appearing twice, a hand
sliced in half, a body partly present.

This is NOT a tuning problem and no constant addresses it. Every existing defence decides WHICH
frame wins a pixel; none decides WHERE the handover happens.

**The fix is seam routing** — choose the boundary so it runs through regions where the frames
AGREE (low-contrast, matching areas) instead of wherever the frusta cross. This is the standard
technique (graph-cut / minimum-error boundary, as in Kwatra et al. and OpenCV's stitching
module), and it is what separates a pose-based reprojector from a real stitcher. It is a
substantial piece of work — a label field plus a global optimisation — and it is the single
highest-value change remaining. NOT started in this session.

**Also flagged by the audit: the frame budget was exhausted again.** 90 frames is exactly
`maxStoredFrames`, and coverage finished at 98.1% — below `goodCoverage` (0.99), so the novelty
gate never switched to buying second views; it simply ran out while still in depth-1 mode. Runs
6-8 finished at 79/85/88, so this is the first time since the gate landed that the ceiling
bound. Worth watching: if run 10 also lands on exactly 90, `minNoveltyFraction` is too permissive
for long sweeps and should rise before `maxStoredFrames` does.

Changed files: `Tests/NadirCap/main.swift` (adversarial subject sized and contrasted like real
legs; assertion restated as a characterised open defect with its target).

---

## SEAM ROUTING — implemented, measured, and defaulted OFF (2026-08-05)
Not a device run. A response to run 9's defect 13, and a negative result worth keeping.

**The diagnosis stands.** Every defence in the stitcher — feather, dominance, drift pricing,
the agreement veto, the nadir cap — answers "WHICH frame wins this pixel". None answers "WHERE
does it stop winning", so the boundary falls where the frusta cross: through a hand, a face, a
leg. That is why run 9 duplicated a person and cut a hand in half.

**The mechanism was built.** `routeSeams` produces a label field on a coarse grid (4096x2048 /
16 = 256x128 cells), keeping the top 4 candidate frames per cell with their low-passed colours,
then minimising `dataCost + smoothness * disagreement` across neighbours. `SeamField.share` is
bilinear over that grid, making the labels a partition of unity so the handover ramps over about
a cell rather than stepping. `FrameProjector` was extracted so the seam pass and the accumulation
pass cannot disagree about where a frame sees a direction.

**It does not earn its place, and the reason is the OPTIMISER, not the idea.**

```
smoothness   seam cost   sharpness      (Tests/ParallaxSharpness)
0 (off)         141002       12.49
0.02            134704       12.05
0.10            135005       12.06
```

A 4.5% reduction in boundary disagreement for a 3.4% loss of sharpness, and on `Tests/NadirCap`
no reduction in hard edges at all. Iterated conditional modes is greedy: flipping one cell
creates two new boundaries, so it almost never helps in isolation and the field sticks near its
initial argmax labelling. Real benefit needs coordinated moves — alpha-expansion over a
max-flow/min-cut — which is a substantially larger piece of work and precisely why every serious
stitcher carries a graph-cut solver. `seamSmoothnessWeight` is therefore **0 by default**; the
scaffolding is kept because alpha-expansion needs exactly it, and only the minimiser must be
replaced. `PanoramaStitcher.lastSeamCost` is the number to move.

**Two things were learned that outlast the attempt.**

1. **Routing does not remove the need to veto.** The first version let the transition band blend
   unconditionally, on the reasoning that the seam had already been placed well. That cost
   **12.49 -> 10.94 sharpness** — most of what the agreement veto is worth — because a
   cell-wide ramp across two disagreeing frames ghosts exactly as an unvetoed blend always did.
   Restoring the veto inside the band recovered it to 12.05. Routing and vetoing answer
   different questions and neither substitutes for the other.
2. **A silent zero in a cost function disables the thing it prices.** `disagreement` returned 0
   whenever the neighbour's frame was absent from this cell's top-k — which is common *at
   boundaries*, the only place the term matters. The optimiser felt no pressure exactly where it
   was supposed to. Fixed by evaluating at the neighbour cell too. The bug was invisible in
   review and only showed up as "the objective barely moves".

**Net effect on shipped behaviour: NONE.** With `seam: 0` the field is nil and `project` takes
the identical pre-existing path. Verified by the numbers being unchanged: ParallaxSharpness
+128.8%, NadirCap 0.0131, StitchHarness MAE 1.28, TextureBlotching green. **The build is
byte-for-byte the run-9 behaviour** — the run the user judged best.

Changed files: `Sources/PanoramaStitcher.swift` (`FrameProjector` extracted, `SeamField`,
`routeSeams`, `seam:` parameter defaulting to 0, `lastSeamCost` diagnostic).

---

## TENTH DEVICE RUN (2026-08-05) — cinema, seated; and SEAM ROUTING NOW EARNS ITS PLACE
Evidence: `mobile/ios_capture/ScreenRecording_08-05-2026 7-42-31 pm_1.MP4` (26 s, the in-app
360 viewer, not the capture screen) and `mobile/ios_capture/IMG_3209.JPG` (4096x2048, the real
production output). A cinema auditorium, captured seated — the hardest scene attempted so far:
near-darkness, a moving person at ~1 m, and a seated operator who cannot rotate freely.

**CONFIRMED — the pipeline holds up in a genuinely hard room.** Full sphere with no black
wedges. Carpet continuous, no exposure steps, ceiling and seat rows geometrically straight, the
seat number "11" legible. Everything closed in runs 6-9 stayed closed.

**NOT A DEFECT — the repeated wall panel.** The panorama shows two similar lit wall panels with
similar seat rows beneath them, ~46 deg apart, which is suspiciously close to the camera's
46.8 deg horizontal FOV and looked like a frame placed a full frustum from where it belonged.
It is not. Normalised cross-correlation of the two blocks peaks at **0.45**, where a duplication
of the same content would sit above 0.85, and a structural (high-passed) self-similarity scan of
the whole wall band finds no peak anywhere (max 0.03). Two genuinely different side-wall panels.
Recorded because the FOV coincidence is a trap worth not falling into twice.

**CONFIRMED STILL OPEN, and severe — defect 13, seam placement.** At native resolution the
person in the panorama is cut by a razor-straight vertical boundary through the middle of her
face, with a second forehead and eye visible on the far side of it, and her forearm is cut by
another straight edge. Boundaries are visibly blocky at roughly the comparison-thumbnail scale.
This is exactly the run-9 diagnosis with a worse scene: the authorship boundary follows frustum
geometry, not image content, and the subject moved between frames.

**ALSO OPEN — large hole-filled regions in the upper rear.** The ceiling behind the operator is
smooth, detail-free interpolation over a wide area. Expected for a SEATED capture, which cannot
reach the rings behind the shoulders, and the honest consequence of a plan designed for a
standing pivot. Not a stitcher defect; a capture-coverage one.

---

## SEAM ROUTING — ICM replaced with alpha-expansion; now ON by default (2026-08-06)
The negative result recorded in the previous seam-routing section is now positive. The diagnosis
was always right and the mechanism was always right; the MINIMISER was the whole problem, exactly
as that entry predicted.

**What changed.** `Sources/GraphCut.swift` (new, ~170 lines) is a Dinic max-flow / min-cut
solver. `routeSeams` now runs alpha-expansion over it: for one candidate label at a time, every
cell simultaneously decides whether to switch to that label, and the globally best such decision
IS a minimum cut. Iterated conditional modes asked each cell alone, and flipping one cell in
isolation creates two new boundaries where flipping a whole region creates none — which is why
the field never left its initial argmax labelling.

The binary term is folded in by Kolmogorov-Zabih reparameterisation, so no auxiliary nodes are
needed. Submodularity is guaranteed by truncating the both-keep term to the sum of the other two;
that can only under-price an existing boundary, never invent one, so the worst case is a seam
left where it was.

**The measurement, on `Tests/ParallaxSharpness`, seam cost quoted before-routing -> after:**

```
                seam cost              sharpness   blotch   cap edges
ICM   0.02      141002 -> 134704 (-4.5%)   12.05     —        0.0131
ICM   0.10      141002 -> 135005 (-4.3%)   12.06     —        0.0131
EXP   0.02      148836 ->  84614 (-43%)    12.71    1.116     0.0131
EXP   0.05      148836 ->  74076 (-50%)    13.16    1.116     0.0131
EXP   0.10  <- SHIPPING  ->  69011 (-54%)  13.46    1.116     0.0131
EXP   0.25      148836 ->  64282 (-57%)    13.87    1.116     0.0131
EXP   1.00      148836 ->  57292 (-62%)    14.33    1.116     0.0131
off             148836                     12.49    1.116     0.0131
```

Both signs reversed: ICM moved the objective 4.5% and LOST 3.4% sharpness; alpha-expansion moves
it 54% and GAINS 7.8%. Sharpness rises rather than falls because a routed region is painted by
ONE frame consistently instead of cross-fading between two wherever their frusta meet. Coverage
is byte-identical across every row (spread 0.00e+00), and StitchHarness MAE is 1.27 against 1.28
before, so no geometric accuracy was traded.

**0.10 is derived, not the best number in that table.** Sharpness there keeps climbing to 1.00
and that number is not to be believed — every frame in that scene renders at identical quality,
so it cannot price letting one frame claim ground far outside its sweet spot. This is the same
blindness that made `dominance` 0.70 look best on the same test and get correctly rejected. The
data term is bounded by 1 per cell and a boundary term is `smoothness * colour distance`, so the
ratio fixes how far the seam may detour: at 0.10, a boundary through content disagreeing at
exactly the veto tolerance (48 levels) costs 4.8 cells' worth of placement quality, so the router
walks about five cells around a hand and no further.

**Two gates, both forced by measurement rather than added defensively.**

1. **Routing does nothing where frames agree** (`SeamField.contested`). Routing everywhere took
   `Tests/TextureBlotching` from 1.116 blotch / 5.17 hardness to **1.58 / 7.81** on a wall of
   pure speckle — most of the way back to the run-7 carpet patchwork that is supposed to be
   closed. Nothing on that wall genuinely disagrees, so every territory the router drew there was
   an artifact it invented. Gating on the same tolerance the colour veto uses makes routing
   byte-identical to off on that scene. The gate needs no feathering of its own: it fires where
   disagreement crosses the veto tolerance, and there the two paths are choosing between frames
   that agree to within that tolerance, so they produce near-identical colour.
2. **Routing stops at the solo nadir cap** (`rowDominance < 1` in `project`). Inside the cap the
   two are alternative answers to the same question, and the cap measures better: routing cut the
   cap's boundary disagreement by three quarters yet raised hard edges **0.0131 -> 0.0216**,
   because a 16-pixel label grid plus a one-cell ramp lands the handover more abruptly than the
   per-pixel argmax it replaces, and at 0.5 m no colour distance is small enough to hide it.

**Cost: the stitch got slower.** `Tests/PanoramaDemo` at production 4096x2048 went **0.44 s ->
1.79 s** for 44 frames on this Mac. Expansion is per-label, so a 90-frame device sweep will be
worse than double that. Unmeasured on hardware and the first thing to check on run 11.

**New test: `Tests/GraphCutSolver`.** Runs with no other sources:
`swiftc -O Sources/GraphCut.swift Tests/GraphCutSolver/main.swift`. Nine checks — CLRS 26.1
(flow 23), a bottleneck that must not be routed around, the case that only reaches its answer by
undoing flow through a residual edge, disconnected and zero-capacity degenerates, and max-flow
equalling the cut `sourceSide` induces on a random 12x12 grid. That last one is the important
one: if `solve` and `sourceSide` ever disagreed, the router would minimise one thing and act on
another. A wrong max-flow does not crash — it silently returns a worse labelling, whose only
symptom is "routing does not help much", which is indistinguishable from "the idea does not work".

**New permanent assertions.** `ParallaxSharpness` now fails the build if routing cuts boundary
disagreement by less than 40% or costs any sharpness — either would mean the minimiser has
regressed toward a greedy one. `TextureBlotching` fails if routing changes blotch or hardness at
all on agreeing ground — the guard on the carpet-patchwork regression.

Changed files: `Sources/GraphCut.swift` (new), `Sources/PanoramaStitcher.swift` (alpha-expansion
replaces the ICM sweep; `seamCycles` replaces `seamIterations`; `disagreement` now averages both
cells of an edge and is symmetric; `SeamField.contested`; `lastSeamCostBeforeRouting`;
`seamSmoothnessWeight` 0 -> 0.10; seam path gated on `rowDominance < 1`),
`Tests/GraphCutSolver/main.swift` (new), `Tests/ParallaxSharpness/main.swift`,
`Tests/TextureBlotching/main.swift`, `Tests/NadirCap/main.swift` (seam sweeps + assertions),
`SweepSpike.xcodeproj` (regenerated to pick up `GraphCut.swift`).

---

## DEPTH-AWARE PARALLAX CORRECTION — the research, implemented (2026-08-06)

Implements the three priorities from the research section below. All twelve host suites pass;
five sources compile AND link for arm64 iOS, 0 errors, 0 warnings. **Not yet run on a device.**

**THE MEASUREMENT FIRST, because it is the point.** `Tests/ParallaxTruth` (new) is the test that
should have existed at run 1. `StitchHarness` already compared a stitch against a known source
panorama and reported MAE 1.27 — rigorous, and it passed through all thirteen device runs while
the pictures got worse, because it renders every frame from a PERFECT PIVOT. Zero translation is
the one condition under which a rotation-only stitcher is exactly correct, so the harness was
measuring the only case that was never broken. `ParallaxTruth` removes that assumption: analytic
room (6x3x6 m box, near sphere at 0.58 m), exactly computable reference panorama, cameras that
also translate. Error is MAE in 0-255 levels over the +-30 degree band the ring plan fully
covers, so hole filling cannot contaminate it.

```
  translation      rotation-only        depth-aware      predicted error
                   (runs 1-13)          (this change)    at 0.58 m
   0.00 m          MAE  14.80          MAE  14.80          0.0 deg
   0.05 m          MAE  54.35          MAE  16.64          4.9 deg
   0.10 m          MAE  75.74          MAE  17.53          9.8 deg
   0.30 m          MAE  72.47          MAE  20.10         27.3 deg
```
**77% of the error removed at 0.10 m, 72% at 0.30 m**, and with depth a 10 cm translation costs
almost nothing against the 14.80 perfect-pivot floor. That floor is the SCENE, not the stitcher —
a 12 cm checker resampled from 480 px frames into a 1024 px panorama — and it is identical with
and without depth, which is what proves it is resampling rather than misregistration. At zero
translation the correction is a byte-exact no-op, which is why every pre-existing test is
unchanged.

**1. Depth-aware reprojection.** `PanoramaStitcher.swift` — `stitch` and `project` gain
`originPosition`, `DepthSampler` reads metric depth at its own resolution, and the per-pixel loop
resolves the ray by fixed-point iteration (`parallaxIterations` 3): back-project the current
pixel to a world point, keep its RANGE from the panorama centre, move it onto the ray actually
being drawn, re-project. The unknown is on both sides — the depth to look up depends on the pixel
and the pixel depends on the depth — so there is no closed form; with translation much smaller
than range it contracts fast. Nearest-neighbour depth sampling, deliberately: interpolating
across an occlusion boundary invents a surface at a range nothing occupies.
`CapturedFrame` gains `depths` / `depthWidth` / `depthHeight` / `depthConfidence`; frames without
depth take the old path unchanged.

**2. `.sceneDepth` enabled.** `Capture.swift:216` — `frameSemantics.insert(.sceneDepth)`, gated on
`supportsFrameSemantics` so a non-Pro iPhone falls back rather than crashing.
`extractDepth(from:)` copies `smoothedSceneDepth ?? sceneDepth` out as Float32 metres plus the
confidence map; `minDepthConfidence` 0.5 rejects low-confidence samples, because a wrong depth
moves a pixel further from truth than no depth at all. `finishSweep` now returns the sweep origin
and `App.swift` passes it — a stitch that did not know it would silently fall back.

**3. Capture guidance.** New `SweepAdvice.pivot` / `.start`: "Keep the phone still and turn your
body around it — like it is on a broomstick." This is the cheapest improvement available and it
is what both competitors instruct. `driftWarningMeters` **0.30 -> 0.12** (and clear 0.20 -> 0.08),
matching `driftHalfWeightMeters` so the number the user is warned at and the number the stitcher
prices by are finally the same quantity.

**Two CaptureAdmission assertions were REVERSED on purpose**, and that is worth flagging loudly:
they certified that "a 20-40 cm body-pivot arc never warns". They were right about the ergonomics
and wrong about the physics, and they were pinning the app's largest defect in place. A wide slow
5-45 cm arc now warns.

**HONEST LIMITS, all now asserted in the tests rather than assumed:**
- A CONSTANT offset is still absorbed by the creeping reference. That is the run-7 VIO defence and
  it is untouched — VIO drift looks exactly like a constant offset.
- A FAST 11-29 cm arc peaks at a measured 0.286 m and still never warns, whatever the threshold,
  because `driftSustainedFrames` needs 15 consecutive frames above the limit. Lowering the limit
  does not fix this and a banner that fires on every wobble is the run-4 defect. Parallax the
  banner cannot see is handled where it belongs — `driftHalfWeightMeters` prices those frames
  down, and the depth correction removes the geometry error outright.
- `ParallaxTruth` supplies EXACT depth. It isolates "does knowing depth fix the geometry" (yes,
  measured) from "is ARKit's depth good enough" (unknown until a device run). LiDAR is noisy,
  has a narrower field of view than the ultrawide camera, and returns nothing on glass or
  mirrors — `confidenceMap` and the `d > 0.05, d < 30` guard fall back to the old path there.

Sources are tagged in the code at every point they justify a decision: `CapturedFrame.depths`,
`CaptureQuality.driftWarningMeters`, `SweepAdvice`, `Capture.startSession`, and the
`Tests/ParallaxTruth` header.

---

## RESEARCH — why none of this was ever going to work, and what Matterport actually does (2026-08-06)

Prompted by "go through it again" after run 13. The conclusion is that runs 6-13 have all been
attacking a symptom, and the literature is unanimous about the cause.

**THE ROOT CAUSE, stated as the textbooks state it.** A panorama can only be stitched from a
camera that rotates about its own entrance pupil. Under pure rotation, a homography maps between
views exactly, as if the scene were at infinity. The moment the camera also TRANSLATES, points at
different depths move by different amounts, no 2D mapping exists that aligns them, and the
literature's phrase for what you get is "ghosting, also known as parallax". `PanoramaStitcher`
projects every pixel onto a unit sphere — it IS a rotation-only model — so every artifact seen in
runs 1-13 (doubled chairs, seams through a hand, the operator's arm preserved as a blade, the
staircase) is the documented, expected output of that model fed translating input. Stitching with
large parallax is described in the 2024-25 literature as still "an intractable problem".

**THE ARITHMETIC, which settles it.** Angular misregistration ~ atan(t / d) for translation `t`
and object distance `d`. `CaptureQuality.driftWarningMeters` is **0.30 m** and
`driftHardLimitMeters` is **0.60 m** — the app does not even warn until 30 cm, and accepts 60 cm.
At 4096 px wide (11.4 px per degree):

| translation | object at 0.5 m | 1 m | 3 m |
|---|---|---|---|
| 0.30 m (no warning yet) | 31.0° = 353 px | 16.7° = 190 px | 5.7° = 65 px |
| 0.12 m (`driftHalfWeightMeters`) | 13.5° = 154 px | 6.8° = 78 px | 2.3° = 26 px |
| 0.02 m (pivoting about the phone) | 2.3° = 26 px | 1.1° = 13 px | 0.4° = 4 px |

`seamScale` is **16 px**. Seam routing was trying to route around misregistration **4 to 22 times
coarser than its own grid**. That is the whole story of runs 11-13 in one line, and it is why
`boundaryCost` could fall 54% while the picture got worse: the seam was being placed beautifully
around an error that no seam placement can fix.

**WHAT MATTERPORT DOES. Two things, and NEITHER is a better stitcher.**
1. *They remove the translation at capture.* The iOS guidance is to "rotate your body around the
   device (as if it was on a monopod or broomstick)" — explicitly "this minimizes parallax
   errors". Google's Street View app says the same thing differently: "hold your device
   vertically and close to your body". Both are instructions to keep the entrance pupil still and
   move the human around it. **This project's guidance says "Hold here" and its drift monitor was
   deliberately relaxed to 0.30 m in run 5 so that a 20-40 cm body-pivot arc "never warns" —
   i.e. it was tuned to ACCEPT the single largest source of its own artifacts.**
2. *They measure depth and use it.* Matterport Capture on LiDAR iPhones "will use LiDAR data to
   improve image stitching", with Cortex AI synthesising depth where LiDAR does not reach. With
   per-pixel depth the correction is exact rather than heuristic: back-project each pixel to a 3D
   world point, then re-project onto the sphere centred on the sweep origin. Translation is
   cancelled instead of hidden. Nikon holds US11568516B2 "Depth-based image stitching for
   handling parallax" on essentially this, and it places seams at depth discontinuities rather
   than by colour — the colour-only seam test in `SeamField.disagreement` is the thing that patent
   exists to replace.

**`sceneDepth` IS NOT ENABLED IN THIS APP.** `Capture.swift:217` builds a bare
`ARWorldTrackingConfiguration` and never sets `frameSemantics`. ARKit delivers a LiDAR-fused dense
depth map at 60 Hz on every `ARFrame` via `.sceneDepth`, alongside a per-pixel `confidenceMap`,
on every Pro iPhone since the 12 Pro. The app is already inside an ARSession holding metric poses
and is simply not asking for the depth. That is the single largest available capability gap.

**THE ACADEMIC THIRD OPTION, for completeness.** Where depth is unavailable the literature
absorbs parallax with local warping rather than a single homography: as-projective-as-possible
warps, robust elastic warping, segmentation-guided multi-homography, and optical-flow view
synthesis. All replace the global rotation model with a per-region or per-pixel one. All are
heavier than anything here, and all are strictly worse than just having the depth.

**WHAT THIS MEANS FOR THE PLAN.** In priority order, and NOT to be done all at once:
1. **Capture guidance.** Change the instruction to "rotate your body around the phone, keep the
   phone still in space" and tighten `driftWarningMeters` from 0.30 toward ~0.10. Zero new
   algorithms, and by the table above it is worth roughly a 10x reduction in misregistration —
   more than every stitcher change made so far, combined.
2. **Enable `.sceneDepth`** and gate on `ARWorldTrackingConfiguration.supportsFrameSemantics`.
   Store the depth map with each frame. Even unused at first, it makes the fix measurable.
3. **Depth-aware reprojection** in `PanoramaStitcher`: back-project by depth, re-project from the
   sweep origin. This is the actual fix and it is what Matterport does.
4. Only then revisit seam routing, at a `seamScale` finer than the residual misregistration.

Sources: Matterport Capture for iOS help centre and the 9to5Mac/iThinkDiff coverage of the LiDAR
release; Google Street View photo sphere capture guidance; Kwatra et al., *Graphcut Textures*
(SIGGRAPH 2003) for the seam formulation already implemented here; Nikon US11568516B2; Zaragoza
et al. APAP and Li et al. robust elastic warping for the warping line; Apple WWDC20 "Explore
ARKit 4" for `sceneDepth`.

---

## THIRTEENTH DEVICE RUN (2026-08-06) — "the worst run so far". ROUTING REVERTED TO OFF.

Files: `IMG_3215.JPG` (4096x2048 equirect), `ScreenRecording_08-06-2026 10-53-02 am_1.MP4` (30 s,
viewer). Included the run-12 capture fix: `Capture.swift` 10:41:58, device binary 10:47:59,
sweep ~10:50, panorama 10:53:43.

**Verdict: worse than run 12, which was worse than run 9. The user said so unprompted.** Two
distinct failures, and I caused one of them.

**1. I told the user to stop sweeping too early. My fault, from the run-12 fix.**
The status line I added fired "Every marker reached · N photos, M% covered — tap Finish Sweep"
the moment the last marker cleared. The plan is **44 sampled DIRECTIONS**; the sphere is a
continuous surface. All 44 can be covered while wide bands between them have never been seen.
The user did as they were told and finished — run 13's recording is 30 s against run 12's 40 s —
and `IMG_3215` is full of the consequence: blown white voids with hard polygon edges where
hole-filling invented the ceiling and the far wall. Fixing the deadlock was right; turning
"markers done" into "you may finish" was not. **Coverage decides when a sweep is done. Markers
are only where to point next.** Fixed at `Capture.swift:341` — below `goodCoverage` it now says
"Markers done, but only M% covered — keep sweeping the gaps before finishing."

**2. Seam routing is off by default again. `seamSmoothnessWeight` 0.10 -> 0.**
Three device runs shipped it ON — 11, 12, 13 — and all three were judged worse than run 9, which
had it OFF. That is three real-scene verdicts against and none for.

The host tests still say routing wins, and the honest reading is that they measure the wrong
thing. `boundaryCost` is routing's OWN objective function, so of course routing lowers it — that
number was never evidence. `ParallaxSharpness` scores a synthetic grating containing no long
straight architecture for a quantised boundary to cut across, so it cannot see the artifact at
all. Neither measures what the user is looking at.

What the user is looking at is a **staircase**. `seamScale` is 16 px at 4096 wide and both
`share` and `contestedFraction` ramp over ONE cell, so every routed boundary is a diagonal
quantised into 16-px steps. Run 13 shows them plainly along desk edges and window beams. The
run-12 gate feathering was not wrong but was aimed one level too high: it removed the
axis-aligned block edges BETWEEN the two paths and did nothing about the label field itself.

This is a REVERT, not a deletion. `GraphCut`, `routeSeams`, `dropSliverTerritories` and
`contestedFraction` all remain, all still tested, and `seamSmoothnessWeight = 0.10` re-enables
every bit of it. **Do not turn it back on without first shrinking `seamScale` and proving on a
device that the staircase is gone.**

*Verified:* `Tests/StitchHarness` now asserts the SHIPPING DEFAULT specifically — every other
seam number in the suite comes from a test that passes `seam:` explicitly, so none of them could
notice the default moving, which is exactly what three bad runs were about. It reports
`shipping default: seam field not built (cost 0 -> 0)` and fails if anything turns routing back
on silently. `seam > 0` gates the entire routing path at `PanoramaStitcher.swift:227`, so with
the default at 0 no seam field is built, the sliver cleanup never runs, and the composite takes
the pre-routing branch. **The shipping stitcher is now the run-9 stitcher**, confirmed by the
unrouted rows: sharpness 12.49, blotch 1.116, hardness 5.174, MAE 1.27, coverage spread
0.00e+00. All ten host suites pass; arm64 iOS links with 0 errors and 0 warnings.

**`Tests/SeamStaircase` (new) — the scene the suite never had, and a DEAD END worth recording.**
Wide flat panels on a cylinder at 1.2 m: long straight architecture under real parallax, the
content `ParallaxSharpness` (grating), `TextureBlotching` (speckle) and `NadirCap` (floor) all
lack, and therefore the content none of them could ever have scored routing on.

It was built to measure the staircase directly. **It cannot, and the reason is structural — DO
NOT retry this.** Routing only engages where frames DISAGREE, and where they disagree there is
no single correct edge position to measure against. Two metrics were tried:
- Second difference of the edge column: routed and unrouted agreed to three decimals (0.251 vs
  0.251) while 76789 pixels genuinely differed. A second difference is local; a staircase is
  flat almost everywhere and spikes only on the step, so 250 quiet rows drown the few that carry
  it.
- RMS deviation from straight: **7.96 px unrouted vs 7.77 routed — routing scores BETTER**,
  because at 1.2 m the allowed +-6 cm of wander really does move a vertical edge by +-16 px, so
  the metric is reading the parallax, not the artifact. Averaging disagreeing views is smoother
  than choosing between them, and always will be.
Move the wall far enough for parallax to vanish and the frames agree, the gate never fires, and
the two renders come out byte-identical. There is no distance that separates cleanly.

So the test asserts only what it can honestly see, which is still worth having:
`routing vs not: 76789 of 2097152 pixels differ, worst channel 152` — routing is not a tidy-up
on architecture, it repaints 3.7% of the panorama and moves panel edges by a full step — and
`shipping vs unrouted: 0 pixels differ`, which locks the revert. **The evidence that routing is
worse is three device runs, not a number in here**, and no number in here was ever going to
settle it. That is the real lesson of runs 11-13.

**What is NOT claimed.** No device run has happened since these changes. Run 9's stitcher is
restored and the premature-finish nudge is gone, both verifiable on the host — but whether the
next image is good is a device question, and three runs in a row have now shown host numbers
disagreeing with the user's eyes. Treat run 14 as the measurement, not this entry.

---

## TWELFTH DEVICE RUN (2026-08-06) — 76 frames, 97%; THE SWEEP DEADLOCKS. Root cause found.

Files: `IMG_3211.HEIC` (capture UI mid-sweep), `ScreenRecording_08-06-2026 10-32-51 am_1.MP4`
(viewer), `IMG_3213.JPG` (the 4096x2048 panorama itself — the first time the raw equirect has
been kept rather than a screen recording of it, and far more useful).

**This run DID include the two fixes above.** `Sources/PanoramaStitcher.swift` mtime 10:14:35,
device binary in DerivedData 10:19:28, sweep 10:29, panorama 10:33. The ceiling in `IMG_3213`
is clean — no rectangular chunks in the beams, which is what the feathered gate was for.

**User's report: "in one of the previous runs the app was running much better and produced a
very good image — why is it not working now", and "the app was not able to recognise the white
dot".** The second sentence is the whole answer, and `IMG_3211` is the proof: the HUD reads
`Tracking · 76 photos`, `Hold here`, `97% of the room covered · 92% double-covered`, with a
white marker dead centre on the window blinds. The user is aimed at it. It never clears.

**ROOT CAUSE — the sweep cannot finish, by construction. `Capture.swift`.**

The marking of a target lived inside `capture()`, which is reachable only after four early
returns: the frame budget (`:341`), the smoothness count, `isFarFromStoredFrames`, and the
novelty gate (`:376`). So:

> A frame aimed at that marker is refused by the novelty gate **because** that direction is
> already covered — and marking targets happened only after the gate. The one condition that
> guarantees a direction is finished was also the condition that guaranteed its marker would
> never be marked finished.

It is not a tuning problem and the user cannot aim their way out of it. Once the gate starts
refusing, the markers freeze, the coverage readout freezes, the status text freezes and the
haptic stops — `state.coverage.add` and the whole `Task { @MainActor }` publish block were
inside `capture()` too. The user holds on a dot that can never clear, gives up, and taps Finish
Sweep with a short frame set.

**Why run 9 looked so much better, precisely.** Run 9 finished at **90 frames = exactly
`maxStoredFrames`**, at 98.1% — below `goodCoverage` 0.99, so the gate never left depth-1 and
every one of those 90 frames was bought for genuinely new ground. The budget filled BEFORE the
gate started refusing, and at capacity the app says "Room covered at 90 photos — tap Finish
Sweep". The user finished a complete sweep and never met the deadlock. Runs 11 and 12 stopped at
82 and 76 with budget still in hand, which means the gate bound first — and that is the first
time this bug could be seen at all. Run 12 stitched **76 frames where run 9 stitched 90**, from
a plan that was never finished. That is the difference the user is looking at.

**This is the THIRD time this exact bug has been fixed in this function.** Run 5 defect 8 (see
the fifth-run section) was the drift banner freezing at the capacity guard — "a warning that
cannot switch off is not a warning" — and the guidance hint was moved out with it. The markers
were left behind. The lesson, now written at the call site: **anything the user is looking at
must be driven by what the CAMERA SAW; only what is kept for stitching belongs behind the
storage gates.**

**FIX.** `Sources/Capture.swift:135` — new `SweepState.markCoveredTargets() -> Bool`, which
marks every outstanding target the coverage map already covers and reports whether any changed.
`:341` — called on EVERY tracked frame, before all four storage gates, publishing the markers
and, when the last one clears, a "Every marker reached · N photos, M% covered — tap Finish
Sweep." status. The copy inside `capture()` became a call to the same routine, so the two cannot
disagree about what "covered" means.

**Nothing about what gets STITCHED changed.** No constant moved. `isCovered` is still asked of
the stored-frame map. A refusal for zero novelty is that map saying it already holds this
ground, so marking the target agrees with it rather than overriding it.

*Verified:* that last claim is the load-bearing one, so it is now asserted. `SweepState` needs
ARKit and cannot be built on the host, so `Tests/CaptureAdmission` pins the invariant it rests
on instead: over a closed horizon ring, **216 of 216 refused directions are already `isCovered`
by the stored map** — checked together with `refused > 0`, without which the assertion would
pass vacuously on a scene that refuses nothing. All ten host suites pass; five sources compile
AND link for arm64 iOS, 0 errors 0 warnings; every stitcher metric byte-identical (sharpness
13.44, blotch 1.116, hardness 5.174, MAE 1.27, coverage spread 0.00e+00).

**Still open after this run** (unchanged by it, and NOT the cause of the regression):
- Operator self-capture. `IMG_3213` bottom-left still shows the user's shoes twice and a hard
  curved seam cutting the desk across the floor. `dropSliverTerritories` removes label ISLANDS;
  this is a large connected territory, so it is out of that fix's reach.
- D-C, the washout. `IMG_3213` is much better exposed than run 11's recording, which suggests
  a good part of what looked like washout there was the screen recording, not the panorama.
  Keep saving the raw equirect — it is the only honest way to judge this.

---

## TWO FIXES SHIPPED FOR RUN 12 (2026-08-06) — feathered routing gate, sliver territories

Both defects named in the run-11 section below. All nine host tests pass; the five sources
still compile AND link for arm64 iOS with 0 errors and 0 warnings.

**D-B — the routing gate is now a ramp.**
`Sources/PanoramaStitcher.swift:668` — `SeamField.isContested -> Bool` replaced by
`contestedFraction -> Float`, bilinear over the same grid and by the same wrap/clamp rule as
`share`. `:1555` — the composite loop mixes the two paths instead of branching between them:
each frame contributes `routed * share + (1 - routed) * blend`, and the routed block only
`continue`s at `routed >= 1`.
*Why:* the gate was a hard nearest-cell test on the 16-px label grid. Where the labels ramped,
the CHOICE OF PATH still stepped, and the two paths contribute different weight even where they
agree on colour — so the gate drew its own grid. That is the run-11 blockiness: rectangular
chunks in the window beams and a staircase down every sliver, on axis-aligned edges no scene
contains.
*Verified:* new grid-signature metric in `Tests/ParallaxSharpness` — share of equatorial
gradient energy landing on cell-edge columns, against the `seam 0` render as a null.
**12.36% routed vs 12.43% unrouted vs 12.50% chance**, asserted at <=1.10x the null.

**HONEST GAP on D-B: no host scene proves the fix, because no host scene exercises it.**
Reinstating the hard gate (`return total > 0.5 ? 1 : 0`) and re-running gives byte-identical
numbers on every suite. `ParallaxSharpness` puts a grating at 0.6 m everywhere, so its whole
grid is contested; `TextureBlotching` is a wall nothing disagrees about, so none of its grid is.
Neither has a contested BOUNDARY, which is the only place the two implementations differ. So
this change is verified as risk-free (exact at both ends, no metric moves anywhere) but its
benefit is unproven off-device. **Run 12's beams and floor edges are the test.**

**D-A — sliver territories are dissolved.**
`Sources/PanoramaStitcher.swift:1083` — new `minTerritoryCells = 64` and
`dropSliverTerritories(_:gridW:gridH:)`, called from `routeSeams` after the expansion loop and
before `boundaryCost()`. Flood-fills connected same-label components (4-connected, longitude
wraps, latitude does not) and reassigns any component under 64 cells to the label it borders
most, ties to the lower frame index, votes counted against the incoming array so the result
cannot depend on visit order.
*Why:* the router was working correctly — it detoured around an object the frames disagreed
about — but the object was the operator's own forearm, so the territory it fenced off preserved
a body part. Nothing in the energy distinguishes that from a genuine occlusion boundary. Size
does: a frame spans ~6% of the sphere, so a real territory is hundreds of the 32768 cells and a
30-cell island is an artifact whatever produced it.
*Verified:* `Tests/SeamTerritory` (new, 22 checks, all pass) — build with
`swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift Sources/GraphCut.swift
Tests/SeamTerritory/main.swift`. Covers the wrap seam counting as one component, the poles NOT
joining, the exact 64/63 boundary, majority and tie-break reassignment, two touching islands,
−1 cells neither adopted nor created, and degenerate grids. Plus the whole suite:
**boundary disagreement 69011 -> 67818 at seam 0.10, sharpness 13.46 -> 13.44, blotch 1.116 and
hardness 5.174 unchanged, nadir cap hard edges 0.0131 unchanged and still 100% painted,
coverage byte-identical everywhere (spread 0.00e+00, MAE 1.27, 78.6%).**

**Code review (`dev-workflow:code-reviewer`) raised three; two did not survive checking.**
- *P0, "the routed veto's `continue` forfeits the dominance path too".* Rejected — verified at
  `:1571` and `:1649` that both vetoes compute the identical expression from the identical
  `thumbnail`/`gain`/`peakColours` against the identical `agreement`, so a frame rejected in one
  is rejected in the other without fail. A comment at `:1571` now records that, and says the
  shortcut must become a flag if either test ever changes.
- *P1, "both paths run for the same frame, so weight is double-credited".* Rejected as a bug,
  accepted as a doc error. Mixing the WEIGHTS is the intent; because the accumulator normalises
  by total weight and the dominance weights sum to more than 1, the result leans toward the
  dominance answer mid-ramp rather than being their linear blend. Continuous, monotone and
  exact at both ends is all the gate needs. The comment at `:1602` claiming a partition of
  unity was wrong and has been rewritten to say what is actually true.
- *P2, small grids.* Valid, fixed. `routeSeams` permits a 2x2 grid, where "under 64 cells"
  would have meant "everything" and flattened the field to one label. Guard added at `:1119`
  (`cells >= minTerritoryCells * 4`) plus a check in `Tests/SeamTerritory`.

**Also internal-ised for testing, deliberately:** `minTerritoryCells`, `dropSliverTerritories`,
`seamScale`. Reaching the cleanup through `stitch` would have meant building a scene whose
alpha-expansion happens to produce an island today — pinning the optimiser rather than the
cleanup, and breaking on every energy change without ever testing wrapping, ties or ordering.

**Not addressed: D-C, the global washout.** Unfixable from the video alone — it needs the raw
captured frames beside the output to tell `exposureGains` from camera AE. See run 11 below.

---

## PLAN — two fixes before run 12 (2026-08-06, workflow Phase 0, goal mode → proceed)

**Objective:** remove the two run-11 defects that are fixable without depth or segmentation, so
run 12 tests routing on a moving subject without them confounding the read.

**Deliverable:** `Sources/PanoramaStitcher.swift`, `Tests/SeamTerritory/main.swift` (new).

**Approach:**
- **D-B, blocky gate.** `isContested` (line 1413) is a hard nearest-cell test on the same 16-px
  grid the labels live on, so the routed and dominance paths — which produce different colour —
  swap along axis-aligned block edges. Add `SeamField.contestedFraction`, bilinear over the
  contested flags exactly as `share` is bilinear over the labels, and mix the two paths by it.
  Both extremes are byte-identical to today, so this can only affect the block edge itself.
  Rejected: shrinking `seamScale` 16 -> 8. That makes the blocks smaller without making them
  not-blocks, and quadruples the alpha-expansion grid when run 11 already had no timing measured.
- **D-A, operator slivers.** The router is doing its job — it detours around a disagreeing
  object — but the object is the operator's own arm, so what it preserves is a knife-edge ghost.
  After expansion, drop connected label components below `minTerritoryCells` and reassign them to
  their majority boundary neighbour. A frame's footprint is ~6% of the sphere (~2000 cells of
  32768), so a 30-cell island is not a territory, it is an artifact.
  Rejected: lowering the nadir cap. The slivers lie out on the floor near −30°, well above the
  cap, and the knee at true nadir is a real object that no single-sourcing can remove.

**Risks:** the territory cleanup can only be justified if `ParallaxSharpness` and `TextureBlotching`
do not move against each other — the two pull in opposite directions and must be run together.
`NadirCap` must show coverage unchanged, since a cleanup that punched a hole would also score well.

**Delegation:** none. Two edits to one file plus one test, single skill set, and the context is
already in hand — a subagent would return what is already known. `code-reviewer` pass before
delivery.

---

## ELEVENTH DEVICE RUN (2026-08-06) — 82 frames, 97.9%; first device run with routing ON

Source: `mobile/ios_capture/ScreenRecording_08-06-2026 9-41-03 am_1.MP4` (40.8 s, 1206x2622,
60 fps). Note the filename contains a narrow no-break space (U+202F) before `am` — quoting it in
a shell fails; glob it (`f=(ScreenRecording*.MP4)`). Frames pulled with
`ffmpeg -vf "fps=1/2,scale=420:-1,tile=5x2"` plus full-res stills at t=14/22/39.

**On-screen result: `82 frames · 97.9% of the sphere captured`.** The recording is ENTIRELY the
`SphericalPanoramaView` viewer — dragging around the finished panorama. There is no capture
footage in it, so nothing here says anything about guidance, drift banners or stitch duration.

**Answers to the three questions run 11 was posed:**
1. **Is the face still cut? NOT ANSWERED — wrong scene.** The brief was explicit: a person at
   1-2 m who moves between frames, a cinema row or a sofa. This was shot in the static office.
   Two seated people do appear near the desk and read as whole (no razor boundary, no second
   forehead), but a static subject cannot exhibit defect 13, so this is not evidence. Defect 13
   remains open and untested against alpha-expansion routing on a device.
2. **Stitch duration: NOT ANSWERED.** The recording starts after the stitch; no timing is shown.
3. **Carpet patchwork: PASSED.** Large areas of plain grey carpet in every direction, uniform,
   no territories. `SeamField.contested` is doing on real carpet what the speckle test asserts.

**Frame budget: fine.** 82 of `maxStoredFrames` 90 at 97.9% — the gate closed the sphere with
headroom, so `minNoveltyFraction` does not need touching.

**Quality, unprompted: the horizon band is the best yet.** Monitor text, keyboard legends, chair
mesh and distant bookshelves are all legible. Nothing that runs 6-9 closed has reopened.

**Three defects visible in this output.** None is a regression; all three are things earlier runs
did not show clearly enough to name.

- **D-A, operator self-capture (worst of the three).** The operator's own knee and jeans fill the
  nadir, and the phone/hand/forearm survives as thin dark blade-shaped slivers lying over the
  floor in several directions (clearest at t=14 and t=22, centre-bottom). The router did the
  right thing locally — it detoured the seam around a disagreeing object — but the object is the
  operator, present in some frames and not others, so what it preserved is a knife-edge ghost of
  an arm. Routing cannot fix this: the fix is either to reject frames whose lower-centre is
  occluded by the body, or to cap the nadir more aggressively than the current solo cap does.
- **D-B, 16-px stair-step blockiness at label boundaries.** `seamScale` is 16, and `share()`
  bilinear-ramps the labels over one cell, but `isContested` is a HARD nearest-cell test at the
  same 16-px grid, so the gate itself switches on and off along axis-aligned block edges.
  Visible as "torn paper" rectangular chunks eating into the wooden window beams and the ceiling
  panels (t=22, the beam line), and as a clean staircase along the edge of the D-A sliver. The
  code comment argues the gate needs no feathering because frames agree to within tolerance
  where it fires; this output is the first evidence against that argument. Suspected, not
  proven — confirm by rendering the same panorama at `seamScale` 8 and comparing.
- **D-C, global washout.** The upper hemisphere is blown to near-white and overall contrast is
  low (the notch reads true black, so it is not a recording artifact). Cannot tell from the video
  whether this is `exposureGains` lifting toward the brightest frames or plain camera AE metering
  the ceiling lights. Needs the raw captured frames beside the output to separate.

Not changed in this session — this entry is an observation log only. No source was edited.

---

## 2026-08-04

- **Iteration 0 plan (recorded per workflow Phase 0, goal mode → proceed without pause).**
  Objective: prove guided rotate-in-place capture + pose-based stitching gives acceptable
  panoramas, and measure VIO inter-sweep distance error, on real hardware.
  Deliverable: `mobile/ios_capture/{project.yml, Sources/Capture.swift,
  Sources/PanoramaStitcher.swift, Sources/App.swift, Sources/Info.plist}`.
  Approach: ARKit world tracking, 24 targets (8 yaw × 3 pitch), auto-fire at ~8° for 5 steady
  frames, stitch by inverse-projecting equirect pixels through each frame's pose+intrinsics with
  feathered blending. Rejected OpenCV feature stitching — poses make it unnecessary, heavy dep.
  Risks: hand-held parallax ghosting (the thing under test), ARKit intrinsics convention needs
  on-device verification, stitch runtime at 4096×2048. Team: none (single Swift module, no
  distinct skill sets; subagents would cost ~4x and return known information).
- `mobile/ios_capture/project.yml` created — XcodeGen spec, iOS 16 deployment target,
  portrait-only, camera + photo-add usage strings. Why: hand-written .pbxproj is fragile.
  Verified: `brew install xcodegen` exit 0; project generation pending Xcode install.
- Env: `npm cache clean --force` run to widen headroom for Xcode. Disk reality — the earlier
  8.8GB figure was the sealed system snapshot; real free space on /System/Volumes/Data is 41GB.
  Xcode download had NOT started as of last check (App Store opened, awaiting user click).
- Rewrote `PLAN.md` → v2 (full file — sweep-panorama pipeline, phased A/B/C scope, 9 detailed
  iterations each with numbered steps and gates, per-decision sources, revised risk table).
  Why: user clarified the goal is replicating Matterport's phone photo→360-tour workflow on any
  phone, and web research showed Matterport uses sweep panoramas + neural depth, not live LiDAR
  mesh. Verified: file written; structure covers capture→backend→viewer→depth→mesh with sources.
- Created `PLAN.md` — full development plan. Chose on-device reconstruction over cloud
  photogrammetry; Flutter shell with native Swift/Kotlin capture modules; Supabase + Vercel free
  tiers; Three.js web viewer. Rationale and rejected alternatives documented in the file.
- Created `CHANGELOG.md` — this file.
- Verified: directory was empty apart from tooling config; machine is Apple Silicon M2 / macOS 26.3,
  which makes local processing a viable substitute for paid GPU compute.

- **Xcode 26.6 confirmed installed** (3.7 GB, iPhoneOS platform present) and its licence accepted.
  Superseded the previous "Xcode is NOT installed" blocker.
- `mobile/ios_capture/SweepSpike.xcodeproj` created via `xcodegen generate` (exit 0).
- Discovered the prior session had already written all four Iteration 0 source files plus a
  host-side stitch verification harness — more than CHANGELOG recorded. Ran the harness using
  CommandLineTools' `swiftc` to bypass the unaccepted Xcode licence.
- `Tests/StitchHarness/PlanSweep.swift:111` `cameraRotation` — added a `roll` parameter and applied
  `CaptureConfig.deviceRollRadians`. Before → after: the file's own doc comment stated a
  portrait-held phone presents its long image axis vertically, but `coverage()` built a level,
  unrolled camera basis, i.e. it modelled LANDSCAPE. Every "portrait" number in the plan table had
  the two FOV axes swapped. Why: the app is portrait-locked, so this inverted which axis the yaw
  spacing must fit. Verified: the same 24-target plan now reports 85.1% sphere held portrait vs
  78.6% modelled level, and the harness prints both rows so the gap stays visible.
- `Tests/StitchHarness/PlanSweep.swift:111` — same function, added a fallback axis when
  `cross(worldUp, backward)` collapses to zero. Before → after: NaN frame at the poles → stable
  basis. Why: the new plan has ±80° rings; at ±90° the old code silently voided the frame.
  Same fix applied to `main.swift:71` `makeTransform`. Verified: pole rings contribute coverage.
- `Tests/StitchHarness/main.swift` — the coverage gate compared `Result.coverage` (an equirect
  PIXEL fraction) against 0.70 (a solid-angle threshold), failing a geometrically correct stitch.
  Before → after: `FAIL coverage 57.6% exceeds 70%` → cos-weighted solid-angle coverage 78.6%,
  PASS. Why: equirect rows near the pole carry equal pixel weight but almost no solid angle.
  Verified: both numbers now printed side by side; MAE check unchanged at 1.26.
- `Tests/StitchHarness/main.swift:155` — pinned the projection test to a fixed 8×[0/±30] plan
  instead of `CaptureTarget.makePlan()`. Why: that test checks projection/inverse-projection
  agreement and must not drift every time the capture plan is retuned.
- `Sources/SweepGeometry.swift` — added `CaptureRing` and per-ring yaw counts, replacing a single
  global `yawSteps`. Why: a ring near a pole needs far fewer frames, since the same frustum spans
  much more longitude there; a uniform count spent 12 frames on a cap 4 can cover.
  Verified: harness search table, 44-target plan reaches 100% sphere.
- `Tests/StitchHarness/PlanSweep.swift:35` — added `Coverage.wallBandOverlap` (fraction of the wall
  band seen by ≥2 frames) and a harness failure below 90%. Why: coverage alone is the wrong
  objective — the feathered blend needs overlap, and the cheapest 100%-coverage plan (28 targets)
  has only 37% overlap, i.e. adjacent frames abut and would seam. Verified: the gate immediately
  rejected the 36-target plan chosen earlier in this session at 56.2%.
- `Sources/SweepGeometry.swift` `CaptureConfig.rings` — set to 12×[0/±30] + 4×[±80] = 44 targets.
  Before → after: 24 targets covering 57.6% of pixels / ~78.6% solid angle with poles entirely
  missing → 100% sphere, 94.3% wall overlap. Why: cheapest plan in the search clearing the overlap
  bar. Verified: `SHIPPING PLAN: 44 targets, 100.0% sphere, 100.0% walls, 94.3% overlap`.
- `Sources/SweepGeometry.swift` `storedFrameMaxDimension` 1024 → 800. Why: the constant was sized
  for 24 frames; at 44 frames 1024 would hold ~138 MB of RGBA and risk a jetsam mid-sweep. 800
  still exceeds what the 4096×2048 output can resolve (needs 683 px on the long axis, 532 on the
  short), so no detail is lost. Verified: harness still passes; derivation recorded in the comment.
- Attempted `xcodebuild` for both `iphonesimulator` and `iphoneos`: BLOCKED before compilation by
  the stale `/Library/Developer/PrivateFrameworks/DVTDownloads.framework` (Oct 2 2025). Needs
  `sudo xcodebuild -runFirstLaunch`. The app source has therefore NOT yet been compiled by any
  iOS toolchain — only `SweepGeometry.swift` and `PanoramaStitcher.swift` are proven to compile,
  via the macOS harness. `Capture.swift` and `App.swift` are UNVERIFIED.
- **Compiled and linked the full app for arm64 iOS, 0 errors / 0 warnings**, by invoking the Xcode
  toolchain's `swiftc` directly against the iPhoneOS SDK. Why: `xcodebuild` dies in its plugin
  loader before reaching the compiler (stale DVTDownloads.framework), but that plugin is only
  needed for packaging/simulator management, not compilation — so the blocker did not actually
  prevent verifying the code. Before → after: `Capture.swift` and `App.swift` UNVERIFIED →
  compile and link clean, producing a Mach-O arm64 executable. Verified: `LINK_EXIT=0`,
  `file SweepSpike` → `Mach-O 64-bit executable arm64`.
- `Sources/Capture.swift:91` `SweepState` — declared `: @unchecked Sendable` and documented the
  confinement invariant (all access on the serial `sessionQueue`). Before → after: two
  `#SendableClosureCaptures` warnings → none. Why: these become hard errors under Swift 6 language
  mode, and the existing `nonisolated(unsafe)` markers were papering over the same thing at the
  use site rather than stating the invariant at the type.
- `Sources/Capture.swift:17` `FrameConverter` — same treatment; `nonisolated(unsafe)` removed from
  both `converter` and `state` at `Capture.swift:143-144` as the compiler then flags them
  redundant. Verified: recompile gives 0 warnings.
- **Added `Tests/PanoramaDemo/main.swift`** — end-to-end execution of the real shipping plan
  through the real `PanoramaStitcher` at the production 4096×2048, on a synthetic room (four
  toned walls, a blown-out window, floor/ceiling, 5° grid for spotting misalignment). Simulates
  the portrait roll and ±8° aiming error a real hand applies. Why: ARKit is only needed to
  ACQUIRE frames; the plan and the stitch are pure geometry and can be executed on a host, so
  "needs a device" was true of far less of the pipeline than assumed. Build:
  ```
  swiftc -O Sources/SweepGeometry.swift Sources/PanoramaStitcher.swift \
    Tests/StitchHarness/PlanSweep.swift Tests/PanoramaDemo/main.swift -o /tmp/demo && /tmp/demo
  ```
  Verified: `DEMO OK`, 44 frames stitched in 0.44 s, 100.00% solid-angle coverage.
- Demo immediately caught a defect the analytic search could not: with aiming error simulated,
  the ±80° cap rings left black wedges at ±50–60°. Fixed in two steps —
  `Sources/SweepGeometry.swift` caps ±80° → **±70°** (99.83% → 99.96%; ±70° scored identically
  in the analytic table, so this cost nothing), then mid ring ±30° → **±33°** (99.96% → 100.00%).
  ±35° also gave 100% coverage but dropped overlap to 88.1%, below the seam gate; 33° is the
  balance point at 90.5%. Verified: harness ALL CHECKS PASSED and demo DEMO OK simultaneously,
  and the rendered panorama shows continuous grid lines with no black wedges.
- **Stitch runtime measured: 0.44 s for 44 frames at 4096×2048** on this Mac (M-series). This was
  an open risk in the plan. A phone will be slower, but this is nowhere near a problem — the
  earlier concern about stitch cost at full resolution is retired.
- Confirmed there is NO non-sudo workaround for the `xcodebuild` plugin failure: Xcode.app ships
  no copy of `DVTDownloads.framework` (`find` over the bundle returns nothing), so the version in
  `/Library/Developer/PrivateFrameworks` is the only one and only `runFirstLaunch` replaces it.
  Do not spend time looking for a `DYLD_FRAMEWORK_PATH` trick.
- **The output is now a navigable 360° view, not a flat image.** User feedback: the deliverable
  should be a room you can look around, not a rectangle. The equirect PNG always WAS the 360 data
  (it is the sphere unwrapped, same format as Street View/Matterport) — what was missing was a
  viewer to undo the projection. Two added:
  - `Sources/App.swift` `SphericalPanoramaView` — replaces the flat scrollable `Image` in
    `PanoramaPreview` with a SceneKit sphere, camera at its centre, `allowsCameraControl` for
    drag-to-look. Sphere is scaled -1 on X so the texture reads correctly from the INSIDE
    (without it every panorama is mirrored — subtle enough to ship by accident); `isDoubleSided`
    is then required because the negative scale flips winding and inward faces would be culled.
    Verified: compiles for arm64 iOS, 0 errors / 0 warnings. Mirroring and up-orientation still
    need a DEVICE check — SceneKit's UV convention is not proven here, only assumed.
  - `web/viewer/index.html` — dependency-free WebGL 360 viewer (Phase A of PLAN.md). No CDN, no
    Three.js. Renders a fullscreen triangle and computes a ray per pixel, then applies the SAME
    equirect mapping the stitcher uses (`lon = atan2(x,-z)`, `lat = asin(y)`), so the projection
    and its inverse are guaranteed consistent. Loads `panorama.jpg` beside it, or `?pano=<url>`.
    Has a Sphere/Flat toggle that shows the stored equirect source — useful for explaining that
    the flat image and the 360 view are the same data.
    NOTE: no mipmaps, deliberately — mip selection across the longitude seam draws a visible line.
  - `web/viewer/panorama.jpg` — the demo panorama, so the viewer opens with content.
- Do NOT tell the user 3 images can make a room panorama. An iPhone wide camera covers ~47°×60°,
  about 2% of a sphere each; three shots reach ~6%. The 44-target plan is the minimum that closes
  the sphere AND leaves blendable overlap.
- **Capture is now free-form, not limited to the ring plan.** User: "the user should take as many
  photos as he/she can that covers the full room so the app can make the best 360 possible."
  Before → after: fired ONLY at 44 fixed targets and discarded every other frame → stores any
  frame that adds a genuinely new view, unbounded by plan.
  - `SweepGeometry.swift` `CaptureQuality` — `minSeparationRadians` 10° (a new frame must point
    ≥10° from every stored frame; stops a stationary phone filling memory with duplicates while
    allowing ~130 distinct views, ~3× the ring plan), `maxStoredFrames` 150 (a MEMORY ceiling:
    800×600×4 = 1.92 MB/frame → ~288 MB, not a plan limit), `maxAngularStepRadians` 0.6°/frame
    (~36°/s) to reject motion-blurred frames.
  - `SweepGeometry.swift` `CoverageMap` — 72×36 cos-weighted solid-angle grid. Needed because
    with no fixed shot count, COVERAGE is the only honest stopping condition. Frustum test
    compares against `tan` rather than calling `atan` per cell.
  - `Capture.swift` — the old target-aim + 5-steady-frame gate is gone. It was wrong for
    continuous sweeping: requiring near-zero motion would rarely fire while the user turns.
    Replaced by smoothness (angular velocity) + separation + capacity. Guidance markers now
    turn green when the COVERAGE MAP says a direction is seen, by any frame, however the user
    got there — not by hitting an exact target.
  - `App.swift` — readout is now a coverage progress bar + "N photos", not "12/44".
  Verified: compiles arm64 iOS 0 errors/0 warnings; harness ALL CHECKS PASSED.
- The 44-target ring plan is RETAINED as on-screen guidance and as the analytic floor the
  harness gates on. It is no longer a capture limit. Do not delete it.

### Open requirement — web upload path (NOT built, needs a decision)
User wants: upload iPhone photos to the web app and get a 360 view. This does NOT work with the
current stitcher and the reason is fundamental, not effort: `PanoramaStitcher` needs each frame's
camera ROTATION, which it gets free from ARKit. Photos exported from the Photos app carry no pose
(EXIF has no reliable scene-relative orientation). Three options, in increasing cost:
1. **App stitches, web displays** (what PLAN.md assumes, cheapest): the phone produces the
   panorama and uploads that. `web/viewer/index.html` already renders it. No new algorithm.
2. **App exports poses alongside photos**: sweep writes a JSON sidecar of per-frame transform +
   intrinsics; the web stitches using the SAME inverse-projection maths. Moderate work, reuses
   all the verified geometry. Still requires capture through the app.
3. **True pose-free stitching in the browser** (feature detection → matching → bundle adjustment,
   i.e. what Hugin/OpenCV `Stitcher` do): the only option that accepts arbitrary photos taken
   with the stock Camera app. This is a project in itself, not an afternoon, and is unreliable on
   blank walls where there are no features to match. Do not start it without deciding it is the
   product.
- **Option 1 chosen and built: phone stitches, web displays.** User picked it over pose-export or
  browser-side feature matching. Two pieces were missing and are now in:
  - `Sources/App.swift` `exportForSharing()` + `ShareSheet` — a Share button next to Save to
    Photos. Writes the panorama to a temp JPEG (quality 0.9) and opens `UIActivityViewController`,
    so it can go out by AirDrop, Files, or any cloud drive. JPEG not PNG: a 4096×2048 PNG of a
    photographic panorama is tens of MB and AirDrop/email handle it badly. Filename embeds
    "equirect-4096x2048" because most 360 viewers detect the format from the 2:1 aspect ratio and
    a human needs to recognise it too. `ShareItem` exists only because `.sheet(item:)` needs an
    Identifiable and `URL` is not one.
  - `web/viewer/index.html` — "Open panorama…" button, plus drag-and-drop onto the view. Reads via
    `FileReader` entirely client-side; nothing is uploaded anywhere, so no backend is needed for
    the loop to close. Also added a `MAX_TEXTURE_SIZE` guard: a panorama wider than the GPU limit
    fails SILENTLY to a black sphere rather than throwing, so oversized images are downscaled
    through a canvas first, preserving the 2:1 ratio.
  Verified: iOS compiles arm64 0 errors/0 warnings; harness ALL CHECKS PASSED; viewer HTML parses
  and its JS passes a syntax check.
  NOT verified: no live browser run of the file-open path (the Chrome extension is not connected
  in this environment), and no device run of the share sheet. Both are straightforward paths but
  neither has been exercised.

### The phone → web loop (option 1), end to end
1. Sweep the room in the app; it captures continuously until coverage reads ~100%.
2. Tap Finish Sweep → stitches on device → 360 preview opens.
3. Tap **Share** → AirDrop to the Mac, or save to Files/iCloud.
4. Open `web/viewer/index.html` in a browser → **Open panorama…** (or drag the file in).
No server, no upload, no credentials. When Supabase lands later, the viewer already accepts
`?pano=<url>` so hosting is a drop-in replacement for the file picker, not a rewrite.

## FIRST DEVICE RUN — the assumptions that held and the three that broke
Evidence: user screen recording, walk-in closet, 33 frames, 97.9% coverage reported in-app.

**HELD (stop worrying about these):**
- **ARKit intrinsics match the stitcher's convention.** This was the top risk all session and it
  is now settled by evidence: wall/ceiling edges, shelf edges and door frames render as STRAIGHT
  lines in the output. A convention mismatch would have produced an unrecognisable image.
  `p_cv = (x,−y,−z)` with `u = fx·x/(−z)+cx`, `v = cy−fy·y/(−z)` is CORRECT on real hardware.
- The whole pipeline runs on device: AR capture → coverage tracking → on-device stitch →
  SceneKit 360 viewer → Save/Share. The room is recognisable and navigable.
- SceneKit sphere orientation is right — not mirrored. The `scale = (-1,1,1)` + `isDoubleSided`
  recipe was correct; that was a guess and it can now be treated as verified.

**BROKE — 1. Smearing, worst on the CLOSEST objects (hanging clothes).**
Diagnosis: parallax, not blur and not a stitching bug. The user rotated their BODY, swinging the
phone on a ~30 cm arc. A panorama assumes all rays leave ONE point; moving the viewpoint shifts
near objects between frames while distant walls barely move — which is exactly the observed
pattern (clothes smeared, far walls sharp). Two fixes:
  - `CaptureQuality.maxTranslationMeters` = 0.12 — frames captured more than 12 cm from the sweep
    origin are REJECTED. Costs a little coverage, buys a lot of sharpness.
  - `App.swift` shows a yellow warning while drifting: "pivot around the phone, not your body".
    This is the highest-value string in the app; the user cannot otherwise see it happening.

**BROKE — 2. Only 33 frames captured of a possible ~130.**
Diagnosis: `maxAngularStepRadians` was 0.6°/frame, derived from an assumed 60 Hz. ARKit actually
delivers frames much slower while YCbCr→RGBA conversion occupies the session queue, so the real
per-frame angular step is far larger and almost every frame was rejected as "too fast".
Fix: 0.6° → **2.5°**/frame. Do not tune this from theoretical frame rates again — measure.

**BROKE — 3. Black wedges (2% of the sphere) read as tears in the room.**
Two fixes, and they are different in kind:
  - `PanoramaStitcher.fillHoles` — fills every uncovered pixel over float RGB before quantising.
    This does NOT invent detail and is NOT a substitute for covering the sphere.
  - `Result.coverage` is still measured BEFORE filling, so the reported number stays honest.

**Dilation was the first attempt at that fill and was WRONG — replaced by pull-push.**
(`PanoramaStitcher.swift:62-230`, dilation → image-pyramid fill.) Dilation costs one full
4096×2048 pass per PIXEL of gap radius, so 12 passes closed only ~24 px (~2°). The wedges in the
recording are hundreds of pixels across, so the middle of every one stayed black — the exact
failure the fill existed to prevent — while still paying 12 scans of 8.4 M pixels plus a Swift
`Dictionary` per pass. Pull-push (`downsample` pull, `push` + `bilinear` push) closes a hole of
ANY size in one pass down the pyramid and one back up, ~1.33× the canvas in total work, and
interpolates the gap's border instead of iterating a blur. Longitude wraps at every level.
Verified: 27-of-44-target sweep at production 4096×2048 → **96.33% real coverage, 0 black pixels
remaining, 0.56 s** (that pre-fill number is deliberately close to the device run's 97.9%);
harness at 78.6% real coverage → 100% non-black.

**`Result.coverage` is now SOLID ANGLE, not an equirect pixel count** (`PanoramaStitcher.swift`
`compose`, per-row `cos(lat)` weighting). The UI in the recording said "97.9% of the sphere
covered" while quoting a pixel fraction — an equirect canvas spends as many pixels on the 1°
zenith cap as on a 1° band at the horizon, so that string was simply false, and the changelog
already warned "never gate on it directly". Now the string is true and the warning is obsolete.
Verified: harness reports 78.6% for the 24-frame synthetic sweep, matching PlanSweep's
INDEPENDENT analytic solid-angle figure for the same plan to the decimal.

**Removed the `minimumWeight = 1e-4` floor on the blend weight** (`PanoramaStitcher.project`).
It was added so a pixel seen only near a frame's edge still got colour, but it DOMINATES wherever
every frame sees a direction near its edge — precisely the overlap band where seams live. There
the new feather⁶ weight collapsed back into a flat average of two misaligned frames: maximum
ghosting, in the one place it hurts most. Coverage is now tracked as "did any frame sample this"
(`weight > 0`) rather than by a weight threshold, so no floor is needed to keep those pixels lit;
`edgeMargin` keeps the feather strictly positive (≥1.7e-17, far above Float underflow).

**The `StitchHarness` coverage gate had gone blind and was repaired in the same change.**
It re-measured coverage by counting non-black pixels IN THE OUTPUT IMAGE — which, once holes are
filled, means "not black", not "captured", so it would have reported 100% for a sweep that saw
nothing. It now gates on `result.coverage` (honest, pre-fill) and adds a SECOND gate that no
output pixel is black post-fill. The latitude-band table is retained but relabelled a diagnostic.

**UI: the preview label now says "captured", and admits when it filled.** With black tears gone
the user can no longer see at a glance that something was missing — an interpolated patch looks
like a soft patch of real room. Below `goodCoverage` the preview adds "The rest was filled in from
its surroundings — sweep the gaps for real detail." (`App.swift`, `coverageSummary`.)

**Also changed: blend weight exponent feather² → feather⁶** (`PanoramaStitcher`). A broad weight
averages parallax mismatch into a smear; a sharply peaked one lets the frame that sees a direction
most centrally dominate. This is the ghosting/seam dial — raise it for sharpness, lower it if hard
seams appear. Verified: harness MAE unchanged at 1.26, so sharpening cost no geometric accuracy.

### Do not repeat these mistakes
- Do not derive capture timing constants from assumed frame rates. ARKit's delivery rate depends
  on what the session queue is doing. Measure on device.
- Do not treat smearing as a blending bug. If NEAR objects smear and FAR ones are sharp, it is
  parallax, i.e. a capture-technique problem, and no stitcher change will fix it properly.
- Do not raise coverage by painting holes. Hole filling is cosmetic; coverage is captured or not.
- Do not measure coverage from the OUTPUT IMAGE. Post-fill, "non-black" is not "captured", and any
  check written that way silently passes everything. Measure from the weight buffer, pre-fill.
- Do not close gaps with iterative dilation. Cost scales with gap RADIUS × canvas, and a truncated
  run leaves the middle of every large gap black. Pull-push is O(canvas) for any hole size.
- Do not put a constant floor under the blend weight. It only binds where all weights are small,
  which is the overlap band, which is where a flat average does the most visible damage.
- Do not assume smearing is a two-frame SEAM problem. Count the frames per direction first
  (frames × frustum solid angle ÷ covered solid angle). A free-form sweep reaches ~5, and a
  five-way average is mush everywhere, which no seam fix addresses.
- Do not tune the blend with the feather exponent alone. One exponent cannot both rank frames and
  exclude them; that is the trade that forces "mush or hard seams". Rank with the feather, exclude
  with `dominanceThreshold`.
- Do not raise `dominanceThreshold` on the strength of `Tests/ParallaxSharpness` alone — that
  scene has uniform exposure and is blind to the seam/brightness-step cost of a harder cutoff.
  Run 3 settled it at 0.5: sharp, no seams. Leave it.
- Do not HARD-REJECT frames on a quality signal when the alternative is missing sphere. It cost
  half the room for two runs. Down-weight instead and let `dominanceThreshold` do the excluding —
  a mediocre frame beats an interpolated hole, and only ever wins where there is no competition.
- Do not judge a capture gate by frame COUNT. Runs 2 and 3 stored MORE frames than run 1 while
  covering half as much sphere: the gate was amputating directions, not thinning evenly.
- Do not tell the user to "turn toward the markers" when the markers are 3D objects that may be
  off screen. Name the direction. The markers can only guide toward what is already visible,
  which excludes exactly the floor and cap directions that go missing.
- Do not put user-facing GEOMETRY in `Capture.swift`. It imports ARKit, so it cannot be host
  tested, and a sign error in a left/right instruction is both invisible in review and actively
  harmful — the user follows it and coverage gets worse. Put it in `SweepGeometry.swift`.
- Do not judge stitch sharpness from a downscaled screen-recording frame. Extract at native
  resolution (`ffmpeg -ss T -i REC -frames:v 1 -vf crop=W:H:X:Y`) — a 420 px preview makes a sharp
  panorama and a mushy one look identical, which nearly cost a wrong diagnosis.
